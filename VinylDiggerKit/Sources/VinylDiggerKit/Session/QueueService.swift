import Foundation
import GRDB

public struct QueueTrack: Equatable, Sendable {
    public let youtubeID: String
    public let title: String?
    /// Discogs sleeve position such as "A1"; nil when it could not be matched.
    public let position: String?
    public let duration: Int?
    public let liked: Bool

    public init(
        youtubeID: String, title: String?, position: String?,
        duration: Int?, liked: Bool = false
    ) {
        self.youtubeID = youtubeID
        self.title = title
        self.position = position
        self.duration = duration
        self.liked = liked
    }
}

public struct QueueCard: Equatable, Sendable {
    public let releaseID: Int
    public let title: String
    public let artistName: String
    public let labelName: String?
    public let catno: String?
    public let year: Int?
    public let styles: [String]
    public let want: Int
    public let reason: String
    public let videoIDs: [String]
    /// Discogs community rating, nil until it has been fetched for this release.
    public let rating: Double?
    public let ratingCount: Int
    public let coverURL: String?
    public let tracks: [QueueTrack]

    public init(
        releaseID: Int, title: String, artistName: String, labelName: String?,
        catno: String?, year: Int?, styles: [String], want: Int, reason: String,
        videoIDs: [String], rating: Double? = nil, ratingCount: Int = 0,
        coverURL: String? = nil, tracks: [QueueTrack] = []
    ) {
        self.releaseID = releaseID
        self.title = title
        self.artistName = artistName
        self.labelName = labelName
        self.catno = catno
        self.year = year
        self.styles = styles
        self.want = want
        self.reason = reason
        self.videoIDs = videoIDs
        self.rating = rating
        self.ratingCount = ratingCount
        self.coverURL = coverURL
        self.tracks = tracks
    }
}

