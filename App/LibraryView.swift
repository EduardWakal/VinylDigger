import SwiftUI
import VinylDiggerKit

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    /// Four record filters plus the track list, which is a different shape of thing
    /// entirely — single tracks, not records.
    private enum Selection: Hashable {
        case decision(DecisionKind)
        case all
        case tracks
    }

    @State private var selection: Selection = .decision(.love)
    @State private var entries: [LibraryEntry] = []
    @State private var likes: [LikedTrack] = []
    @State private var counts: [DecisionKind: Int] = [:]
    @State private var total = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picker
            Divider()
            content
            Divider()
            footer
        }
        .onAppear {
            reload()
            Task {
                await environment.hydrateLibrary()
                reload()
            }
        }
        .onChange(of: selection) { _, _ in reload() }
    }

    private var picker: some View {
        HStack(spacing: 8) {
            chip("Wantlist", systemImage: "eye.fill",
                 count: counts[.love] ?? 0, value: .decision(.love))
            chip("später", systemImage: "clock.arrow.circlepath",
                 count: counts[.later] ?? 0, value: .decision(.later))
            chip("weg", systemImage: "xmark",
                 count: counts[.discard] ?? 0, value: .decision(.discard))
            chip("alle", systemImage: "square.stack", count: total, value: .all)

            Divider().frame(height: 18)

            chip("Tracks", systemImage: "heart.fill", count: likes.count, value: .tracks)
            Spacer()
        }
        .padding(12)
    }

    private func chip(
        _ title: String, systemImage: String, count: Int, value: Selection
    ) -> some View {
        Button {
            selection = value
        } label: {
            Label("\(title) \(count)", systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .tint(selection == value ? .accentColor : .secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .tracks:
            if likes.isEmpty {
                empty("Noch keine Tracks", "Im Player das Herz neben einer Spur klicken.")
            } else {
                List(likes, id: \.youtubeID) { trackRow($0) }
                    .listStyle(.inset)
            }
        default:
            if entries.isEmpty {
                empty("Nichts hier", "Entscheide im Player, dann füllt sich diese Liste.")
            } else {
                List(entries, id: \.release.id) { releaseRow($0) }
                    .listStyle(.inset)
            }
        }
    }

    private func empty(_ title: String, _ hint: String) -> some View {
        ContentUnavailableView(title, systemImage: "square.stack", description: Text(hint))
            .frame(maxHeight: .infinity)
    }

    /// The whole row opens the record in the player — that is where the tracks are.
    private func releaseRow(_ entry: LibraryEntry) -> some View {
        Button {
            Task { await environment.openInPlayer(releaseID: entry.release.id) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                CoverThumb(
                    releaseID: entry.release.id,
                    remote: entry.release.coverURL,
                    store: environment.covers
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.release.artistName)
                        .font(.headline)
                    Text(entry.release.title)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if let label = entry.labelName { Text(label) }
                        if let catno = entry.release.catno { Text(catno) }
                        if let year = entry.release.year { Text(String(year)) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        if entry.release.ratingCount > 0 {
                            Label(
                                String(
                                    format: "%.2f (%d)",
                                    entry.release.rating, entry.release.ratingCount
                                ),
                                systemImage: "star.fill"
                            )
                        }
                        if entry.likedTrackCount > 0 {
                            Label("\(entry.likedTrackCount)", systemImage: "heart.fill")
                                .foregroundStyle(.pink)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(entry.decidedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 10) {
                        Image(systemName: "play.circle")
                            .foregroundStyle(.tint)

                        Button {
                            Task {
                                await environment.remove(releaseID: entry.release.id)
                                reload()
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(removeTitle(entry.kind))
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            removeButton(entry)
        }
        .contextMenu {
            removeButton(entry)
        }
    }

    /// Removing a wantlist record deletes it on Discogs as well, so the label says
    /// which list is meant rather than a bare "delete".
    private func removeButton(_ entry: LibraryEntry) -> some View {
        Button(role: .destructive) {
            Task {
                await environment.remove(releaseID: entry.release.id)
                reload()
            }
        } label: {
            Label(removeTitle(entry.kind), systemImage: "trash")
        }
    }

    private func removeTitle(_ kind: DecisionKind) -> String {
        switch kind {
        case .love: return "Von der Wantlist nehmen"
        case .later: return "Aus \"später\" nehmen"
        case .discard: return "Aus \"weg\" nehmen"
        }
    }

    private func trackRow(_ like: LikedTrack) -> some View {
        HStack(spacing: 10) {
            Button {
                environment.toggleLike(releaseID: like.releaseID, youtubeID: like.youtubeID)
                reload()
            } label: {
                Image(systemName: "heart.fill").foregroundStyle(.pink)
            }
            .buttonStyle(.borderless)
            .help("nicht mehr mögen")

            Text(like.trackPosition ?? "—")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 28, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(like.trackTitle ?? "ohne Titel")
                Text("\(like.artistName) · \(like.releaseTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let label = like.labelName {
                Text(label).font(.caption).foregroundStyle(.tertiary)
            }

            Button {
                Task { await environment.openInPlayer(releaseID: like.releaseID) }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("Platte im Player öffnen")
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text(selection == .tracks ? "\(likes.count) Tracks" : "\(entries.count) Platten")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func reload() {
        let all = environment.library(kind: nil)
        counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        total = all.count
        likes = environment.likedTracks()

        switch selection {
        case .decision(let kind): entries = environment.library(kind: kind)
        case .all: entries = all
        case .tracks: entries = []
        }
    }
}

/// Small sleeve for list rows; same cache as the player card.
struct CoverThumb: View {
    let releaseID: Int
    let remote: String?
    let store: CoverStore

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(1, contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "opticaldisc").foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: "\(releaseID)|\(remote ?? "")") {
            image = nil
            guard let remote, let url = URL(string: remote) else { return }
            guard let local = try? await store.localURL(for: releaseID, remote: url) else { return }
            image = NSImage(contentsOf: local)
        }
    }
}
