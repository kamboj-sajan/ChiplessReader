import SwiftUI

struct LogsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.connectionKind == .mock {
                HStack {
                    Text("Simulation fault injection:").foregroundStyle(.secondary)
                    Button("Malformed Packet") { Task { await model.injectMalformedPacket() } }
                    Button("Simulate Disconnect") { Task { await model.injectDisconnect() } }
                    Spacer()
                }
                .padding()
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.logLines.count) { _, _ in
                    if let last = model.logLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            if model.logLines.isEmpty {
                ContentUnavailableView("No log entries yet", systemImage: "terminal")
                    .frame(maxHeight: .infinity)
            }
        }
    }
}
