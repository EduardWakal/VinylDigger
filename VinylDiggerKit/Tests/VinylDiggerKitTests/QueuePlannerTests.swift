import XCTest
@testable import VinylDiggerKit

final class QueuePlannerTests: XCTestCase {
    private func item(_ id: Int, label: Int?, score: Double) -> ScoredRelease {
        ScoredRelease(releaseID: id, score: score, labelID: label, reason: "test")
    }

    func testKeepsOrderWhenLabelsAlternate() {
        let input = [
            item(1, label: 10, score: 5),
            item(2, label: 20, score: 4),
            item(3, label: 10, score: 3)
        ]
        let planned = QueuePlanner.plan(input, limit: 10)
        XCTAssertEqual(planned.map(\.releaseID), [1, 2, 3])
    }

    func testBreaksUpFourthConsecutiveSameLabel() {
        let input = [
            item(1, label: 10, score: 9),
            item(2, label: 10, score: 8),
            item(3, label: 10, score: 7),
            item(4, label: 10, score: 6),
            item(5, label: 20, score: 1)
        ]
        let planned = QueuePlanner.plan(input, limit: 10)
        XCTAssertEqual(planned.map(\.releaseID), [1, 2, 3, 5, 4])
    }

    func testDeferredItemReturnsWhenNoAlternativeRemains() {
        let input = [
            item(1, label: 10, score: 9),
            item(2, label: 10, score: 8),
            item(3, label: 10, score: 7),
            item(4, label: 10, score: 6)
        ]
        let planned = QueuePlanner.plan(input, limit: 10)
        XCTAssertEqual(planned.map(\.releaseID), [1, 2, 3, 4])
    }

    func testDropsZeroScoredItems() {
        let input = [item(1, label: 10, score: 5), item(2, label: 20, score: 0)]
        let planned = QueuePlanner.plan(input, limit: 10)
        XCTAssertEqual(planned.map(\.releaseID), [1])
    }

    func testRespectsLimit() {
        let input = (1...100).map { item($0, label: $0, score: Double(100 - $0)) }
        let planned = QueuePlanner.plan(input, limit: 50)
        XCTAssertEqual(planned.count, 50)
    }

    func testNilLabelIsNeverThrottled() {
        let input = (1...5).map { item($0, label: nil, score: Double(10 - $0)) }
        let planned = QueuePlanner.plan(input, limit: 10)
        XCTAssertEqual(planned.map(\.releaseID), [1, 2, 3, 4, 5])
    }

    func testEmptyInputYieldsEmptyQueue() {
        XCTAssertTrue(QueuePlanner.plan([], limit: 10).isEmpty)
    }
}
