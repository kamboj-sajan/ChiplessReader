import Foundation

/// The chipless reader SDK: connect to the reader (STM32 over USB, or the virtual reader),
/// configure it and read tags. Mirrors the chipped reader SDK's Get/Set style.
///
/// ```swift
/// let reader = ChiplessReader(port: "/dev/cu.usbmodem3771385A31")
/// try reader.connect()
/// try reader.setProfile(.standard(bits: 10))       // 10 bits across 860-865 MHz
/// try reader.setTxPower(.plus5dBm, paEnabled: true)
/// try reader.setReferenceAttenuation(dB: 24)
/// try reader.putDatabaseEntry(TagDatabaseEntry(name: "Pallet 7", bitString: "1010110011")!)
/// let tag = try reader.readTag()                    // sweep + decode + lookup on the STM32
/// print(tag.name, tag.bitString, tag.rssiDBm, tag.marginDB)
/// ```
///
/// Calls are synchronous and thread-safe (one request on the wire at a time). Run them off the
/// main thread in a UI. Tag reports pushed by the reader in AUTO mode arrive on `onTagReport`
/// (on a background queue).
public final class ChiplessReader {
    public let portPath: String
    public var timeout: TimeInterval = 3.0
    /// Tag reports pushed by the reader in AUTO mode.
    public var onTagReport: ((TagReport) -> Void)?
    /// "TX A5 …" / "RX A5 …" lines for a raw frame log.
    public var onFrameLog: ((String) -> Void)?
    /// The port closed underneath us (USB unplugged, virtual reader stopped).
    public var onDisconnect: ((String) -> Void)?

    private var port: SerialPort?
    private let parser = ChiplessFrameParser()
    private let cond = NSCondition()
    private var awaiting: UInt8?
    private var reply: ChiplessFrame?
    private let requestLock = NSLock()
    private let events = DispatchQueue(label: "ChiplessKit.events")

    public init(port: String, baudRate: Int = 115_200) {
        self.portPath = port
        self.baud = baudRate
    }
    private let baud: Int

    public var isConnected: Bool { port?.isOpen ?? false }

    // MARK: - Connection

    public func connect() throws {
        if isConnected { return }
        let p = SerialPort(path: portPath, baudRate: baud)
        p.onData = { [weak self] bytes in self?.handleIncoming(bytes) }
        p.onClose = { [weak self] reason in
            guard let self else { return }
            self.events.async { self.onDisconnect?(reason) }
        }
        try p.open()
        port = p
        parser.reset()
    }

    public func disconnect() {
        port?.close()
        port = nil
    }

    // MARK: - Finding the reader

    /// Ask one serial port whether a chipless reader is on it (sends GET_INFO).
    /// Returns nil if the port can't be opened or nothing answers - e.g. the ST-LINK's own
    /// virtual COM port, which also shows up as /dev/cu.usbmodem… on the Mac.
    public static func probe(port: String, timeout: TimeInterval = 1.0) -> ReaderInfo? {
        let r = ChiplessReader(port: port)
        r.timeout = timeout
        do { try r.connect() } catch { return nil }
        defer { r.disconnect() }
        return try? r.getInfo()
    }

    /// Probe every candidate port (`SerialPort.candidatePorts()`); returns the ones with a reader.
    public static func findReaders(timeout: TimeInterval = 1.0) -> [(port: String, info: ReaderInfo)] {
        SerialPort.candidatePorts().compactMap { p in probe(port: p, timeout: timeout).map { (port: p, info: $0) } }
    }

    // MARK: - Raw request / reply

    /// Send one command and wait for its reply. Throws if the reader answers with a non-OK status.
    @discardableResult
    public func request(_ command: ChiplessCommand, payload: [UInt8] = [], timeout: TimeInterval? = nil) throws -> [UInt8] {
        let frame = try exchange(command.rawValue, payload: payload, timeout: timeout ?? self.timeout)
        guard frame.status == ChiplessStatus.ok.rawValue else {
            let st = ChiplessStatus(rawValue: frame.status)?.description ?? String(format: "0x%02X", frame.status)
            throw ChiplessError.readerStatus(command: command.name, status: st)
        }
        return frame.payload
    }

