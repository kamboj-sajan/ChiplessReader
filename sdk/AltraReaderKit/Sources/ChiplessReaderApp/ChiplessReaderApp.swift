// ChiplessReaderApp - the macOS app for the chipless RFID reader, built on ChiplessKit.
//
// Open "Chipless Reader.app" (scripts/build_app.sh makes it). It finds the reader on its own
// when the board's micro-USB (CN5) cable is plugged in. Demo Mode runs the reader firmware on
// the Mac, with a simulated RF chain and tags, when no board is attached.
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // needed when launched with `swift run` (no .app bundle) so the window gets focus
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ChiplessReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = ReaderModel()

    var body: some Scene {
        Window("Chipless Reader", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Reader") {
                Button("Read Tag") { model.readOnce() }
                    .keyboardShortcut("r")
                    .disabled(!model.canConfigure)
                Button(model.autoMode ? "Stop Continuous Reading" : "Read Continuously") { model.toggleAuto() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.isConnected)
                Divider()
                Button("Save to Reader") { model.saveToReader() }
                    .keyboardShortcut("s")
                    .disabled(!model.canConfigure)
                Divider()
                Button("Find Reader") { model.findReader() }
                    .disabled(model.isConnected)
                Button(model.demoActive ? "Leave Demo Mode" : "Start Demo Mode") { model.toggleDemo() }
            }
        }
    }
}
