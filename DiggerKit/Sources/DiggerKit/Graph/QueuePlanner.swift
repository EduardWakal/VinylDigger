import Foundation

/// Orders scored releases for the audition queue, keeping any single label from
/// dominating a long stretch of the run.
public enum QueuePlanner {
    public static let maxConsecutiveSameLabel = 3

    public static func plan(_ scored: [ScoredRelease], limit: Int) -> [ScoredRelease] {
        var remaining = scored.filter { $0.score > 0 }
        var output: [ScoredRelease] = []
        var deferred: [ScoredRelease] = []

        while output.count < limit, !remaining.isEmpty || !deferred.isEmpty {
            if remaining.isEmpty {
                // Nothing left but items we pushed aside — take them in order.
                remaining = deferred
                deferred = []
            }

            guard !remaining.isEmpty else { break }
            let next = remaining.removeFirst()

            if let labelID = next.labelID, runLength(of: labelID, in: output) >= maxConsecutiveSameLabel {
                // Look for any candidate from another label to break the run.
                if let index = remaining.firstIndex(where: { $0.labelID != labelID }) {
                    let replacement = remaining.remove(at: index)
                    deferred.append(next)
                    output.append(replacement)
                    continue
                }
            }

            output.append(next)
        }

        return output
    }

    private static func runLength(of labelID: Int, in output: [ScoredRelease]) -> Int {
        var count = 0
        for item in output.reversed() {
            guard item.labelID == labelID else { break }
            count += 1
        }
        return count
    }
}
