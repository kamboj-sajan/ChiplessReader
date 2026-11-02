// chiplesscli - command-line front end for ChiplessKit.
//
//   swift run chiplesscli demo                         full walkthrough (uses /tmp/chipless-reader)
//   swift run chiplesscli info    --port /dev/cu.usbmodemXXXX
//   swift run chiplesscli set-lo  --khz 862500
//   swift run chiplesscli read    --count 5
//   swift run chiplesscli help
import Foundation
import ChiplessKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Argument parsing

struct Args {
    var command = "help"
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var it = argv.makeIterator()
        var positional: [String] = []
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if ["verbose", "fast", "no-color", "json", "help"].contains(key) { flags.insert(key); continue }
                if let v = it.next() { options[key] = v }
            } else {
                positional.append(a)
            }
        }
        if let first = positional.first { command = first }
    }
    func string(_ k: String) -> String? { options[k] }
    func int(_ k: String) -> Int? { options[k].flatMap { Int($0) } }
    func double(_ k: String) -> Double? { options[k].flatMap { Double($0) } }
    func has(_ f: String) -> Bool { flags.contains(f) }
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
let useColor = isatty(1) != 0 && !args.has("no-color")
func c(_ s: String, _ code: String) -> String { useColor ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func bold(_ s: String) -> String { c(s, "1") }
func green(_ s: String) -> String { c(s, "32") }
func red(_ s: String) -> String { c(s, "31") }
func yellow(_ s: String) -> String { c(s, "33") }
func cyan(_ s: String) -> String { c(s, "36") }
func dim(_ s: String) -> String { c(s, "2") }
func f1(_ v: Double) -> String { String(format: "%.1f", v) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func lpad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((red("error: ") + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Help

let help = """
\(bold("chiplesscli")) - control the chipless RFID reader (STM32 or virtual reader)

\(bold("Usage:")) chiplesscli <command> [--port PATH] [options] [--verbose]
  --port PATH   serial port (default: $CHIPLESS_PORT, else /tmp/chipless-reader, else first USB modem)
  --verbose     print every frame sent/received (hex)

\(bold("Device"))
  ports                         list candidate serial ports
  info                          model, firmware, UID, RF backend          (GET_INFO)
  status                        mode, PLL lock, counters                  (GET_STATUS)
  config                        current configuration                     (GET_CONFIG)
  ping [--count N]              round-trip test                           (PING)
  reset-config                  default settings + calibration            (RESET_CONFIG)
  save                          store settings, calibration, database     (NV_SAVE)

\(bold("RF configuration"))
  set-lo --khz 862500           program the ADF4351 local oscillator      (SET_LO)
  set-power --dbm 5 [--pa on|off]   ADF4351 level -4/-1/2/5 dBm + PA      (SET_TX_POWER)
  set-atten --db 24             PE4312 reference attenuator 0..31.5 dB    (SET_RX_CONFIG)
  set-sweep --start 860000 --stop 865000 --step 25    sweep in kHz        (SET_SWEEP)
  set-acq --settle 200 --avg 8  settle time (us) + ADC averages           (SET_ACQ)
  set-detect --threshold 6 [--bits f1,f2,...]  notch threshold + bit freqs (SET_DETECT)
  detect                        show threshold + bit frequencies          (GET_DETECT)
  measure                       one AD8302 reading at the LO              (MEASURE)
  profile [--bits 1|2|10]       show, or set a standard 860-865 MHz format (GET/SET_PROFILE)

\(bold("Calibration"))
  auto-level                    centre the AD8302 with the attenuator     (AUTO_LEVEL)
  atten-scan [--step 1]         VMAG at every attenuator setting          (ATTEN_SCAN)
  cal                           show the RF chain numbers                 (GET_CAL)

\(bold("Tag database on the reader"))
  db                            list the tags                             (DB_GET)
  db-add --name X --bits 1010110011                                       (DB_PUT)
  db-del --bits 1010110011                                                (DB_DELETE)
  db-clear                                                                (DB_CLEAR)

\(bold("Tags"))
  bg                            capture background (no tag present)       (CAPTURE_BG)
  bg-clear                      forget background                         (CLEAR_BG)
  read [--count N]              read tag(s) - ID, bits, RSSI, margin      (READ_TAG)
  auto [--seconds 5] [--interval 250]   continuous reading (AUTO mode)    (SET_MODE)
  sweep [--csv FILE]            plot / export the last sweep              (GET_SWEEP_DATA)

\(bold("Simulation")) (virtual reader, or STM32 built with the simulated RF backend)
  sim                           show simulated tags and state             (SIM_GET)
  sim --tag N|NAME|none [--distance CM] [--noise DB] [--q Q]              (SIM_SET)

\(bold("Demo"))
  demo [--fast]                 scripted end-to-end demonstration

\(bold("Low level"))
  raw --hex "A5 04 00 01 00 3E 2E"   send bytes, print the reply
"""

// MARK: - Port / connection

func defaultPort() -> String {
    if let p = args.string("port") { return p }
    if let p = ProcessInfo.processInfo.environment["CHIPLESS_PORT"] { return p }
    // no port given: ask every candidate port and use the first one where a reader answers
    let found = ChiplessReader.findReaders(timeout: 0.8)
    if let first = found.first {
        if found.count > 1 { print(dim("several readers found, using \(first.port) (choose with --port)")) }
        return first.port
    }
    let c = SerialPort.candidatePorts()
    fail(c.isEmpty
         ? "no serial ports found. Start the virtual reader, or plug in the STM32's micro-USB (CN5) port."
         : "none of these ports answered as a reader: \(c.joined(separator: ", "))\n       If you're using the STM32: is the firmware running (press Resume in STM32CubeIDE)? Is the micro-USB (CN5) cable plugged in?")
}

func connect() -> ChiplessReader {
    let port = defaultPort()
    let r = ChiplessReader(port: port)
    if args.has("verbose") { r.onFrameLog = { print(dim("    " + $0)) } }
    do { try r.connect() } catch {
        fail("\(error)\n       Is the virtual reader running (firmware/host: ./build/chipless-vreader) or the STM32 plugged in?")
    }
    return r
}

func run<T>(_ what: @autoclosure () throws -> T) -> T {
    do { return try what() } catch { fail("\(error)") }
}

// MARK: - Printing

func printLO(_ lo: LOResult) {
    print("  LO \(bold(String(format: "%.3f MHz", Double(lo.requestedKHz) / 1000)))  PLL: \(lo.locked ? green("LOCKED") : red("NOT LOCKED"))")
    print("  ADF4351: VCO \(String(format: "%.3f", Double(lo.vcoKHz) / 1000)) MHz ÷ \(lo.rfDivider),  N = \(lo.int) + \(lo.frac)/\(lo.mod),  output = \(lo.actualHz) Hz")
    let regs = (0..<6).reversed().map { "R\($0) \(String(format: "%08X", lo.registers[$0]))" }.joined(separator: "  ")
    print("  SPI words (R5→R0): \(regs)")
}

func printMeasurement(_ m: RFMeasurement) {
    print("  @ \(String(format: "%.3f", Double(m.loKHz) / 1000)) MHz: ADC \(m.adcMagnitude)/\(m.adcPhase) (12-bit) → VMAG \(m.vmagMillivolts) mV, VPHS \(m.vphsMillivolts) mV")
    print("  AD8302 gain \(String(format: "%+.2f", m.gainDB)) dB, |phase| \(f1(m.phaseDegrees))°  →  INPA \(f1(m.referenceDBm)) dBm, INPB \(f1(m.receivedDBm)) dBm, RSSI \(bold(f1(m.rssiDBm) + " dBm"))\(m.clipped ? red("  CLIPPED") : "")")
}

var library = TagLibrary()

func tagHeader() {
    print(dim("  #     TAG ID   BITS f1→fN      NAME      RSSI dBm   MARGIN dB   PHASE°   SWEEP"))
}

func tagRow(_ t: TagReport) {
    let seq = lpad("\(t.sequence)", 4)
    guard t.found else {
        print("  \(seq)  " + yellow("no tag detected") + "           RSSI \(f1(t.rssiDBm))  (\(t.points) pts, \(t.sweepMilliseconds) ms)")
        return
    }
    let name = t.matched ? green(t.name) : (library.match(t.id).map { green($0.tag.name) } ?? yellow("unknown"))
    let margin = t.marginDB >= 3 ? green(lpad(f1(t.marginDB), 6)) : yellow(lpad(f1(t.marginDB), 6))
    print("  \(seq)  \(bold(pad(t.hexID, 7)))  \(pad(t.bitString, 14))  \(pad(name, useColor ? 17 : 8))  \(lpad(f1(t.rssiDBm), 7))   \(margin)      \(lpad(f1(t.phaseDegrees), 5))   \(t.points) pts \(t.sweepMilliseconds) ms\(t.backgroundSubtracted ? " bg" : "")")
}

func depthBars(_ t: TagReport, threshold: Double) {
    let maxD = max(t.notchDepthsDB.max() ?? 1, threshold * 2)
    for (k, d) in t.notchDepthsDB.enumerated() {
        let n = Int((d / maxD * 40).rounded())
        let bar = String(repeating: "█", count: max(0, n))
        let bit = d >= threshold ? green("1") : dim("0")
        print("   f\(lpad("\(k + 1)", 2))  \(bit)  \(lpad(f1(d), 5)) dB \(d >= threshold ? cyan(bar) : dim(bar))")
    }
    print(dim("               threshold \(f1(threshold)) dB"))
}

func asciiPlot(_ pts: [SweepPoint], bits: [UInt32], width: Int = 72, height: Int = 12) {
    guard pts.count > 1 else { print("  (no sweep data - run a read first)"); return }
    let vals = pts.map { $0.responseDB }
    let lo = vals.min()!, hi = vals.max()!
    let span = max(hi - lo, 1)
    let f0 = pts.first!.frequencyMHz, f1v = pts.last!.frequencyMHz
    var cols = [Double](repeating: .nan, count: width)
    for p in pts {
        let x = min(width - 1, Int((p.frequencyMHz - f0) / (f1v - f0) * Double(width - 1)))
        cols[x] = cols[x].isNaN ? p.responseDB : min(cols[x], p.responseDB)
    }
    for row in 0..<height {
        let level = hi - span * Double(row) / Double(height - 1)
        var line = ""
        for x in 0..<width {
            let v = cols[x]
            if v.isNaN { line += " "; continue }
            let y = Int(((hi - v) / span * Double(height - 1)).rounded())
            line += y == row ? "•" : (y < row ? " " : " ")
        }
        print("  \(lpad(f1(level), 6)) │\(cyan(line))")
    }
    var marks = [Character](repeating: " ", count: width)
    for f in bits {
        let x = Int((Double(f) / 1000 - f0) / (f1v - f0) * Double(width - 1))
        if x >= 0 && x < width { marks[x] = "^" }
    }
    print("         └" + String(repeating: "─", count: width))
    print("          " + String(marks) + dim("  ^ = tag bit frequencies"))
    print("          \(String(format: "%.1f MHz", f0))" + String(repeating: " ", count: max(1, width - 22)) + String(format: "%.1f MHz", f1v))
    print(dim("          y: \(pts.first?.backgroundDBm == nil ? "received power (dBm)" : "received − background (dB)")"))
}

func loadLibrary(_ r: ChiplessReader) {
    if let path = args.string("library") {
        library = run(try TagLibrary.load(from: URL(fileURLWithPath: path)))
    }
}

// MARK: - Commands

func cmdDemo() {
    let fast = args.has("fast")
    func step(_ n: Int, _ title: String) {
        print("\n" + bold(cyan("━━ \(n). \(title) ")) + cyan(String(repeating: "━", count: max(3, 60 - title.count))))
    }
    func pause() { if !fast { usleep(600_000) } }

    let r = connect()
    print(bold("Chipless RFID reader - SDK demonstration") + dim("   port \(r.portPath)"))

    step(1, "Connect and identify the reader")
    let info = run(try r.getInfo())
    print("  \(bold(info.model))  firmware \(info.firmwareVersion)  hw rev \(info.hardwareRevision)  UID \(info.uid)")
    print("  RF front-end: " + (info.simulatedFrontEnd ? yellow("SIMULATED (ADF4351 / PA / LNA / AD8302 / tag modelled in firmware)") : green("HARDWARE")))
    let t0 = Date()
    for _ in 0..<20 { _ = run(try r.ping()) }
    print("  20 × PING ok, average round trip \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000 / 20)) ms")
    run(try r.setMode(.response))
    pause()

    step(2, "Tune the local oscillator to 862.5 MHz (SDK → STM32 → ADF4351)")
    printLO(run(try r.setLO(kHz: 862_500)))
    pause()

    step(3, "Transmit power and receiver levels")
    let tx = run(try r.setTxPower(.plus5dBm, paEnabled: true))
    print("  ADF4351 +5 dBm → MAX2235 PA on → TX at antenna ≈ \(bold(f1(tx) + " dBm"))")
    let inpa = run(try r.setReferenceAttenuation(dB: 24))
    print("  PE4312 reference attenuator 24.0 dB → AD8302 INPA ≈ \(f1(inpa)) dBm")
    printMeasurement(run(try r.measure()))
    pause()

    step(4, "Tag profile: 10 bits across 860-865 MHz")
    let profile = run(try r.setProfile(.standard(bits: 10)))
    let det = run(try r.getDetection())
    print("  sweep 860.0 → 865.0 MHz, 25 kHz steps = \(profile.sweepPoints) points, \(profile.settleMicroseconds) µs settle, \(profile.averages) ADC samples/point")
    print("  \(det.bitFrequenciesKHz.count) bits, notch threshold \(f1(det.thresholdDB)) dB, phase confirmation \(f1(profile.phaseThresholdDegrees))°:")
    print("  " + det.bitFrequenciesKHz.enumerated().map { "f\($0.offset + 1) \(String(format: "%.2f", Double($0.element) / 1000))" }.joined(separator: "  "))
    pause()

    guard let sim = try? r.getSimulation() else {
        print(yellow("\n  Reader has a hardware front-end: skipping the simulated-tag steps. Use `read` with a real tag."))
        return
    }
    let tenBit = sim.tags.filter { $0.bitCount == 10 }

    step(5, "Background capture (no tag in front of the antennas)")
    _ = run(try r.setSimulation(tagIndex: nil, distanceCm: 20))
    let empty = run(try r.readTag())
    print("  read with no tag: " + (empty.found ? red("tag reported!") : green("no tag detected")) + "  (RSSI \(f1(empty.rssiDBm)) dBm = antenna leakage)")
    let bg = run(try r.captureBackground())
    print("  background stored: \(bg.points) points in \(bg.milliseconds) ms")
    pause()

    step(6, "Read each ten-bit tag at 20 cm and identify it from the reader's database")
    tagHeader()
    var correct = 0
    var sample: TagReport?
    for t in tenBit {
        _ = run(try r.setSimulation(tagIndex: t.index, distanceCm: 20))
        let rep = run(try r.readTag())
        tagRow(rep)
        if rep.found && rep.id == t.code { correct += 1 } else {
            print(red("        expected \(t.name) = 0x\(String(t.code, radix: 16, uppercase: true))"))
        }
        if sample == nil { sample = rep }
        if !fast { usleep(250_000) }
    }
    print("  → \(bold("\(correct)/\(tenBit.count)")) tags identified correctly")
    pause()

    if let s = sample {
        step(7, "Inside one read: notch depth per bit (\(s.matched ? s.name : s.hexID))")
        depthBars(s, threshold: det.thresholdDB)
        _ = run(try r.setSimulation(tagIndex: tenBit[0].index, distanceCm: 20))
        _ = run(try r.readTag())
        print("")
        asciiPlot(run(try r.sweepData()), bits: det.bitFrequenciesKHz)
        pause()
    }

    step(8, "Read range: \(tenBit[0].name) at increasing distance (5 reads each)")
    print(dim("  distance   correct   mean margin   RSSI"))
    for d in [10, 20, 30, 40, 50, 60] {
        _ = run(try r.setSimulation(tagIndex: tenBit[0].index, distanceCm: d))
        var ok = 0, margin = 0.0, rssi = 0.0
        for _ in 0..<5 {
            let rep = run(try r.readTag())
            if rep.found && rep.id == tenBit[0].code { ok += 1 }
            margin += rep.marginDB; rssi += rep.rssiDBm
        }
        let okStr = ok == 5 ? green("\(ok)/5") : (ok == 0 ? red("\(ok)/5") : yellow("\(ok)/5"))
        print("  \(lpad("\(d)", 5)) cm     \(okStr)       \(lpad(f1(margin / 5), 5)) dB    \(f1(rssi / 5)) dBm")
    }

    step(9, "AUTO mode: the reader reads continuously and pushes tag reports")
    _ = run(try r.setSimulation(tagIndex: tenBit[1].index, distanceCm: 20))
    let lock = NSLock()
    var reports: [TagReport] = []
    r.onTagReport = { rep in lock.lock(); reports.append(rep); lock.unlock(); tagRow(rep) }
    tagHeader()
    run(try r.setMode(.auto, intervalMs: 250))
    Thread.sleep(forTimeInterval: fast ? 1.5 : 3.0)
    do { try r.setLO(kHz: 866_000) } catch { print(dim("  (config change while in AUTO mode → reader replied: \(error))")) }
    run(try r.setMode(.response))
    Thread.sleep(forTimeInterval: 0.3)
    lock.lock(); let n = reports.count; lock.unlock()
    print("  → \(n) tag reports pushed by the reader while in AUTO mode")

    step(10, "Reader status")
    let st = run(try r.getStatus())
    print("  mode \(st.mode), PLL \(st.pllLocked ? "locked" : "unlocked"), LO \(String(format: "%.3f", Double(st.loKHz) / 1000)) MHz, TX \(f1(st.txPowerDBm)) dBm")
    print("  frames ok \(st.framesOK), frame errors \(st.framesWithErrors), reads \(st.reads), tags found \(st.tagsFound)")
    _ = try? r.setSimulation(tagIndex: tenBit[0].index, distanceCm: 20)
    print("\n" + bold(green("Demo complete: every step above was a real command sent by the SDK and executed by the reader firmware.")))
    r.disconnect()
}

switch args.command {
case "help", "-h", "--help":
    print(help)

case "ports":
    let p = SerialPort.candidatePorts()
    if p.isEmpty { print("no candidate ports found") }
    for port in p {
        if let i = ChiplessReader.probe(port: port, timeout: 0.8) {
            print("\(pad(port, 34)) \(green("← reader")): \(i.model) fw \(i.firmwareVersion)\(i.simulatedFrontEnd ? ", simulated RF" : "")")
        } else {
            print("\(pad(port, 34)) \(dim("no reply (not the reader - e.g. the ST-LINK's own port)"))")
        }
    }

case "info":
    let r = connect()
    let i = run(try r.getInfo())
    print("model     \(i.model)\nfirmware  \(i.firmwareVersion)\nhardware  rev \(i.hardwareRevision)\nUID       \(i.uid)\nRF        \(i.simulatedFrontEnd ? "simulated front-end" : "hardware front-end")\nport      \(r.portPath)")

case "status":
    let s = run(try connect().getStatus())
    print("mode \(s.mode)  PLL \(s.pllLocked ? "locked" : "UNLOCKED")  LO \(s.loKHz) kHz  TX \(f1(s.txPowerDBm)) dBm  background \(s.backgroundCaptured ? "yes" : "no")")
    print("uptime \(s.uptimeMs / 1000) s  frames ok \(s.framesOK)  errors \(s.framesWithErrors)  reads \(s.reads)  tags found \(s.tagsFound)")

case "config":
    let c = run(try connect().getConfig())
    print("""
    LO             \(c.loKHz) kHz
    sweep          \(c.sweepStartKHz) .. \(c.sweepStopKHz) kHz, step \(c.sweepStepKHz) kHz (\(c.sweepPoints) points)
    TX             ADF4351 \(c.txLevel), PA \(c.paEnabled ? "on" : "off")
    ref atten      \(f1(c.refAttenuationDB)) dB
    acquisition    settle \(c.settleMicroseconds) us, \(c.averages) averages
    detection      threshold \(f1(c.thresholdDB)) dB, \(c.bitCount) bits
    mode           \(c.mode) (auto interval \(c.autoIntervalMs) ms)
    """)

case "ping":
    let r = connect()
    let n = args.int("count") ?? 10
    let t0 = Date()
    var ok = 0
    for _ in 0..<n { if run(try r.ping()) { ok += 1 } }
    print("\(ok)/\(n) replies, average \(String(format: "%.2f", Date().timeIntervalSince(t0) * 1000 / Double(n))) ms")

case "reset-config":
    run(try connect().resetConfig()); print("default settings and calibration restored")

case "save":
    run(try connect().saveToFlash()); print("settings, calibration and database stored in the reader's flash")

case "profile":
    let r = connect()
    if let n = args.int("bits") { run(try r.setProfile(.standard(bits: n))) }
    let p = run(try r.getProfile())
    print("\(p.name): \(p.bitFrequenciesKHz.count) bits, sweep \(p.sweepStartKHz)..\(p.sweepStopKHz) kHz step \(p.sweepStepKHz) (\(p.sweepPoints) points)")
    print("settle \(p.settleMicroseconds) us, \(p.averages) averages, read every \(p.autoIntervalMs) ms, threshold \(f1(p.thresholdDB)) dB, phase \(f1(p.phaseThresholdDegrees)) deg, database tolerance \(p.maxBitErrors) bits")
    print("tags need a resonator Q of about \(p.requiredResonatorQ) or higher")
    for (k, f) in p.bitFrequenciesKHz.enumerated() { print("  f\(k + 1)  \(String(format: "%.3f", Double(f) / 1000)) MHz") }

case "auto-level":
    let a = run(try connect().autoLevel())
    print("PE4312 \(f1(a.oldAttenuationDB)) → \(f1(a.newAttenuationDB)) dB, gain \(f1(a.gainMinDB))..\(f1(a.gainMaxDB)) dB, INPA \(f1(a.inpaDBm)) dBm, \(a.clippedPoints) clipped points")
    for p in a.conditions.problems { print(yellow("  " + p)) }

case "atten-scan":
    let pts = run(try connect().attenuatorScan(stepDB: args.double("step") ?? 1))
    print(dim("  atten dB   VMAG mV   gain dB   INPA dBm"))
    for p in pts { print("  \(lpad(f1(p.attenuationDB), 8))   \(lpad("\(p.vmagMillivolts)", 7))   \(lpad(f1(p.gainDB), 7))   \(lpad(f1(p.inpaDBm), 8))") }

case "cal":
    let c = run(try connect().getCalibration())
    print("TX filter loss \(c.txFilterLossDB) dB, PA trim \(c.paTrimDB) dB, coupler \(c.couplerDB) dB (through \(c.couplerThroughLossDB) dB)")
    print("attenuator loss \(c.attenuatorInsertionLossDB) dB, LNA gain \(c.lnaGainDB) dB, RX filter loss \(c.rxFilterLossDB) dB, RSSI trim \(c.rssiTrimDB) dB")
    print("VMAG \(c.vmagCenterMillivolts) mV + \(c.vmagSlopeMillivoltsPerDB) mV/dB, VPHS \(c.vphsCenterMillivolts) mV + \(c.vphsSlopeMillivoltsPerDegree) mV/deg")

case "db":
    let d = run(try connect().databaseEntries())
    print("\(d.entries.count) of \(d.capacity) entries")
    for e in d.entries { print("  \(pad(e.name, 18)) \(pad(e.bitString, 12)) \(e.hexID)") }

case "db-add":
    guard let n = args.string("name"), let b = args.string("bits"), let e = TagDatabaseEntry(name: n, bitString: b) else { fail("db-add needs --name and --bits 1010110011") }
    run(try connect().putDatabaseEntry(e)); print("stored \(e.name) = \(e.bitString) (\(e.hexID)). Use `save` to keep it across power cycles.")

case "db-del":
    guard let b = args.string("bits"), let e = TagDatabaseEntry(name: "", bitString: b) else { fail("db-del needs --bits 1010110011") }
    run(try connect().deleteDatabaseEntry(e)); print("removed \(e.bitString)")

case "db-clear":
    run(try connect().clearDatabase()); print("database cleared")

case "set-lo":
    guard let khz = args.int("khz") else { fail("set-lo needs --khz") }
    printLO(run(try connect().setLO(kHz: UInt32(khz))))

case "set-power":
    guard let dbm = args.int("dbm"), let level = TxPowerLevel(dBm: dbm) else { fail("set-power needs --dbm -4|-1|2|5") }
    let pa = (args.string("pa") ?? "on") != "off"
    let tx = run(try connect().setTxPower(level, paEnabled: pa))
    print("ADF4351 \(level), PA \(pa ? "on" : "off") → TX at antenna ≈ \(f1(tx)) dBm")

case "set-atten":
    guard let db = args.double("db") else { fail("set-atten needs --db 0..31.5") }
    let inpa = run(try connect().setReferenceAttenuation(dB: db))
    print("PE4312 \(f1(db)) dB → AD8302 INPA ≈ \(f1(inpa)) dBm")

case "set-sweep":
    guard let a = args.int("start"), let b = args.int("stop"), let s = args.int("step") else { fail("set-sweep needs --start --stop --step (kHz)") }
    let n = run(try connect().setSweep(startKHz: UInt32(a), stopKHz: UInt32(b), stepKHz: UInt32(s)))
    print("sweep \(a)..\(b) kHz step \(s) kHz → \(n) points")

case "set-acq":
    let r = connect()
    run(try r.setAcquisition(settleMicroseconds: UInt16(args.int("settle") ?? 200), averages: UInt8(args.int("avg") ?? 8)))
    print("ok")

case "set-detect":
    let r = connect()
    var d = run(try r.getDetection())
    if let t = args.double("threshold") { d.thresholdDB = t }
    if let b = args.string("bits") { d.bitFrequenciesKHz = b.split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) } }
    run(try r.setDetection(d))
    print("threshold \(f1(d.thresholdDB)) dB, \(d.bitFrequenciesKHz.count) bits")

case "detect":
    let d = run(try connect().getDetection())
    print("threshold \(f1(d.thresholdDB)) dB")
    for (k, f) in d.bitFrequenciesKHz.enumerated() { print("  bit \(k) (f\(k + 1))  \(String(format: "%.3f", Double(f) / 1000)) MHz") }

case "measure":
    printMeasurement(run(try connect().measure()))

case "bg":
    let b = run(try connect().captureBackground())
    print("background captured: \(b.points) points in \(b.milliseconds) ms")

case "bg-clear":
    run(try connect().clearBackground()); print("background cleared")

case "read":
    let r = connect()
    loadLibrary(r)
    let n = args.int("count") ?? 1
    tagHeader()
    var last: TagReport?
    for _ in 0..<n { let t = run(try r.readTag()); tagRow(t); last = t }
    if n == 1, let t = last, t.found {
        let thr = (try? r.getDetection().thresholdDB) ?? 6
        print("")
        depthBars(t, threshold: thr)
    }

case "auto":
    let r = connect()
    loadLibrary(r)
    tagHeader()
    r.onTagReport = { tagRow($0) }
    run(try r.setMode(.auto, intervalMs: UInt16(args.int("interval") ?? 250)))
    Thread.sleep(forTimeInterval: args.double("seconds") ?? 5)
    run(try r.setMode(.response))
    Thread.sleep(forTimeInterval: 0.2)

case "sweep":
    let r = connect()
    var pts = run(try r.sweepData())
    if pts.isEmpty { _ = run(try r.readTag()); pts = run(try r.sweepData()) }
    if let path = args.string("csv") {
        var csv = "frequency_mhz,received_dbm,phase_deg,background_dbm,response_db\n"
        for p in pts {
            csv += String(format: "%.3f,%.2f,%.1f,%@,%.2f\n", p.frequencyMHz, p.receivedDBm, p.phaseDegrees,
                          p.backgroundDBm.map { String(format: "%.2f", $0) } ?? "", p.responseDB)
        }
        run(try csv.write(toFile: path, atomically: true, encoding: .utf8))
        print("wrote \(pts.count) points to \(path)")
    } else {
        asciiPlot(pts, bits: (try? r.getDetection().bitFrequenciesKHz) ?? [])
    }

case "sim":
    let r = connect()
    var s = run(try r.getSimulation())
    if args.string("tag") != nil || args.int("distance") != nil || args.double("noise") != nil || args.int("q") != nil {
        var idx = s.tagIndex
        if let t = args.string("tag") {
            if t.lowercased() == "none" { idx = nil }
            else if let i = Int(t) { idx = i }
            else if let m = s.tags.first(where: { $0.name.lowercased() == t.lowercased() }) { idx = m.index }
            else { fail("unknown tag \(t)") }
        }
        s = run(try r.setSimulation(tagIndex: idx, distanceCm: args.int("distance") ?? s.distanceCm, noiseDB: args.double("noise") ?? s.noiseDB, resonatorQ: args.int("q") ?? s.resonatorQ))
    }
    print("simulated tag in front of the antennas: \(s.tagIndex.map { s.tags[$0].name } ?? "none"), distance \(s.distanceCm) cm, noise \(s.noiseDB) dB, resonator Q \(s.resonatorQ)")
    print("known simulated tags:")
    for t in s.tags {
        print("  [\(t.index)] \(pad(t.name, 10))  ID 0x\(String(format: "%03X", t.code))  bits \(t.bitString)")
    }

case "raw":
    guard let hex = args.string("hex") else { fail("raw needs --hex \"A5 ...\"") }
    let clean = hex.replacingOccurrences(of: " ", with: "")
    var bytes: [UInt8] = []
    var i = clean.startIndex
    while i < clean.endIndex {
        let j = clean.index(i, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
        guard let b = UInt8(clean[i..<j], radix: 16) else { fail("bad hex") }
        bytes.append(b); i = j
    }
    let r = connect()
    let cmd = bytes.count > 3 ? bytes[3] : 0
    let f = run(try r.exchangeRaw(bytes, expecting: cmd, timeout: 2))
    print("reply: \(hexString(ChiplessCodec.encode(f)))")
    print("cmd 0x\(String(format: "%02X", f.command)) status \(ChiplessStatus(rawValue: f.status)?.description ?? "?") payload \(f.payload.count) bytes")

case "demo":
    cmdDemo()

default:
    fail("unknown command '\(args.command)' - try `chiplesscli help`")
}