/// Coordinates the store, the graph and the Discogs client.
///
/// This is the only type that knows about all three. Everything it hands out is
/// already resolved for display; everything it takes in is a user decision.
public actor QueueService {
    public static let revisitInterval: TimeInterval = 30 * 86_400
    private static let collectionWeightDelta = 0.18

    let database: AppDatabase
    let client: DiscogsClient
    private let outbox: OutboxProcessor
    let username: String
    let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        client: DiscogsClient,
        outbox: OutboxProcessor,
        username: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.client = client
        self.outbox = outbox
        self.username = username
        self.now = now
    }

    // MARK: - Queue

    public nonisolated func rebuildQueue(limit: Int) throws -> [QueueCard] {
        let current = now()

        return try database.write { db in
            let artists = try ArtistRecord.fetchAll(db)
            let labels = try LabelRecord.fetchAll(db)
            let edgeRecords = try EdgeRecord.fetchAll(db)
            let releases = try ReleaseRecord.fetchAll(db)
            let decisions = try DecisionRecord.fetchAll(db)

            let seeds = artists.filter { $0.effectiveWeight >= 1.0 }.map { NodeID(kind: .artist, id: $0.id) }
            let edges = edgeRecords.map {
                GraphEdge(
                    from: NodeID(kind: $0.fromKind, id: $0.fromID),
                    to: NodeID(kind: $0.toKind, id: $0.toID),
                    kind: $0.kind
                )
            }

            var adjustments: [WeightAdjustment] = []
            let releasesByID = Dictionary(uniqueKeysWithValues: releases.map { ($0.id, $0) })
            let artistIDsByNameForSignals = Dictionary(
                artists.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first }
            )

            var likesPerRelease: [Int: Int] = [:]
            for like in try TrackLikeRecord.fetchAll(db) {
                likesPerRelease[like.releaseID, default: 0] += 1
            }

            /// Every signal lands on both the label and the artist. Only crediting
            /// the label meant an artist the user clearly likes gained nothing.
            func credit(_ release: ReleaseRecord, _ delta: Double) {
                guard delta != 0 else { return }
                if let labelID = release.labelID {
                    adjustments.append(WeightAdjustment(node: NodeID(kind: .label, id: labelID), delta: delta))
                }
                if let artistID = artistIDsByNameForSignals[release.artistName] {
                    adjustments.append(WeightAdjustment(node: NodeID(kind: .artist, id: artistID), delta: delta))
                }
            }

            for decision in decisions {
                guard let release = releasesByID[decision.releaseID] else { continue }
                // The discovery tab is a high-discard surface by design — most of
                // what it shows is meant to be passed over. Crediting those discards
                // would demote artists the user actually likes, since a discovered
                // record that resolves to an artist is exactly a known-artist one.
                // A love still counts; that is the point of the feature.
                if decision.kind == .discard && release.discovered { continue }
                credit(release, TasteSignal.decisionWeight(decision.kind))
            }
            for release in releases where release.owned {
                credit(release, TasteSignal.owned)
            }
            for (releaseID, count) in likesPerRelease {
                guard let release = releasesByID[releaseID] else { continue }
                credit(release, TasteSignal.trackLikeWeight(count: count))
            }

            var weights = WeightPropagator.propagate(seeds: seeds, edges: edges, adjustments: adjustments)
            // A hand-set weight wins over whatever the graph worked out, and keeps
            // winning as the graph grows.
            for artist in artists {
                guard let manual = artist.manualWeight else { continue }
                weights[NodeID(kind: .artist, id: artist.id)] = manual
            }
            for label in labels {
                guard let manual = label.manualWeight else { continue }
                weights[NodeID(kind: .label, id: label.id)] = manual
            }

            // The statistics tab reads stored weights, and a hand-set one always wins,
            // so only the computed column is rewritten here.
            for artist in artists {
                let computed = weights[NodeID(kind: .artist, id: artist.id)] ?? 0
                guard abs(computed - artist.weight) > 0.0001 else { continue }
                try db.execute(
                    sql: "UPDATE artist SET weight = ? WHERE id = ?",
                    arguments: [max(computed, artist.weight >= 1.0 ? 1.0 : 0), artist.id]
                )
            }
            for label in labels {
                let computed = weights[NodeID(kind: .label, id: label.id)] ?? 0
                guard abs(computed - label.weight) > 0.0001 else { continue }
                try db.execute(
                    sql: "UPDATE label SET weight = ? WHERE id = ?",
                    arguments: [computed, label.id]
                )
            }

            let latestDecision = Dictionary(
                decisions.map { ($0.releaseID, $0) },
                uniquingKeysWith: { $0.decidedAt >= $1.decidedAt ? $0 : $1 }
            )
            let artistIDsByName = Dictionary(
                artists.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first }
            )
            let labelNames = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let likedKeys = Set(try TrackLikeRecord.fetchAll(db).map { "\($0.releaseID)|\($0.youtubeID)" })

            let releasesWithVideo = Set(
                try Int.fetchAll(db, sql: "SELECT DISTINCT releaseID FROM video WHERE unavailable = 0")
            )

            // A discovered stub carries a real artist name and a real want count,
            // so it can score above zero and would otherwise crowd the ordinary,
            // taste-driven queue before the user ever weighed in on it. Once a
            // decision exists it behaves like any other release from then on.
            let candidates = releases
                .filter { !($0.discovered && latestDecision[$0.id] == nil) }
                .map { release in
                    ScoringCandidate(
                        releaseID: release.id,
                        artistIDs: artistIDsByName[release.artistName].map { [$0] } ?? [],
                        labelID: release.labelID,
                        want: release.want,
                        isDecided: latestDecision[release.id] != nil,
                        isOwned: release.owned,
                        revisitAt: latestDecision[release.id]?.revisitAt,
                        preview: previewState(for: release, hasVideo: releasesWithVideo.contains(release.id))
                    )
                }

            let scored = Scorer.score(
                candidates: candidates, weights: weights, labelNames: labelNames, now: current
            )
            let planned = QueuePlanner.plan(scored, limit: limit)

            try QueueItemRecord.deleteAll(db)
            var cards: [QueueCard] = []

            for (rank, item) in planned.enumerated() {
                var queueItem = QueueItemRecord(
                    releaseID: item.releaseID, score: item.score, rank: rank, reason: item.reason
                )
                try queueItem.insert(db)

                guard let release = releasesByID[item.releaseID] else { continue }
                let videos = try VideoRecord
                    .filter(Column("releaseID") == release.id && Column("unavailable") == false)
                    .order(Column("position"))
                    .fetchAll(db)

                cards.append(QueueCard(
                    releaseID: release.id,
                    title: release.title,
                    artistName: release.artistName,
                    labelName: release.labelID.flatMap { labelNames[$0] },
                    catno: release.catno,
                    year: release.year,
                    styles: release.styles,
                    want: release.want,
                    reason: item.reason,
                    videoIDs: videos.map(\.youtubeID),
                    rating: release.ratingCount > 0 ? release.rating : nil,
                    ratingCount: release.ratingCount,
                    coverURL: release.coverURL,
                    tracks: videos.map {
                        QueueTrack(
                            youtubeID: $0.youtubeID, title: $0.title,
                            position: $0.trackPosition, duration: $0.duration,
                            liked: likedKeys.contains("\(release.id)|\($0.youtubeID)")
                        )
                    }
                ))
            }

            return cards
        }
    }

    /// Only a release whose detail has been read can be called unplayable — before
    /// that the absence of videos means nobody looked yet.
    private nonisolated func previewState(
        for release: ReleaseRecord, hasVideo: Bool
    ) -> PreviewState {
        if hasVideo { return .available }
        return release.detailFetched ? PreviewState.none : .unknown
    }

    // MARK: - Decisions

    public func decide(releaseID: Int, kind: DecisionKind) async throws {
        let current = now()
        let revisitAt = kind == .later ? current.addingTimeInterval(Self.revisitInterval) : nil

        try database.write { db in
            var record = DecisionRecord(
                id: nil, releaseID: releaseID, kind: kind,
                decidedAt: current, revisitAt: revisitAt
            )
            try record.insert(db)
        }

        guard kind == .love else { return }
        try outbox.enqueue(releaseID: releaseID)
        await outbox.drain()
        // The decision and the wantlist write are already durable. Expansion only
        // enriches the graph, so a failed lookup must not undo the decision — the
        // next love re-runs it.
        try? await expand(from: releaseID)
    }

    // MARK: - Sync

    public func syncCollection() async throws -> Int {
        let ids = try await client.collectionReleaseIDs(username: username)
        try database.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE release SET owned = 1 WHERE id = ?", arguments: [id])
            }
        }
        return ids.count
    }

    /// Pulls the Discogs wantlist in so the library shows the same thing Discogs
    /// does. Entries the app never saw are filed as stubs and hydrated later like
    /// any other release; a release already known keeps whatever it has.
    @discardableResult
    public func syncWantlist() async throws -> Int {
        let wants = try await client.wantlist(username: username)
        let current = now()

        try database.write { db in
            for want in wants {
                if let labelID = want.labelID, let labelName = want.labelName {
                    try NodeUpsert.label(id: labelID, name: labelName, in: db)
                }

                if try ReleaseRecord.fetchOne(db, key: want.id) == nil {
                    var record = ReleaseRecord(
                        id: want.id, title: want.title, artistName: want.artistName,
                        year: want.year, catno: want.catno, labelID: want.labelID,
                        styles: [], want: 0, have: 0, hydrated: false
                    )
                    try record.save(db)
                }

                let alreadyLoved = try DecisionRecord
                    .filter(Column("releaseID") == want.id && Column("kind") == DecisionKind.love.rawValue)
                    .fetchCount(db) > 0
                guard !alreadyLoved else { continue }

                var decision = DecisionRecord(
                    id: nil, releaseID: want.id, kind: .love,
                    decidedAt: current, revisitAt: nil
                )
                try decision.insert(db)
            }
        }
        return wants.count
    }

    /// Grows the graph outwards from the records the user has spoken about, in the
    /// order of how loudly they spoke: records carrying a marked track first, then
    /// the wantlist. Returns how many records were expanded from.
    @discardableResult
    public func expandFromTaste(limit: Int = 10) async throws -> Int {
        let ordered = try database.read { db -> [Int] in
            let liked = try TrackLikeRecord
                .order(Column("likedAt").desc)
                .fetchAll(db)
                .map(\.releaseID)

            let wanted = try DecisionRecord
                .filter(Column("kind") == DecisionKind.love.rawValue)
                .order(Column("decidedAt").desc)
                .fetchAll(db)
                .map(\.releaseID)

            var seen = Set<Int>()
            return (liked + wanted).filter { seen.insert($0).inserted }
        }

        var expanded = 0
        for releaseID in ordered.prefix(limit) {
            // One bad lookup must not stop the rest — the next run picks it up.
            guard (try? await expand(from: releaseID)) != nil else { continue }
            expanded += 1
        }
        return expanded
    }

    // MARK: - Expansion

    /// Builds a card for any release, whether or not it is in the queue — the
    /// library needs one for records that were decided long ago.
    public nonisolated func card(forReleaseID releaseID: Int) throws -> QueueCard {
        let stub = QueueCard(
            releaseID: releaseID, title: "", artistName: "", labelName: nil,
            catno: nil, year: nil, styles: [], want: 0, reason: "", videoIDs: []
        )
        let card = try refreshedCard(stub)
        guard card.releaseID == releaseID, !card.title.isEmpty || !card.artistName.isEmpty else {
            throw DiscogsError.transport
        }
        return card
    }

    /// Re-reads one card's release and videos without touching the queue order.
    ///
    /// Rebuilding the queue after a hydration would reshuffle it — the fetch writes
    /// a fresh `want`, which feeds the score — and the card under the user's cursor
    /// would silently become a different release.
    public nonisolated func refreshedCard(_ card: QueueCard) throws -> QueueCard {
        try database.read { db in
            guard let release = try ReleaseRecord.fetchOne(db, key: card.releaseID) else {
                return card
            }
            let videos = try VideoRecord
                .filter(Column("releaseID") == release.id && Column("unavailable") == false)
                .order(Column("position"))
                .fetchAll(db)

            let likedIDs = Set(
                try TrackLikeRecord
                    .filter(Column("releaseID") == release.id)
                    .fetchAll(db)
                    .map(\.youtubeID)
            )

            return QueueCard(
                releaseID: release.id,
                title: release.title,
                artistName: release.artistName,
                labelName: release.labelID.flatMap { labelID in
                    try? LabelRecord.fetchOne(db, key: labelID)?.name
                } ?? card.labelName,
                catno: release.catno,
                year: release.year,
                styles: release.styles,
                want: release.want,
                reason: card.reason,
                videoIDs: videos.map(\.youtubeID),
                rating: release.ratingCount > 0 ? release.rating : nil,
                ratingCount: release.ratingCount,
                coverURL: release.coverURL,
                tracks: videos.map {
                    QueueTrack(
                        youtubeID: $0.youtubeID, title: $0.title,
                        position: $0.trackPosition, duration: $0.duration,
                        liked: likedIDs.contains($0.youtubeID)
                    )
                }
            )
        }
    }

    /// Fetches everything the card needs that the bootstrap dumps do not carry:
    /// rating, sleeve image, video titles, durations and track positions.
    /// A release is only ever fetched once.
    @discardableResult
    public func hydrateRelease(releaseID: Int) async throws -> ReleaseRecord {
        let cached = try database.read { db in
            try ReleaseRecord.fetchOne(db, key: releaseID)
        }
        if let cached, cached.detailFetched { return cached }

        let release = try await client.release(id: releaseID)
        let positions = TrackMatcher.positions(
            videos: release.videos, tracklist: release.tracklist
        )

        return try database.write { db in
            try db.execute(
                sql: """
                    UPDATE release SET rating = ?, ratingCount = ?, want = ?, have = ?,
                    coverURL = ?, title = ?, artistName = ?, year = ?,
                    tracklist = ?, detailFetched = 1 WHERE id = ?
                    """,
                arguments: [
                    release.community.rating.average, release.community.rating.count,
                    release.community.want, release.community.have,
                    release.coverURL,
                    // The fetch is the authority. Rows filed under a master id carry a
                    // title that belongs to a different record; this corrects them.
                    release.title,
                    release.artists.first?.name ?? cached?.artistName ?? "",
                    release.year,
                    try JSONEncoder().encode(
                        release.tracklist.map { ReleaseTrack(position: $0.position, title: $0.title) }
                    ),
                    releaseID
                ]
            )

            // Releases the graph turned up carry no videos of their own — only the
            // bootstrap dumps brought any. Without inserting here they would stay
            // unplayable forever even though Discogs lists the videos.
            var slot = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM video WHERE releaseID = ?",
                arguments: [releaseID]
            ) ?? 0

            for (index, video) in release.videos.enumerated() {
                guard let youtubeID = video.youtubeID else { continue }
                let updated = try db.execute(
                    sql: """
                        UPDATE video SET title = ?, duration = ?, trackPosition = ?
                        WHERE releaseID = ? AND youtubeID = ?
                        """,
                    arguments: [
                        video.title, video.duration, positions[index],
                        releaseID, youtubeID
                    ]
                )
                _ = updated
                guard db.changesCount == 0 else { continue }

                var record = VideoRecord(
                    id: nil, releaseID: releaseID, youtubeID: youtubeID,
                    title: video.title, position: slot, unavailable: false,
                    duration: video.duration, trackPosition: positions[index]
                )
                try record.insert(db)
                slot += 1
            }

            guard let updated = try ReleaseRecord.fetchOne(db, key: releaseID) else {
                throw DiscogsError.transport
            }
            return updated
        }
    }

    public func expand(from releaseID: Int) async throws {
        let release = try await client.release(id: releaseID)

        for artistRef in release.artists {
            let artist = try await client.artist(id: artistRef.id)

            try database.write { db in
                try NodeUpsert.artist(
                    id: artist.id, name: artist.name, refreshedAt: self.now(), in: db
                )

                for alias in artist.aliases {
                    try NodeUpsert.artist(id: alias.id, name: alias.name, refreshedAt: nil, in: db)
                    var edge = EdgeRecord(
                        id: nil, fromKind: .artist, fromID: artist.id,
                        toKind: .artist, toID: alias.id, kind: .alias
                    )
                    try? edge.insert(db)
                }

                for group in artist.groups {
                    try NodeUpsert.artist(id: group.id, name: group.name, refreshedAt: nil, in: db)
                    var edge = EdgeRecord(
                        id: nil, fromKind: .artist, fromID: artist.id,
                        toKind: .artist, toID: group.id, kind: .group
                    )
                    try? edge.insert(db)
                }
            }

            // One page is enough to learn which labels this artist works with.
            let page = try await client.artistReleases(id: artist.id, page: 1)
            try database.write { db in
                for summary in page.items {
                    // Master entries carry a master id; storing it would file a
                    // different record under this title.
                    guard let releaseID = summary.releaseID else { continue }
                    guard try ReleaseRecord.fetchOne(db, key: releaseID) == nil else { continue }
                    var record = ReleaseRecord(
                        id: releaseID, title: summary.title,
                        artistName: summary.artist ?? artist.name,
                        year: summary.year, catno: summary.catno, labelID: nil,
                        styles: [], want: 0, have: 0, hydrated: false
                    )
                    try record.save(db)
                }
            }
        }

        for labelRef in release.labels {
            try database.write { db in
                try NodeUpsert.label(id: labelRef.id, name: labelRef.name, in: db)
                try db.execute(
                    sql: "UPDATE release SET labelID = ? WHERE id = ?",
                    arguments: [labelRef.id, release.id]
                )

                for artistRef in release.artists {
                    var edge = EdgeRecord(
                        id: nil, fromKind: .artist, fromID: artistRef.id,
                        toKind: .label, toID: labelRef.id, kind: .artistToLabel
                    )
                    try? edge.insert(db)
                }
            }
        }
    }
}
