import Foundation

/// The two vault notes serve different jobs, so they are written separately.
public enum ObsidianDocument: String, CaseIterable, Sendable {
    /// A Soulseek shopping list: the tracks that were marked while listening.
    case searchList = "Vinyl - Gesuchte Tracks.md"
    /// What is on each record, for when one has actually been bought.
    case records = "Vinylsammlung.md"
}

/// Turns the library into vault notes. Pure on purpose — the file access lives in
/// `ObsidianWriter`, so the wording can be tested without touching disk.
public enum ObsidianRenderer {
    /// Everything from here down belongs to the user and is never rewritten.
    public static let handMarker = "<!-- ab hier von Hand -->"

    /// One checkbox per liked track, in the shape the Downloads notes already use,
    /// plus the record it came from so a failed search has something to fall back on.
    public static func renderSearchList(likes: [LikedTrack], generatedAt: Date) -> String {
        var lines = [
            "# Vinyl — Gesuchte Tracks",
            "",
            "Beim Hören markierte Tracks, als Suchzeilen für Nicotine+. Findet die Suche "
                + "den Track nicht, hilft meist der Plattenname darunter.",
            "",
            "Stand: \(format(generatedAt)) · \(likes.count) Tracks · Ablauf siehe [[Ablauf]].",
            "",
            "Schon in der Library? Gegenprüfen in [[Musiksammlung - Trackliste]].",
            ""
        ]

        if likes.isEmpty {
            lines.append("_Noch nichts markiert._")
            return lines.joined(separator: "\n")
        }

        for like in likes {
            let title = like.trackTitle ?? "ohne Titel"
            lines.append("- [ ] \(searchLine(artist: like.artistName, title: title))")

            var fallback = ["Platte: \(like.releaseTitle)"]
            if let label = like.labelName { fallback.append(label) }
            if let position = like.trackPosition { fallback.append(position) }
            lines.append("    - \(fallback.joined(separator: " · "))")
            lines.append("    - https://www.youtube.com/watch?v=\(like.youtubeID)")
        }

        return lines.joined(separator: "\n")
    }

    /// Every record on the wantlist with its full tracklist, so it is clear what is
    /// on a record before and after buying it. Marked tracks carry a ♥.
    public static func renderRecords(library: [LibraryEntry], likes: [LikedTrack], generatedAt: Date) -> String {
        let wanted = library.filter { $0.kind == .love }
        let likedTitles = Set(likes.map { "\($0.releaseID)|\(($0.trackTitle ?? "").lowercased())" })

        var lines = [
            "# Vinylsammlung",
            "",
            "Platten auf der Wantlist mit ihrer Trackliste — was drauf ist, bevor und "
                + "nachdem sie gekauft ist. Getrennt von der digitalen [[Musiksammlung]].",
            "",
            "Stand: \(format(generatedAt)) · \(wanted.count) Platten · "
                + "\(likes.count) markierte Tracks in [[Vinyl - Gesuchte Tracks]].",
            ""
        ]

        guard !wanted.isEmpty else {
            lines.append("_Noch nichts auf der Wantlist._")
            return lines.joined(separator: "\n")
        }

        let grouped = Dictionary(grouping: wanted) { $0.labelName ?? "Ohne Label" }
        for label in grouped.keys.sorted() {
            lines += ["## \(label)", ""]

            for entry in grouped[label]!.sorted(by: { $0.release.title < $1.release.title }) {
                let release = entry.release
                var head = "### \(release.artistName) — \(release.title)"
                lines.append(head)

                var detail: [String] = []
                if let catno = release.catno { detail.append(catno) }
                if let year = release.year { detail.append(String(year)) }
                if release.ratingCount > 0 {
                    detail.append(String(format: "★ %.2f (%d)", release.rating, release.ratingCount))
                }
                detail.append("[Discogs](https://www.discogs.com/release/\(release.id))")
                lines += [detail.joined(separator: " · "), ""]

                if release.tracklist.isEmpty {
                    lines.append("_Trackliste noch nicht geladen._")
                } else {
                    for track in release.tracklist {
                        let position = track.position.map { "**\($0)** " } ?? ""
                        let liked = likedTitles.contains("\(release.id)|\(track.title.lowercased())")
                        lines.append("- \(position)\(track.title)\(liked ? "  ♥" : "")")
                    }
                }
                lines.append("")
                head = ""
            }
        }

        return lines.joined(separator: "\n")
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

    /// Nicotine+ chokes on the bracketed extras Discogs titles carry around.
    private static func searchLine(artist: String, title: String) -> String {
        var cleaned = title
        while let open = cleaned.lastIndex(of: "["), let close = cleaned.lastIndex(of: "]"),
              open < close {
            cleaned.removeSubrange(open...close)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        // Discogs video titles usually already read "Artist - Title".
        if cleaned.lowercased().contains(artist.lowercased()) { return cleaned }
        return "\(artist) - \(cleaned)"
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        return formatter.string(from: date)
    }
}

/// Writes one note into the vault, keeping its hand-written tail.
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

    public func write(_ rendered: String, to document: ObsidianDocument) throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw WriterError.directoryMissing(directory.path)
        }

        let target = directory.appendingPathComponent(document.rawValue)
        let existing = try? String(contentsOf: target, encoding: .utf8)
        let merged = ObsidianRenderer.merge(rendered: rendered, into: existing)
        try merged.write(to: target, atomically: true, encoding: .utf8)
    }
}
