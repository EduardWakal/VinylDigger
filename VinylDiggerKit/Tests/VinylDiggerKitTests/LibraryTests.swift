import XCTest
import GRDB
@testable import VinylDiggerKit

final class LibraryTests: XCTestCase {
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
        let outbox = OutboxProcessor(database: db, writer: client, username: "schakal", now: { self.now })
        let service = QueueService(
            database: db, client: client, outbox: outbox, username: "schakal", now: { self.now }
        )
        return (service, db)
    }

    private func seed(_ db: AppDatabase) throws {
        try db.write { database in
            var label = LabelRecord(id: 15, name: "20:20 Vision", weight: 0.4, refreshedAt: nil)
            try label.save(database)
            var artist = ArtistRecord(id: 13320, name: "Carl A. Finlow", weight: 1.0, refreshedAt: nil)
            try artist.save(database)

            for (id, title, kind) in [
                (2831, "Fresh Connections", DecisionKind.love),
                (2832, "Second EP", DecisionKind.discard),
                (2833, "Third EP", DecisionKind.later)
            ] {
                var release = ReleaseRecord(
                    id: id, title: title, artistName: "Inland Knights", year: 1999,
                    catno: "VIS0\(id)", labelID: 15, styles: ["Deep House"],
                    want: 100, have: 50, hydrated: true
                )
                try release.save(database)
                var decision = DecisionRecord(
                    id: nil, releaseID: id, kind: kind,
                    decidedAt: self.now.addingTimeInterval(Double(id)), revisitAt: nil
                )
                try decision.insert(database)
                var video = VideoRecord(
                    id: nil, releaseID: id, youtubeID: "vid\(id)", title: "T",
                    position: 0, unavailable: false
                )
                try video.insert(database)
            }
        }
    }

    func testLibraryFiltersByDecisionKind() throws {
        let (service, db) = try makeService()
        try seed(db)

        let loved = try service.library(kind: .love)

        XCTAssertEqual(loved.count, 1)
        XCTAssertEqual(loved[0].release.id, 2831)
        XCTAssertEqual(loved[0].labelName, "20:20 Vision")
        XCTAssertEqual(loved[0].kind, .love)
    }

    func testLibraryWithoutFilterReturnsEverythingNewestFirst() throws {
        let (service, db) = try makeService()
        try seed(db)

        let all = try service.library(kind: nil)

        XCTAssertEqual(all.map(\.release.id), [2833, 2832, 2831])
    }

    func testLibraryCountsLikedTracks() throws {
        let (service, db) = try makeService()
        try seed(db)
        _ = try service.toggleTrackLike(releaseID: 2831, youtubeID: "vid2831")

        let loved = try service.library(kind: .love)

        XCTAssertEqual(loved[0].likedTrackCount, 1)
    }

    func testToggleTrackLikeSwitchesBothWays() throws {
        let (service, db) = try makeService()
        try seed(db)

        XCTAssertTrue(try service.toggleTrackLike(releaseID: 2831, youtubeID: "vid2831"))
        XCTAssertEqual(try db.read { try TrackLikeRecord.fetchCount($0) }, 1)

        XCTAssertFalse(try service.toggleTrackLike(releaseID: 2831, youtubeID: "vid2831"))
        XCTAssertEqual(try db.read { try TrackLikeRecord.fetchCount($0) }, 0)
    }

    func testToggleTrackLikeIgnoresUnknownVideo() throws {
        let (service, db) = try makeService()
        try seed(db)

        XCTAssertFalse(try service.toggleTrackLike(releaseID: 2831, youtubeID: "nope"))
        XCTAssertEqual(try db.read { try TrackLikeRecord.fetchCount($0) }, 0)
    }

    func testLikedTracksCarryReleaseContext() throws {
        let (service, db) = try makeService()
        try seed(db)
        _ = try service.toggleTrackLike(releaseID: 2831, youtubeID: "vid2831")

        let likes = try service.likedTracks()

        XCTAssertEqual(likes.count, 1)
        XCTAssertEqual(likes[0].releaseTitle, "Fresh Connections")
        XCTAssertEqual(likes[0].artistName, "Inland Knights")
        XCTAssertEqual(likes[0].labelName, "20:20 Vision")
        XCTAssertEqual(likes[0].youtubeID, "vid2831")
    }

    func testRebuildQueueMarksLikedTracks() throws {
        let (service, db) = try makeService()
        try seed(db)
        // Decided releases leave the queue, so the like has to sit on a fresh one.
        try db.write { database in
            var release = ReleaseRecord(
                id: 4001, title: "Undecided EP", artistName: "Carl A. Finlow",
                year: 2001, catno: "VIS100", labelID: 15, styles: ["Deep House"],
                want: 300, have: 20, hydrated: true
            )
            try release.save(database)
            var video = VideoRecord(
                id: nil, releaseID: 4001, youtubeID: "vid4001", title: "A1",
                position: 0, unavailable: false
            )
            try video.insert(database)
        }
        _ = try service.toggleTrackLike(releaseID: 4001, youtubeID: "vid4001")

        let cards = try service.rebuildQueue(limit: 20)
        let card = cards.first { $0.releaseID == 4001 }

        XCTAssertEqual(card?.tracks.first?.liked, true)
    }

    func testManualWeightOverridesGraphWeight() throws {
        let (service, db) = try makeService()
        try seed(db)

        try service.setManualWeight(0.9, label: 15)

        let stored = try db.read { try LabelRecord.fetchOne($0, key: 15) }
        XCTAssertEqual(stored?.manualWeight, 0.9)
        XCTAssertEqual(stored?.effectiveWeight, 0.9)
        XCTAssertEqual(stored?.weight, 0.4, "the computed weight must survive untouched")
    }

    func testClearingManualWeightHandsControlBack() throws {
        let (service, db) = try makeService()
        try seed(db)
        try service.setManualWeight(0.9, label: 15)

        try service.setManualWeight(nil, label: 15)

        let stored = try db.read { try LabelRecord.fetchOne($0, key: 15) }
        XCTAssertNil(stored?.manualWeight)
        XCTAssertEqual(stored?.effectiveWeight, 0.4)
    }

    func testManualArtistWeightIsStored() throws {
        let (service, db) = try makeService()
        try seed(db)

        try service.setManualWeight(0.25, artist: 13320)

        XCTAssertEqual(try db.read { try ArtistRecord.fetchOne($0, key: 13320) }?.manualWeight, 0.25)
    }
}

