import SwiftUI
import VinylDiggerKit

@main
struct VinylDiggerApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Queue neu berechnen") {
                    Task { await environment.reload() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }



        Settings {
            SettingsView().environmentObject(environment)
        }
    }
}
