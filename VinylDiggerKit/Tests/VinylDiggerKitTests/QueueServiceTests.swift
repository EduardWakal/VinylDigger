import XCTest
import GRDB
@testable import VinylDiggerKit

final class QueueServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeService(
        transport: StubTransport = StubTransport(replies: [])
    ) throws -> (QueueService, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        try secrets.write("tok", for: .discogsToken)
        let client = DiscogsClient(
            transport: transport, secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
        let outbox = OutboxProcessor(database: db, writer: client, username: "schakal", now: { self.now })
        let service = QueueService(
            database: db, client: client, outbox: outbox,
            username: "schakal", now: { self.now }
        )
        return (service, db)
    }

    private func seedGraph(_ db: AppDatabase) throws {
        try db.write { database in
            var artist = ArtistRecord(id: 13320, name: "Carl A. Finlow", weight: 1.0, refreshedAt: nil)
            try artist.save(database)
            var label = LabelRecord(id: 15, name: "20:20 Vision", weight: 0.0, refreshedAt: nil)
            try label.save(database)
            var edge = EdgeRecord(
                id: nil, fromKind: .artist, fromID: 13320,
                toKind: .label, toID: 15, kind: .artistToLabel
            )
            try edge.insert(database)
            var release = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: 1999, catno: "VIS035", labelID: 15, styles: ["Deep House"],
                want: 582, have: 517, hydrated: true
            )
            try release.save(database)
            var video = VideoRecord(
                id: nil, releaseID: 2831, youtubeID: "cqRa3O8xQNQ",
                title: nil, position: 0, unavailable: false
            )
            try video.insert(database)
        }
    }

    func testRebuildQueueReturnsCardsForReachableReleases() throws {
        let (service, db) = try makeService()
        try seedGraph(db)

        let cards = try service.rebuildQueue(limit: 10)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].releaseID, 2831)
        XCTAssertEqual(cards[0].labelName, "20:20 Vision")
        XCTAssertEqual(cards[0].videoIDs, ["cqRa3O8xQNQ"])
        XCTAssertTrue(cards[0].reason.contains("20:20 Vision"))
    }

    private var releaseBody: Data {
        Data(#"""
        {"id": 2831, "title": "Fresh Connections", "labels": [], "artists": [],
         "community": {"want": 600, "have": 520, "rating": {"average": 4.22, "count": 79}},
         "images": [{"type": "primary", "uri": "https://i.discogs.com/front.jpeg"}],
         "tracklist": [{"position": "B1", "title": "Fresh Connections"}],
         "videos": [{"uri": "https://youtu.be/cqRa3O8xQNQ",
                     "title": "Inland Knights - Fresh Connections", "duration": 451}]}
        """#.utf8)
    }

    func testHydrateReleaseStoresRatingCoverAndVideoDetail() async throws {
        let (service, db) = try makeService(
            transport: StubTransport(replies: [.init(body: releaseBody)])
        )
        try seedGraph(db)

        let stored = try await service.hydrateRelease(releaseID: 2831)

        XCTAssertEqual(stored.rating, 4.22, accuracy: 0.001)
        XCTAssertEqual(stored.ratingCount, 79)
        XCTAssertEqual(stored.want, 600)
        XCTAssertEqual(stored.coverURL, "https://i.discogs.com/front.jpeg")

        let video = try db.read {
            try VideoRecord.filter(Column("releaseID") == 2831).fetchOne($0)
        }
        XCTAssertEqual(video?.title, "Inland Knights - Fresh Connections")
        XCTAssertEqual(video?.duration, 451)
        XCTAssertEqual(video?.trackPosition, "B1")
    }

    func testHydrateReleaseIsSkippedWhenAlreadyKnown() async throws {
        let transport = StubTransport(replies: [])
        let (service, db) = try makeService(transport: transport)
        try seedGraph(db)
        try db.write { database in
            try database.execute(
                sql: "UPDATE release SET rating = 3.5, ratingCount = 12 WHERE id = 2831"
            )
        }

        let stored = try await service.hydrateRelease(releaseID: 2831)

        XCTAssertEqual(stored.ratingCount, 12)
        XCTAssertTrue(transport.sentRequests.isEmpty)
    }

    func testRebuildQueueCarriesCoverAndTracksOntoCard() throws {
        let (service, db) = try makeService()
        try seedGraph(db)
        try db.write { database in
            try database.execute(sql: """
                UPDATE release SET rating = 4.22, ratingCount = 79,
                coverURL = 'https://i.discogs.com/front.jpeg' WHERE id = 2831
                """)
            try database.execute(sql: """
                UPDATE video SET title = 'Inland Knights - Fresh Connections',
                duration = 451, trackPosition = 'B1' WHERE releaseID = 2831
                """)
        }

        let cards = try service.rebuildQueue(limit: 10)

        XCTAssertEqual(cards[0].rating ?? 0, 4.22, accuracy: 0.001)
        XCTAssertEqual(cards[0].coverURL, "https://i.discogs.com/front.jpeg")
        XCTAssertEqual(cards[0].tracks.count, 1)
        XCTAssertEqual(cards[0].tracks[0].youtubeID, "cqRa3O8xQNQ")
        XCTAssertEqual(cards[0].tracks[0].position, "B1")
        XCTAssertEqual(cards[0].tracks[0].duration, 451)
    }

    func testRebuildQueuePersistsQueueItems() throws {
        let (service, db) = try makeService()
        try seedGraph(db)

        _ = try service.rebuildQueue(limit: 10)

        let items = try db.read { try QueueItemRecord.fetchAll($0) }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].rank, 0)
    }

    func testRebuildQueueSkipsUnreachableReleases() throws {
        let (service, db) = try makeService()
        try db.write { database in
            var orphan = ReleaseRecord(
                id: 999, title: "Orphan", artistName: "Nobody", year: nil, catno: nil,
                labelID: nil, styles: [], want: 0, have: 0, hydrated: true
            )
            try orphan.save(database)
        }

        XCTAssertTrue(try service.rebuildQueue(limit: 10).isEmpty)
    }

    func testDiscardRemovesReleaseFromNextQueue() async throws {
        let (service, db) = try makeService()
        try seedGraph(db)

        try await service.decide(releaseID: 2831, kind: .discard)

        XCTAssertTrue(try service.rebuildQueue(limit: 10).isEmpty)
    }

    func testLaterSetsRevisitDateThirtyDaysOut() async throws {
        let (service, db) = try makeService()
        try seedGraph(db)

        try await service.decide(releaseID: 2831, kind: .later)

        let decision = try db.read { try DecisionRecord.fetchAll($0) }[0]
        XCTAssertEqual(decision.kind, .later)
        XCTAssertEqual(decision.revisitAt, now.addingTimeInterval(QueueService.revisitInterval))
    }

    func testLoveWritesToWantlist() async throws {
        let transport = StubTransport(replies: [])
        let (service, db) = try makeService(transport: transport)
        try seedGraph(db)

        try await service.decide(releaseID: 2831, kind: .love)

        let wantlistWrites = transport.sentRequests.filter {
            $0.httpMethod == "PUT" && $0.url?.path == "/users/schakal/wants/2831"
        }
        XCTAssertEqual(wantlistWrites.count, 1)
        XCTAssertTrue(
            try db.read { try OutboxRecord.fetchAll($0) }.isEmpty,
            "a delivered write leaves nothing queued"
        )
    }

    func testLoveKeepsWantlistWriteQueuedWhenDeliveryFails() async throws {
        let transport = StubTransport(replies: [.init(status: 500)])
        let (service, db) = try makeService(transport: transport)
        try seedGraph(db)

        try await service.decide(releaseID: 2831, kind: .love)

        let outbox = try db.read { try OutboxRecord.fetchAll($0) }
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox[0].releaseID, 2831)
        XCTAssertEqual(outbox[0].attempts, 1)
    }

    func testLoveRaisesLabelWeightInNextScoring() async throws {
        let (service, db) = try makeService()
        try seedGraph(db)
        try db.write { database in
            var second = ReleaseRecord(
                id: 3000, title: "Second", artistName: "Someone", year: 2000, catno: nil,
                labelID: 15, styles: [], want: 10, have: 1, hydrated: true
            )
            try second.save(database)
        }

        // Score the sibling release on the same label before and after the love.
        _ = try service.rebuildQueue(limit: 10)
        let before = try db.read { try QueueItemRecord.fetchOne($0, key: 3000) }

        try await service.decide(releaseID: 2831, kind: .love)

        _ = try service.rebuildQueue(limit: 10)
        let after = try db.read { try QueueItemRecord.fetchOne($0, key: 3000) }

        let beforeScore = try XCTUnwrap(before?.score)
        let afterScore = try XCTUnwrap(after?.score)
        XCTAssertGreaterThan(
            afterScore, beforeScore,
            "loving one release must raise its label's weight for the label's other releases"
        )
    }

    func testSyncCollectionMarksReleasesOwned() async throws {
        let json = """
        {"pagination": {"page": 1, "pages": 1}, "releases": [{"id": 2831}]}
        """
        let (service, db) = try makeService(
            transport: StubTransport(replies: [.init(body: Data(json.utf8))])
        )
        try seedGraph(db)

        let count = try await service.syncCollection()

        XCTAssertEqual(count, 1)
        let release = try db.read { try ReleaseRecord.fetchOne($0, key: 2831) }
        XCTAssertTrue(release?.owned == true)
        XCTAssertTrue(try service.rebuildQueue(limit: 10).isEmpty, "owned releases never queue")
    }

    func testExpandAddsAliasAndLabelEdges() async throws {
        let artistJSON = """
        {"id": 13320, "name": "Carl A. Finlow",
         "aliases": [{"id": 999, "name": "Random Factor"}],
         "groups": [{"id": 555, "name": "20:20 Vision"}]}
        """
        let releasesJSON = """
        {"pagination": {"page": 1, "pages": 1},
         "releases": [{"id": 4000, "title": "X", "year": 2001,
                       "label": "Artform", "catno": "artform001",
                       "artist": "Carl A. Finlow", "role": "Main"}]}
        """
        let releaseJSON = """
        {"id": 2831, "title": "Fresh Connections",
         "artists": [{"id": 13320, "name": "Carl A. Finlow"}],
         "labels": [{"id": 15, "name": "20:20 Vision", "catno": "VIS035"}]}
        """
        let (service, db) = try makeService(transport: StubTransport(replies: [
            .init(body: Data(releaseJSON.utf8)),
            .init(body: Data(artistJSON.utf8)),
            .init(body: Data(releasesJSON.utf8))
        ]))
        try seedGraph(db)

        try await service.expand(from: 2831)

        let edges = try db.read { try EdgeRecord.fetchAll($0) }
        XCTAssertTrue(edges.contains { $0.kind == .alias && $0.toID == 999 })
        XCTAssertTrue(edges.contains { $0.kind == .group && $0.toID == 555 })
    }
}
