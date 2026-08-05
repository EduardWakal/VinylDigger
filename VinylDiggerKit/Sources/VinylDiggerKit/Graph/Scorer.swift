import Foundation

public struct ScoringCandidate: Equatable, Sendable {
    public let releaseID: Int
    public let artistIDs: [Int]
    public let labelID: Int?
    public let want: Int
    public let isDecided: Bool
    public let isOwned: Bool
    public let revisitAt: Date?

    public init(
        releaseID: Int, artistIDs: [Int], labelID: Int?, want: Int,
        isDecided: Bool, isOwned: Bool, revisitAt: Date?
    ) {
        self.releaseID = releaseID
        self.artistIDs = artistIDs
        self.labelID = labelID
        self.want = want
        self.isDecided = isDecided
        self.isOwned = isOwned
        self.revisitAt = revisitAt
    }
}

public struct ScoredRelease: Equatable, Sendable {
    public let releaseID: Int
    public let score: Double
    public let labelID: Int?
    public let reason: String

    public init(releaseID: Int, score: Double, labelID: Int?, reason: String) {
        self.releaseID = releaseID
        self.score = score
        self.labelID = labelID
        self.reason = reason
    }
}

public enum Scorer {
    private static let demandShare = 0.3

    public static func score(
        candidates: [ScoringCandidate],
        weights: [NodeID: Double],
        labelNames: [Int: String],
        now: Date
    ) -> [ScoredRelease] {
        // Normalise demand against the pool at hand, not a global maximum, so a
        // less sought-after vein still spreads across the full range.
        let maxWant = max(candidates.map(\.want).max() ?? 0, 1)
        let denominator = log1p(Double(maxWant))

        let scored = candidates.map { candidate -> ScoredRelease in
            let novelty = self.novelty(for: candidate, now: now)

            var affinity = 0.0
            var strongest: (name: String, weight: Double)?

            for artistID in candidate.artistIDs {
                let weight = weights[NodeID(kind: .artist, id: artistID)] ?? 0
                affinity += weight
                if weight > (strongest?.weight ?? 0) {
                    strongest = ("Artist", weight)
                }
            }

            if let labelID = candidate.labelID {
                let weight = weights[NodeID(kind: .label, id: labelID)] ?? 0
                affinity += weight
                if weight > (strongest?.weight ?? 0) {
                    strongest = (labelNames[labelID] ?? "Label \(labelID)", weight)
                }
            }

            let demand = denominator > 0 ? log1p(Double(candidate.want)) / denominator : 0
            let score = affinity * ((1 - demandShare) + demandShare * demand) * novelty

            let reason = strongest.map { "über \($0.name)" } ?? "ohne Bezug"
            return ScoredRelease(
                releaseID: candidate.releaseID, score: score,
                labelID: candidate.labelID, reason: reason
            )
        }

        return scored.sorted {
            $0.score == $1.score ? $0.releaseID < $1.releaseID : $0.score > $1.score
        }
    }

    private static func novelty(for candidate: ScoringCandidate, now: Date) -> Double {
        if candidate.isOwned { return 0 }
        guard candidate.isDecided else { return 1 }
        // A postponed release comes back once its revisit date has passed.
        guard let revisitAt = candidate.revisitAt else { return 0 }
        return revisitAt <= now ? 1 : 0
    }
}
