import XCTest
@testable import VinylDiggerKit

final class PlaylistCursorTests: XCTestCase {
    func testStartsOnFirstVideo() {
        let cursor = PlaylistCursor(videoIDs: ["a", "b", "c"])

        XCTAssertEqual(cursor.current, "a")
        XCTAssertEqual(cursor.index, 0)
        XCTAssertFalse(cursor.isEmpty)
    }

    func testAdvanceWalksForward() {
        var cursor = PlaylistCursor(videoIDs: ["a", "b"])

        XCTAssertEqual(cursor.advance(), "b")
        XCTAssertEqual(cursor.index, 1)
    }

    func testAdvanceReturnsNilAtEndAndStaysPut() {
        var cursor = PlaylistCursor(videoIDs: ["a"])

        XCTAssertNil(cursor.advance())
        XCTAssertEqual(cursor.index, 0)
        XCTAssertEqual(cursor.current, "a")
    }

    func testSelectJumpsToIndex() {
        var cursor = PlaylistCursor(videoIDs: ["a", "b", "c"])

        XCTAssertEqual(cursor.select(2), "c")
        XCTAssertEqual(cursor.index, 2)
    }

    func testSelectOutOfRangeIsIgnored() {
        var cursor = PlaylistCursor(videoIDs: ["a", "b"])

        XCTAssertNil(cursor.select(5))
        XCTAssertEqual(cursor.index, 0)
        XCTAssertNil(cursor.select(-1))
        XCTAssertEqual(cursor.index, 0)
    }

    func testEmptyCursorHasNoCurrent() {
        var cursor = PlaylistCursor(videoIDs: [])

        XCTAssertTrue(cursor.isEmpty)
        XCTAssertNil(cursor.current)
        XCTAssertNil(cursor.advance())
    }
}