    /// Low-level: send any command byte (even unknown ones) and return the raw reply frame.
    public func exchange(_ command: UInt8, payload: [UInt8] = [], timeout: TimeInterval = 3.0) throws -> ChiplessFrame {
        try exchangeRaw(ChiplessCodec.encode(command: command, payload: payload), expecting: command, timeout: timeout)
    }

    /// Lowest level: write arbitrary bytes and wait for a reply to `expecting`.
    public func exchangeRaw(_ bytes: [UInt8], expecting command: UInt8, timeout: TimeInterval = 3.0) throws -> ChiplessFrame {
        requestLock.lock()
        defer { requestLock.unlock() }
        guard let port, port.isOpen else { throw ChiplessError.notConnected }

        cond.lock()
        awaiting = ChiplessCommand.replyCode(for: command)
        reply = nil
        cond.unlock()

        onFrameLog?("TX " + hexString(bytes))
        try port.write(bytes)

        let deadline = Date().addingTimeInterval(timeout)
        cond.lock()
        while reply == nil {
            if !cond.wait(until: deadline) { break }
        }
        let r = reply
        awaiting = nil
        reply = nil
        cond.unlock()

        guard let r else {
            throw ChiplessError.timeout(ChiplessCommand(rawValue: command)?.name ?? String(format: "0x%02X", command))
        }
        return r
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        for f in parser.feed(bytes) {
            onFrameLog?("RX " + hexString(ChiplessCodec.encode(f)))
            if f.command == ChiplessCommand.tagReportEvent {
                if let report = try? ChiplessReader.parseTagReport(f.payload) {
                    events.async { [weak self] in self?.onTagReport?(report) }
                }
                continue
            }
            cond.lock()
            if let a = awaiting, a == f.command {
                reply = f
                cond.signal()
            }
            cond.unlock()
        }
    }

    // MARK: - Device

    public func getInfo() throws -> ReaderInfo {
        var r = ByteReader(try request(.getInfo))
        let major = try r.u8(), minor = try r.u8(), hw = try r.u8(), sim = try r.u8()
        let uid = hexString(try r.bytes(12), separator: "")
        let model = try r.string(16)
        return ReaderInfo(firmwareVersion: "\(major).\(minor)", hardwareRevision: Int(hw),
                          simulatedFrontEnd: sim != 0, uid: uid, model: model)
    }

    public func ping(_ token: UInt32 = UInt32.random(in: 0...UInt32.max)) throws -> Bool {
        var w = ByteWriter(); w.u32(token)
        var r = ByteReader(try request(.ping, payload: w.bytes))
        return try r.u32() == token
    }

    public func getStatus() throws -> ReaderStatus {
        var r = ByteReader(try request(.getStatus))
        return ReaderStatus(mode: ReaderMode(rawValue: try r.u8()) ?? .response, pllLocked: try r.u8() != 0,
                            backgroundCaptured: try r.u8() != 0, loKHz: try r.u32(), uptimeMs: try r.u32(),
                            framesOK: try r.u32(), framesWithErrors: try r.u32(), reads: try r.u32(),
                            tagsFound: try r.u32(), txPowerDBm: Double(try r.i16()) / 10)
    }

    public func getConfig() throws -> ReaderConfig {
        var r = ByteReader(try request(.getConfig))
        return ReaderConfig(loKHz: try r.u32(), sweepStartKHz: try r.u32(), sweepStopKHz: try r.u32(),
                            sweepStepKHz: try r.u32(), txLevel: TxPowerLevel(rawValue: try r.u8()) ?? .plus5dBm,
                            paEnabled: try r.u8() != 0, refAttenuationDB: Double(try r.u8()) / 2,
                            settleMicroseconds: try r.u16(), averages: try r.u8(),
                            thresholdDB: Double(try r.u16()) / 10, bitCount: Int(try r.u8()),
                            mode: ReaderMode(rawValue: try r.u8()) ?? .response, autoIntervalMs: try r.u16())
    }

    /// Restore the default settings and calibration in the reader's memory. The database is kept.
    public func resetConfig() throws { try request(.resetConfig) }

    /// Store the current settings, calibration and tag database in the reader's flash.
    public func saveToFlash() throws { try request(.saveToFlash, timeout: max(timeout, 5)) }

