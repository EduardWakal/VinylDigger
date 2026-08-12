import Foundation

/// Orders scored releases for the audition queue.
///
/// Ranking on score alone collapses the run: the graph favours a few veins, the
/// user hearts what shows up, those veins gain weight, and the next queue is even
/// narrower. So each pick is penalised by how often its artist and label already
/// appeared — a well-worn diversity re-ranking, the same shape as maximal marginal
/// relevance, only with a count instead of a similarity measure.
///
/// Nothing is discarded. A repeated artist drops behind fresher material and comes
/// back once the alternatives are used up.
public enum QueuePlanner {
    /// How hard a repeat is punished. At 1.0 the second release by an artist counts
    /// half, the third a third, and so on.
    public static let repeatPenalty = 1.0
    /// The label penalty is gentler — a label is a much wider net than an artist.
    public static let labelPenalty = 0.7

    public static func plan(_ scored: [ScoredRelease], limit: Int) -> [ScoredRelease] {
        var remaining = scored.filter { $0.score > 0 }
        var output: [ScoredRelease] = []
        var artistCounts: [Int: Int] = [:]
        var labelCounts: [Int: Int] = [:]

        while output.count < limit, !remaining.isEmpty {
            var bestIndex = 0
            var bestValue = -Double.infinity

            for (index, candidate) in remaining.enumerated() {
                let value = adjusted(
                    candidate, artistCounts: artistCounts, labelCounts: labelCounts
                )
                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }

            let picked = remaining.remove(at: bestIndex)
            for artistID in picked.artistIDs {
                artistCounts[artistID, default: 0] += 1
            }
            if let labelID = picked.labelID {
                labelCounts[labelID, default: 0] += 1
            }
            output.append(picked)
        }

        return output
    }

    private static func adjusted(
        _ candidate: ScoredRelease, artistCounts: [Int: Int], labelCounts: [Int: Int]
    ) -> Double {
        let artistSeen = candidate.artistIDs
            .map { artistCounts[$0] ?? 0 }
            .max() ?? 0
        let labelSeen = candidate.labelID.map { labelCounts[$0] ?? 0 } ?? 0

        let artistFactor = 1 / (1 + repeatPenalty * Double(artistSeen))
        let labelFactor = 1 / (1 + labelPenalty * Double(labelSeen))

        return candidate.score * artistFactor * labelFactor
    }
}
