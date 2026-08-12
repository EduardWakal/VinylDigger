import SwiftUI
import VinylDiggerKit

/// The transport. Belongs to the window, not to a tab: a record started in the
/// discovery tab has to stay steerable from every other tab.
struct TransportView: View {
    @ObservedObject var player: PlayerController
    let onLikeCurrent: () -> Void

    @State private var scrub: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(player.hasLoadedVideo ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))

                if player.hasLoadedVideo {
                    Text(player.currentTrackLabel ?? "l\u{00E4}uft")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let context = player.contextLabel {
                        Text(context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("nichts geladen")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text("\(formatSeconds(player.position)) / \(formatSeconds(player.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { player.isScrubbing ? scrub : player.position },
                    set: { scrub = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        scrub = player.position
                        player.isScrubbing = true
                    } else {
                        player.isScrubbing = false
                        player.seek(to: scrub)
                    }
                }
            )
            .disabled(player.duration <= 0)

            HStack(spacing: 8) {
                Button { player.restart() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .help("von vorn")

                Button { player.seek(by: -10) } label: {
                    Image(systemName: "gobackward.10")
                }
                .keyboardShortcut("[", modifiers: [])
                .help("10 Sekunden zurück")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Wiedergabe")

                Button { player.seek(by: 10) } label: {
                    Image(systemName: "goforward.10")
                }
                .keyboardShortcut("]", modifiers: [])
                .help("10 Sekunden vor")

                Button { player.nextVideo() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .help("nächste Spur")

                Button { onLikeCurrent() } label: {
                    Image(systemName: "heart")
                }
                .keyboardShortcut("l", modifiers: [])
                .help("laufende Spur mögen")

                Spacer()
            }
            .disabled(!player.hasLoadedVideo)
        }
    }
}

func formatSeconds(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