    /// RESPONSE: the reader acts only on commands. AUTO: it reads continuously and pushes
    /// `TagReport`s to `onTagReport`. Configuration commands are refused (BUSY) in AUTO mode.
    public func setMode(_ mode: ReaderMode, intervalMs: UInt16 = 250) throws {
        var w = ByteWriter(); w.u8(mode.rawValue); w.u16(intervalMs)
        try request(.setMode, payload: w.bytes)
    }

    // MARK: - RF configuration (the chipless equivalent of region / frequency / power / Rx config)

    /// Park the local oscillator (ADF4351) on one frequency. The STM32 computes the registers,
    /// writes them over SPI and reports PLL lock.
    @discardableResult
    public func setLO(kHz: UInt32) throws -> LOResult {
        var w = ByteWriter(); w.u32(kHz)
        var r = ByteReader(try request(.setLO, payload: w.bytes))
        var res = LOResult(requestedKHz: try r.u32(), locked: try r.u8() != 0, actualHz: try r.u32(),
                           int: try r.u16(), frac: try r.u16(), mod: try r.u16(), rfDivider: try r.u8(),
                           vcoKHz: try r.u32(), registers: [])
        for _ in 0..<6 { res.registers.append(try r.u32()) }
        return res
    }

    /// Frequency sweep used for every tag read (start = stop gives a single fixed tone).
    @discardableResult
    public func setSweep(startKHz: UInt32, stopKHz: UInt32, stepKHz: UInt32) throws -> Int {
        var w = ByteWriter(); w.u32(startKHz); w.u32(stopKHz); w.u32(stepKHz)
        var r = ByteReader(try request(.setSweep, payload: w.bytes))
        _ = try r.bytes(12)
        return Int(try r.u16())
    }

    /// ADF4351 output level and PA (MAX2235) on/off. Returns the calibrated TX power at the antenna.
    @discardableResult
    public func setTxPower(_ level: TxPowerLevel, paEnabled: Bool = true) throws -> Double {
        var r = ByteReader(try request(.setTxPower, payload: [level.rawValue, paEnabled ? 1 : 0]))
        _ = try r.bytes(2)
        return Double(try r.i16()) / 10
    }

    /// PE4312 reference attenuator (0…31.5 dB in 0.5 dB steps) - levels the AD8302 reference
    /// input to the echo. Returns the estimated reference level at AD8302 INPA (dBm).
    /// The reader refuses a setting that would put INPA above the AD8302's 0 dBm input limit.
    @discardableResult
    public func setReferenceAttenuation(dB: Double) throws -> Double {
        try setReferenceAttenuationReportingLimit(dB: dB).inpaDBm
    }

    /// Same as `setReferenceAttenuation(dB:)`, also returning the lowest setting allowed at this TX level.
    @discardableResult
    public func setReferenceAttenuationReportingLimit(dB: Double) throws -> (inpaDBm: Double, minimumDB: Double) {
        guard dB >= 0, dB <= 31.5 else { throw ChiplessError.invalidArgument("attenuation must be 0…31.5 dB") }
        var r = ByteReader(try request(.setRxConfig, payload: [UInt8((dB * 2).rounded())]))
        _ = try r.u8()
        let inpa = Double(try r.i16()) / 10
        return (inpa, Double(try r.u8()) / 2)
    }

    /// Hold the PA on at the current LO frequency, for checking the output on a spectrum analyser.
    /// Otherwise the PA only runs during measurements.
    public func setCarrier(_ on: Bool) throws {
        try request(.setCarrier, payload: [on ? 1 : 0])
    }

    /// Settling time after each frequency step and ADC samples averaged per point.
    public func setAcquisition(settleMicroseconds: UInt16, averages: UInt8) throws {
        var w = ByteWriter(); w.u16(settleMicroseconds); w.u8(averages)
        try request(.setAcquisition, payload: w.bytes)
    }

    public func setDetection(_ d: DetectionSettings) throws {
        var w = ByteWriter()
        w.u16(UInt16((d.thresholdDB * 10).rounded()))
        w.u8(UInt8(d.bitFrequenciesKHz.count))
        for f in d.bitFrequenciesKHz { w.u32(f) }
        try request(.setDetection, payload: w.bytes)
    }

