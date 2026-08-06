import Foundation

/// Maps Discogs videos onto tracklist positions.
///
/// Video titles are free text ("BCR035 : Mr G - Toi Toi") while the tracklist
/// holds the position ("B1"). A wrong position is worse than none, so anything
/// ambiguous resolves to nil.
public enum TrackMatcher {
    public static func positions(
        videos: [DiscogsVideo], tracklist: [DiscogsTrack]
    ) -> [String?] {
        let candidates = tracklist.compactMap { track -> (position: String, needle: String)? in
            guard let position = track.position, !position.isEmpty else { return nil }
            let needle = normalize(track.title)
            guard !needle.isEmpty else { return nil }
            return (position, needle)
        }

        return videos.map { video in
            let haystack = normalize(video.title ?? "")
            guard !haystack.isEmpty else { return nil }

            let hits = candidates.filter { haystack.contains($0.needle) }
            guard let longest = hits.map(\.needle.count).max() else { return nil }

            let best = hits.filter { $0.needle.count == longest }
            // Two tracks matching equally well means we cannot tell them apart.
            guard best.count == 1 else { return nil }
            return best[0].position
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
    }
}
