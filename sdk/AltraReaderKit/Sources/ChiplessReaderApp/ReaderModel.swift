import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ChiplessKit

/// One line of the read history: all reads of the same decoded pattern folded together
/// (like the chipped SDK's inventory list with its detection count).
struct TagRow: Identifiable, Equatable {
    let id: String
    var name: String
    var hexID: String
    var bits: String
    var count: Int
    var rssiDBm: Double
    var marginDB: Double
    var lastSeen: Date
}

struct PlotPoint: Identifiable {
    let id: Int
    let mhz: Double
    let db: Double
    let phase: Double
}

enum AppSection: String, CaseIterable, Identifiable {
    case read = "Read Tags"
    case setup = "Reader Setup"
    case database = "Tag Database"
    case calibration = "Calibration"
    case log = "Log"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .read: return "dot.radiowaves.left.and.right"
        case .setup: return "slider.horizontal.3"
        case .database: return "list.bullet.rectangle"
        case .calibration: return "gauge.with.dots.needle.50percent"
        case .log: return "text.alignleft"
        }
    }
}

enum ConnectionState: Equatable {
    case searching
    case noReader
    case outdatedFirmware(String)
    case connected
}

@MainActor
final class ReaderModel: ObservableObject {
    /// The protocol this app speaks. An older firmware answers the old commands and not the new ones.
    static let requiredFirmware = (major: 0, minor: 3)

    // connection
    @Published var section: AppSection = .read
    @Published var state: ConnectionState = .searching
    @Published var portPath: String = ""
    @Published var ports: [String] = []
    @Published var info: ReaderInfo?
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var demoActive = false
    @Published var unsavedChanges = false

    var isConnected: Bool { state == .connected }
    var canConfigure: Bool { isConnected && !autoMode }

    // tag profile (Reader Setup)
    @Published var profileName = "10-bit 860-865"
    @Published var sweepStartMHz: Double = 860
    @Published var sweepStopMHz: Double = 865
    @Published var sweepStepKHz: Double = 25
    @Published var bitFrequenciesMHz: [Double] = []
    @Published var settleMicroseconds: Double = 200
    @Published var averages: Double = 8
    @Published var readIntervalMs: Double = 250
    @Published var thresholdDB: Double = 6
    @Published var phaseThresholdDegrees: Double = 15
    @Published var maxBitErrors: Int = 0
    @Published var appliedProfile: TagProfile?

    // gain
    @Published var txLevel: TxPowerLevel = .plus5dBm
    @Published var paEnabled = true
    @Published var txPowerDBm: Double?

    // calibration
    @Published var refAttenDB: Double = 24
    @Published var minimumAttenDB: Double = 0
    @Published var inpaDBm: Double?
    @Published var measurement: RFMeasurement?
    @Published var liveMeasure = false
    @Published var autoLevelResult: AutoLevelResult?
    @Published var scan: [AttenuatorScanPoint] = []
    @Published var calibration: RFCalibration = .datasheet
    @Published var loMHz: Double = 862.5
    @Published var loResult: LOResult?
    @Published var carrierOn = false

    // database
    @Published var database: [TagDatabaseEntry] = []
    @Published var databaseCapacity = 64

    // tags
    @Published var rows: [TagRow] = []
    @Published var lastReport: TagReport?
    @Published var totalReads = 0
    @Published var autoMode = false
    @Published var plot: [PlotPoint] = []
    @Published var plotIsBackgroundSubtracted = false
    @Published var backgroundCaptured = false

    // simulation
    @Published var sim: SimulationState?
    @Published var simTagIndex: Int = -1
    @Published var simDistanceCm: Double = 20
    @Published var simQ: Int = 2000

    // log
    @Published var log: [String] = []
    @Published var showFrames = false

