import SwiftUI
import ChiplessKit

/// Everything the reader must be told about the tags and the transmit signal: the agreement between
/// tag and reader (which frequencies, what rate) and the ADF4351 gain.
struct SetupView: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        if !model.isConnected {
            NotConnectedPlaceholder()
        } else {
            Form {
                TagFormatSection()
                SweepSection()
                GainSection()
                RateSection()
                DecisionSection()
                Section {
                    HStack {
                        Button("Restore Defaults") { model.resetReaderSettings() }
                        Spacer()
                        Button("Discard") { model.loadReaderState() }.disabled(!model.draftDiffersFromReader)
                        Button("Apply to Reader") { model.applyProfile() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.draftDiffersFromReader)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!model.canConfigure)
        }
    }
}

struct TagFormatSection: View {
    @EnvironmentObject var model: ReaderModel

    private var bitCount: Binding<Int> {
        Binding(get: { model.bitFrequenciesMHz.count }, set: { model.setBitCount($0) })
    }
    private var preset: Binding<Int> {
        Binding(get: { [1, 2, 10].contains(model.bitFrequenciesMHz.count) ? model.bitFrequenciesMHz.count : 0 },
                set: { if $0 != 0 { model.setBitCount($0) } })
    }

    var body: some View {
        Section {
            Picker("Tag format", selection: preset) {
                Text("Single (1 bit)").tag(1)
                Text("Double (2 bits)").tag(2)
                Text("Ten-bit").tag(10)
                if preset.wrappedValue == 0 { Text("\(model.bitFrequenciesMHz.count) bits").tag(0) }
            }
            .pickerStyle(.segmented)
            Stepper("Bits: \(model.bitFrequenciesMHz.count)", value: bitCount, in: 1...16)
            TextField("Profile name", text: $model.profileName)
            DisclosureGroup("Bit frequencies (one resonator per bit)") {
                ForEach(model.bitFrequenciesMHz.indices, id: \.self) { k in
                    HStack {
                        Text("f\(k + 1)").frame(width: 34, alignment: .leading).foregroundStyle(.secondary)
                        TextField("MHz", value: $model.bitFrequenciesMHz[k], format: .number.precision(.fractionLength(3)))
                            .labelsHidden()
                            .frame(width: 110)
                        Text("MHz").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                Button("Space Evenly Across the Sweep") { model.setBitCount(model.bitFrequenciesMHz.count) }
            }
        } header: {
            Text("Tag format")
        } footer: {
            Text("The default splits the band into equal cells with one bit at each centre. Replace these with the frequencies your fabricated tags actually resonate at.")
        }
    }
}

struct SweepSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        let p = model.draftProfile
        Section {
            LabeledContent("Band") {
                HStack {
                    TextField("Start", value: $model.sweepStartMHz, format: .number).labelsHidden().frame(width: 80)
                    Text("to")
                    TextField("Stop", value: $model.sweepStopMHz, format: .number).labelsHidden().frame(width: 80)
                    Text("MHz")
                }
            }
            LabeledContent("Step") {
                HStack {
                    TextField("Step", value: $model.sweepStepKHz, format: .number).labelsHidden().frame(width: 80)
                    Text("kHz")
                }
            }
            LabeledContent("Sweep") {
                Text("\(p.sweepPoints) points, about \(estimatedMs(p)) ms").monospacedDigit()
            }
            LabeledContent("Closest bit spacing") {
                Text("\(p.minimumBitSpacingKHz) kHz, \(pointsPerBit(p)) sweep points").monospacedDigit()
            }
            LabeledContent("Tags need resonator Q of about") {
                Text("\(p.requiredResonatorQ) or higher").monospacedDigit()
                    .foregroundStyle(p.requiredResonatorQ > 500 ? Color.orange : Color.primary)
            }
            if p.sweepPoints > 512 {
                Label("The reader holds at most 512 points. Use a larger step or a narrower band.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if pointsPerBit(p) < 4 {
                Label("Fewer than 4 sweep points per bit: notches can fall between points. Use a smaller step.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } header: {
            Text("Frequency sweep")
        } footer: {
            Text("Q estimate from the simulated front-end. Printed copper resonators usually reach a few hundred, so measure real tags on a VNA before relying on a narrow layout.")
        }
    }

    private func pointsPerBit(_ p: TagProfile) -> Int { Int(p.minimumBitSpacingKHz / max(p.sweepStepKHz, 1)) }

    /// PA ramp, then for each point: SPI, band selection, settle, ADC samples (ADF4351, MAX2235 and STM32 timings).
    private func estimatedMs(_ p: TagProfile) -> Int {
        let perPoint = 25.0 + 80.0 + Double(p.settleMicroseconds) + Double(p.averages) * 5.0
        return Int((1000 + Double(p.sweepPoints) * perPoint) / 1000)
    }
}

struct GainSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section {
            Picker("ADF4351 output", selection: $model.txLevel) {
                ForEach(TxPowerLevel.allCases, id: \.self) { Text($0.description).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Power amplifier (MAX2235)", isOn: $model.paEnabled)
            HStack {
                if let tx = model.txPowerDBm {
                    Text(String(format: "About %.1f dBm at the antenna", tx)).monospacedDigit()
                }
                Spacer()
                Button("Apply Gain") { model.applyTxPower() }
            }
        } header: {
            Text("Gain")
        } footer: {
            Text("The MAX2235 is close to saturation at these drive levels (datasheet curve at 3.6 V): the 9 dB range at the ADF4351 moves the antenna power by only about 3 dB. The PA runs only during measurements.")
        }
    }
}

struct RateSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section("Read rate") {
            LabeledContent("Continuous reading") {
                HStack {
                    Text("every")
                    TextField("ms", value: $model.readIntervalMs, format: .number).labelsHidden().frame(width: 70)
                    Text("ms")
                }
            }
            LabeledContent("Settle after each step") {
                HStack {
                    TextField("µs", value: $model.settleMicroseconds, format: .number).labelsHidden().frame(width: 70)
                    Text("µs")
                }
            }
            Stepper("ADC samples averaged per point: \(Int(model.averages))", value: $model.averages, in: 1...64)
        }
    }
}

struct DecisionSection: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        Section {
            HStack {
                Text("Notch depth for a 1")
                Slider(value: $model.thresholdDB, in: 1...20, step: 0.5)
                Text(String(format: "%.1f dB", model.thresholdDB)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            HStack {
                Text("Phase swing that confirms it")
                Slider(value: $model.phaseThresholdDegrees, in: 0...60, step: 1)
                Text(model.phaseThresholdDegrees == 0 ? "Off" : String(format: "%.0f°", model.phaseThresholdDegrees)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            Stepper("Database match may differ by \(Fmt.count(model.maxBitErrors, "bit"))", value: $model.maxBitErrors, in: 0...4)
        } header: {
            Text("Bit decision")
        } footer: {
            Text("A bit reads 1 when the notch is deep enough and the phase moves with it, unless the notch is more than twice the threshold. A level step with no resonance behind it moves no phase.")
        }
    }
}
