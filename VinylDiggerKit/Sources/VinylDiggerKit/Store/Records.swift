import Foundation
import GRDB

public struct ArtistRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "artist"

    public var id: Int
    public var name: String
    public var weight: Double
    public var refreshedAt: Date?

    public init(id: Int, name: String, weight: Double, refreshedAt: Date?) {
        self.id = id
        self.name = name
        self.weight = weight
        self.refreshedAt = refreshedAt
    }
}

public struct LabelRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "label"

    public var id: Int
    public var name: String
    public var weight: Double
    public var refreshedAt: Date?

    public init(id: Int, name: String, weight: Double, refreshedAt: Date?) {
        self.id = id
        self.name = name
        self.weight = weight
        self.refreshedAt = refreshedAt
    }
}

public struct ReleaseRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "release"

    public var id: Int
    public var title: String
    public var artistName: String
    public var year: Int?
    public var catno: String?
    public var labelID: Int?
    public var styles: [String]
    public var want: Int
    public var have: Int
    /// False until the expensive /releases/{id} lookup filled in want, have, styles and videos.
    public var hydrated: Bool
    /// True when the release is already in the user's Discogs collection.
    public var owned: Bool
    /// Discogs community rating, 0–5. Zero also means "not fetched yet"; use
    /// `ratingCount` to tell an unrated release from an unknown one.
    public var rating: Double
    public var ratingCount: Int
    /// Sleeve front from Discogs; nil until the release has been hydrated.
    public var coverURL: String?
    /// True once `/releases/{id}` has been read for this release. Rating alone is
    /// no marker — plenty of releases carry none, and those must not be refetched
    /// on every visit.
    public var detailFetched: Bool

    public init(
        id: Int, title: String, artistName: String, year: Int?, catno: String?,
        labelID: Int?, styles: [String], want: Int, have: Int, hydrated: Bool,
        owned: Bool = false, rating: Double = 0, ratingCount: Int = 0,
        coverURL: String? = nil, detailFetched: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.year = year
        self.catno = catno
        self.labelID = labelID
        self.styles = styles
        self.want = want
        self.have = have
        self.hydrated = hydrated
        self.owned = owned
        self.rating = rating
        self.ratingCount = ratingCount
        self.coverURL = coverURL
        self.detailFetched = detailFetched
    }
}

public struct VideoRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "video"

    public var id: Int64?
    public var releaseID: Int
    public var youtubeID: String
    public var title: String?
    public var position: Int
    public var unavailable: Bool
    /// Length in seconds from Discogs; the tracklist rarely carries one.
    public var duration: Int?
    /// Discogs sleeve position such as "A1" — unrelated to `position`, which is
    /// this video's order inside the release.
    public var trackPosition: String?

    public init(
        id: Int64?, releaseID: Int, youtubeID: String, title: String?,
        position: Int, unavailable: Bool, duration: Int? = nil,
        trackPosition: String? = nil
    ) {
        self.id = id
        self.releaseID = releaseID
        self.youtubeID = youtubeID
        self.title = title
        self.position = position
        self.unavailable = unavailable
        self.duration = duration
        self.trackPosition = trackPosition
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct EdgeRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "edge"

    public var id: Int64?
    public var fromKind: NodeKind
    public var fromID: Int
    public var toKind: NodeKind
    public var toID: Int
    public var kind: EdgeKind

    public init(id: Int64?, fromKind: NodeKind, fromID: Int, toKind: NodeKind, toID: Int, kind: EdgeKind) {
        self.id = id
        self.fromKind = fromKind
        self.fromID = fromID
        self.toKind = toKind
        self.toID = toID
        self.kind = kind
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct DecisionRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "decision"

    public var id: Int64?
    public var releaseID: Int
    public var kind: DecisionKind
    public var decidedAt: Date
    public var revisitAt: Date?

    public init(id: Int64?, releaseID: Int, kind: DecisionKind, decidedAt: Date, revisitAt: Date?) {
        self.id = id
        self.releaseID = releaseID
        self.kind = kind
        self.decidedAt = decidedAt
        self.revisitAt = revisitAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct QueueItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "queue_item"

    public var releaseID: Int
    public var score: Double
    public var rank: Int
    public var reason: String

    public init(releaseID: Int, score: Double, rank: Int, reason: String) {
        self.releaseID = releaseID
        self.score = score
        self.rank = rank
        self.reason = reason
    }
}

public struct OutboxRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "outbox"

    public var id: Int64?
    public var releaseID: Int
    public var attempts: Int
    public var lastError: String?
    public var nextAttemptAt: Date

    public init(id: Int64?, releaseID: Int, attempts: Int, lastError: String?, nextAttemptAt: Date) {
        self.id = id
        self.releaseID = releaseID
        self.attempts = attempts
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
