import SwiftUI
import Charts
import ChiplessKit

/// The PE4312 reference attenuator and the RF chain numbers. The diagram's rule: keep both AD8302
/// inputs inside -60 to 0 dBm, and within 30 dB of each other.
struct CalibrationView: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        if !model.isConnected {
            NotConnectedPlaceholder()
        } else {
            Form {
                AttenuatorSection()
                ScanSection()
                ChainSection()
                ToneSection()
            }
            .formStyle(.grouped)
            .disabled(!model.canConfigure)
            .task(id: model.liveMeasure) {
                while model.liveMeasure && !Task.isCancelled {
                    if !model.busy { model.measure() }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            .onDisappear { model.liveMeasure = false }
        }
    }
}

struct AttenuatorSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section {
            HStack {
                Text("PE4312 attenuation")
                Slider(value: $model.refAttenDB, in: model.minimumAttenDB...31.5, step: 0.5) { editing in
                    if !editing { model.applyAttenuation() }
                }
                Text(String(format: "%.1f dB", model.refAttenDB)).monospacedDigit().frame(width: 62, alignment: .trailing)
                Stepper("", value: $model.refAttenDB, in: model.minimumAttenDB...31.5, step: 0.5)
                    .labelsHidden()
                Button("Apply") { model.applyAttenuation() }
            }
            LevelBar(title: "INPA (reference)", dbm: model.measurement?.referenceDBm ?? model.inpaDBm)
            LevelBar(title: "INPB (echo)", dbm: model.measurement?.receivedDBm)
            if let m = model.measurement {
                LabeledContent("AD8302 outputs") {
                    Text(String(format: "VMAG %d mV (%+.2f dB), VPHS %d mV (%.1f°)", Int(m.vmagMillivolts), m.gainDB, Int(m.vphsMillivolts), m.phaseDegrees)).monospacedDigit()
                }
                LabeledContent("At the RX antenna") { Text(String(format: "%.1f dBm", m.rssiDBm)).monospacedDigit() }
                ForEach(m.conditions.problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            HStack {
                Button("Measure") { model.measure() }
                Toggle("Live", isOn: $model.liveMeasure).toggleStyle(.checkbox)
                Spacer()
                Button("Auto-level") { model.autoLevel() }
                    .buttonStyle(.borderedProminent)
                    .help("Sweeps the band and picks the attenuation that centres the AD8302 on what it sees")
            }
            if let a = model.autoLevelResult {
                Text(String(format: "Auto-level: %.1f → %.1f dB. Gain over the sweep %+.1f to %+.1f dB, %d clipped points.", a.oldAttenuationDB, a.newAttenuationDB, a.gainMinDB, a.gainMaxDB, a.clippedPoints))
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Reference attenuator")
        } footer: {
            Text(String(format: "The lowest setting allowed at this TX level is %.1f dB: below it INPA would pass the AD8302's 0 dBm input limit, and the reader refuses it. The AD8302 is rated to +10 dBm absolute maximum.", model.minimumAttenDB))
        }
    }
}

/// -60 to 0 dBm is the AD8302's input range; the bar shows where a level falls in it.
struct LevelBar: View {
    let title: String
    let dbm: Double?
    private let low = -70.0, high = 10.0

    var body: some View {
        LabeledContent(title) {
            HStack {
                GeometryReader { g in
                    let x = { (v: Double) in g.size.width * (min(max(v, low), high) - low) / (high - low) }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.2))
                        Rectangle().fill(Color.green.opacity(0.28))
                            .frame(width: x(0) - x(-60))
                            .offset(x: x(-60))
                        if let dbm {
                            Rectangle().fill(inRange ? Color.primary : Color.red)
                                .frame(width: 3)
                                .offset(x: x(dbm) - 1.5)
                        }
                    }
                }
                .frame(width: 240, height: 12)
                Text(dbm.map { String(format: "%+.1f dBm", $0) } ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(inRange ? Color.primary : Color.red)
                    .frame(width: 78, alignment: .trailing)
            }
        }
        .help("Green is the AD8302's -60 to 0 dBm input range")
    }

    private var inRange: Bool {
        guard let dbm else { return true }
        return dbm <= 0 && dbm >= -60
    }
}

