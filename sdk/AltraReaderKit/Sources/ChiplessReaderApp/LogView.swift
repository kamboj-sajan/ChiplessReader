import SwiftUI
import AppKit

struct LogView: View {
    @EnvironmentObject var model: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Show frames in hex", isOn: $model.showFrames).toggleStyle(.checkbox)
                Spacer()
                if !model.isConnected {
                    Menu("Connect to Port") {
                        ForEach(model.ports, id: \.self) { p in Button(p) { model.connect(to: p) } }
                        if model.ports.isEmpty { Text("No serial ports found") }
                    }
                    .frame(width: 170)
                } else {
                    Text(model.portPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { model.log.removeAll() }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: model.log.count) { _, n in
                    if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
                .onAppear { if !model.log.isEmpty { proxy.scrollTo(model.log.count - 1, anchor: .bottom) } }
            }
        }
    }
}
