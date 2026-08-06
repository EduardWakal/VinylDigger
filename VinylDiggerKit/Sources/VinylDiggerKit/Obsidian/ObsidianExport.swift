import Foundation

public struct ObsidianExport: Equatable, Sendable {
    public let overview: String
    public let tracklist: String

    public init(overview: String, tracklist: String) {
        self.overview = overview
        self.tracklist = tracklist
    }
}

/// Turns the library into the two vault notes. Pure on purpose — the file access
/// lives in `ObsidianWriter`, so the wording can be tested without touching disk.
public enum ObsidianRenderer {
    /// Everything from here down belongs to the user and is never rewritten.
    public static let handMarker = "<!-- ab hier von Hand -->"

    public static func render(
        library: [LibraryEntry], likes: [LikedTrack], generatedAt: Date
    ) -> ObsidianExport {
        ObsidianExport(
            overview: renderOverview(library: library, likes: likes, generatedAt: generatedAt),
            tracklist: renderTracklist(library: library, likes: likes, generatedAt: generatedAt)
        )
    }

    /// Replaces the managed part and leaves whatever sits below the marker alone.
    public static func merge(rendered: String, into existing: String?) -> String {
        let tail: String
        if let existing, let range = existing.range(of: handMarker) {
            tail = String(existing[range.lowerBound...])
        } else {
            tail = "\(handMarker)\n"
        }
        return rendered + "\n\n" + tail
    }

    // MARK: - Private

    private static func renderOverview(
        library: [LibraryEntry], likes: [LikedTrack], generatedAt: Date
    ) -> String {
        let loved = library.filter { $0.kind == .love }
        let later = library.filter { $0.kind == .later }
        let discarded = library.filter { $0.kind == .discard }

        var lines = [
            "# Vinylsammlung",
            "",
            "Platten aus dem Digging über Discogs, getrennt von der digitalen "
                + "[[Musiksammlung]]. Die Rohliste liegt in [[Dig Minimal-House Vinyl]].",
            "",
            "Stand: \(format(generatedAt)) · von VinylDigger geschrieben.",
            "",
            "## Umfang",
            "",
            "| | Anzahl |",
            "|---|---|",
            "| Wantlist ♥ | \(loved.count) |",
            "| Später ↓ | \(later.count) |",
            "| Verworfen ✗ | \(discarded.count) |",
            "| Markierte Tracks ★ | \(likes.count) |",
            ""
        ]

        let labels = tally(loved.compactMap(\.labelName))
        if !labels.isEmpty {
            lines += ["## Labels in der Wantlist", "", "| Label | Platten |", "|---|---|"]
            lines += labels.prefix(15).map { "| \($0.name) | \($0.count) |" }
            lines.append("")
        }

        let artists = tally(loved.map(\.release.artistName))
        if !artists.isEmpty {
            lines += ["## Artists in der Wantlist", "", "| Artist | Platten |", "|---|---|"]
            lines += artists.prefix(15).map { "| \($0.name) | \($0.count) |" }
            lines.append("")
        }

        let years = tally(loved.compactMap { $0.release.year.map(String.init) })
        if !years.isEmpty {
            lines += [
                "## Jahre",
                "",
                years.sorted { $0.name > $1.name }
                    .map { "\($0.name): \($0.count)" }
                    .joined(separator: " · "),
                ""
            ]
        }

        lines += ["Volle Liste: [[Vinylsammlung - Trackliste]]"]
        return lines.joined(separator: "\n")
    }

    private static func renderTracklist(
        library: [LibraryEntry], likes: [LikedTrack], generatedAt: Date
    ) -> String {
        let loved = library.filter { $0.kind == .love }
        let likesByRelease = Dictionary(grouping: likes, by: \.releaseID)

        var lines = [
            "# Vinylsammlung — Trackliste",
            "",
            "Jede Platte auf der Wantlist, darunter die Spuren, die beim Hören "
                + "markiert wurden. Übersicht und Statistik: [[Vinylsammlung]].",
            "",
            "Stand: \(format(generatedAt)) · \(loved.count) Platten · \(likes.count) markierte Tracks.",
            ""
        ]

        let grouped = Dictionary(grouping: loved) { $0.labelName ?? "Ohne Label" }
        for label in grouped.keys.sorted() {
            lines += ["## \(label)", ""]

            for entry in grouped[label]!.sorted(by: { $0.release.title < $1.release.title }) {
                let release = entry.release
                var head = "- **\(release.artistName) — \(release.title)**"
                var detail: [String] = []
                if let catno = release.catno { detail.append(catno) }
                if let year = release.year { detail.append(String(year)) }
                if release.ratingCount > 0 {
                    detail.append(String(format: "★ %.2f (%d)", release.rating, release.ratingCount))
                }
                if !detail.isEmpty { head += " · " + detail.joined(separator: " · ") }
                lines.append(head)

                for like in (likesByRelease[release.id] ?? []).sorted(by: sortLikes) {
                    let position = like.trackPosition.map { "\($0) · " } ?? ""
                    let title = like.trackTitle ?? "ohne Titel"
                    lines.append(
                        "    - ★ \(position)\(title) — "
                            + "https://www.youtube.com/watch?v=\(like.youtubeID)"
                    )
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func sortLikes(_ lhs: LikedTrack, _ rhs: LikedTrack) -> Bool {
        (lhs.trackPosition ?? "zz") < (rhs.trackPosition ?? "zz")
    }

    private static func tally(_ values: [String]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        return formatter.string(from: date)
    }
}

/// Writes the two notes into the vault, keeping each file's hand-written tail.
public actor ObsidianWriter {
    public enum WriterError: Error, Equatable {
        case directoryMissing(String)
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Obsidian/Schakal/Musik")
    }

    public func write(_ export: ObsidianExport) throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WriterError.directoryMissing(directory.path)
        }

        try write(export.overview, to: "Vinylsammlung.md")
        try write(export.tracklist, to: "Vinylsammlung - Trackliste.md")
    }

    private func write(_ rendered: String, to name: String) throws {
        let target = directory.appendingPathComponent(name)
        let existing = try? String(contentsOf: target, encoding: .utf8)
        let merged = ObsidianRenderer.merge(rendered: rendered, into: existing)
        try merged.write(to: target, atomically: true, encoding: .utf8)
    }
}
