import SwiftUI
import ChiplessKit

/// The list the STM32 identifies tags against. It lives on the reader, not on the Mac.
struct DatabaseView: View {
    @EnvironmentObject var model: ReaderModel
    @State private var selection = Set<TagDatabaseEntry.ID>()
    @State private var editing: EntryDraft?

    var body: some View {
        if !model.isConnected {
            NotConnectedPlaceholder()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { editing = EntryDraft() } label: { Label("Add Tag", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button {
                        if let e = selectedEntries.first { editing = EntryDraft(entry: e) }
                    } label: { Label("Edit", systemImage: "pencil") }
                        .disabled(selectedEntries.count != 1)
                    Button {
                        model.deleteEntries(selectedEntries)
                        selection.removeAll()
                    } label: { Label("Delete", systemImage: "trash") }
                        .disabled(selectedEntries.isEmpty)
                    Spacer()
                    Text("\(model.database.count) of \(model.databaseCapacity) tags").foregroundStyle(.secondary)
                    Button("Import…") { model.importDatabase() }
                    Button("Export…") { model.exportDatabase() }.disabled(model.database.isEmpty)
                }
                .padding(12)
                .disabled(!model.canConfigure)

                Table(model.database, selection: $selection) {
                    TableColumn("Name", value: \.name)
                    TableColumn("Pattern f1→fN") { e in Text(e.bitString).font(.body.monospaced()) }
                    TableColumn("ID") { e in Text(e.hexID).font(.body.monospaced()) }.width(80)
                    TableColumn("Bits") { e in Text("\(e.bitCount)").monospacedDigit() }.width(40)
                }
                .contextMenu(forSelectionType: TagDatabaseEntry.ID.self) { ids in
                    Button("Delete") { model.deleteEntries(model.database.filter { ids.contains($0.id) }) }
                } primaryAction: { ids in
                    if let id = ids.first, let e = model.database.first(where: { $0.id == id }) { editing = EntryDraft(entry: e) }
                }

                Text("The reader compares each decoded pattern against this list. Changes take effect at once; Save to Reader keeps them across power cycles.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
            }
            .sheet(item: $editing) { draft in
                EntryEditor(draft: draft, bitHint: model.bitFrequenciesMHz.count)
            }
        }
    }

    private var selectedEntries: [TagDatabaseEntry] { model.database.filter { selection.contains($0.id) } }
}

struct EntryDraft: Identifiable {
    let id = UUID()
    var original: TagDatabaseEntry?
    init(entry: TagDatabaseEntry? = nil) { original = entry }
}

struct EntryEditor: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let draft: EntryDraft
    let bitHint: Int
    @State private var name = ""
    @State private var pattern = ""

    private var entry: TagDatabaseEntry? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        return TagDatabaseEntry(name: String(n.prefix(16)), bitString: pattern)
    }
    private var clash: TagDatabaseEntry? {
        guard let e = entry, e.id != draft.original?.id else { return nil }
        return model.database.first { $0.id == e.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.original == nil ? "Add a tag" : "Edit tag").font(.title3.bold())
            LabeledContent("Name") { TextField("Up to 16 characters", text: $name).labelsHidden() }
            LabeledContent("Bit pattern") {
                TextField("1010110011", text: $pattern).labelsHidden().font(.body.monospaced())
            }
            Text("Written f1 first (lowest frequency on the left): 1 where the tag has a resonator, 0 where it doesn't.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !pattern.isEmpty && TagPattern.id(fromBits: pattern) == nil {
                Label("Use only 0 and 1, 16 digits at most.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if !pattern.isEmpty && pattern.count != bitHint {
                Label("The reader is set for \(bitHint) bits. This \(pattern.count)-bit tag only matches under a \(pattern.count)-bit format.", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if pattern.allSatisfy({ $0 == "0" }) && !pattern.isEmpty {
                Label("A tag with no resonators looks the same as no tag at all.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let c = clash { Label("This replaces the name \"\(c.name)\" for the same pattern.", systemImage: "info.circle").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.original == nil ? "Add" : "Save") {
                    if let e = entry { model.putEntry(e, replacing: draft.original) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            name = draft.original?.name ?? ""
            pattern = draft.original?.bitString ?? ""
        }
    }
}