    public func getDetection() throws -> DetectionSettings {
        var r = ByteReader(try request(.getDetection))
        let thr = Double(try r.u16()) / 10
        let n = Int(try r.u8())
        var f: [UInt32] = []
        for _ in 0..<n { f.append(try r.u32()) }
        return DetectionSettings(thresholdDB: thr, bitFrequenciesKHz: f)
    }

    // MARK: - Tag profile

    /// Send the complete tag profile (sweep, bit frequencies, read rate, decision settings) at once.
    @discardableResult
    public func setProfile(_ p: TagProfile) throws -> TagProfile {
        guard (1...16).contains(p.bitFrequenciesKHz.count) else { throw ChiplessError.invalidArgument("a profile needs 1…16 bits") }
        var w = ByteWriter()
        let name = Array(p.name.utf8.prefix(16))
        for b in name { w.u8(b) }
        for _ in name.count..<16 { w.u8(0) }
        w.u32(p.sweepStartKHz); w.u32(p.sweepStopKHz); w.u32(p.sweepStepKHz)
        w.u16(p.settleMicroseconds); w.u8(p.averages)
        w.u16(UInt16((p.thresholdDB * 10).rounded())); w.u16(UInt16((p.phaseThresholdDegrees * 10).rounded()))
        w.u16(p.autoIntervalMs); w.u8(p.maxBitErrors); w.u8(UInt8(p.bitFrequenciesKHz.count))
        for f in p.bitFrequenciesKHz { w.u32(f) }
        return try ChiplessReader.parseProfile(try request(.setProfile, payload: w.bytes))
    }

    public func getProfile() throws -> TagProfile {
        try ChiplessReader.parseProfile(try request(.getProfile))
    }

    static func parseProfile(_ payload: [UInt8]) throws -> TagProfile {
        var r = ByteReader(payload)
        let name = try r.string(16)
        let start = try r.u32(), stop = try r.u32(), step = try r.u32()
        let settle = try r.u16(), avg = try r.u8()
        let thr = Double(try r.u16()) / 10, phase = Double(try r.u16()) / 10
        let interval = try r.u16(), errs = try r.u8(), n = Int(try r.u8())
        var bits: [UInt32] = []
        for _ in 0..<n { bits.append(try r.u32()) }
        return TagProfile(name: name, sweepStartKHz: start, sweepStopKHz: stop, sweepStepKHz: step,
                          settleMicroseconds: settle, averages: avg, thresholdDB: thr, phaseThresholdDegrees: phase,
                          autoIntervalMs: interval, maxBitErrors: errs, bitFrequenciesKHz: bits)
    }

    // MARK: - Tag database on the reader

    /// Every tag in the reader's database, plus how many it can hold.
    public func databaseEntries() throws -> (entries: [TagDatabaseEntry], capacity: Int) {
        var info = ByteReader(try request(.databaseInfo))
        let count = Int(try info.u16()), capacity = Int(try info.u16())
        var out: [TagDatabaseEntry] = []
        for i in 0..<count {
            var w = ByteWriter(); w.u16(UInt16(i))
            var r = ByteReader(try request(.databaseGet, payload: w.bytes))
            _ = try r.u16()
            let id = try r.u32(), bits = Int(try r.u8())
            out.append(TagDatabaseEntry(name: try r.string(16), tagID: id, bitCount: bits))
        }
        return (out, capacity)
    }

    /// Add a tag, or rename it if that pattern is already there.
    public func putDatabaseEntry(_ e: TagDatabaseEntry) throws {
        var w = ByteWriter()
        w.u32(e.tagID); w.u8(UInt8(e.bitCount))
        for b in e.name.utf8.prefix(16) { w.u8(b) }
        try request(.databasePut, payload: w.bytes)
    }

    public func deleteDatabaseEntry(_ e: TagDatabaseEntry) throws {
        var w = ByteWriter()
        w.u32(e.tagID); w.u8(UInt8(e.bitCount))
        try request(.databaseDelete, payload: w.bytes)
    }

    public func clearDatabase() throws { try request(.databaseClear) }

    // MARK: - Calibration

    public func getCalibration() throws -> RFCalibration {
        try ChiplessReader.parseCalibration(try request(.getCalibration))
    }

