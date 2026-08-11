import SwiftUI
import VinylDiggerKit

/// One window, three tabs. Replaces the separate Seeds and Verlauf windows, which
/// only lived in the Fenster menu and were never found.
struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    // TabView writes its selection back while this view is updating, so the
    // binding cannot point straight at a @Published on the environment. The tab
    // held here, mirrored both ways below, keeps the write out of the update.
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            QueueView()
                .tabItem { Label("Player", systemImage: "play.circle") }
                .tag(0)

            DiscoveryView()
                .tabItem { Label("Entdecken", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(3)

            LibraryView()
                .tabItem { Label("Sammlung", systemImage: "square.stack") }
                .tag(1)

            StatsView()
                .tabItem { Label("Statistik", systemImage: "chart.bar") }
                .tag(2)
        }
        // Mounted once on the TabView, not inside a single tab: macOS unmounts an
        // unselected tab's views entirely, and a WKWebView outside the hierarchy
        // does not reliably keep playing.
        .background(PlayerHost(controller: environment.player).frame(width: 1, height: 1))
        .frame(minWidth: 720, minHeight: 720)
        // The environment stays the channel the library uses to send a record over
        // to the player, so the two selections are kept level in both directions.
        .onChange(of: environment.selectedTab) { _, requested in tab = requested }
        .onChange(of: tab) { _, selected in environment.selectedTab = selected }
    }
}
