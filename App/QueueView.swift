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
            TransportView(player: environment.player) {
                environment.likeCurrentlyPlaying()
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
        HStack(spacing: 10) {
            Button {
                environment.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!environment.canGoBack)
            .help("vorige Platte")

            Button {
                environment.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!environment.canGoForward)
            .help("nächste Platte")

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
            }

            Text("warum: \(card.reason)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { Task { await environment.decide(.discard) } } label: {
                Label("weg", systemImage: "xmark")
            }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

            Button { Task { await environment.decide(.later) } } label: {
                Label("später", systemImage: "clock.arrow.circlepath")
            }
                .keyboardShortcut(.downArrow, modifiers: [.command])

            Spacer()

            Button { love() } label: {
                Label("Wantlist", systemImage: "eye.fill")
            }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
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
                HStack(spacing: 10) {
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
                            Spacer(minLength: 12)
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

                    Button {
                        onToggleLike(track.youtubeID)
                    } label: {
                        Image(systemName: track.liked ? "heart.fill" : "heart")
                            .foregroundStyle(track.liked ? AnyShapeStyle(.pink) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.borderless)
                    .help(track.liked ? "Track nicht mehr mögen" : "Track mögen")
                }
            }
        }
    }
}

/// The transport. Sits below the card and stays put, so playback can always be
/// stopped — a card without a preview used to take the pause button with it.
private struct TransportView: View {
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
