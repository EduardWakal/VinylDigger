import Foundation

/// Whether a release can actually be listened to.
///
/// `unknown` matters: a release the graph just turned up has no videos yet simply
/// because nobody fetched its detail. Treating that as unplayable would bury it
/// before it ever got a chance.
public enum PreviewState: Equatable, Sendable {
    case available
    case unknown
    case none
}

public struct ScoringCandidate: Equatable, Sendable {
    public let releaseID: Int
    public let artistIDs: [Int]
    public let labelID: Int?
    public let want: Int
    public let isDecided: Bool
    public let isOwned: Bool
    public let revisitAt: Date?
    public let preview: PreviewState

    public init(
        releaseID: Int, artistIDs: [Int], labelID: Int?, want: Int,
        isDecided: Bool, isOwned: Bool, revisitAt: Date?,
        preview: PreviewState = .unknown
    ) {
        self.releaseID = releaseID
        self.artistIDs = artistIDs
        self.labelID = labelID
        self.want = want
        self.isDecided = isDecided
        self.isOwned = isOwned
        self.revisitAt = revisitAt
        self.preview = preview
    }
}

public struct ScoredRelease: Equatable, Sendable {
    public let releaseID: Int
    public let score: Double
    public let labelID: Int?
    public let artistIDs: [Int]
    public let reason: String

    public init(
        releaseID: Int, score: Double, labelID: Int?,
        artistIDs: [Int] = [], reason: String
    ) {
        self.releaseID = releaseID
        self.score = score
        self.labelID = labelID
        self.artistIDs = artistIDs
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

            // Diminishing returns. Raw affinity grows with every heart, so without
            // this a vein the user liked a few times would outscore everything else
            // for good and the queue would narrow to it.
            let saturated = affinity / (1 + affinity)

            let score = saturated
                * ((1 - demandShare) + demandShare * demand)
                * novelty
                * previewFactor(candidate.preview)

            let reason = strongest.map { "über \($0.name)" } ?? "ohne Bezug"
            return ScoredRelease(
                releaseID: candidate.releaseID, score: score,
                labelID: candidate.labelID, artistIDs: candidate.artistIDs,
                reason: reason
            )
        }

        return scored.sorted {
            $0.score == $1.score ? $0.releaseID < $1.releaseID : $0.score > $1.score
        }
    }

    /// A release with no playable video is not worthless — it may still be worth
    /// buying — but it cannot be auditioned, so it waits.
    private static func previewFactor(_ preview: PreviewState) -> Double {
        switch preview {
        case .available: return 1.0
        case .unknown: return 0.7
        case .none: return 0.15
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