struct ScanSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section {
            HStack {
                Text("Steps the PE4312 at the current frequency and records VMAG. A straight line shows the attenuator is wired correctly, and its slope is the AD8302's real mV/dB.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Run Scan") { model.runScan() }
            }
            if !model.scan.isEmpty {
                Chart(model.scan) { p in
                    LineMark(x: .value("Attenuation", p.attenuationDB), y: .value("VMAG", Double(p.vmagMillivolts)))
                    PointMark(x: .value("Attenuation", p.attenuationDB), y: .value("VMAG", Double(p.vmagMillivolts)))
                        .symbolSize(18)
                }
                .chartXAxisLabel("attenuation (dB)")
                .chartYAxisLabel("VMAG (mV)")
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 170)
                if let f = model.scanFit {
                    HStack {
                        Text(String(format: "Slope %.2f mV/dB, worst departure from the line %.2f dB", f.slope, f.worstDB)).monospacedDigit()
                        if f.worstDB > 1 {
                            Label("Not a straight line: check the PE4312 wiring (P/S high, data, clock, LE).", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Use This Slope") { model.useMeasuredSlope() }.disabled(f.worstDB > 1)
                    }
                } else {
                    Text("Too few unclipped points to fit a line. Run Auto-level first.").foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Attenuator scan")
        }
    }
}

struct ChainSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section {
            CalRow("TX filter loss", "LFCN-1000+", $model.calibration.txFilterLossDB, "dB", RFCalibration.datasheet.txFilterLossDB)
            CalRow("PA output trim", "added to the MAX2235 curve", $model.calibration.paTrimDB, "dB", RFCalibration.datasheet.paTrimDB)
            CalRow("Coupling", "X3C09F1-20S", $model.calibration.couplerDB, "dB", RFCalibration.datasheet.couplerDB)
            CalRow("Coupler through loss", "X3C09F1-20S", $model.calibration.couplerThroughLossDB, "dB", RFCalibration.datasheet.couplerThroughLossDB)
            CalRow("Attenuator loss at 0 dB", "PE4312", $model.calibration.attenuatorInsertionLossDB, "dB", RFCalibration.datasheet.attenuatorInsertionLossDB)
            CalRow("LNA gain", "HMC8410", $model.calibration.lnaGainDB, "dB", RFCalibration.datasheet.lnaGainDB)
            CalRow("RX filter loss", "LFCN-1000+ and HFCN-650+", $model.calibration.rxFilterLossDB, "dB", RFCalibration.datasheet.rxFilterLossDB)
            CalRow("VMAG at equal levels", "AD8302", $model.calibration.vmagCenterMillivolts, "mV", RFCalibration.datasheet.vmagCenterMillivolts)
            CalRow("VMAG slope", "AD8302 at 900 MHz", $model.calibration.vmagSlopeMillivoltsPerDB, "mV/dB", RFCalibration.datasheet.vmagSlopeMillivoltsPerDB)
            CalRow("VPHS at 90°", "AD8302", $model.calibration.vphsCenterMillivolts, "mV", RFCalibration.datasheet.vphsCenterMillivolts)
            CalRow("VPHS slope", "AD8302 at 900 MHz", $model.calibration.vphsSlopeMillivoltsPerDegree, "mV/°", RFCalibration.datasheet.vphsSlopeMillivoltsPerDegree)
            CalRow("RSSI trim", "added to the reported level", $model.calibration.rssiTrimDB, "dB", RFCalibration.datasheet.rssiTrimDB)
            HStack {
                Button("Reset to Datasheet Values") { model.resetCalibrationToDatasheet() }
                Spacer()
                Button("Apply to Reader") { model.applyCalibration() }.buttonStyle(.borderedProminent)
            }
        } header: {
            Text("RF chain")
        } footer: {
            Text("These start as datasheet values. They set how accurate the dBm figures are; notch detection does not depend on them. Replace them with what you measure on the bench.")
        }
    }
}

struct CalRow: View {
    let title: String, source: String
    @Binding var value: Double
    let unit: String
    let reference: Double

    init(_ title: String, _ source: String, _ value: Binding<Double>, _ unit: String, _ reference: Double) {
        self.title = title
        self.source = source
        self._value = value
        self.unit = unit
        self.reference = reference
    }

    var body: some View {
        LabeledContent {
            HStack {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(unit).frame(width: 48, alignment: .leading).foregroundStyle(.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(source + (abs(value - reference) > 0.001 ? String(format: " (datasheet %g %@)", reference, unit) : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ToneSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section {
            HStack {
                Text("Frequency")
                TextField("MHz", value: $model.loMHz, format: .number.precision(.fractionLength(3)))
                    .labelsHidden().frame(width: 100)
                Text("MHz")
                Spacer()
                Button("Set Frequency") { model.applyLO() }
            }
            if let lo = model.loResult {
                Label(lo.locked ? "PLL locked" : "PLL not locked", systemImage: lo.locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(lo.locked ? Color.green : Color.red)
                Text("VCO \(String(format: "%.3f", Double(lo.vcoKHz) / 1000)) MHz ÷ \(lo.rfDivider), N = \(lo.int) + \(lo.frac)/\(lo.mod)")
                    .font(.caption.monospaced())
                Text((0..<6).reversed().map { "R\($0) \(String(format: "%08X", lo.registers[$0]))" }.joined(separator: "  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Toggle("Hold the carrier on at this frequency", isOn: Binding(get: { model.carrierOn }, set: { model.setCarrier($0) }))
        } header: {
            Text("Single tone")
        } footer: {
            Text("For checking the output on a spectrum analyser. The PA transmits continuously while this is on, about 1 W with the gain at its top setting. Otherwise it runs only during measurements.")
        }
    }
}