    @discardableResult
    public func setCalibration(_ c: RFCalibration) throws -> RFCalibration {
        var w = ByteWriter()
        let v = [c.txFilterLossDB, c.paTrimDB, c.couplerDB, c.couplerThroughLossDB, c.attenuatorInsertionLossDB,
                 c.lnaGainDB, c.rxFilterLossDB, c.vmagCenterMillivolts / 10, c.vmagSlopeMillivoltsPerDB,
                 c.vphsCenterMillivolts / 10, c.vphsSlopeMillivoltsPerDegree, c.rssiTrimDB]
        for x in v { w.i16(Int16((x * 100).rounded())) }
        return try ChiplessReader.parseCalibration(try request(.setCalibration, payload: w.bytes))
    }

    static func parseCalibration(_ payload: [UInt8]) throws -> RFCalibration {
        var r = ByteReader(payload)
        func next() throws -> Double { Double(try r.i16()) / 100 }
        return RFCalibration(txFilterLossDB: try next(), paTrimDB: try next(), couplerDB: try next(),
                             couplerThroughLossDB: try next(), attenuatorInsertionLossDB: try next(),
                             lnaGainDB: try next(), rxFilterLossDB: try next(), vmagCenterMillivolts: try next() * 10,
                             vmagSlopeMillivoltsPerDB: try next(), vphsCenterMillivolts: try next() * 10,
                             vphsSlopeMillivoltsPerDegree: try next(), rssiTrimDB: try next())
    }

    /// Step the attenuator at the current LO and record VMAG at each setting. A straight line shows the
    /// PE4312 is wired correctly, and its slope is the AD8302's mV/dB. Starts at the safe minimum setting.
    public func attenuatorScan(stepDB: Double = 1) throws -> [AttenuatorScanPoint] {
        var r = ByteReader(try request(.attenuatorScan, payload: [UInt8((stepDB * 2).rounded())], timeout: max(timeout, 10)))
        let n = Int(try r.u8())
        var out: [AttenuatorScanPoint] = []
        for _ in 0..<n {
            out.append(AttenuatorScanPoint(attenuationDB: Double(try r.u8()) / 2, vmagMillivolts: try r.u16(),
                                           gainDB: Double(try r.i16()) / 100, inpaDBm: Double(try r.i16()) / 10,
                                           conditions: RFConditions(rawValue: try r.u8())))
        }
        return out
    }

    /// Find and apply the attenuator setting that centres the AD8302 on what a sweep sees.
    public func autoLevel() throws -> AutoLevelResult {
        var r = ByteReader(try request(.autoLevel, timeout: max(timeout, 10)))
        return AutoLevelResult(oldAttenuationDB: Double(try r.u8()) / 2, newAttenuationDB: Double(try r.u8()) / 2,
                               gainMinDB: Double(try r.i16()) / 100, gainMaxDB: Double(try r.i16()) / 100,
                               inpaDBm: Double(try r.i16()) / 10, clippedPoints: Int(try r.u16()),
                               conditions: RFConditions(rawValue: try r.u8()), iterations: Int(try r.u8()))
    }

    // MARK: - Measurements and tag reads

    /// One AD8302 reading at the current LO frequency.
    public func measure() throws -> RFMeasurement {
        var r = ByteReader(try request(.measure))
        return RFMeasurement(loKHz: try r.u32(), adcMagnitude: try r.u16(), adcPhase: try r.u16(),
                           vmagMillivolts: try r.u16(), vphsMillivolts: try r.u16(),
                           gainDB: Double(try r.i16()) / 100, phaseDegrees: Double(try r.u16()) / 10,
                           referenceDBm: Double(try r.i16()) / 10, receivedDBm: Double(try r.i16()) / 10,
                           rssiDBm: Double(try r.i16()) / 10, clipped: try r.u8() != 0, pllLocked: try r.u8() != 0,
                           conditions: RFConditions(rawValue: try r.u8()))
    }

    /// Sweep + decode on the reader: the chipless equivalent of a single inventory round.
    public func readTag() throws -> TagReport {
        try ChiplessReader.parseTagReport(try request(.readTag, timeout: max(timeout, 10)))
    }

    /// Sweep with no tag present and store it; later reads subtract it (removes antenna leakage).
    @discardableResult
    public func captureBackground() throws -> (points: Int, milliseconds: Int) {
        var r = ByteReader(try request(.captureBackground, timeout: max(timeout, 10)))
        return (Int(try r.u16()), Int(try r.u16()))
    }

