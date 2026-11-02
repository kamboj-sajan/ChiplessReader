import SwiftUI
import Charts
import ChiplessKit

struct ReadView: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        if !model.isConnected {
            NotConnectedPlaceholder()
        } else {
            VSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ReadControls()
                        ResultCard()
                        if model.sim != nil { SimulatorPanel() }
                    }
                    .padding(16)
                }
                .frame(minHeight: 300)
                HSplitView {
                    SweepCharts().frame(minWidth: 420)
                    ReadHistory().frame(minWidth: 320, idealWidth: 420)
                }
                .frame(minHeight: 260)
            }
        }
    }
}

struct ReadControls: View {
    @EnvironmentObject var model: ReaderModel
    @State private var confirmBackground = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.readOnce() } label: { Label("Read Tag", systemImage: "wave.3.right") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfigure)
            Button { model.toggleAuto() } label: {
                Label(model.autoMode ? "Stop" : "Read Continuously", systemImage: model.autoMode ? "stop.fill" : "repeat")
            }
            .controlSize(.large)
            Divider().frame(height: 24)
            Button {
                if model.sim != nil { model.captureBackground() } else { confirmBackground = true }
            } label: {
                Label("Capture Background", systemImage: model.backgroundCaptured ? "checkmark.circle.fill" : "circle.dashed")
            }
            .controlSize(.large)
            .disabled(!model.canConfigure)
            .help("A sweep with no tag present. Later reads subtract it, which removes antenna leakage and room reflections.")
            .confirmationDialog("Remove every tag from in front of the antennas.", isPresented: $confirmBackground) {
                Button("Capture Background") { model.captureBackground() }
            } message: {
                Text("The reader sweeps once and subtracts this from later reads. Capture again after changing the sweep or the gain.")
            }
            Spacer()
            if let p = model.appliedProfile {
                Text("\(p.name): \(Fmt.count(p.bitFrequenciesKHz.count, "bit")), \(Fmt.mhz(p.sweepStartKHz))–\(Fmt.mhz(p.sweepStopKHz)) MHz")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct ResultCard: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = model.lastReport {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title(r))
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(r.found ? (r.matched ? Color.primary : Color.orange) : Color.secondary)
                    if r.found {
                        Text(r.hexID).font(.title3.monospaced()).foregroundStyle(.secondary)
                        if r.matched && r.bitErrors > 0 {
                            Text("\(Fmt.count(r.bitErrors, "bit")) off").font(.callout).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if let unknown = model.lastReadUnknown { AddUnknownButton(report: unknown) }
                }
                BitStrip(report: r, threshold: model.thresholdDB, frequencies: model.appliedProfile?.bitFrequenciesKHz ?? [])
                Text("Under each bit: notch depth, then phase swing. A 1 needs at least \(String(format: "%.1f dB", model.thresholdDB)) with the phase moving at least \(String(format: "%.0f°", model.phaseThresholdDegrees)).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Metric("RSSI", String(format: "%.1f dBm", r.rssiDBm))
                    Metric("Margin", String(format: "%.1f dB", r.marginDB), r.marginDB >= 3 ? .primary : .orange)
                    Metric("Phase at notch", String(format: "%.0f°", r.phaseDegrees))
                    Metric("Sweep", "\(r.points) points, \(r.sweepMilliseconds) ms")
                    Metric("Background", r.backgroundSubtracted ? "Subtracted" : "None", r.backgroundSubtracted ? .primary : .orange)
                    if r.clippedPoints > 0 { Metric("Clipped points", "\(r.clippedPoints)", .red) }
                    if r.unlockedPoints > 0 { Metric("Unlocked points", "\(r.unlockedPoints)", .red) }
                }
            } else {
                Text("Press Read Tag").font(.title2).foregroundStyle(.secondary)
                Text("The reader sweeps the band, compares magnitude and phase at each bit frequency, and looks the pattern up in its database.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func title(_ r: TagReport) -> String {
        if !r.found { return "No tag detected" }
        return r.matched ? r.name : "Not in the database"
    }
}

struct AddUnknownButton: View {
    @EnvironmentObject var model: ReaderModel
    let report: TagReport
    @State private var asking = false
    @State private var name = ""

    var body: some View {
        Button("Add to Database…") { name = ""; asking = true }
            .disabled(!model.canConfigure)
            .popover(isPresented: $asking) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Name for \(report.bitString)").font(.headline)
                    TextField("Name (16 characters)", text: $name).frame(width: 220)
                    HStack {
                        Spacer()
                        Button("Add") {
                            model.putEntry(TagDatabaseEntry(name: String(name.prefix(16)), tagID: report.id, bitCount: report.bitCount))
                            asking = false
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(14)
            }
    }
}

struct Metric: View {
    let title: String, value: String
    var color: Color = .primary
    init(_ title: String, _ value: String, _ color: Color = .primary) { self.title = title; self.value = value; self.color = color }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).foregroundStyle(color)
        }
    }
}

