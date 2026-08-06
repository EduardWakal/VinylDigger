import SwiftUI
import VinylDiggerKit

/// One window, three tabs. Replaces the separate Seeds and Verlauf windows, which
/// only lived in the Fenster menu and were never found.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        TabView {
            QueueView()
                .tabItem { Label("Player", systemImage: "play.circle") }

            LibraryView()
                .tabItem { Label("Sammlung", systemImage: "square.stack") }

            StatsView()
                .tabItem { Label("Statistik", systemImage: "chart.bar") }
        }
        .frame(minWidth: 720, minHeight: 720)
    }
}
