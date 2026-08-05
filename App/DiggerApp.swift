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
    }
}
