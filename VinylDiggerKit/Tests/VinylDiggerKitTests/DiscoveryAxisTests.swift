import XCTest
@testable import VinylDiggerKit

final class DiscoveryAxisTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02-02

    func testWindowsCoverAllTimeAndFourRanges() {
        let windows = DiscoveryRotation.windows(now: reference)

        XCTAssertEqual(windows.count, 5)
        XCTAssertNil(windows[0].from)
        XCTAssertNil(windows[0].to)
        XCTAssertEqual(windows[1].from, 1990)
        XCTAssertEqual(windows[1].to, 1999)
        XCTAssertEqual(windows[2].from, 2000)
        XCTAssertEqual(windows[2].to, 2009)
        XCTAssertEqual(windows[3].from, 2010)
        XCTAssertEqual(windows[3].to, 2019)
        XCTAssertEqual(windows[4].to, 2026)
        XCTAssertEqual(windows[4].from, 2024)
    }

    func testRotationWalksEveryStyleAndWindowBeforeSecondPage() {
        let styles = ["House", "Minimal"]
        var cursor = DiscoveryCursor.start
        var seen: [DiscoveryAxis] = []

        let combinations = styles.count * DiscoveryRotation.windows(now: reference).count
        for _ in 0..<combinations {
            let step = DiscoveryRotation.next(styles: styles, cursor: cursor, now: reference)!
            seen.append(step.axis)
            XCTAssertEqual(step.axis.page, 1)
            cursor = step.next
        }

        XCTAssertEqual(Set(seen.map(\.key)).count, combinations)

        // Styles turn over fastest: first two share a window and differ in style.
        XCTAssertEqual(seen[0].style, "House")
        XCTAssertEqual(seen[1].style, "Minimal")
        XCTAssertEqual(seen[0].window, seen[1].window)
        // Third element moves to the next window.
        XCTAssertNotEqual(seen[2].window, seen[0].window)
        XCTAssertEqual(seen[2].style, "House")

        let wrapped = DiscoveryRotation.next(styles: styles, cursor: cursor, now: reference)!
        XCTAssertEqual(wrapped.axis.page, 2)
        XCTAssertEqual(wrapped.axis.style, "House")
    }

    func testRotationYieldsNothingWithoutStyles() {
        XCTAssertNil(DiscoveryRotation.next(styles: [], cursor: .start, now: reference))
    }

    func testCursorOutOfRangeFallsBackToStart() {
        let step = DiscoveryRotation.next(
            styles: ["House"],
            cursor: DiscoveryCursor(styleIndex: 99, windowIndex: 99, page: 4),
            now: reference
        )!

        XCTAssertEqual(step.axis.style, "House")
        XCTAssertEqual(step.axis.page, 4)
    }
}
