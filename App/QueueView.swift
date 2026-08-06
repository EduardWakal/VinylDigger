import SwiftUI
import VinylDiggerKit

struct QueueView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var pickingTracks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if let card = environment.currentCard {
                cardBody(card)
            } else {
                ContentUnavailableView(
                    "Queue leer",
                    systemImage: "opticaldisc",
                    description: Text("Entscheide ein paar Releases, damit der Graph nachwachsen kann.")
                )
                .frame(maxHeight: .infinity)
            }
            Divider()
            controls
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 640)
        .background(PlayerHost(controller: environment.player).frame(width: 1, height: 1))
        .task { await environment.start() }
        .sheet(isPresented: $pickingTracks) {
            if let card = environment.currentCard {
                TrackPickerView(card: card) { chosen in
                    Task { await environment.loveWithTracks(chosen) }
                }
            }
        }
    }

    /// A record with more than one track gets the picker — on an EP it is often a
    /// single cut that earns the buy.
    private func love() {
        guard let card = environment.currentCard else { return }
        if card.tracks.count > 1 {
            pickingTracks = true
        } else {
            Task { await environment.loveWithTracks(card.tracks.map(\.youtubeID)) }
        }
    }

    private var header: some View {
        HStack {
            Text("\(environment.currentIndex + 1) / \(max(environment.cards.count, 1))")
                .font(.system(.caption, design: .monospaced))
            Spacer()
            Text(environment.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cardBody(_ card: QueueCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                CoverView(
                    releaseID: card.releaseID, remote: card.coverURL, store: environment.covers
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(card.artistName)
                        .font(.title2.weight(.semibold))
                    Text(card.title)
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if let label = card.labelName { Text(label) }
                        if let catno = card.catno { Text(catno) }
                        if let year = card.year { Text(String(year)) }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Text(card.styles.joined(separator: " · "))
                        if let rating = card.rating {
                            Label(
                                String(format: "%.2f (%d)", rating, card.ratingCount),
                                systemImage: "star.fill"
                            )
                        }
                        Label("\(card.want)", systemImage: "heart")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if card.tracks.isEmpty {
                Label("kein Preview", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                TrackList(
                    releaseID: card.releaseID,
                    tracks: card.tracks,
                    player: environment.player,
                    onToggleLike: { environment.toggleLike(releaseID: card.releaseID, youtubeID: $0) }
                )
                TransportView(player: environment.player) {
                    guard let id = environment.player.currentVideoID else { return }
                    environment.toggleLike(releaseID: card.releaseID, youtubeID: id)
                }
            }

            Text("warum: \(card.reason)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("✗ weg") { Task { await environment.decide(.discard) } }
                .keyboardShortcut(.leftArrow, modifiers: [])

            Button("↓ später") { Task { await environment.decide(.later) } }
                .keyboardShortcut(.downArrow, modifiers: [])

            Spacer()

            Button("♥ Wantlist") { love() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .buttonStyle(.borderedProminent)
        }
        .disabled(environment.currentCard == nil)
    }
}

/// The playable videos of the release. Observes the player directly so the marker
/// follows along when a track ends and the next one starts on its own.
private struct TrackList: View {
    let releaseID: Int
    let tracks: [QueueTrack]
    @ObservedObject var player: PlayerController
    let onToggleLike: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    player.play(index: index)
                } label: {
                    HStack(spacing: 8) {
                        Text(index == player.currentIndex ? "\u{25B8}" : " ")
                            .font(.system(.caption, design: .monospaced))
                        Text(track.position ?? "\u{2014}")
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 28, alignment: .leading)
                        Text(track.title ?? "ohne Titel")
                            .lineLimit(1)
                        Spacer()
                        if let duration = track.duration {
                            Text(formatSeconds(TimeInterval(duration)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .fontWeight(index == player.currentIndex ? .semibold : .regular)
                .overlay(alignment: .trailing) {
                    Button {
                        onToggleLike(track.youtubeID)
                    } label: {
                        Image(systemName: track.liked ? "star.fill" : "star")
                            .foregroundStyle(track.liked ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.borderless)
                    .offset(x: 22)
                    .help(track.liked ? "Markierung entfernen" : "Track markieren")
                }
            }
        }
    }
}

/// Observes the player directly — SwiftUI does not follow an ObservableObject
/// held inside another one, so reading it through AppEnvironment would leave the
/// progress bar and the play/pause label frozen.
private struct TransportView: View {
    @ObservedObject var player: PlayerController
    let onLikeCurrent: () -> Void

    @State private var scrub: TimeInterval = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                Button("\u{23EE}") { player.restart() }
                Button("\u{2212}10 s") { player.seek(by: -10) }
                    .keyboardShortcut("[", modifiers: [])
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("+10 s") { player.seek(by: 10) }
                    .keyboardShortcut("]", modifiers: [])
                Button("\u{23ED}") { player.nextVideo() }
                Button("\u{2605} L") { onLikeCurrent() }
                    .keyboardShortcut("l", modifiers: [])
                    .help("laufende Spur markieren")
                Spacer()
                Text("\(formatSeconds(player.position)) / \(formatSeconds(player.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Loads a sleeve through the on-disk cache and keeps the slot filled while it arrives.
private struct CoverView: View {
    let releaseID: Int
    let remote: String?
    let store: CoverStore

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "opticaldisc")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // Keyed on the URL too: hydration fills the cover in after the card is
        // already on screen, and the release ID alone would not change then.
        .task(id: "\(releaseID)|\(remote ?? "")") { await load() }
    }

    private func load() async {
        image = nil
        guard let remote, let url = URL(string: remote) else { return }
        guard let local = try? await store.localURL(for: releaseID, remote: url) else { return }
        image = NSImage(contentsOf: local)
    }
}

private func formatSeconds(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
