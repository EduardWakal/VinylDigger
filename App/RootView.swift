import SwiftUI
import VinylDiggerKit

/// One window, three tabs. Replaces the separate Seeds and Verlauf windows, which
/// only lived in the Fenster menu and were never found.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    /// Always opens on the player — that is the tab the app exists for.
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
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
