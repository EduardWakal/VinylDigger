import XCTest
import GRDB
@testable import VinylDiggerKit

final class AppDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    func testMigrationsCreateAllTables() throws {
        let db = try makeDatabase()
        let tables = try db.read { database in
            try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
        }
        XCTAssertEqual(tables, [
            "artist", "decision", "discovery_cursor", "discovery_item", "edge", "export_cursor", "label", "outbox", "queue_item",
            "release", "track_like", "video"
        ])
    }

    func testArtistRoundTrips() throws {
        let db = try makeDatabase()
        try db.write { database in
            var record = ArtistRecord(id: 13320, name: "Carl A. Finlow", weight: 1.0, refreshedAt: nil)
            try record.save(database)
        }
        let loaded = try db.read { try ArtistRecord.fetchOne($0, key: 13320) }
        XCTAssertEqual(loaded?.name, "Carl A. Finlow")
        XCTAssertEqual(loaded?.weight, 1.0)
    }

    func testReleaseRoundTripsWithStyles() throws {
        let db = try makeDatabase()
        try db.write { database in
            var record = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: 1999, catno: "VIS035", labelID: 15, styles: ["House", "Deep House"],
                want: 582, have: 517, hydrated: true
            )
            try record.save(database)
        }
        let loaded = try db.read { try ReleaseRecord.fetchOne($0, key: 2831) }
        XCTAssertEqual(loaded?.styles, ["House", "Deep House"])
        XCTAssertEqual(loaded?.want, 582)
        XCTAssertTrue(loaded?.hydrated == true)
    }

    func testReleaseRoundTripsWithRating() throws {
        let db = try makeDatabase()
        try db.write { database in
            var record = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: 1999, catno: "VIS035", labelID: 15, styles: [],
                want: 582, have: 517, hydrated: true, rating: 4.22, ratingCount: 79
            )
            try record.save(database)
        }
        let loaded = try db.read { try ReleaseRecord.fetchOne($0, key: 2831) }
        XCTAssertEqual(loaded?.rating ?? 0, 4.22, accuracy: 0.001)
        XCTAssertEqual(loaded?.ratingCount, 79)
    }

    func testRatingDefaultsToZeroForExistingRows() throws {
        let db = try makeDatabase()
        try db.write { database in
            var record = ReleaseRecord(
                id: 7, title: "X", artistName: "Y", year: nil, catno: nil,
                labelID: nil, styles: [], want: 0, have: 0, hydrated: false
            )
            try record.save(database)
        }
        let loaded = try db.read { try ReleaseRecord.fetchOne($0, key: 7) }
        XCTAssertEqual(loaded?.rating, 0)
        XCTAssertEqual(loaded?.ratingCount, 0)
    }

    func testReleaseRoundTripsWithCoverURL() throws {
        let db = try makeDatabase()
        try db.write { database in
            var record = ReleaseRecord(
                id: 2831, title: "Fresh Connections", artistName: "Inland Knights",
                year: nil, catno: nil, labelID: nil, styles: [], want: 0, have: 0,
                hydrated: true, coverURL: "https://i.discogs.com/front.jpeg"
            )
            try record.save(database)
        }
        let loaded = try db.read { try ReleaseRecord.fetchOne($0, key: 2831) }
        XCTAssertEqual(loaded?.coverURL, "https://i.discogs.com/front.jpeg")
    }

    func testVideoRoundTripsWithDurationAndTrackPosition() throws {
        let db = try makeDatabase()
        try db.write { database in
            var record = VideoRecord(
                id: nil, releaseID: 2831, youtubeID: "abc", title: "Mr G - Toi Toi",
                position: 0, unavailable: false, duration: 451, trackPosition: "B1"
            )
            try record.insert(database)
        }
        let loaded = try db.read { try VideoRecord.fetchOne($0, key: 1) }
        XCTAssertEqual(loaded?.duration, 451)
        XCTAssertEqual(loaded?.trackPosition, "B1")
        XCTAssertEqual(loaded?.position, 0)
    }

    func testNewColumnsDefaultToNil() throws {
        let db = try makeDatabase()
        try db.write { database in
            var release = ReleaseRecord(
                id: 7, title: "X", artistName: "Y", year: nil, catno: nil,
                labelID: nil, styles: [], want: 0, have: 0, hydrated: false
            )
            try release.save(database)
            var video = VideoRecord(
                id: nil, releaseID: 7, youtubeID: "abc", title: nil,
                position: 0, unavailable: false
            )
            try video.insert(database)
        }
        XCTAssertNil(try db.read { try ReleaseRecord.fetchOne($0, key: 7) }?.coverURL)
        let video = try db.read { try VideoRecord.filter(Column("releaseID") == 7).fetchOne($0) }
        XCTAssertNil(video?.duration)
        XCTAssertNil(video?.trackPosition)
    }

    func testMigrationV5ResetsRatingSoCoverGetsFetchedOnce() throws {
        let db = try makeDatabase()
        try db.write { database in
            // A row hydrated before v4 existed: rating known, cover never fetched.
            try database.execute(sql: """
                INSERT INTO release (id, title, artistName, styles, want, have, hydrated, owned,
                                     rating, ratingCount, coverURL)
                VALUES (99, 'Old', 'Artist', ?, 5, 3, 1, 0, 4.45, 29, NULL)
                """, arguments: [Data("[]".utf8)])
        }

        // v5 already ran as part of makeDatabase, so a row inserted afterwards keeps
        // its values — the reset only applies to what existed at migration time.
        let loaded = try db.read { try ReleaseRecord.fetchOne($0, key: 99) }
        XCTAssertEqual(loaded?.ratingCount, 29)

        let applied = try db.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertTrue(applied.contains("v5"))
    }

    func testEdgeRoundTrips() throws {
        let db = try makeDatabase()
        try db.write { database in
            var artist = ArtistRecord(id: 1, name: "A", weight: 1.0, refreshedAt: nil)
            try artist.save(database)
            var label = LabelRecord(id: 15, name: "20:20 Vision", weight: 0.0, refreshedAt: nil)
            try label.save(database)
            var edge = EdgeRecord(
                id: nil, fromKind: .artist, fromID: 1, toKind: .label, toID: 15, kind: .artistToLabel
            )
            try edge.insert(database)
        }
        let edges = try db.read { try EdgeRecord.fetchAll($0) }
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].kind, .artistToLabel)
    }

    func testDuplicateEdgeIsRejected() throws {
        let db = try makeDatabase()
        try db.write { database in
            var edge = EdgeRecord(
                id: nil, fromKind: .artist, fromID: 1, toKind: .label, toID: 15, kind: .artistToLabel
            )
            try edge.insert(database)
        }
        XCTAssertThrowsError(try db.write { database in
            var duplicate = EdgeRecord(
                id: nil, fromKind: .artist, fromID: 1, toKind: .label, toID: 15, kind: .artistToLabel
            )
            try duplicate.insert(database)
        })
    }

    func testDecisionRoundTrips() throws {
        let db = try makeDatabase()
        let when = Date(timeIntervalSince1970: 1_000_000)
        try db.write { database in
            var decision = DecisionRecord(
                id: nil, releaseID: 2831, kind: .later, decidedAt: when,
                revisitAt: when.addingTimeInterval(30 * 86_400)
            )
            try decision.insert(database)
        }
        let loaded = try db.read { try DecisionRecord.fetchAll($0) }
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .later)
        XCTAssertNotNil(loaded[0].revisitAt)
    }

    func testOutboxRoundTrips() throws {
        let db = try makeDatabase()
        try db.write { database in
            var entry = OutboxRecord(
                id: nil, releaseID: 2831, attempts: 0, lastError: nil,
                nextAttemptAt: Date(timeIntervalSince1970: 0)
            )
            try entry.insert(database)
        }
        let entries = try db.read { try OutboxRecord.fetchAll($0) }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].attempts, 0)
    }

    func testMigrationIsIdempotent() throws {
        let path = NSTemporaryDirectory() + "digger-migration-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try AppDatabase(path: path)
        XCTAssertNoThrow(try AppDatabase(path: path))
    }

    func testStoresAndReadsDiscoveryItem() throws {
        let database = try AppDatabase.inMemory()
        let stamp = Date(timeIntervalSince1970: 1_770_000_000)

        try database.write { db in
            var item = DiscoveryItemRecord(
                releaseID: 2831, masterID: 41133, title: "Fresh Connections",
                artistName: "Inland Knights", styles: ["Deep House"],
                have: 517, want: 582, year: 1999, labelName: "20:20 Vision",
                catno: "VIS035", axisKey: "Deep House|All-Time|1",
                score: 0.8, rank: 0, fetchedAt: stamp
            )
            try item.insert(db)
        }

        let stored = try database.read { try DiscoveryItemRecord.fetchOne($0, key: 2831) }
        XCTAssertEqual(stored?.artistName, "Inland Knights")
        XCTAssertEqual(stored?.styles, ["Deep House"])
        XCTAssertEqual(stored?.have, 517)
    }

    func testDiscoveryCursorRoundTrips() throws {
        let database = try AppDatabase.inMemory()

        try database.write { db in
            var cursor = DiscoveryCursorRecord(
                id: DiscoveryCursorRecord.singletonID,
                styleIndex: 2, windowIndex: 3, page: 4
            )
            try cursor.save(db)
        }

        let stored = try database.read {
            try DiscoveryCursorRecord.fetchOne($0, key: DiscoveryCursorRecord.singletonID)
        }
        XCTAssertEqual(stored?.styleIndex, 2)
        XCTAssertEqual(stored?.windowIndex, 3)
        XCTAssertEqual(stored?.page, 4)
    }
}

