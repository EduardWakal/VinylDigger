import XCTest
@testable import VinylDiggerKit

final class ScorerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let labelNames = [15: "20:20 Vision"]

    private func candidate(
        id: Int, artists: [Int] = [1], label: Int? = 15, want: Int = 100,
        decided: Bool = false, owned: Bool = false, revisit: Date? = nil
    ) -> ScoringCandidate {
        // Playable throughout, so these tests measure the weighting alone.
        ScoringCandidate(
            releaseID: id, artistIDs: artists, labelID: label, want: want,
            isDecided: decided, isOwned: owned, revisitAt: revisit,
            preview: .available
        )
    }

    private var weights: [NodeID: Double] {
        [
            NodeID(kind: .artist, id: 1): 0.5,
            NodeID(kind: .label, id: 15): 0.6
        ]
    }

    func testAffinitySumsArtistAndLabelWeights() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, want: 1)],
            weights: weights, labelNames: labelNames, now: now
        )
        // affinity 1.1, saturated to 1.1/2.1; single candidate so demand = 1
        XCTAssertEqual(scored[0].score, 1.1 / 2.1, accuracy: 0.0001)
    }

    func testDemandIsNormalisedAgainstPoolMaximum() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, want: 1000), candidate(id: 2, want: 1)],
            weights: weights, labelNames: labelNames, now: now
        )
        let top = scored.first { $0.releaseID == 1 }!
        let bottom = scored.first { $0.releaseID == 2 }!

        let saturated = 1.1 / 2.1
        XCTAssertEqual(top.score, saturated * 1.0, accuracy: 0.0001)
        let expectedDemand = log1p(1.0) / log1p(1000.0)
        XCTAssertEqual(bottom.score, saturated * (0.7 + 0.3 * expectedDemand), accuracy: 0.0001)
    }

    func testDemandContributesAtMostThirtyPercent() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, want: 10_000), candidate(id: 2, want: 0)],
            weights: weights, labelNames: labelNames, now: now
        )
        let top = scored.first { $0.releaseID == 1 }!.score
        let bottom = scored.first { $0.releaseID == 2 }!.score

        XCTAssertEqual(bottom / top, 0.7, accuracy: 0.0001)
    }

    func testDecidedReleaseScoresZero() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, decided: true)],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertEqual(scored[0].score, 0)
    }

    func testOwnedReleaseScoresZero() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, owned: true)],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertEqual(scored[0].score, 0)
    }

    func testPostponedReleaseScoresZeroBeforeRevisitDate() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, decided: true, revisit: now.addingTimeInterval(86_400))],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertEqual(scored[0].score, 0)
    }

    func testPostponedReleaseScoresAgainAfterRevisitDate() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, want: 1, decided: true, revisit: now.addingTimeInterval(-1))],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertGreaterThan(scored[0].score, 0)
    }

    func testResultIsSortedByScoreDescending() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, want: 1), candidate(id: 2, want: 1000)],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertEqual(scored.map(\.releaseID), [2, 1])
    }

    func testReasonNamesTheStrongestContributor() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1)],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertTrue(scored[0].reason.contains("20:20 Vision"))
    }

    func testUnknownNodesContributeNothing() {
        let scored = Scorer.score(
            candidates: [candidate(id: 1, artists: [42], label: 99, want: 1)],
            weights: weights, labelNames: labelNames, now: now
        )
        XCTAssertEqual(scored[0].score, 0)
    }
}