    public func clearBackground() throws { try request(.clearBackground) }

    /// The raw data of the most recent sweep (for plotting / export).
    public func sweepData() throws -> [SweepPoint] {
        var points: [SweepPoint] = []
        var offset: UInt16 = 0
        while true {
            var w = ByteWriter(); w.u16(offset); w.u16(160)
            var r = ByteReader(try request(.getSweepData, payload: w.bytes))
            let total = try r.u16(), off = try r.u16(), count = try r.u16()
            let start = try r.u32(), step = try r.u32()
            _ = try r.u8()
            for i in 0..<Int(count) {
                let rx = try r.i16(), ph = try r.u16(), bg = try r.i16()
                points.append(SweepPoint(frequencyMHz: Double(start + (UInt32(off) + UInt32(i)) * step) / 1000,
                                         receivedDBm: Double(rx) / 100, phaseDegrees: Double(ph) / 10,
                                         backgroundDBm: bg == Int16.min ? nil : Double(bg) / 100))
            }
            offset = off + count
            if offset >= total || count == 0 { return points }
        }
    }

    public static func parseTagReport(_ payload: [UInt8]) throws -> TagReport {
        var r = ByteReader(payload)
        let seq = try r.u32(), found = try r.u8() != 0, n = Int(try r.u8()), id = try r.u32()
        let rssi = Double(try r.i16()) / 10, phase = Double(try r.u16()) / 10, margin = Double(try r.i16()) / 10
        let ms = Int(try r.u16()), pts = Int(try r.u16()), bg = try r.u8() != 0
        let clip = Int(try r.u16()), unl = Int(try r.u16())
        var depths: [Double] = []
        for _ in 0..<n { depths.append(Double(try r.i16()) / 10) }
        var swings: [Double] = []
        for _ in 0..<n { swings.append(Double(try r.i16()) / 10) }
        let matched = try r.u8() != 0, errs = Int(try r.u8()), dbIndex = Int(try r.i16())
        let name = try r.string(16)
        return TagReport(sequence: seq, found: found, bitCount: n, id: id, rssiDBm: rssi, phaseDegrees: phase,
                         marginDB: margin, sweepMilliseconds: ms, points: pts, backgroundSubtracted: bg,
                         clippedPoints: clip, unlockedPoints: unl, notchDepthsDB: depths, phaseSwingsDegrees: swings,
                         matched: matched, bitErrors: errs, databaseIndex: dbIndex < 0 ? nil : dbIndex,
                         name: name, timestamp: Date())
    }

    // MARK: - Simulation (virtual reader / STM32 built with the simulated RF backend)

    public func getSimulation() throws -> SimulationState {
        try ChiplessReader.parseSimulation(try request(.simGet))
    }

    /// Place a simulated tag in front of the antennas (nil = remove it), at a distance, with noise.
    @discardableResult
    public func setSimulation(tagIndex: Int?, distanceCm: Int = 20, noiseDB: Double = 0.05, resonatorQ: Int? = nil) throws -> SimulationState {
        var w = ByteWriter()
        w.i8(Int8(tagIndex ?? -1))
        w.u16(UInt16(distanceCm))
        w.u16(UInt16((noiseDB * 100).rounded()))
        if let resonatorQ { w.u16(UInt16(resonatorQ)) }
        return try ChiplessReader.parseSimulation(try request(.simSet, payload: w.bytes))
    }

    static func parseSimulation(_ p: [UInt8]) throws -> SimulationState {
        var r = ByteReader(p)
        let idx = Int(try r.i8()), dist = Int(try r.u16()), noise = Double(try r.u16()) / 100
        let q = Int(try r.u16())
        let nt = Int(try r.u8())
        var tags: [SimulatedTag] = []
        for i in 0..<nt {
            let code = try r.u32(), name = try r.string(12), bits = Int(try r.u8())
            tags.append(SimulatedTag(index: i, name: name, code: code, bitCount: bits))
        }
        return SimulationState(tagIndex: idx < 0 ? nil : idx, distanceCm: dist, noiseDB: noise, resonatorQ: q, tags: tags)
    }
}

/// Thread-safe by construction: one request at a time under `requestLock`, reply hand-off under
/// `cond`, events delivered on a private serial queue.
extension ChiplessReader: @unchecked Sendable {}
