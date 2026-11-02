import SwiftUI

@main
struct ReaderManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Altra Reader Manager") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}