final class NodeUpsertTests: XCTestCase {
    private func database() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.write { database in
            var seed = ArtistRecord(id: 13320, name: "Carl A. Finlow", weight: 1.0, refreshedAt: nil)
            try seed.save(database)
            var label = LabelRecord(id: 15, name: "20:20 Vision", weight: 0.6, refreshedAt: nil)
            try label.save(database)
        }
        return db
    }

    func testUpsertKeepsExistingArtistWeight() throws {
        let db = try database()
        let stamp = Date(timeIntervalSince1970: 1_000_000)

        try db.write { database in
            try NodeUpsert.artist(id: 13320, name: "Carl A. Finlow", refreshedAt: stamp, in: database)
        }

        let stored = try db.read { try ArtistRecord.fetchOne($0, key: 13320) }
        XCTAssertEqual(stored?.weight, 1.0, "a seed weight must survive an expansion")
        XCTAssertEqual(stored?.refreshedAt, stamp)
    }

    func testUpsertInsertsUnknownArtistWithoutWeight() throws {
        let db = try database()

        try db.write { database in
            try NodeUpsert.artist(id: 99, name: "Neu", refreshedAt: nil, in: database)
        }

        let stored = try db.read { try ArtistRecord.fetchOne($0, key: 99) }
        XCTAssertEqual(stored?.name, "Neu")
        XCTAssertEqual(stored?.weight, 0)
    }

    func testUpsertKeepsManualWeight() throws {
        let db = try database()
        try db.write { database in
            try database.execute(sql: "UPDATE artist SET manualWeight = 0.42 WHERE id = 13320")
        }

        try db.write { database in
            try NodeUpsert.artist(id: 13320, name: "Carl A. Finlow", refreshedAt: nil, in: database)
        }

        XCTAssertEqual(try db.read { try ArtistRecord.fetchOne($0, key: 13320) }?.manualWeight, 0.42)
    }

    func testUpsertKeepsExistingLabelWeight() throws {
        let db = try database()

        try db.write { database in
            try NodeUpsert.label(id: 15, name: "20:20 Vision", in: database)
        }

        XCTAssertEqual(try db.read { try LabelRecord.fetchOne($0, key: 15) }?.weight, 0.6)
    }

    func testUpsertRefreshesTheName() throws {
        let db = try database()

        try db.write { database in
            try NodeUpsert.label(id: 15, name: "20:20 Vision Recordings", in: database)
        }

        XCTAssertEqual(try db.read { try LabelRecord.fetchOne($0, key: 15) }?.name, "20:20 Vision Recordings")
    }
}