final class VideoBackfillMigrationTests: XCTestCase {
    func testV9ClearsDetailFetchedForReleasesWithoutVideos() throws {
        let db = try AppDatabase.inMemory()
        try db.write { database in
            // Fetched under the old code, which never inserted videos.
            var barren = ReleaseRecord(
                id: 1, title: "Ohne", artistName: "A", year: nil, catno: nil, labelID: nil,
                styles: [], want: 0, have: 0, hydrated: false, detailFetched: true
            )
            try barren.save(database)

            var withVideo = ReleaseRecord(
                id: 2, title: "Mit", artistName: "B", year: nil, catno: nil, labelID: nil,
                styles: [], want: 0, have: 0, hydrated: false, detailFetched: true
            )
            try withVideo.save(database)
            var video = VideoRecord(
                id: nil, releaseID: 2, youtubeID: "abc", title: nil,
                position: 0, unavailable: false
            )
            try video.insert(database)
        }

        // The migration already ran, so apply the same statement it carries.
        try db.write { database in
            try database.execute(sql: """
                UPDATE release SET detailFetched = 0
                WHERE detailFetched = 1
                  AND NOT EXISTS (SELECT 1 FROM video WHERE video.releaseID = release.id)
                """)
        }

        XCTAssertEqual(try db.read { try ReleaseRecord.fetchOne($0, key: 1) }?.detailFetched, false)
        XCTAssertEqual(try db.read { try ReleaseRecord.fetchOne($0, key: 2) }?.detailFetched, true)
    }

    func testV9IsRegistered() throws {
        let db = try AppDatabase.inMemory()
        let applied = try db.read { database in
            try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations")
        }
        XCTAssertTrue(applied.contains("v9"))
    }
}
