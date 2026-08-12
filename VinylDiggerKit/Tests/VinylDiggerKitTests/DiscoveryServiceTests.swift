import XCTest
import GRDB
@testable import VinylDiggerKit

final class DiscoveryServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeClient(_ transport: StubTransport) -> DiscogsClient {
        let secrets = InMemorySecretStore()
        try? secrets.write("tok", for: .discogsToken)
        return DiscogsClient(
            transport: transport, secrets: secrets,
            limiter: RateLimiter(capacity: 100, refillPerSecond: 100),
            userAgent: "VinylDiggerTests/1.0"
        )
    }

    private func results(_ hits: String) -> Data {
        Data("{\"results\": [\(hits)]}".utf8)
    }

    private func hit(id: Int, artist: String, want: Int, master: Int = 0) -> String {
        """
        {"id": \(id), "master_id": \(master), "title": "\(artist) - Titel \(id)",
         "year": "1999", "label": ["Label"], "catno": "CAT\(id)",
         "style": ["Deep House"], "community": {"have": 10, "want": \(want)}}
        """
    }

    func testRefreshStoresBatchAndAdvancesCursor() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results([hit(id: 1, artist: "Neu", want: 500)].joined(separator: ",")))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards[0].releaseID, 1)
        XCTAssertEqual(cards[0].artistName, "Neu")
        XCTAssertTrue(cards[0].reason.contains("Deep House"))

        let cursor = try database.read {
            try DiscoveryCursorRecord.fetchOne($0, key: DiscoveryCursorRecord.singletonID)
        }
        XCTAssertEqual(cursor?.windowIndex, 1)
    }

    func testReasonSurvivesAStyleContainingTheSeparator() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results(hit(id: 1, artist: "Neu", want: 500)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep|House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertTrue(cards[0].reason.hasPrefix("Deep|House \u{00B7} All-Time"))
    }

    func testRefreshFilesStubReleasesSoTheyCanBeHydrated() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results(hit(id: 42, artist: "Neu", want: 500)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        _ = try await service.refresh(limit: 10)

        let release = try database.read { try ReleaseRecord.fetchOne($0, key: 42) }
        XCTAssertEqual(release?.artistName, "Neu")
        XCTAssertEqual(release?.detailFetched, false)
    }

    func testRefreshSkipsExhaustedAxisAndTriesTheNext() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            var owned = ReleaseRecord(
                id: 1, title: "Titel 1", artistName: "Neu", year: nil, catno: nil,
                labelID: nil, styles: [], want: 0, have: 0, hydrated: false, owned: true
            )
            try owned.save(db)
        }
        let transport = StubTransport(replies: [
            .init(body: results(hit(id: 1, artist: "Neu", want: 500))),
            .init(body: results(hit(id: 2, artist: "Neu", want: 400)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.map(\.releaseID), [2])
        XCTAssertEqual(transport.sentRequests.count, 2)

        // Verify the two requests target different axes
        let url1 = transport.sentRequests[0].url
        let url2 = transport.sentRequests[1].url
        let components1 = URLComponents(url: url1!, resolvingAgainstBaseURL: false)
        let components2 = URLComponents(url: url2!, resolvingAgainstBaseURL: false)

        let query1 = Dictionary(
            components1?.queryItems?.map { ($0.name, $0.value) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        let query2 = Dictionary(
            components2?.queryItems?.map { ($0.name, $0.value) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )

        // Both requests should have the same style
        XCTAssertEqual(query1["style"], "Deep House")
        XCTAssertEqual(query2["style"], "Deep House")

        // First request (all-time window) should have no year parameter
        XCTAssertNil(query1["year"])

        // Second request should have year parameter for the 1990-1999 window
        XCTAssertEqual(query2["year"], "1990-1999")
    }

    func testRefreshGivesUpAfterThreeEmptyAxes() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results("")), .init(body: results("")), .init(body: results(""))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertTrue(cards.isEmpty)
        XCTAssertEqual(transport.sentRequests.count, 3)
    }

    func testRefreshWithoutStylesThrows() async {
        let database = try! AppDatabase.inMemory()
        let service = DiscoveryService(
            database: database, client: makeClient(StubTransport(replies: [])),
            styles: [], now: { self.now }
        )

        do {
            _ = try await service.refresh(limit: 10)
            XCTFail("expected noStyles")
        } catch let error as DiscoveryError {
            XCTAssertEqual(error, .noStyles)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testFailedSearchLeavesCursorAndBatchAlone() async throws {
        let database = try AppDatabase.inMemory()
        let good = StubTransport(replies: [
            .init(body: results(hit(id: 1, artist: "Neu", want: 500)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(good),
            styles: ["Deep House"], now: { self.now }
        )
        _ = try await service.refresh(limit: 10)

        let failing = DiscoveryService(
            database: database,
            client: makeClient(StubTransport(replies: [.init(status: 500)])),
            styles: ["Deep House"], now: { self.now }
        )
        _ = try? await failing.refresh(limit: 10)

        XCTAssertEqual(try failing.currentBatch().map(\.releaseID), [1])
        let cursor = try database.read {
            try DiscoveryCursorRecord.fetchOne($0, key: DiscoveryCursorRecord.singletonID)
        }
        XCTAssertEqual(cursor?.windowIndex, 1)
    }

    func testKnownArtistIsMarkedForTheRanker() async throws {
        let database = try AppDatabase.inMemory()
        try database.write { db in
            var artist = ArtistRecord(id: 9, name: "Bekannt", weight: 1, refreshedAt: nil)
            try artist.save(db)
        }
        let transport = StubTransport(replies: [
            .init(body: results([
                hit(id: 1, artist: "Bekannt", want: 500),
                hit(id: 2, artist: "Neu", want: 500)
            ].joined(separator: ",")))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.map(\.releaseID), [2, 1])
    }

    // MARK: - review item 5: liked tracks on discovery cards

    func testCurrentBatchMarksLikedTracks() async throws {
        let database = try AppDatabase.inMemory()
        let transport = StubTransport(replies: [
            .init(body: results(hit(id: 1, artist: "Neu", want: 500)))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )
        _ = try await service.refresh(limit: 10)

        try database.write { db in
            var video = VideoRecord(
                id: nil, releaseID: 1, youtubeID: "abc", title: nil,
                position: 0, unavailable: false
            )
            try video.insert(db)
            var like = TrackLikeRecord(id: nil, releaseID: 1, youtubeID: "abc", likedAt: self.now)
            try like.insert(db)
        }

        let cards = try service.currentBatch()

        XCTAssertEqual(cards[0].tracks.first?.liked, true)
    }

    // MARK: - review item 6: store upserts instead of inserting

    func testRefreshDoesNotThrowWhenDuplicateReleaseIDsSurviveDedup() async throws {
        let database = try AppDatabase.inMemory()
        // Two hits with the same release id and no master id both survive
        // `DiscoveryRanker.deduplicate`, which only merges by master id.
        let transport = StubTransport(replies: [
            .init(body: results([
                hit(id: 1, artist: "Neu", want: 500),
                hit(id: 1, artist: "Neu", want: 500)
            ].joined(separator: ",")))
        ])
        let service = DiscoveryService(
            database: database, client: makeClient(transport),
            styles: ["Deep House"], now: { self.now }
        )

        let cards = try await service.refresh(limit: 10)

        XCTAssertEqual(cards.map(\.releaseID), [1])
    }
}
