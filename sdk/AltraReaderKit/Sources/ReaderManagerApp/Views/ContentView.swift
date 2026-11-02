import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case connect = "Connect"
    case inventory = "Inventory"
    case tagAccess = "Tag Access"
    case configuration = "Configuration"
    case logs = "Logs & Diagnostics"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .connect: return "cable.connector"
        case .inventory: return "list.bullet.rectangle"
        case .tagAccess: return "pencil.and.list.clipboard"
        case .configuration: return "slider.horizontal.3"
        case .logs: return "terminal"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: AppSection? = .connect

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Altra Reader")
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selection ?? .connect {
                case .connect: ConnectView()
                case .inventory: InventoryView()
                case .tagAccess: TagAccessView()
                case .configuration: ConfigurationView()
                case .logs: LogsView()
                }
            }
            .navigationTitle((selection ?? .connect).rawValue)
            .toolbar {
                ToolbarItem(placement: .status) {
                    ConnectionStatusBadge()
                }
            }
        }
        .alert("Error", isPresented: errorBinding, presenting: model.lastErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.lastErrorMessage != nil }, set: { shown in if !shown { model.clearError() } })
    }
}

struct ConnectionStatusBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isConnected ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(model.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
