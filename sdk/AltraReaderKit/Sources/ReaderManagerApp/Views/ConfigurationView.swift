import SwiftUI
import ReaderProtocol

struct ConfigurationView: View {
    @EnvironmentObject var model: AppModel
    @State private var region: RFRegion = .na
    @State private var rfPowerDBm: Double = 30
    @State private var session: Gen2Session = .s0
    @State private var target: Gen2Target = .a
    @State private var qValue: Double = 4
    @State private var filterEnabled = false
    @State private var filterBank: MemoryBank = .epc
    @State private var filterMask = ""
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("RF Region") {
                Picker("Region", selection: $region) {
                    ForEach(RFRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Apply Region") { apply { try await model.applyRegion(region) } }
            }

            Section("RF Power") {
                HStack {
                    Slider(value: $rfPowerDBm, in: 0...33, step: 1)
                    Text("\(Int(rfPowerDBm)) dBm").monospacedDigit().frame(width: 60)
                }
                Button("Apply Power (All Antennas)") { apply { try await model.applyPower(Int(rfPowerDBm)) } }
            }

            Section("Gen2 Parameters") {
                Picker("Session", selection: $session) {
                    ForEach(Gen2Session.allCases, id: \.self) { Text("S\($0.rawValue)").tag($0) }
                }
                Picker("Target", selection: $target) {
                    ForEach(Gen2Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Q Value: \(Int(qValue))", value: $qValue, in: 0...15)
                Button("Apply Gen2 Config") {
                    apply { try await model.applyGen2(Gen2Configuration(session: session, target: target, qValue: Int(qValue))) }
                }
            }

            Section("Tag Filter") {
                Toggle("Enable Filter", isOn: $filterEnabled)
                Picker("Bank", selection: $filterBank) {
                    ForEach(MemoryBank.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .disabled(!filterEnabled)
                TextField("Mask (hex)", text: $filterMask).disabled(!filterEnabled).font(.system(.body, design: .monospaced))
                Button("Apply Filter") {
                    apply {
                        let filter = filterEnabled ? TagFilter(bank: filterBank, startBit: 32, maskHex: filterMask) : nil
                        try await model.applyFilter(filter)
                    }
                }
            }

            if let statusMessage {
                Section { Text(statusMessage).foregroundStyle(.secondary) }
            }

            if !model.isConnected {
                Section {
                    Text("Connect to a reader first — settings apply live, matching the reference app's model (no offline profile editing yet).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .disabled(!model.isConnected)
    }

    private func apply(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                statusMessage = "Applied."
            } catch {
                statusMessage = "Failed: \(error)"
            }
        }
    }
}
