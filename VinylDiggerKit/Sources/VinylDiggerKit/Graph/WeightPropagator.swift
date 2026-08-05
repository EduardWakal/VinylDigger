import Foundation

/// Spreads weight outward from seed nodes, damped once per hop.
///
/// Pure: no I/O, no clock, no randomness. Same input always yields the same map.
public enum WeightPropagator {
    public static let maxDepth = 3
    public static let weightRange = 0.0...2.0

    public static func propagate(
        seeds: [NodeID],
        edges: [GraphEdge],
        adjustments: [WeightAdjustment]
    ) -> [NodeID: Double] {
        var outgoing: [NodeID: [GraphEdge]] = [:]
        for edge in edges {
            outgoing[edge.from, default: []].append(edge)
        }

        var best: [NodeID: Double] = [:]
        for seed in seeds { best[seed] = 1.0 }

        // Breadth-first by depth. A node is only re-expanded when a stronger path
        // reaches it, so cycles settle instead of looping.
        var frontier: [(node: NodeID, weight: Double)] = seeds.map { ($0, 1.0) }

        for _ in 0..<maxDepth {
            var next: [(node: NodeID, weight: Double)] = []
            for entry in frontier {
                for edge in outgoing[entry.node] ?? [] {
                    let candidate = entry.weight * edge.kind.decay
                    if candidate > (best[edge.to] ?? 0) {
                        best[edge.to] = candidate
                        next.append((edge.to, candidate))
                    }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        for adjustment in adjustments {
            best[adjustment.node] = (best[adjustment.node] ?? 0) + adjustment.delta
        }

        return best.mapValues { min(max($0, weightRange.lowerBound), weightRange.upperBound) }
    }
}
