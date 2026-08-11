import XCTest
import GRDB
@testable import VinylDiggerKit

final class ExportCursorTests: XCTestCase {
    func testTheCursorIsAbsentUntilSomethingIsExported() throws {
        let db = try AppDatabase.inMemory()
        let loaded = try db.read {
            try ExportCursorRecord.fetchOne($0, key: ExportCursorRecord.singletonID)
        }
        XCTAssertNil(loaded)
    }

    func testSavingTheCursorTwiceKeepsOneRow() throws {
        let db = try AppDatabase.inMemory()
        try db.write { database in
            var first = ExportCursorRecord(lastExportedAt: Date(timeIntervalSince1970: 1_000))
            try first.save(database)
            var second = ExportCursorRecord(lastExportedAt: Date(timeIntervalSince1970: 2_000))
            try second.save(database)
        }
        let all = try db.read { try ExportCursorRecord.fetchAll($0) }
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].lastExportedAt, Date(timeIntervalSince1970: 2_000))
    }
}

final class DigSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeService() throws -> (QueueService, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        try secrets.write("tok", for: .discogsToken)
        let client = DiscogsClient(
            transport: StubTransport(replies: []), secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
        let outbox = OutboxProcessor(
            database: db, writer: client, username: "schakal", now: { self.now }
        )
        let service = QueueService(
            database: db, client: client, outbox: outbox,
            username: "schakal", now: { self.now }
        )
        return (service, db)
    }

    /// Two releases, one owned, each with one video, plus a like on each.
    private func seed(_ db: AppDatabase, likedAt: Date, ownedLikedAt: Date) throws {
        try db.write { database in
            var wanted = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: 1999, catno: "VIS035", labelID: nil, styles: ["Deep House"],
                want: 582, have: 517, hydrated: true, owned: false
            )
            try wanted.save(database)
            var shelved = ReleaseRecord(
                id: 4242, title: "Im Regal", artistName: "Mr. G",
                year: 2001, catno: "PH01", labelID: nil, styles: ["House"],
                want: 10, have: 900, hydrated: true, owned: true
            )
            try shelved.save(database)

            for (releaseID, youtubeID) in [(2831, "aaa"), (4242, "bbb")] {
                var video = VideoRecord(
                    id: nil, releaseID: releaseID, youtubeID: youtubeID, title: "Track",
                    position: 0, unavailable: false, duration: 300, trackPosition: "A1"
                )
                try video.insert(database)
            }

            var like = TrackLikeRecord(
                id: nil, releaseID: 2831, youtubeID: "aaa", likedAt: likedAt
            )
            try like.insert(database)
            var ownedLike = TrackLikeRecord(
                id: nil, releaseID: 4242, youtubeID: "bbb", likedAt: ownedLikedAt
            )
            try ownedLike.insert(database)
        }
    }

    func testWithoutACursorEverythingCounts() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now, ownedLikedAt: now)

        let session = try service.digSession(until: now.addingTimeInterval(60))

        XCTAssertEqual(session.map(\.youtubeID), ["aaa"], "the owned record must not be searched for")
    }

    func testOnlyWhatWasMarkedAfterTheCursorCounts() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now, ownedLikedAt: now)
        try service.markExported(at: now.addingTimeInterval(10))

        XCTAssertTrue(try service.digSession(until: now.addingTimeInterval(60)).isEmpty)

        try db.write { database in
            var later = TrackLikeRecord(
                id: nil, releaseID: 2831, youtubeID: "ccc",
                likedAt: now.addingTimeInterval(20)
            )
            try later.insert(database)
        }

        let session = try service.digSession(until: now.addingTimeInterval(60))
        XCTAssertEqual(session.map(\.youtubeID), ["ccc"])
    }

    func testALikeSetAfterTheCutoffIsLeftForTheNextSession() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now.addingTimeInterval(100), ownedLikedAt: now)

        XCTAssertTrue(try service.digSession(until: now.addingTimeInterval(50)).isEmpty)
        XCTAssertEqual(
            try service.digSession(until: now.addingTimeInterval(200)).map(\.youtubeID), ["aaa"]
        )
    }

    func testTheFullListStillCarriesEverything() throws {
        let (service, db) = try makeService()
        try seed(db, likedAt: now, ownedLikedAt: now)
        try service.markExported(at: now.addingTimeInterval(10))

        XCTAssertEqual(try service.likedTracks().count, 2, "renderRecords needs all of them")
    }

    func testBoundaryConditionsOnUntilAndCursor() throws {
        let (service, db) = try makeService()
        let cursor = now.addingTimeInterval(100)
        let until = now.addingTimeInterval(200)

        try db.write { database in
            var release = ReleaseRecord(
                id: 9999, title: "Test Release", artistName: "Test Artist",
                year: 2020, catno: "TST01", labelID: nil, styles: ["Test"],
                want: 1, have: 1, hydrated: true, owned: false
            )
            try release.save(database)
            var video = VideoRecord(
                id: nil, releaseID: 9999, youtubeID: "boundary-test",
                title: "Track", position: 0, unavailable: false, duration: 300,
                trackPosition: "A1"
            )
            try video.insert(database)

            var atCursor = TrackLikeRecord(
                id: nil, releaseID: 9999, youtubeID: "at-cursor",
                likedAt: cursor
            )
            try atCursor.insert(database)
            var beforeCursor = TrackLikeRecord(
                id: nil, releaseID: 9999, youtubeID: "before-cursor",
                likedAt: cursor.addingTimeInterval(-1)
            )
            try beforeCursor.insert(database)
            var atUntil = TrackLikeRecord(
                id: nil, releaseID: 9999, youtubeID: "at-until",
                likedAt: until
            )
            try atUntil.insert(database)
            var afterUntil = TrackLikeRecord(
                id: nil, releaseID: 9999, youtubeID: "after-until",
                likedAt: until.addingTimeInterval(1)
            )
            try afterUntil.insert(database)
        }

        try service.markExported(at: cursor)

        let session = try service.digSession(until: until)
        let youtubeIDs = session.map(\.youtubeID)

        XCTAssertTrue(youtubeIDs.contains("at-until"), "likedAt <= until includes exactly at until")
        XCTAssertFalse(youtubeIDs.contains("at-cursor"), "likedAt > since excludes exactly at cursor")
        XCTAssertFalse(youtubeIDs.contains("before-cursor"), "likedAt > since excludes before cursor")
        XCTAssertFalse(youtubeIDs.contains("after-until"), "likedAt <= until excludes after until")
    }
}
