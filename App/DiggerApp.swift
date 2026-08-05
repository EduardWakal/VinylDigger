import SwiftUI
import DiggerKit

@main
struct DiggerApp: App {
    @StateObject private var player = PlayerController()

    var body: some Scene {
        WindowGroup {
            VStack {
                Text("Player-Prüfstand")
                    .font(.headline)
                Text(player.currentVideoID ?? "kein Video")
                    .font(.system(.body, design: .monospaced))
                Text(String(format: "%.0f / %.0f s", player.elapsed, player.windowLength))
                HStack {
                    Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    Button("Nächstes Video") { player.nextVideo() }
                    Button("+60 s") { player.extendWindow() }
                }
                PlayerHost(controller: player)
                    .frame(width: 1, height: 1)
            }
            .padding()
            .frame(minWidth: 420, minHeight: 260)
            .onAppear {
                player.load(videoIDs: ["cqRa3O8xQNQ", "phnuYmvJYvk"])
            }
        }
    }
}
