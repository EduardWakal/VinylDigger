import Foundation
import GRDB

/// Writes graph nodes without touching their weights.
///
/// `save` on a record overwrites every column, so building an `ArtistRecord` with
/// `weight: 0` and saving it wipes a seed's 1.0 — which empties the queue, because
/// no seeds means nothing to propagate from. Expansion only ever learns names, so
/// it goes through here.
public enum NodeUpsert {
    public static func artist(id: Int, name: String, refreshedAt: Date?, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO artist (id, name, weight, refreshedAt) VALUES (?, ?, 0, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    refreshedAt = COALESCE(excluded.refreshedAt, artist.refreshedAt)
                """,
            arguments: [id, name, refreshedAt]
        )
    }

    public static func label(id: Int, name: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO label (id, name, weight) VALUES (?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name
                """,
            arguments: [id, name]
        )
    }
}
