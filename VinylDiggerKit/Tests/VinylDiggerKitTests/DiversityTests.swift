import XCTest
@testable import VinylDiggerKit

final class ScorerSaturationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func candidate(
        _ id: Int, artist: Int, label: Int?, want: Int = 100,
        preview: PreviewState = .available
    ) -> ScoringCandidate {
        ScoringCandidate(
            releaseID: id, artistIDs: [artist], labelID: label, want: want,
            isDecided: false, isOwned: false, revisitAt: nil, preview: preview
        )
    }

    func testAffinityGrowthFlattensOut() {
        // A label the user keeps hearting must not run away with the queue.
        func score(labelWeight: Double) -> Double {
            Scorer.score(
                candidates: [candidate(1, artist: 10, label: 20)],
                weights: [NodeID(kind: .label, id: 20): labelWeight],
                labelNames: [:], now: now
            )[0].score
        }

        let modest = score(labelWeight: 1)
        let heavy = score(labelWeight: 4)
        let absurd = score(labelWeight: 40)

        XCTAssertGreaterThan(heavy, modest)
        XCTAssertGreaterThan(absurd, heavy)
        // Quadrupling again must add far less than the first step did.
        XCTAssertLessThan(absurd - heavy, heavy - modest)
        XCTAssertLessThan(absurd, 1.0, "the saturated affinity stays bounded")
    }

    func testReleaseKnownToHaveNoPreviewIsPushedDown() {
        let scored = Scorer.score(
            candidates: [
                candidate(1, artist: 10, label: 20, preview: .available),
                candidate(2, artist: 10, label: 20, preview: .none)
            ],
            weights: [NodeID(kind: .label, id: 20): 1.0],
            labelNames: [:], now: now
        )

        XCTAssertEqual(scored[0].releaseID, 1)
        XCTAssertLessThan(scored[1].score, scored[0].score)
        XCTAssertGreaterThan(scored[1].score, 0, "it stays reachable, just later")
    }

    func testUnknownPreviewSitsBetweenTheTwo() {
        func score(_ preview: PreviewState) -> Double {
            Scorer.score(
                candidates: [candidate(1, artist: 10, label: 20, preview: preview)],
                weights: [NodeID(kind: .label, id: 20): 1.0],
                labelNames: [:], now: now
            )[0].score
        }

        XCTAssertLessThan(score(.none), score(.unknown))
        XCTAssertLessThan(score(.unknown), score(.available))
    }
}

final class QueuePlannerDiversityTests: XCTestCase {
    private func scored(_ id: Int, score: Double, artist: Int, label: Int) -> ScoredRelease {
        ScoredRelease(
            releaseID: id, score: score, labelID: label,
            artistIDs: [artist], reason: "test"
        )
    }

    func testOneArtistCannotFillTheQueue() {
        // Ten strong releases by one artist, three weaker ones by others.
        var input = (1...10).map { scored($0, score: 1.0, artist: 1, label: 1) }
        input += [
            scored(11, score: 0.3, artist: 2, label: 2),
            scored(12, score: 0.3, artist: 3, label: 3),
            scored(13, score: 0.3, artist: 4, label: 4)
        ]

        let planned = QueuePlanner.plan(input, limit: 10)
        let byArtistOne = planned.filter { $0.artistIDs == [1] }.count

        XCTAssertLessThan(byArtistOne, 10, "one artist must not own the whole run")
        XCTAssertTrue(planned.contains { $0.artistIDs == [2] })
        XCTAssertTrue(planned.contains { $0.artistIDs == [3] })
    }

    func testStrongestStillComesFirst() {
        let input = [
            scored(1, score: 0.2, artist: 1, label: 1),
            scored(2, score: 0.9, artist: 2, label: 2),
            scored(3, score: 0.5, artist: 3, label: 3)
        ]

        XCTAssertEqual(QueuePlanner.plan(input, limit: 3).first?.releaseID, 2)
    }

    func testRepeatedArtistIsPushedBackNotDropped() {
        let input = [
            scored(1, score: 1.0, artist: 1, label: 1),
            scored(2, score: 0.95, artist: 1, label: 1),
            scored(3, score: 0.6, artist: 2, label: 2)
        ]

        let planned = QueuePlanner.plan(input, limit: 3)

        XCTAssertEqual(planned.count, 3, "nothing is thrown away")
        XCTAssertEqual(planned[0].releaseID, 1)
        XCTAssertEqual(planned[1].releaseID, 3, "the other artist gets a turn first")
        XCTAssertEqual(planned[2].releaseID, 2)
    }

    func testAClearlyBetterRecordStillWinsDespiteTheRepeat() {
        // Diversity nudges, it does not overrule a large gap in quality.
        let input = [
            scored(1, score: 1.0, artist: 1, label: 1),
            scored(2, score: 0.95, artist: 1, label: 1),
            scored(3, score: 0.05, artist: 2, label: 2)
        ]

        XCTAssertEqual(QueuePlanner.plan(input, limit: 2).map(\.releaseID), [1, 2])
    }

    func testLabelsAreMixedAsWell() {
        var input = (1...6).map { scored($0, score: 1.0, artist: $0, label: 1) }
        input.append(scored(7, score: 0.4, artist: 7, label: 2))

        let planned = QueuePlanner.plan(input, limit: 4)

        XCTAssertTrue(planned.contains { $0.labelID == 2 }, "a second label must break through")
    }

    func testZeroScoresStayOut() {
        let input = [
            scored(1, score: 0, artist: 1, label: 1),
            scored(2, score: 0.5, artist: 2, label: 2)
        ]

        XCTAssertEqual(QueuePlanner.plan(input, limit: 10).map(\.releaseID), [2])
    }

    func testEmptyInputIsFine() {
        XCTAssertTrue(QueuePlanner.plan([], limit: 10).isEmpty)
    }
}
