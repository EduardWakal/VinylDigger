import XCTest
import GRDB
@testable import DiggerKit

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
        XCTAssertEqual(tables, ["artist", "decision", "edge", "label", "outbox", "queue_item", "release", "video"])
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
}
