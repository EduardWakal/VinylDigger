import XCTest
import GRDB
@testable import VinylDiggerKit

final class TrackLikeTests: XCTestCase {
    private func seeded() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.write { database in
            var label = LabelRecord(id: 15, name: "20:20 Vision", weight: 0, refreshedAt: nil)
            try label.save(database)
            var release = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: 1999, catno: "VIS035", labelID: 15, styles: ["Deep House"],
                want: 582, have: 517, hydrated: true
            )
            try release.save(database)
            for (index, id) in ["aaa", "bbb"].enumerated() {
                var video = VideoRecord(
                    id: nil, releaseID: 2831, youtubeID: id, title: "Track \(index)",
                    position: index, unavailable: false, duration: 300,
                    trackPosition: index == 0 ? "A1" : "B1"
                )
                try video.insert(database)
            }
        }
        return db
    }

    func testTrackLikeRoundTrips() throws {
        let db = try seeded()
        try db.write { database in
            var like = TrackLikeRecord(
                id: nil, releaseID: 2831, youtubeID: "aaa",
                likedAt: Date(timeIntervalSince1970: 1_000_000)
            )
            try like.insert(database)
        }
        let loaded = try db.read { try TrackLikeRecord.fetchAll($0) }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].youtubeID, "aaa")
    }

    func testDuplicateLikeIsRejected() throws {
        let db = try seeded()
        try db.write { database in
            var like = TrackLikeRecord(id: nil, releaseID: 2831, youtubeID: "aaa", likedAt: Date())
            try like.insert(database)
        }
        XCTAssertThrowsError(try db.write { database in
            var again = TrackLikeRecord(id: nil, releaseID: 2831, youtubeID: "aaa", likedAt: Date())
            try again.insert(database)
        })
    }

    func testSameVideoOnAnotherReleaseIsAllowed() throws {
        let db = try seeded()
        try db.write { database in
            var other = ReleaseRecord(
                id: 99, title: "Other", artistName: "Someone", year: nil, catno: nil,
                labelID: nil, styles: [], want: 0, have: 0, hydrated: false
            )
            try other.save(database)
            var first = TrackLikeRecord(id: nil, releaseID: 2831, youtubeID: "aaa", likedAt: Date())
            try first.insert(database)
            var second = TrackLikeRecord(id: nil, releaseID: 99, youtubeID: "aaa", likedAt: Date())
            try second.insert(database)
        }
        XCTAssertEqual(try db.read { try TrackLikeRecord.fetchCount($0) }, 2)
    }
}
