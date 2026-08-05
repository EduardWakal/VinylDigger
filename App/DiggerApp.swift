import SwiftUI
import DiggerKit

@main
struct DiggerApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            QueueView()
                .environmentObject(environment)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Queue neu berechnen") {
                    Task { await environment.reload() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Window("Seeds", id: "seeds") {
            SeedsView().environmentObject(environment)
        }

        Window("Verlauf", id: "history") {
            HistoryView().environmentObject(environment)
        }

        Settings {
            SettingsView().environmentObject(environment)
        }
    }
}