    private var reader: ChiplessReader?
    private let io = DispatchQueue(label: "ChiplessReaderApp.io")
    private let demo = DemoReader()
    private var portWatch: Timer?
    private var lastPlotRefresh = Date.distantPast
    private var plotRefreshInFlight = false

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        if CommandLine.arguments.contains("--demo") { toggleDemo() } else { findReader() }
        // a board plugged in later is picked up without pressing anything
        portWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchPorts() }
        }
    }

    private func shutdown() {
        let r = reader
        reader = nil
        if let r {
            try? r.setMode(.response)
            if carrierOn { try? r.setCarrier(false) }
            r.disconnect()
        }
        demo.stop()
    }

    // MARK: - plumbing

    private func appendLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        log.append("[\(f.string(from: Date()))] \(s)")
        if log.count > 800 { log.removeFirst(log.count - 800) }
    }

    /// Run an SDK call off the main thread, then apply the result on the main thread.
    private func perform<T>(_ label: String, _ work: @escaping @Sendable (ChiplessReader) throws -> T,
                            then apply: @escaping (T) -> Void = { _ in }) {
        guard let r = reader else { errorMessage = "Not connected to a reader."; return }
        busy = true
        io.async {
            let result = Result { try work(r) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let v):
                    self.errorMessage = nil
                    apply(v)
                case .failure(let e):
                    self.errorMessage = "\(label): \(e)"
                    self.appendLog("ERROR \(label): \(e)")
                }
            }
        }
    }

    // MARK: - connection

    private func watchPorts() {
        guard !isConnected, !demoActive else { return }
        let now = SerialPort.candidatePorts()
        if now != ports {
            ports = now
            findReader()
        }
    }

    /// Ask every serial port "are you a reader?" and connect to the first that answers.
    func findReader() {
        guard !isConnected, state != .connected else { return }
        state = .searching
        ports = SerialPort.candidatePorts()
        DispatchQueue.global().async {
            let found = ChiplessReader.findReaders(timeout: 0.8)
            Task { @MainActor [weak self] in
                guard let self, !self.isConnected else { return }
                if let first = found.first {
                    self.appendLog("Reader found on \(first.port): \(first.info.model) firmware \(first.info.firmwareVersion)")
                    self.connect(to: first.port)
                } else {
                    self.state = .noReader
                }
            }
        }
    }

    func connect(to port: String) {
        let r = ChiplessReader(port: port)
        portPath = port
        r.onFrameLog = { [weak self] line in
            Task { @MainActor in
                guard let self, self.showFrames else { return }
                self.appendLog(line)
            }
        }
        r.onTagReport = { [weak self] rep in
            Task { @MainActor in self?.ingest(rep, refreshPlot: true) }
        }
        r.onDisconnect = { [weak self] reason in
            Task { @MainActor in self?.handleDisconnect(reason) }
        }
        do {
            try r.connect()
        } catch {
            errorMessage = "\(error)"
            state = .noReader
            return
        }
        reader = r
        busy = true
        io.async {
            r.timeout = 1.5
            let info = try? r.getInfo()
            r.timeout = 3
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                guard let info else {
                    self.reader = nil
                    self.io.async { r.disconnect() }
                    self.state = .noReader
                    self.appendLog("No reader answered on \(port).")
                    return
                }
                if !Self.firmwareIsCurrent(info.firmwareVersion) {
                    self.reader = nil
                    self.io.async { r.disconnect() }
                    self.state = .outdatedFirmware(info.firmwareVersion)
                    self.appendLog("This board runs firmware \(info.firmwareVersion). The app needs \(Self.requiredFirmware.major).\(Self.requiredFirmware.minor) or newer.")
                    return
                }
                self.state = .connected
                self.loadReaderState()
            }
        }
    }

    private static func firmwareIsCurrent(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return (parts[0], parts[1]) >= (requiredFirmware.major, requiredFirmware.minor)
    }

    private func handleDisconnect(_ reason: String) {
        guard reader != nil else { return }
        reader = nil
        state = .noReader
        autoMode = false
        liveMeasure = false
        carrierOn = false
        info = nil
        sim = nil
        appendLog("Reader disconnected: \(reason)")
    }

    /// Everything on screen comes from the reader, so it shows what the reader will really do.
    func loadReaderState() {
        perform("connect", { r -> (ReaderInfo, ReaderConfig, TagProfile, RFCalibration, [TagDatabaseEntry], Int, SimulationState?, ReaderStatus) in
            try r.setMode(.response)
            try r.setCarrier(false)
            let d = try r.databaseEntries()
            return (try r.getInfo(), try r.getConfig(), try r.getProfile(), try r.getCalibration(), d.entries, d.capacity,
                    try? r.getSimulation(), try r.getStatus())
        }, then: { [weak self] (info, cfg, profile, cal, db, cap, sim, status) in
            guard let self else { return }
            self.info = info
            self.loMHz = Double(cfg.loKHz) / 1000
            self.txLevel = cfg.txLevel
            self.paEnabled = cfg.paEnabled
            self.txPowerDBm = status.txPowerDBm
            self.refAttenDB = cfg.refAttenuationDB
            self.loadProfile(profile)
            self.calibration = cal
            self.database = db
            self.databaseCapacity = cap
            self.backgroundCaptured = status.backgroundCaptured
            self.autoMode = false
            self.carrierOn = false
            self.unsavedChanges = false
            self.sim = sim
            if let sim {
                self.simTagIndex = sim.tagIndex ?? -1
                self.simDistanceCm = Double(sim.distanceCm)
                self.simQ = sim.resonatorQ
            }
            self.appendLog("\(info.model) firmware \(info.firmwareVersion), UID \(info.uid), RF front-end \(info.simulatedFrontEnd ? "SIMULATED" : "HARDWARE")")
            self.applyAttenuation(markChanged: false)
        })
    }

    func disconnect() {
        let r = reader
        reader = nil
        io.async { try? r?.setMode(.response); r?.disconnect() }
        autoMode = false
        liveMeasure = false
        carrierOn = false
        info = nil
        sim = nil
        state = .noReader
        appendLog("Disconnected")
    }

    func toggleDemo() {
        if demoActive {
            disconnect()
            demo.stop()
            demoActive = false
            findReader()
            return
        }
        if isConnected { disconnect() }
        do {
            let port = try demo.start { [weak self] line in
                Task { @MainActor in self?.appendLog("reader: " + line) }
            }
            demoActive = true
            appendLog("Demo Mode: the reader firmware is running on this Mac with a simulated RF chain.")
            connect(to: port)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - tag profile

    private func loadProfile(_ p: TagProfile) {
        profileName = p.name
        sweepStartMHz = Double(p.sweepStartKHz) / 1000
        sweepStopMHz = Double(p.sweepStopKHz) / 1000
        sweepStepKHz = Double(p.sweepStepKHz)
        bitFrequenciesMHz = p.bitFrequenciesKHz.map { Double($0) / 1000 }
        settleMicroseconds = Double(p.settleMicroseconds)
        averages = Double(p.averages)
        readIntervalMs = Double(p.autoIntervalMs)
        thresholdDB = p.thresholdDB
        phaseThresholdDegrees = p.phaseThresholdDegrees
        maxBitErrors = Int(p.maxBitErrors)
        appliedProfile = p
    }

    /// The profile as currently entered on the Reader Setup screen.
    var draftProfile: TagProfile {
        TagProfile(name: profileName,
                   sweepStartKHz: UInt32((sweepStartMHz * 1000).rounded()),
                   sweepStopKHz: UInt32((sweepStopMHz * 1000).rounded()),
                   sweepStepKHz: UInt32(max(sweepStepKHz, 1).rounded()),
                   settleMicroseconds: UInt16(settleMicroseconds.rounded()),
                   averages: UInt8(averages.rounded()),
                   thresholdDB: thresholdDB,
                   phaseThresholdDegrees: phaseThresholdDegrees,
                   autoIntervalMs: UInt16(readIntervalMs.rounded()),
                   maxBitErrors: UInt8(maxBitErrors),
                   bitFrequenciesKHz: bitFrequenciesMHz.map { UInt32(($0 * 1000).rounded()) })
    }

    var draftDiffersFromReader: Bool { appliedProfile != nil && draftProfile != appliedProfile }

    /// Spread n bits evenly across the band entered on the Reader Setup screen.
    func setBitCount(_ n: Int) {
        let start = UInt32((sweepStartMHz * 1000).rounded()), stop = UInt32((sweepStopMHz * 1000).rounded())
        guard stop > start else { return }
        bitFrequenciesMHz = TagProfile.evenlySpaced(bits: n, startKHz: start, stopKHz: stop).map { Double($0) / 1000 }
        profileName = n == 1 ? "Single" : n == 2 ? "Double" : "\(n)-bit \(Int(sweepStartMHz))-\(Int(sweepStopMHz))"
    }

    func applyProfile() {
        let p = draftProfile
        perform("Apply settings", { try $0.setProfile(p) }, then: { [weak self] got in
            guard let self else { return }
            let sweepChanged = self.appliedProfile.map {
                ($0.sweepStartKHz, $0.sweepStopKHz, $0.sweepStepKHz) != (got.sweepStartKHz, got.sweepStopKHz, got.sweepStepKHz)
            } ?? true
            if sweepChanged { self.backgroundCaptured = false }
            self.loadProfile(got)
            self.unsavedChanges = true
            self.appendLog("Profile \"\(got.name)\": \(got.bitFrequenciesKHz.count) bits, \(got.sweepPoints) points")
        })
    }

    func applyTxPower() {
        let level = txLevel, pa = paEnabled
        perform("Set gain", { r -> (Double, (inpaDBm: Double, minimumDB: Double)) in
            let tx = try r.setTxPower(level, paEnabled: pa)
            let cfg = try r.getConfig()
            return (tx, try r.setReferenceAttenuationReportingLimit(dB: cfg.refAttenuationDB))
        }, then: { [weak self] (dbm, limit) in
            guard let self else { return }
            self.txPowerDBm = dbm
            self.inpaDBm = limit.inpaDBm
            self.minimumAttenDB = limit.minimumDB
            self.backgroundCaptured = false
            self.unsavedChanges = true
            self.appendLog("ADF4351 \(level), PA \(pa ? "on" : "off") -> TX \(String(format: "%.1f", dbm)) dBm")
        })
    }

    // MARK: - calibration

    func applyAttenuation(markChanged: Bool = true) {
        let db = (refAttenDB * 2).rounded() / 2
        perform("Set attenuator", { try $0.setReferenceAttenuationReportingLimit(dB: db) }, then: { [weak self] limit in
            guard let self else { return }
            self.inpaDBm = limit.inpaDBm
            self.minimumAttenDB = limit.minimumDB
            if markChanged { self.unsavedChanges = true }
            if self.measurement != nil { self.measure() }
            self.appendLog(String(format: "PE4312 %.1f dB -> INPA %.1f dBm", db, limit.inpaDBm))
        })
    }

    func measure() {
        perform("Measure", { try $0.measure() }, then: { [weak self] m in
            self?.measurement = m
        })
    }

    func autoLevel() {
        perform("Auto-level", { try $0.autoLevel() }, then: { [weak self] a in
            guard let self else { return }
            self.autoLevelResult = a
            self.refAttenDB = a.newAttenuationDB
            self.inpaDBm = a.inpaDBm
            self.unsavedChanges = true
            self.measure()
            self.appendLog(String(format: "Auto-level: %.1f -> %.1f dB, gain %+.1f to %+.1f dB", a.oldAttenuationDB, a.newAttenuationDB, a.gainMinDB, a.gainMaxDB))
        })
    }

    func runScan() {
        perform("Attenuator scan", { try $0.attenuatorScan(stepDB: 1) }, then: { [weak self] pts in
            self?.scan = pts
        })
    }

    /// Straight-line fit of VMAG against the attenuator: mV/dB, and the largest departure from the line in dB.
    var scanFit: (slope: Double, worstDB: Double)? {
        let pts = scan.filter { !$0.conditions.contains(.clipped) }
        guard pts.count >= 3 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.attenuationDB).reduce(0, +) / n
        let my = pts.map { Double($0.vmagMillivolts) }.reduce(0, +) / n
        let sxy = pts.reduce(0) { $0 + ($1.attenuationDB - mx) * (Double($1.vmagMillivolts) - my) }
        let sxx = pts.reduce(0) { $0 + pow($1.attenuationDB - mx, 2) }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        guard slope != 0 else { return nil }
        let worst = pts.map { abs(Double($0.vmagMillivolts) - (my + slope * ($0.attenuationDB - mx))) / abs(slope) }.max() ?? 0
        return (abs(slope), worst)
    }

    func useMeasuredSlope() {
        guard let f = scanFit else { return }
        calibration.vmagSlopeMillivoltsPerDB = (f.slope * 100).rounded() / 100
        applyCalibration()
    }

    func applyCalibration() {
        let c = calibration
        perform("Set calibration", { try $0.setCalibration(c) }, then: { [weak self] got in
            self?.calibration = got
            self?.unsavedChanges = true
            self?.appendLog("Calibration updated")
        })
    }

    func resetCalibrationToDatasheet() {
        calibration = .datasheet
        applyCalibration()
    }

    func applyLO() {
        let khz = UInt32((loMHz * 1000).rounded())
        perform("Set frequency", { try $0.setLO(kHz: khz) }, then: { [weak self] lo in
            self?.loResult = lo
            self?.appendLog(String(format: "LO %.3f MHz -> INT %d FRAC %d/%d, RF divider %d, %@", Double(khz) / 1000,
                                   Int(lo.int), Int(lo.frac), Int(lo.mod), Int(lo.rfDivider), lo.locked ? "locked" : "NOT LOCKED"))
        })
    }

    func setCarrier(_ on: Bool) {
        perform("Carrier", { try $0.setCarrier(on) }, then: { [weak self] _ in
            self?.carrierOn = on
            self?.appendLog(on ? "Carrier on" : "Carrier off")
        })
    }

    // MARK: - database

    func refreshDatabase() {
        perform("Read database", { try $0.databaseEntries() }, then: { [weak self] d in
            self?.database = d.entries
            self?.databaseCapacity = d.capacity
        })
    }

    func putEntry(_ e: TagDatabaseEntry, replacing old: TagDatabaseEntry? = nil) {
        perform("Add tag", { r -> (entries: [TagDatabaseEntry], capacity: Int) in
            if let old, old.id != e.id { try r.deleteDatabaseEntry(old) }
            try r.putDatabaseEntry(e)
            return try r.databaseEntries()
        }, then: { [weak self] d in
            self?.database = d.entries
            self?.unsavedChanges = true
            self?.appendLog("Database: \(e.name) = \(e.bitString)")
        })
    }

    func deleteEntries(_ entries: [TagDatabaseEntry]) {
        perform("Delete tag", { r -> (entries: [TagDatabaseEntry], capacity: Int) in
            for e in entries { try r.deleteDatabaseEntry(e) }
            return try r.databaseEntries()
        }, then: { [weak self] d in
            self?.database = d.entries
            self?.unsavedChanges = true
        })
    }

    func importDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let list = try JSONDecoder().decode([TagDatabaseEntry].self, from: Data(contentsOf: url))
            perform("Import tags", { r -> (entries: [TagDatabaseEntry], capacity: Int) in
                for e in list { try r.putDatabaseEntry(e) }
                return try r.databaseEntries()
            }, then: { [weak self] d in
                self?.database = d.entries
                self?.unsavedChanges = true
                self?.appendLog("Imported \(list.count) tags from \(url.lastPathComponent)")
            })
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func exportDatabase() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "chipless-tags.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(database).write(to: url)
            appendLog("Exported \(database.count) tags to \(url.lastPathComponent)")
        } catch {
            errorMessage = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func saveToReader() {
        perform("Save to reader", { try $0.saveToFlash() }, then: { [weak self] _ in
            self?.unsavedChanges = false
            self?.appendLog("Settings, calibration and database stored in the reader's flash")
        })
    }

    func resetReaderSettings() {
        perform("Reset settings", { try $0.resetConfig() }, then: { [weak self] _ in
            self?.loadReaderState()
            self?.unsavedChanges = true
        })
    }

    // MARK: - tags

    func readOnce() {
        perform("Read tag", { r -> (TagReport, [SweepPoint]) in
            let rep = try r.readTag()
            return (rep, try r.sweepData())
        }, then: { [weak self] (rep, pts) in
            self?.ingest(rep, refreshPlot: false)
            self?.setPlot(pts)
        })
    }

    /// With a real tag the operator takes it away first. In Demo Mode the simulated tag is lifted
    /// out for the background sweep and put back afterwards.
    func captureBackground() {
        let index = simTagIndex
        let simulated = sim != nil
        let d = Int(simDistanceCm), q = simQ
        perform("Capture background", { r -> (points: Int, milliseconds: Int) in
            if simulated { _ = try r.setSimulation(tagIndex: nil, distanceCm: d, resonatorQ: q) }
            let res = try r.captureBackground()
            if simulated { _ = try r.setSimulation(tagIndex: index < 0 ? nil : index, distanceCm: d, resonatorQ: q) }
            return res
        }, then: { [weak self] res in
            self?.backgroundCaptured = true
            self?.appendLog("Background captured: \(res.points) points in \(res.milliseconds) ms")
        })
    }

    func toggleAuto() {
        let enable = !autoMode
        let interval = UInt16(max(50, readIntervalMs.rounded()))
        perform("Continuous reading", { try $0.setMode(enable ? .auto : .response, intervalMs: interval) }, then: { [weak self] _ in
            self?.autoMode = enable
            self?.appendLog(enable ? "Reading continuously every \(interval) ms" : "Stopped continuous reading")
        })
    }

    func clearTags() {
        rows.removeAll()
        totalReads = 0
        lastReport = nil
        plot = []
    }

    private func setPlot(_ pts: [SweepPoint]) {
        plot = pts.enumerated().map { PlotPoint(id: $0.offset, mhz: $0.element.frequencyMHz, db: $0.element.responseDB, phase: $0.element.phaseDegrees) }
        plotIsBackgroundSubtracted = pts.first?.backgroundDBm != nil
    }

    private func ingest(_ rep: TagReport, refreshPlot: Bool) {
        totalReads += 1
        lastReport = rep
        if refreshPlot, Date().timeIntervalSince(lastPlotRefresh) > 1, !plotRefreshInFlight, let r = reader {
            lastPlotRefresh = Date()
            plotRefreshInFlight = true
            io.async { [weak self] in
                let pts = try? r.sweepData()
                Task { @MainActor in
                    self?.plotRefreshInFlight = false
                    if let pts { self?.setPlot(pts) }
                }
            }
        }
        guard rep.found else {
            appendLog("Read #\(rep.sequence): no tag (RSSI \(String(format: "%.1f", rep.rssiDBm)) dBm)")
            return
        }
        let name = rep.matched ? rep.name : "Not in database"
        let key = "\(rep.bitCount):\(rep.id)"
        if let i = rows.firstIndex(where: { $0.id == key }) {
            rows[i].count += 1
            rows[i].name = name
            rows[i].rssiDBm = rep.rssiDBm
            rows[i].marginDB = rep.marginDB
            rows[i].lastSeen = rep.timestamp
        } else {
            rows.insert(TagRow(id: key, name: name, hexID: rep.hexID, bits: rep.bitString, count: 1, rssiDBm: rep.rssiDBm,
                               marginDB: rep.marginDB, lastSeen: rep.timestamp), at: 0)
        }
        appendLog("Read #\(rep.sequence): \(rep.bitString) \(rep.hexID) \(name), RSSI \(String(format: "%.1f", rep.rssiDBm)) dBm, margin \(String(format: "%.1f", rep.marginDB)) dB")
    }

    /// Add the pattern just read to the database under a name.
    var lastReadUnknown: TagReport? {
        guard let r = lastReport, r.found, !r.matched else { return nil }
        return r
    }

    // MARK: - simulation

    func applySimulation() {
        let idx = simTagIndex < 0 ? nil : simTagIndex
        let d = Int(simDistanceCm.rounded()), q = simQ
        // the tag and the reader have to agree on the format, as with real tags
        let tagBits = idx.flatMap { i in sim?.tags.first { $0.index == i }?.bitCount }
        let profile: TagProfile? = (tagBits != nil && tagBits != bitFrequenciesMHz.count) ? .standard(bits: tagBits!) : nil
        perform("Simulated tag", { r -> (SimulationState, TagProfile?, Int?) in
            var newProfile: TagProfile?
            var bgPoints: Int?
            if let profile {
                newProfile = try r.setProfile(profile)
                _ = try r.setSimulation(tagIndex: nil, distanceCm: d, resonatorQ: q)
                bgPoints = try r.captureBackground().points
            }
            return (try r.setSimulation(tagIndex: idx, distanceCm: d, resonatorQ: q), newProfile, bgPoints)
        }, then: { [weak self] (s, newProfile, bg) in
            guard let self else { return }
            self.sim = s
            if let newProfile {
                self.loadProfile(newProfile)
                self.appendLog("Reader switched to the \(newProfile.bitFrequenciesKHz.count)-bit format to match the tag")
            }
            if bg != nil { self.backgroundCaptured = true }
        })
    }
}
