import SwiftUI
import VinylDiggerKit

struct QueueView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var pickingTracks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if let card = environment.displayedCard {
                // Some records carry a dozen tracks; the card has to give way.
                ScrollView { RecordCardView(card: card) }
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
        .task { await environment.start() }
        .sheet(isPresented: $pickingTracks) {
            if let card = environment.displayedCard {
                TrackPickerView(card: card) { chosen in
                    Task { await environment.loveWithTracks(chosen) }
                }
            }
        }
    }

    /// A record with more than one track gets the picker — on an EP it is often a
    /// single cut that earns the buy.
    private func love() {
        guard let card = environment.displayedCard else { return }
        if card.tracks.count > 1 {
            pickingTracks = true
        } else {
            Task { await environment.loveWithTracks(card.tracks.map(\.youtubeID)) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if environment.mode == .inspect {
                Button {
                    environment.backToDig()
                } label: {
                    Label("Dig-Modus", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.escape, modifiers: [])
                .help("zurück zur Warteschlange")
            }

            if environment.mode == .dig {
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
            }

            if environment.mode == .dig {
                Text("\(environment.currentIndex + 1) / \(max(environment.cards.count, 1))")
                    .font(.system(.caption, design: .monospaced))
            } else {
                Text("aus der Sammlung")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(environment.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if environment.mode == .inspect {
            HStack(spacing: 12) {
                Text("Herz an einer Spur markiert einzelne Tracks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { love() } label: {
                    Label("Wantlist", systemImage: "eye.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            digControls
        }
    }

    private var digControls: some View {
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
struct TrackList: View {
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

/// Loads a sleeve through the on-disk cache and keeps the slot filled while it arrives.
struct CoverView: View {
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
