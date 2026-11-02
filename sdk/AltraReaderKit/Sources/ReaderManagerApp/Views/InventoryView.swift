import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReaderSDK

struct InventoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InventoryTableView(inventory: model.inventory, model: model)
    }
}

/// Observes `InventorySession` directly (rather than through `AppModel`) so
/// updates to `rows`/`totalReads` — which are `@Published` on the session itself —
/// actually trigger a redraw.
private struct InventoryTableView: View {
    @ObservedObject var inventory: InventorySession
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\InventoryRow.readCount, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(inventory.rows.count) tags").font(.headline)
                Text("·").foregroundStyle(.secondary)
                Text("\(inventory.totalReads) reads").foregroundStyle(.secondary)
                Spacer()
                Button(model.isInventoryRunning ? "Stop" : "Start") {
                    Task { await model.toggleInventory() }
                }
                .disabled(!model.isConnected)
                Button("Single Scan") { Task { await model.performSingleScan() } }
                    .disabled(!model.isConnected || model.isInventoryRunning)
                Button("Clear") { inventory.clear() }
                Menu("Export") {
                    Button("Export CSV…") { exportCSV() }
                    Button("Export JSON…") { exportJSON() }
                }
                .disabled(inventory.rows.isEmpty)
            }
            .padding()

            if inventory.rows.isEmpty {
                ContentUnavailableView(
                    model.isConnected ? "No tags seen yet" : "Not connected",
                    systemImage: "wave.3.right",
                    description: Text(model.isConnected
                        ? "Start inventory to begin reading tags."
                        : "Connect to a reader on the Connect screen first.")
                )
                .frame(maxHeight: .infinity)
            } else {
                Table(filteredRows, sortOrder: $sortOrder) {
                    TableColumn("EPC", value: \.epc)
                    TableColumn("Antenna") { row in Text("\(row.antenna)") }
                    TableColumn("RSSI") { row in Text("\(row.lastRSSI) dBm") }
                    TableColumn("Reads") { row in Text("\(row.readCount)") }
                    TableColumn("First Seen") { row in Text(row.firstSeen, style: .time) }
                    TableColumn("Last Seen") { row in Text(row.lastSeen, style: .time) }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Filter by EPC")
    }

    private var filteredRows: [InventoryRow] {
        let base = searchText.isEmpty
            ? inventory.rows
            : inventory.rows.filter { $0.epc.localizedCaseInsensitiveContains(searchText) }
        return base.sorted(using: sortOrder)
    }

    private func exportCSV() {
        save(data: Data(InventoryExport.csv(inventory.rows).utf8), suggestedName: "inventory.csv", type: .commaSeparatedText)
    }

    private func exportJSON() {
        guard let data = try? InventoryExport.json(inventory.rows) else { return }
        save(data: data, suggestedName: "inventory.json", type: .json)
    }

    private func save(data: Data, suggestedName: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
