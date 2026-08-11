import Foundation
import GRDB

public struct ArtistRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "artist"

    public var id: Int
    public var name: String
    public var weight: Double
    public var refreshedAt: Date?
    /// Set by hand to override what the graph computed. nil hands control back.
    public var manualWeight: Double?

    public init(
        id: Int, name: String, weight: Double, refreshedAt: Date?,
        manualWeight: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.weight = weight
        self.refreshedAt = refreshedAt
        self.manualWeight = manualWeight
    }

    /// What the queue should score against.
    public var effectiveWeight: Double { manualWeight ?? weight }
}

public struct LabelRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "label"

    public var id: Int
    public var name: String
    public var weight: Double
    public var refreshedAt: Date?
    /// Set by hand to override what the graph computed. nil hands control back.
    public var manualWeight: Double?

    public init(
        id: Int, name: String, weight: Double, refreshedAt: Date?,
        manualWeight: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.weight = weight
        self.refreshedAt = refreshedAt
        self.manualWeight = manualWeight
    }

    /// What the queue should score against.
    public var effectiveWeight: Double { manualWeight ?? weight }
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
    /// Every track on the sleeve, not only the ones with a video.
    public var tracklist: [ReleaseTrack]
    /// True once `/releases/{id}` has been read for this release. Rating alone is
    /// no marker — plenty of releases carry none, and those must not be refetched
    /// on every visit.
    public var detailFetched: Bool
    /// True for a stub `DiscoveryService.store` filed from a style-chart hit.
    /// Kept out of the ordinary queue until the user has decided on it — see
    /// `QueueService.rebuildQueue`.
    public var discovered: Bool

    public init(
        id: Int, title: String, artistName: String, year: Int?, catno: String?,
        labelID: Int?, styles: [String], want: Int, have: Int, hydrated: Bool,
        owned: Bool = false, rating: Double = 0, ratingCount: Int = 0,
        coverURL: String? = nil, detailFetched: Bool = false,
        tracklist: [ReleaseTrack] = [], discovered: Bool = false
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
        self.tracklist = tracklist
        self.discovered = discovered
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

/// One line of a record's tracklist as Discogs prints it on the sleeve.
public struct ReleaseTrack: Codable, Equatable, Sendable {
    public let position: String?
    public let title: String

    public init(position: String?, title: String) {
        self.position = position
        self.title = title
    }
}

/// A single track marked as good. Discogs has no track-level list, so this layer
/// is ours alone — a ♥ on the card still writes the whole release to the wantlist.
public struct TrackLikeRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "track_like"

    public var id: Int64?
    public var releaseID: Int
    public var youtubeID: String
    public var likedAt: Date

    public init(id: Int64?, releaseID: Int, youtubeID: String, likedAt: Date) {
        self.id = id
        self.releaseID = releaseID
        self.youtubeID = youtubeID
        self.likedAt = likedAt
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

/// One record from the style charts, waiting to be auditioned. The table is
/// cleared and refilled on every refresh, like `queue_item`.
public struct DiscoveryItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "discovery_item"

    public var releaseID: Int
    /// Nil when Discogs files the release under no master.
    public var masterID: Int?
    public var title: String
    public var artistName: String
    public var styles: [String]
    public var have: Int
    public var want: Int
    public var year: Int?
    public var labelName: String?
    public var catno: String?
    /// Which style, window and page turned this up — shown on the card.
    public var axisKey: String
    public var score: Double
    public var rank: Int
    public var fetchedAt: Date

    public init(
        releaseID: Int, masterID: Int?, title: String, artistName: String,
        styles: [String], have: Int, want: Int, year: Int?, labelName: String?,
        catno: String?, axisKey: String, score: Double, rank: Int, fetchedAt: Date
    ) {
        self.releaseID = releaseID
        self.masterID = masterID
        self.title = title
        self.artistName = artistName
        self.styles = styles
        self.have = have
        self.want = want
        self.year = year
        self.labelName = labelName
        self.catno = catno
        self.axisKey = axisKey
        self.score = score
        self.rank = rank
        self.fetchedAt = fetchedAt
    }
}

/// Where the rotation stopped last time. Exactly one row.
public struct DiscoveryCursorRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "discovery_cursor"
    public static let singletonID = 1

    public var id: Int
    public var styleIndex: Int
    public var windowIndex: Int
    public var page: Int

    public init(id: Int = DiscoveryCursorRecord.singletonID, styleIndex: Int, windowIndex: Int, page: Int) {
        self.id = id
        self.styleIndex = styleIndex
        self.windowIndex = windowIndex
        self.page = page
    }
}
