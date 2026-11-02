import SwiftUI
import ReaderTransport

struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var isConnecting = false

    var body: some View {
        Form {
            Section("Connection Settings") {
                Picker("Transport", selection: $model.connectionKind) {
                    ForEach(ConnectionKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .disabled(model.isConnected)

                switch model.connectionKind {
                case .mock:
                    Text("No hardware required — generates simulated tag traffic.")
                        .foregroundStyle(.secondary)
                case .serial:
                    Picker("Device", selection: $model.serialPath) {
                        ForEach(model.availableSerialDevices, id: \.self) { Text($0).tag($0) }
                        if model.availableSerialDevices.isEmpty {
                            Text("No serial devices found").tag("")
                        }
                    }
                    .disabled(model.isConnected)
                    TextField("Baud rate", text: $model.baudRate)
                        .disabled(model.isConnected)
                case .tcp:
                    TextField("Host / IP", text: $model.tcpHost)
                        .disabled(model.isConnected)
                    TextField("Port", text: $model.tcpPort)
                        .disabled(model.isConnected)
                }
            }

            Section {
                HStack {
                    Button(model.isConnected ? "Disconnect" : "Connect") {
                        Task {
                            isConnecting = true
                            if model.isConnected {
                                await model.disconnect()
                            } else {
                                await model.connect()
                            }
                            isConnecting = false
                        }
                    }
                    .disabled(isConnecting)
                    if isConnecting { ProgressView().controlSize(.small) }
                }
            }

            if let info = model.readerInfo {
                Section("Hardware Information") {
                    LabeledContent("Mainboard", value: info.mainboardType)
                    LabeledContent("Module", value: info.moduleType)
                    LabeledContent("Hardware Version", value: info.hardwareVersion)
                    LabeledContent("Software Version", value: info.softwareVersion)
                    LabeledContent("Antenna Ports", value: "\(info.antennaCount)")
                }
            } else if model.connectionKind != .mock, model.isConnected {
                Section("Hardware Information") {
                    Text("Reader connected at the transport level, but reader commands are blocked until the wire protocol is verified for this module. See Documentation/PROTOCOL.md.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
