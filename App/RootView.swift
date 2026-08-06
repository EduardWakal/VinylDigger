import SwiftUI
import VinylDiggerKit

/// One window, three tabs. Replaces the separate Seeds and Verlauf windows, which
/// only lived in the Fenster menu and were never found.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        // The selection lives in the environment so the library can send a record
        // over to the player.
        TabView(selection: $environment.selectedTab) {
            QueueView()
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(0)

            LibraryView()
                .tabItem { Label("Sammlung", systemImage: "square.stack") }
                .tag(1)

            StatsView()
                .tabItem { Label("Statistik", systemImage: "chart.bar") }
                .tag(2)
        }
        .frame(minWidth: 720, minHeight: 720)
    }
}
