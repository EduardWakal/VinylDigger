import Foundation

public struct DiscoveryCandidate: Equatable, Sendable {
    public let releaseID: Int
    public let masterID: Int?
    public let artistName: String
    public let labelName: String?
    /// How many people are looking for this record. Collector demand, not sales.
    public let want: Int
    /// Every style Discogs files the record under, used to weed out pop records
    /// that merely carry the searched tag.
    public let styles: [String]
    /// True when this artist already sits in the taste graph.
    public let isKnownArtist: Bool
    public let isOwned: Bool
    public let isDecided: Bool
    public let revisitAt: Date?

    public init(
        releaseID: Int, masterID: Int?, artistName: String, labelName: String?,
        want: Int, styles: [String], isKnownArtist: Bool, isOwned: Bool,
        isDecided: Bool, revisitAt: Date?
    ) {
        self.releaseID = releaseID
        self.masterID = masterID
        self.artistName = artistName
        self.labelName = labelName
        self.want = want
        self.styles = styles
        self.isKnownArtist = isKnownArtist
        self.isOwned = isOwned
        self.isDecided = isDecided
        self.revisitAt = revisitAt
    }
}

public struct RankedDiscovery: Equatable, Sendable {
    public let releaseID: Int
    public let score: Double

    public init(releaseID: Int, score: Double) {
        self.releaseID = releaseID
        self.score = score
    }
}

/// Orders a batch of style-chart hits.
///
/// Deliberately not `Scorer`: that one multiplies by graph affinity, and every
/// record here comes from outside the graph, so all of them would score zero.
/// What stands in for affinity is how many people are hunting the record.
public enum DiscoveryRanker {
    /// How much a record loses for being by an artist already in the graph.
    /// Lower it to 0 to shut familiar names out entirely.
    public static let knownArtistFactor = 0.5

    /// Styles that mark a hit as something other than club music, however the
    /// tags read. A pop record with a "Tech House" tag outranks every real one
    /// on demand alone, so it is dropped rather than ranked down.
    ///
    /// Kept deliberately short: it should catch pop, not borderline cases. Every
    /// entry here was seen at the top of a live search.
    public static let foreignStyles: Set<String> = [
        "pop", "dance-pop", "hyperpop", "synth-pop", "europop", "j-pop", "k-pop",
        "hip hop", "rap", "chanson", "schlager", "country", "ballad", "rock",
        "pop rock", "indie rock", "reggaeton"
    ]

    public static func rank(
        _ candidates: [DiscoveryCandidate], limit: Int, now: Date
    ) -> [RankedDiscovery] {
        let playable = candidates.filter { novelty($0, now: now) > 0 && !isForeign($0) }
        let deduped = deduplicate(playable)
        guard !deduped.isEmpty else { return [] }

        let maxWant = max(deduped.map(\.want).max() ?? 0, 1)
        let denominator = log1p(Double(maxWant))

        // QueuePlanner counts repeats by integer id, but a search hit carries only
        // names. Numbering them within the batch is enough — the counts never
        // leave this call.
        var artistIDs: [String: Int] = [:]
        var labelIDs: [String: Int] = [:]
        func number(_ name: String, in table: inout [String: Int]) -> Int {
            if let existing = table[name] { return existing }
            let next = table.count + 1
            table[name] = next
            return next
        }

        let scored = deduped.map { candidate -> ScoredRelease in
            let demand = denominator > 0 ? log1p(Double(candidate.want)) / denominator : 0
            let familiarity = candidate.isKnownArtist ? knownArtistFactor : 1.0
            return ScoredRelease(
                releaseID: candidate.releaseID,
                score: demand * familiarity,
                labelID: candidate.labelName.map { number($0, in: &labelIDs) },
                artistIDs: [number(candidate.artistName, in: &artistIDs)],
                reason: ""
            )
        }

        let ordered = QueuePlanner.plan(
            scored.sorted {
                $0.score == $1.score ? $0.releaseID < $1.releaseID : $0.score > $1.score
            },
            limit: limit
        )
        return ordered.map { RankedDiscovery(releaseID: $0.releaseID, score: $0.score) }
    }

    /// One entry per master — a reissue is the same record twice. The most
    /// sought-after pressing wins, because that is the one being hunted.
    private static func deduplicate(_ candidates: [DiscoveryCandidate]) -> [DiscoveryCandidate] {
        var best: [Int: DiscoveryCandidate] = [:]
        var withoutMaster: [DiscoveryCandidate] = []

        for candidate in candidates {
            guard let masterID = candidate.masterID else {
                withoutMaster.append(candidate)
                continue
            }
            if let existing = best[masterID], existing.want >= candidate.want { continue }
            best[masterID] = candidate
        }

        return Array(best.values) + withoutMaster
    }

    /// A record with no styles at all is unknown, not foreign — dropping it would
    /// quietly shrink the pool for a missing tag.
    private static func isForeign(_ candidate: DiscoveryCandidate) -> Bool {
        candidate.styles.contains { foreignStyles.contains($0.lowercased()) }
    }

    /// Same rule as `Scorer.novelty`: a postponed record comes back once its
    /// revisit date has passed.
    private static func novelty(_ candidate: DiscoveryCandidate, now: Date) -> Double {
        if candidate.isOwned { return 0 }
        guard candidate.isDecided else { return 1 }
        guard let revisitAt = candidate.revisitAt else { return 0 }
        return revisitAt <= now ? 1 : 0
    }
}