/// One cell per bit: f1 on the left, as the pattern is written.
struct BitStrip: View {
    let report: TagReport
    let threshold: Double
    let frequencies: [UInt32]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<report.bitCount, id: \.self) { k in
                let one = (report.id >> UInt32(k)) & 1 == 1
                VStack(spacing: 3) {
                    Text("f\(k + 1)").font(.caption2).foregroundStyle(.secondary)
                    Text(one ? "1" : "0")
                        .font(.title2.monospaced().bold())
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(one ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(one ? Color.white : Color.secondary)
                    if k < report.notchDepthsDB.count {
                        Text(String(format: "%.1f dB", report.notchDepthsDB[k])).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if k < report.phaseSwingsDegrees.count {
                        Text(String(format: "%.0f°", report.phaseSwingsDegrees[k])).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 76)
                .help(k < frequencies.count ? "\(Fmt.mhz3(frequencies[k])) MHz" : "")
            }
        }
    }
}

struct SimulatorPanel: View {
    @EnvironmentObject var model: ReaderModel
    static let qValues = [100, 250, 500, 750, 1000, 1250, 1500, 2000, 3000, 5000]

    var body: some View {
        if let sim = model.sim {
            VStack(alignment: .leading, spacing: 8) {
                Label("Simulated tag", systemImage: "testtube.2").font(.headline)
                HStack(spacing: 20) {
                    Picker("Tag", selection: $model.simTagIndex) {
                        Text("None").tag(-1)
                        ForEach(sim.tags, id: \.index) { t in Text("\(t.name)  \(t.bitString)").tag(t.index) }
                    }
                    .frame(maxWidth: 300)
                    .onChange(of: model.simTagIndex) { _, _ in model.applySimulation() }
                    HStack {
                        Text("Distance")
                        Slider(value: $model.simDistanceCm, in: 5...100, step: 5) { editing in
                            if !editing { model.applySimulation() }
                        }
                        .frame(width: 140)
                        Text("\(Int(model.simDistanceCm)) cm").monospacedDigit().frame(width: 50, alignment: .leading)
                    }
                    Picker("Resonator Q", selection: $model.simQ) {
                        ForEach(Self.qValues, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .frame(maxWidth: 170)
                    .onChange(of: model.simQ) { _, _ in model.applySimulation() }
                }
                .disabled(!model.canConfigure)
                Text("Q sets how sharp each notch is. With 10 bits 500 kHz apart the notches merge below Q ≈ 1250; try Q 250 to see it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct SweepCharts: View {
    @EnvironmentObject var model: ReaderModel

    private var domain: ClosedRange<Double> {
        let a = model.plot.first?.mhz ?? model.sweepStartMHz, b = model.plot.last?.mhz ?? model.sweepStopMHz
        return a...max(b, a + 0.001)
    }
    private var bits: [(k: Int, mhz: Double, one: Bool)] {
        let id = model.lastReport?.id ?? 0
        return model.bitFrequenciesMHz.enumerated().map { (k: $0.offset, mhz: $0.element, one: (id >> UInt32($0.offset)) & 1 == 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.plotIsBackgroundSubtracted ? "Magnitude: received minus background (dB)" : "Magnitude: received power (dBm)")
                .font(.caption.bold())
            chart(y: \.db, label: "dB", color: .blue)
            Text("Phase: AD8302 |φ| (degrees)").font(.caption.bold())
            chart(y: \.phase, label: "°", color: .purple)
        }
        .padding(12)
    }

    private func chart(y: KeyPath<PlotPoint, Double>, label: String, color: Color) -> some View {
        Chart {
            ForEach(bits, id: \.k) { b in
                RuleMark(x: .value("bit", b.mhz))
                    .foregroundStyle(b.one ? Color.orange.opacity(0.55) : Color.gray.opacity(0.22))
            }
            ForEach(model.plot) { p in
                LineMark(x: .value("MHz", p.mhz), y: .value(label, p[keyPath: y]))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.3))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel("MHz")
    }
}

struct ReadHistory: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tags read").font(.headline)
                Text(Fmt.count(model.totalReads, "read")).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { model.clearTags() }.controlSize(.small)
            }
            Table(model.rows) {
                TableColumn("Name") { r in Text(r.name).foregroundStyle(r.name == "Not in database" ? Color.orange : Color.primary) }
                TableColumn("Pattern f1→fN") { r in Text(r.bits).font(.body.monospaced()) }.width(min: 110, ideal: 130)
                TableColumn("Count") { r in Text("\(r.count)").monospacedDigit() }.width(44)
                TableColumn("RSSI") { r in Text(String(format: "%.1f", r.rssiDBm)).monospacedDigit() }.width(46)
                TableColumn("Margin") { r in
                    Text(String(format: "%.1f", r.marginDB)).monospacedDigit().foregroundStyle(r.marginDB >= 3 ? Color.primary : Color.orange)
                }.width(50)
            }
        }
        .padding(12)
    }
}

enum Fmt {
    static func mhz(_ khz: UInt32) -> String { String(format: "%g", Double(khz) / 1000) }
    static func mhz3(_ khz: UInt32) -> String { String(format: "%.3f", Double(khz) / 1000) }
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
