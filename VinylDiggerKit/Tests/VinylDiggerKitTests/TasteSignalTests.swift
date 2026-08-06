import XCTest
import GRDB
@testable import VinylDiggerKit

final class TasteSignalTests: XCTestCase {
    func testALikedTrackOutweighsAWantlistEntry() {
        XCTAssertGreaterThan(TasteSignal.trackLikeWeight(count: 1), TasteSignal.wantlist)
    }

    func testTheOrderOfEvidenceHolds() {
        XCTAssertGreaterThan(TasteSignal.wantlist, TasteSignal.owned)
        XCTAssertGreaterThan(TasteSignal.owned, TasteSignal.later)
        XCTAssertGreaterThan(TasteSignal.later, 0)
        XCTAssertLessThan(TasteSignal.discard, 0)
    }

    func testMoreLikedTracksCountMoreButFlattenOut() {
        let one = TasteSignal.trackLikeWeight(count: 1)
        let two = TasteSignal.trackLikeWeight(count: 2)
        let five = TasteSignal.trackLikeWeight(count: 5)

        XCTAssertGreaterThan(two, one)
        XCTAssertGreaterThan(five, two)
        XCTAssertLessThan(five, 5 * one, "one favourite record must not drown out five others")
    }

    func testNoLikedTracksIsNoSignal() {
        XCTAssertEqual(TasteSignal.trackLikeWeight(count: 0), 0)
    }
}

final class WeightPersistenceTests: XCTestCase {
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
        let outbox = OutboxProcessor(database: db, writer: client, username: "s", now: { self.now })
        return (
            QueueService(database: db, client: client, outbox: outbox, username: "s", now: { self.now }),
            db
        )
    }

    private func seed(_ db: AppDatabase) throws {
        try db.write { database in
            var artist = ArtistRecord(id: 13320, name: "Carl A. Finlow", weight: 1.0, refreshedAt: nil)
            try artist.save(database)
            var label = LabelRecord(id: 15, name: "20:20 Vision", weight: 0, refreshedAt: nil)
            try label.save(database)
            var edge = EdgeRecord(
                id: nil, fromKind: .artist, fromID: 13320,
                toKind: .label, toID: 15, kind: .artistToLabel
            )
            try edge.insert(database)
            var release = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Carl A. Finlow",
                year: 1999, catno: "VIS035", labelID: 15, styles: [], want: 10, have: 5,
                hydrated: true
            )
            try release.save(database)
            var video = VideoRecord(
                id: nil, releaseID: 2831, youtubeID: "abc", title: "A1",
                position: 0, unavailable: false
            )
            try video.insert(database)
        }
    }

    func testComputedWeightsAreWrittenBack() throws {
        let (service, db) = try makeService()
        try seed(db)

        _ = try service.rebuildQueue(limit: 10)

        let label = try db.read { try LabelRecord.fetchOne($0, key: 15) }
        XCTAssertGreaterThan(
            label?.weight ?? 0, 0,
            "the statistics tab reads stored weights, so they have to be stored"
        )
    }

    func testALikedTrackRaisesItsLabelAboveAPlainWantlistEntry() throws {
        let (service, db) = try makeService()
        try seed(db)

        try db.write { database in
            var other = LabelRecord(id: 16, name: "Nur Wantlist", weight: 0, refreshedAt: nil)
            try other.save(database)
            var edge = EdgeRecord(
                id: nil, fromKind: .artist, fromID: 13320,
                toKind: .label, toID: 16, kind: .artistToLabel
            )
            try edge.insert(database)
            var release = ReleaseRecord(
                id: 2832, title: "Anderes", artistName: "Carl A. Finlow", year: nil,
                catno: nil, labelID: 16, styles: [], want: 10, have: 5, hydrated: true
            )
            try release.save(database)

            for id in [2831, 2832] {
                var decision = DecisionRecord(
                    id: nil, releaseID: id, kind: .love, decidedAt: self.now, revisitAt: nil
                )
                try decision.insert(database)
            }
        }
        _ = try service.toggleTrackLike(releaseID: 2831, youtubeID: "abc")

        _ = try service.rebuildQueue(limit: 10)

        let liked = try db.read { try LabelRecord.fetchOne($0, key: 15) }?.weight ?? 0
        let plain = try db.read { try LabelRecord.fetchOne($0, key: 16) }?.weight ?? 0
        XCTAssertGreaterThan(liked, plain)
    }

    func testAManualWeightIsNeverOverwrittenByTheComputedOne() throws {
        let (service, db) = try makeService()
        try seed(db)
        try service.setManualWeight(0.9, label: 15)

        _ = try service.rebuildQueue(limit: 10)

        let label = try db.read { try LabelRecord.fetchOne($0, key: 15) }
        XCTAssertEqual(label?.manualWeight, 0.9)
        XCTAssertEqual(label?.effectiveWeight, 0.9)
    }

    func testSeedArtistsKeepTheirWeight() throws {
        let (service, db) = try makeService()
        try seed(db)

        _ = try service.rebuildQueue(limit: 10)

        XCTAssertEqual(try db.read { try ArtistRecord.fetchOne($0, key: 13320) }?.weight, 1.0)
    }
}
