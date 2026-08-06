import Foundation
import GRDB

/// One decided release, resolved for display.
public struct LibraryEntry: Equatable, Sendable {
    public let release: ReleaseRecord
    public let labelName: String?
    public let kind: DecisionKind
    public let decidedAt: Date
    public let likedTrackCount: Int

    public init(
        release: ReleaseRecord, labelName: String?, kind: DecisionKind,
        decidedAt: Date, likedTrackCount: Int
    ) {
        self.release = release
        self.labelName = labelName
        self.kind = kind
        self.decidedAt = decidedAt
        self.likedTrackCount = likedTrackCount
    }
}

/// A marked track together with the release it sits on.
public struct LikedTrack: Equatable, Sendable {
    public let releaseID: Int
    public let releaseTitle: String
    public let artistName: String
    public let labelName: String?
    public let trackPosition: String?
    public let trackTitle: String?
    public let youtubeID: String
    public let likedAt: Date

    public init(
        releaseID: Int, releaseTitle: String, artistName: String, labelName: String?,
        trackPosition: String?, trackTitle: String?, youtubeID: String, likedAt: Date
    ) {
        self.releaseID = releaseID
        self.releaseTitle = releaseTitle
        self.artistName = artistName
        self.labelName = labelName
        self.trackPosition = trackPosition
        self.trackTitle = trackTitle
        self.youtubeID = youtubeID
        self.likedAt = likedAt
    }
}

extension QueueService {
    /// Decided releases, newest first. `kind` nil returns every decision.
    public nonisolated func library(kind: DecisionKind?) throws -> [LibraryEntry] {
        try database.read { db in
            let labelNames = Dictionary(
                try LabelRecord.fetchAll(db).map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            var likeCounts: [Int: Int] = [:]
            for like in try TrackLikeRecord.fetchAll(db) {
                likeCounts[like.releaseID, default: 0] += 1
            }

            // One release can be decided more than once; only the latest counts.
            let latest = Dictionary(
                try DecisionRecord.fetchAll(db).map { ($0.releaseID, $0) },
                uniquingKeysWith: { $0.decidedAt >= $1.decidedAt ? $0 : $1 }
            )

            return latest.values
                .filter { kind == nil || $0.kind == kind }
                .sorted { $0.decidedAt > $1.decidedAt }
                .compactMap { decision -> LibraryEntry? in
                    guard let release = try? ReleaseRecord.fetchOne(db, key: decision.releaseID) else {
                        return nil
                    }
                    return LibraryEntry(
                        release: release,
                        labelName: release.labelID.flatMap { labelNames[$0] },
                        kind: decision.kind,
                        decidedAt: decision.decidedAt,
                        likedTrackCount: likeCounts[release.id] ?? 0
                    )
                }
        }
    }

    /// Flips a track like. Returns the state afterwards; an unknown video is ignored.
    @discardableResult
    public nonisolated func toggleTrackLike(releaseID: Int, youtubeID: String) throws -> Bool {
        try database.write { db in
            let known = try VideoRecord
                .filter(Column("releaseID") == releaseID && Column("youtubeID") == youtubeID)
                .fetchCount(db) > 0
            guard known else { return false }

            let existing = try TrackLikeRecord
                .filter(Column("releaseID") == releaseID && Column("youtubeID") == youtubeID)
                .fetchOne(db)

            if let existing {
                _ = try existing.delete(db)
                return false
            }
            var record = TrackLikeRecord(
                id: nil, releaseID: releaseID, youtubeID: youtubeID, likedAt: self.now()
            )
            try record.insert(db)
            return true
        }
    }

    public nonisolated func likedTracks() throws -> [LikedTrack] {
        try database.read { db in
            let labelNames = Dictionary(
                try LabelRecord.fetchAll(db).map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )

            return try TrackLikeRecord
                .order(Column("likedAt").desc)
                .fetchAll(db)
                .compactMap { like in
                    guard let release = try ReleaseRecord.fetchOne(db, key: like.releaseID) else {
                        return nil
                    }
                    let video = try VideoRecord
                        .filter(
                            Column("releaseID") == like.releaseID
                            && Column("youtubeID") == like.youtubeID
                        )
                        .fetchOne(db)

                    return LikedTrack(
                        releaseID: release.id,
                        releaseTitle: release.title,
                        artistName: release.artistName,
                        labelName: release.labelID.flatMap { labelNames[$0] },
                        trackPosition: video?.trackPosition,
                        trackTitle: video?.title,
                        youtubeID: like.youtubeID,
                        likedAt: like.likedAt
                    )
                }
        }
    }

    /// Takes a search hit the user confirmed, files it as a release and hearts it.
    /// Runs through the normal decision path so wantlist, outbox and graph expansion
    /// behave exactly as they do for a card decided in the queue.
    public func importSearchHit(releaseID: Int, summary: DiscogsReleaseSummary) async throws {
        try database.write { db in
            guard try ReleaseRecord.fetchOne(db, key: releaseID) == nil else { return }
            var record = ReleaseRecord(
                id: releaseID,
                title: summary.title,
                artistName: summary.artist ?? "",
                year: summary.year,
                catno: summary.catno,
                labelID: nil,
                styles: [],
                want: 0,
                have: 0,
                hydrated: false
            )
            try record.save(db)
        }
        try await decide(releaseID: releaseID, kind: .love)
    }

    public nonisolated func setManualWeight(_ weight: Double?, artist id: Int) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE artist SET manualWeight = ? WHERE id = ?", arguments: [weight, id]
            )
        }
    }

    public nonisolated func setManualWeight(_ weight: Double?, label id: Int) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE label SET manualWeight = ? WHERE id = ?", arguments: [weight, id]
            )
        }
    }
}
