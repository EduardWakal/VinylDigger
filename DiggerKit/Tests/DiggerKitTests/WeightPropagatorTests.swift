import XCTest
@testable import DiggerKit

final class WeightPropagatorTests: XCTestCase {
    private let finlow = NodeID(kind: .artist, id: 13320)
    private let randomFactor = NodeID(kind: .artist, id: 999)
    private let vision = NodeID(kind: .label, id: 15)
    private let inlandKnights = NodeID(kind: .artist, id: 2000)

    /// finlow --alias--> randomFactor --artistToLabel--> vision --labelToArtist--> inlandKnights
    private var chain: [GraphEdge] {
        [
            GraphEdge(from: finlow, to: randomFactor, kind: .alias),
            GraphEdge(from: randomFactor, to: vision, kind: .artistToLabel),
            GraphEdge(from: vision, to: inlandKnights, kind: .labelToArtist)
        ]
    }

    func testSeedStartsAtOne() {
        let weights = WeightPropagator.propagate(seeds: [finlow], edges: [], adjustments: [])
        XCTAssertEqual(weights[finlow], 1.0)
    }

    func testDecayAppliesPerEdgeKind() {
        let weights = WeightPropagator.propagate(seeds: [finlow], edges: chain, adjustments: [])
        XCTAssertEqual(weights[randomFactor] ?? 0, 0.90, accuracy: 0.0001)
        XCTAssertEqual(weights[vision] ?? 0, 0.90 * 0.60, accuracy: 0.0001)
        XCTAssertEqual(weights[inlandKnights] ?? 0, 0.90 * 0.60 * 0.35, accuracy: 0.0001)
    }

    func testDepthCapStopsPropagation() {
        let tail = NodeID(kind: .label, id: 77)
        let edges = chain + [GraphEdge(from: inlandKnights, to: tail, kind: .artistToLabel)]

        let weights = WeightPropagator.propagate(seeds: [finlow], edges: edges, adjustments: [])

        XCTAssertNotNil(weights[inlandKnights])
        XCTAssertNil(weights[tail], "depth 4 must not be reached")
    }

    func testStrongestPathWins() {
        // vision reachable directly (0.60) and via the alias hop (0.90 * 0.60 = 0.54)
        let edges = chain + [GraphEdge(from: finlow, to: vision, kind: .artistToLabel)]

        let weights = WeightPropagator.propagate(seeds: [finlow], edges: edges, adjustments: [])

        XCTAssertEqual(weights[vision] ?? 0, 0.60, accuracy: 0.0001)
    }

    func testMultipleSeedsBothStartAtOne() {
        let other = NodeID(kind: .artist, id: 1494)
        let weights = WeightPropagator.propagate(seeds: [finlow, other], edges: [], adjustments: [])
        XCTAssertEqual(weights[finlow], 1.0)
        XCTAssertEqual(weights[other], 1.0)
    }

    func testLoveAdjustmentRaisesWeight() {
        let weights = WeightPropagator.propagate(
            seeds: [finlow],
            edges: chain,
            adjustments: [WeightAdjustment(node: vision, delta: DecisionKind.love.weightDelta)]
        )
        XCTAssertEqual(weights[vision] ?? 0, 0.90 * 0.60 + 0.25, accuracy: 0.0001)
    }

    func testDiscardAdjustmentLowersWeight() {
        let weights = WeightPropagator.propagate(
            seeds: [finlow],
            edges: chain,
            adjustments: [WeightAdjustment(node: vision, delta: DecisionKind.discard.weightDelta)]
        )
        XCTAssertEqual(weights[vision] ?? 0, 0.90 * 0.60 - 0.15, accuracy: 0.0001)
    }

    func testAdjustmentsAccumulate() {
        let weights = WeightPropagator.propagate(
            seeds: [finlow],
            edges: chain,
            adjustments: [
                WeightAdjustment(node: vision, delta: 0.25),
                WeightAdjustment(node: vision, delta: 0.25)
            ]
        )
        XCTAssertEqual(weights[vision] ?? 0, 0.90 * 0.60 + 0.50, accuracy: 0.0001)
    }

    func testWeightClampsToUpperBound() {
        let weights = WeightPropagator.propagate(
            seeds: [finlow],
            edges: [],
            adjustments: (0..<20).map { _ in WeightAdjustment(node: finlow, delta: 0.25) }
        )
        XCTAssertEqual(weights[finlow], 2.0)
    }

    func testWeightClampsToLowerBound() {
        let weights = WeightPropagator.propagate(
            seeds: [finlow],
            edges: [],
            adjustments: (0..<20).map { _ in WeightAdjustment(node: finlow, delta: -0.15) }
        )
        XCTAssertEqual(weights[finlow], 0.0)
    }

    func testCycleTerminates() {
        let a = NodeID(kind: .artist, id: 1)
        let b = NodeID(kind: .label, id: 2)
        let edges = [
            GraphEdge(from: a, to: b, kind: .artistToLabel),
            GraphEdge(from: b, to: a, kind: .labelToArtist)
        ]

        let weights = WeightPropagator.propagate(seeds: [a], edges: edges, adjustments: [])

        XCTAssertEqual(weights[a], 1.0)
        XCTAssertEqual(weights[b] ?? 0, 0.60, accuracy: 0.0001)
    }

    func testIsDeterministic() {
        let first = WeightPropagator.propagate(seeds: [finlow], edges: chain, adjustments: [])
        let second = WeightPropagator.propagate(seeds: [finlow], edges: chain.reversed(), adjustments: [])
        XCTAssertEqual(first, second)
    }
}
