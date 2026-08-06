import Foundation
import GRDB

public final class AppDatabase {
    private let writer: DatabaseWriter

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        writer = try DatabasePool(path: path)
        try Self.migrator.migrate(writer)
    }

    private init(writer: DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VinylDigger/vinyldigger.sqlite").path
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "artist") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 0)
                t.column("refreshedAt", .datetime)
            }

            try db.create(table: "label") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 0)
                t.column("refreshedAt", .datetime)
            }

            try db.create(table: "release") { t in
                t.primaryKey("id", .integer)
                t.column("title", .text).notNull()
                t.column("artistName", .text).notNull()
                t.column("year", .integer)
                t.column("catno", .text)
                t.column("labelID", .integer)
                t.column("styles", .blob).notNull()
                t.column("want", .integer).notNull().defaults(to: 0)
                t.column("have", .integer).notNull().defaults(to: 0)
                t.column("hydrated", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "release_label", on: "release", columns: ["labelID"])

            try db.create(table: "video") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("releaseID", .integer).notNull().indexed()
                t.column("youtubeID", .text).notNull()
                t.column("title", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
                t.column("unavailable", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["releaseID", "youtubeID"])
            }

            try db.create(table: "edge") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fromKind", .text).notNull()
                t.column("fromID", .integer).notNull()
                t.column("toKind", .text).notNull()
                t.column("toID", .integer).notNull()
                t.column("kind", .text).notNull()
                t.uniqueKey(["fromKind", "fromID", "toKind", "toID", "kind"])
            }

            try db.create(table: "decision") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("releaseID", .integer).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("decidedAt", .datetime).notNull()
                t.column("revisitAt", .datetime)
            }

            try db.create(table: "queue_item") { t in
                t.primaryKey("releaseID", .integer)
                t.column("score", .double).notNull()
                t.column("rank", .integer).notNull()
                t.column("reason", .text).notNull()
            }

            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("releaseID", .integer).notNull().unique()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("nextAttemptAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "release") { t in
                t.add(column: "owned", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.alter(table: "release") { t in
                t.add(column: "rating", .double).notNull().defaults(to: 0)
                t.add(column: "ratingCount", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v4") { db in
            try db.alter(table: "release") { t in
                t.add(column: "coverURL", .text)
            }
            try db.alter(table: "video") { t in
                t.add(column: "duration", .integer)
                t.add(column: "trackPosition", .text)
            }
        }

        // Releases hydrated before v4 carry a rating but no cover, video duration or
        // track position. hydrateRelease skips anything with a rating, so without this
        // reset those rows would never pick the new fields up.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: "UPDATE release SET rating = 0, ratingCount = 0")
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "release") { t in
                t.add(column: "detailFetched", .boolean).notNull().defaults(to: false)
            }
            // Anything already carrying a cover went through the detail fetch.
            try db.execute(sql: "UPDATE release SET detailFetched = 1 WHERE coverURL IS NOT NULL")
        }

        migrator.registerMigration("v7") { db in
            try db.create(table: "track_like") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("releaseID", .integer).notNull().indexed()
                t.column("youtubeID", .text).notNull()
                t.column("likedAt", .datetime).notNull()
                t.uniqueKey(["releaseID", "youtubeID"])
            }
        }

        migrator.registerMigration("v8") { db in
            try db.alter(table: "artist") { t in
                t.add(column: "manualWeight", .double)
            }
            try db.alter(table: "label") { t in
                t.add(column: "manualWeight", .double)
            }
        }

        return migrator
    }
}