final class WantlistSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private var wantsBody: Data {
        Data(#"""
        {"pagination": {"page": 1, "pages": 1, "items": 2, "per_page": 100},
         "wants": [
          {"id": 5040318, "basic_information": {"title": "J's Credit EP", "year": 2013,
            "artists": [{"id": 1, "name": "Mr. G"}],
            "labels": [{"id": 42, "name": "Bass Culture", "catno": "BCR035"}]}},
          {"id": 1302967, "basic_information": {"title": "Preacher", "year": 2008,
            "artists": [{"id": 2, "name": "Moodymanc"}],
            "labels": [{"id": 15, "name": "20:20 Vision", "catno": "VIS200"}]}}
         ]}
        """#.utf8)
    }

    private func makeService(_ transport: StubTransport) throws -> (QueueService, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        try secrets.write("tok", for: .discogsToken)
        let client = DiscogsClient(
            transport: transport, secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
        let outbox = OutboxProcessor(database: db, writer: client, username: "schakal", now: { self.now })
        return (
            QueueService(
                database: db, client: client, outbox: outbox,
                username: "schakal", now: { self.now }
            ),
            db
        )
    }

    func testSyncWantlistFilesUnknownReleases() async throws {
        let (service, db) = try makeService(StubTransport(replies: [.init(body: wantsBody)]))

        let count = try await service.syncWantlist()

        XCTAssertEqual(count, 2)
        let release = try db.read { try ReleaseRecord.fetchOne($0, key: 5040318) }
        XCTAssertEqual(release?.title, "J's Credit EP")
        XCTAssertEqual(release?.artistName, "Mr. G")
        XCTAssertEqual(release?.catno, "BCR035")
        XCTAssertEqual(release?.labelID, 42)
        XCTAssertEqual(try db.read { try LabelRecord.fetchOne($0, key: 42) }?.name, "Bass Culture")
    }

    func testSyncWantlistRecordsALoveSoTheLibraryMatchesDiscogs() async throws {
        let (service, db) = try makeService(StubTransport(replies: [.init(body: wantsBody)]))

        _ = try await service.syncWantlist()

        let loved = try service.library(kind: .love).map(\.release.id).sorted()
        XCTAssertEqual(loved, [1302967, 5040318])
    }

    func testSyncWantlistDoesNotDuplicateAnExistingDecision() async throws {
        let (service, db) = try makeService(StubTransport(replies: [.init(body: wantsBody)]))
        try db.write { database in
            var release = ReleaseRecord(
                id: 5040318, title: "J's Credit EP", artistName: "Mr. G", year: nil,
                catno: nil, labelID: nil, styles: [], want: 0, have: 0, hydrated: false
            )
            try release.save(database)
            var decision = DecisionRecord(
                id: nil, releaseID: 5040318, kind: .love,
                decidedAt: self.now, revisitAt: nil
            )
            try decision.insert(database)
        }

        _ = try await service.syncWantlist()

        let decisions = try db.read {
            try DecisionRecord.filter(Column("releaseID") == 5040318).fetchAll($0)
        }
        XCTAssertEqual(decisions.count, 1)
    }

    func testSyncWantlistLeavesAnExistingTitleAlone() async throws {
        let (service, db) = try makeService(StubTransport(replies: [.init(body: wantsBody)]))
        try db.write { database in
            var release = ReleaseRecord(
                id: 5040318, title: "Schon bekannt", artistName: "Mr. G", year: 2013,
                catno: "BCR035", labelID: 42, styles: ["Deep House"], want: 99, have: 4,
                hydrated: true
            )
            try release.save(database)
        }

        _ = try await service.syncWantlist()

        let release = try db.read { try ReleaseRecord.fetchOne($0, key: 5040318) }
        XCTAssertEqual(release?.title, "Schon bekannt")
        XCTAssertEqual(release?.want, 99, "a hydrated release must not be overwritten by the stub")
    }
}
