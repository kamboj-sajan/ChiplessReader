import SwiftUI
import ChiplessKit

struct ContentView: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(AppSection.allCases, selection: Binding(get: { model.section }, set: { model.section = $0 ?? .read })) { s in
                    Label(s.rawValue, systemImage: s.symbol).tag(s)
                }
                ConnectionStatusCard().padding(10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let e = model.errorMessage { ErrorBanner(message: e) }
                switch model.section {
                case .read: ReadView()
                case .setup: SetupView()
                case .database: DatabaseView()
                case .calibration: CalibrationView()
                case .log: LogView()
                }
            }
            .navigationTitle(model.section.rawValue)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.busy { ProgressView().controlSize(.small) }
                    if model.isConnected {
                        Button {
                            model.saveToReader()
                        } label: {
                            Label(model.unsavedChanges ? "Save to Reader" : "Saved", systemImage: model.unsavedChanges ? "square.and.arrow.down" : "checkmark.circle")
                        }
                        .labelStyle(.titleAndIcon)
                        .disabled(!model.unsavedChanges || !model.canConfigure)
                        .help("Store the settings, calibration and tag database in the reader, so they survive a power cycle")
                    }
                }
            }
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var model: ReaderModel
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") { model.errorMessage = nil }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
    }
}

/// Bottom of the sidebar: what the app is connected to, and what to do if it isn't.
struct ConnectionStatusCard: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .searching:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking for the reader…").font(.callout) }
            case .noReader:
                Label("No reader found", systemImage: "cable.connector.slash").font(.callout.bold())
                Text("Connect the board's micro-USB port (CN5) to this Mac. The app will find it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Try Demo Mode") { model.toggleDemo() }.controlSize(.small)
            case .outdatedFirmware(let v):
                Label("Firmware \(v) on the board", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold()).foregroundStyle(.orange)
                Text("Needs firmware \(ReaderModel.requiredFirmware.major).\(ReaderModel.requiredFirmware.minor).")
                    .font(.caption).foregroundStyle(.secondary)
            case .connected:
                if let i = model.info {
                    Label(model.demoActive ? "Demo Mode" : "Reader connected", systemImage: model.demoActive ? "play.circle.fill" : "checkmark.circle.fill")
                        .font(.callout.bold())
                        .foregroundStyle(model.demoActive ? Color.orange : Color.green)
                    Text("\(i.model), firmware \(i.firmwareVersion)").font(.caption).foregroundStyle(.secondary)
                    Text(i.simulatedFrontEnd ? "Simulated RF" : "RF hardware").font(.caption).foregroundStyle(.secondary)
                    if model.demoActive {
                        Button("Leave Demo Mode") { model.toggleDemo() }.controlSize(.small)
                    } else {
                        Button("Disconnect") { model.disconnect() }.controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Shown on screens that need a reader when none is connected.
struct NotConnectedPlaceholder: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        if case .outdatedFirmware(let v) = model.state {
            ContentUnavailableView {
                Label("The board needs new firmware", systemImage: "cpu")
            } description: {
                Text("The board answered, but it runs firmware \(v) and this app needs \(ReaderModel.requiredFirmware.major).\(ReaderModel.requiredFirmware.minor). Flash firmware/stm32/prebuilt/chipless_reader.elf from STM32CubeIDE: Run ▸ Debug Configurations, select the .elf, Debug, then Resume.")
            } actions: {
                Button("Check Again") { model.findReader() }.buttonStyle(.borderedProminent)
                Button("Try Demo Mode") { model.toggleDemo() }
            }
        } else {
            ContentUnavailableView {
                Label("No reader connected", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text("Connect the board's micro-USB port (CN5). The app finds it on its own. To try the app without a board, use Demo Mode: it runs the same firmware on this Mac with a simulated radio and tags.")
            } actions: {
                Button("Try Demo Mode") { model.toggleDemo() }.buttonStyle(.borderedProminent)
                Button("Look Again") { model.findReader() }
            }
        }
    }
}
