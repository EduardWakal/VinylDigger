import XCTest
@testable import VinylDiggerKit

final class DiscoveryRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func candidate(
        id: Int, artist: String = "A", label: String? = nil, want: Int = 100,
        styles: [String] = ["Tech House"], known: Bool = false, owned: Bool = false,
        decided: Bool = false, master: Int? = nil, revisitAt: Date? = nil
    ) -> DiscoveryCandidate {
        DiscoveryCandidate(
            releaseID: id, masterID: master, artistName: artist, labelName: label,
            want: want, styles: styles, isKnownArtist: known, isOwned: owned,
            isDecided: decided, revisitAt: revisitAt
        )
    }

    func testDropsOwnedAndDecided() {
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "A", owned: true),
                candidate(id: 2, artist: "B", decided: true),
                candidate(id: 3, artist: "C")
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [3])
    }

    func testPostponedRecordReturnsAfterItsDate() {
        let past = now.addingTimeInterval(-60)
        let future = now.addingTimeInterval(60)

        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "A", decided: true, revisitAt: past),
                candidate(id: 2, artist: "B", decided: true, revisitAt: future)
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [1])
    }

    func testKnownArtistRanksBehindUnknownAtEqualWant() {
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "Bekannt", want: 500, known: true),
                candidate(id: 2, artist: "Neu", want: 500, known: false)
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [2, 1])
    }

    func testDeduplicatesByMasterKeepingTheMostWanted() {
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "A", want: 100, master: 77),
                candidate(id: 2, artist: "A", want: 900, master: 77),
                candidate(id: 3, artist: "B", want: 50, master: nil)
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [2, 3])
    }

    func testDropsForeignStyles() {
        // What the live search actually returned at the top of "Tech House".
        let ranked = DiscoveryRanker.rank(
            [
                candidate(
                    id: 1, artist: "Charli XCX", want: 3757,
                    styles: ["Tech House", "Electro House", "Dance-pop", "Hyperpop"]
                ),
                candidate(
                    id: 2, artist: "Stromae", want: 2812,
                    styles: ["Hip Hop", "Tech House", "Chanson"]
                ),
                candidate(
                    id: 3, artist: "Villalobos", want: 4888,
                    styles: ["Minimal Techno", "Tech House", "House"]
                )
            ],
            limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [3])
    }

    func testKeepsRecordsWithoutStyles() {
        // An unstyled hit is unknown, not foreign. Throwing it out would silently
        // shrink the pool.
        let ranked = DiscoveryRanker.rank(
            [candidate(id: 1, artist: "A", styles: [])], limit: 10, now: now
        )

        XCTAssertEqual(ranked.map(\.releaseID), [1])
    }

    func testForeignStyleMatchIgnoresCase() {
        let ranked = DiscoveryRanker.rank(
            [candidate(id: 1, artist: "A", styles: ["dance-POP"])], limit: 10, now: now
        )

        XCTAssertTrue(ranked.isEmpty)
    }

    func testSpreadsAcrossArtists() {
        // Three by one artist, one by another. The lone outsider must not end last.
        let ranked = DiscoveryRanker.rank(
            [
                candidate(id: 1, artist: "Vielschreiber", want: 900),
                candidate(id: 2, artist: "Vielschreiber", want: 890),
                candidate(id: 3, artist: "Vielschreiber", want: 880),
                candidate(id: 4, artist: "Anderer", want: 400)
            ],
            limit: 4, now: now
        )

        XCTAssertEqual(ranked[0].releaseID, 1)
        XCTAssertEqual(ranked[1].releaseID, 4)
    }

    func testHonoursLimit() {
        let many = (1...20).map { candidate(id: $0, artist: "A\($0)") }
        XCTAssertEqual(DiscoveryRanker.rank(many, limit: 5, now: now).count, 5)
    }
}
