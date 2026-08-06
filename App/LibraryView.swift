import SwiftUI
import VinylDiggerKit

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var filter: DecisionKind? = .love
    @State private var entries: [LibraryEntry] = []
    @State private var counts: [DecisionKind: Int] = [:]
    @State private var ownedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            picker
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nichts hier",
                    systemImage: "square.stack",
                    description: Text("Entscheide im Player, dann füllt sich diese Liste.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(entries, id: \.release.id) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .onAppear(perform: reload)
        .onChange(of: filter) { _, _ in reload() }
    }

    private var picker: some View {
        HStack(spacing: 8) {
            chip("👁 Wantlist", count: counts[.love] ?? 0, kind: .love)
            chip("↓ später", count: counts[.later] ?? 0, kind: .later)
            chip("✗ weg", count: counts[.discard] ?? 0, kind: .discard)
            chip("alle", count: entriesTotal, kind: nil)
            Spacer()
            Text("◉ besessen \(ownedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var entriesTotal: Int {
        (counts[.love] ?? 0) + (counts[.later] ?? 0) + (counts[.discard] ?? 0)
    }

    private func chip(_ label: String, count: Int, kind: DecisionKind?) -> some View {
        Button("\(label) \(count)") { filter = kind }
            .buttonStyle(.bordered)
            .tint(filter == kind ? .accentColor : .secondary)
    }

    private func row(_ entry: LibraryEntry) -> some View {
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
                        Label("\(entry.likedTrackCount) Tracks", systemImage: "heart.fill")
                    }
                    Link(
                        "Discogs",
                        destination: URL(string: "https://www.discogs.com/release/\(entry.release.id)")!
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(entry.decidedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    environment.playFromLibrary(releaseID: entry.release.id)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("im Player abspielen")
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            Button("Letzte Entscheidung rückgängig") {
                Task {
                    await environment.undoLastDecision()
                    reload()
                }
            }
            Spacer()
            Text("\(entries.count) Einträge")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func reload() {
        entries = environment.library(kind: filter)
        let all = environment.library(kind: nil)
        counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        ownedCount = all.filter { $0.release.owned }.count
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
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
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
