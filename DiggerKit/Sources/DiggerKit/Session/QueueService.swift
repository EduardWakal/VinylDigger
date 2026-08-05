import Foundation
import GRDB

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
    public let tracklist: [String]
}

/// Coordinates the store, the graph and the Discogs client.
///
/// This is the only type that knows about all three. Everything it hands out is
/// already resolved for display; everything it takes in is a user decision.
public actor QueueService {
    public static let revisitInterval: TimeInterval = 30 * 86_400
    private static let collectionWeightDelta = 0.18

    private let database: AppDatabase
    private let client: DiscogsClient
    private let outbox: OutboxProcessor
    private let username: String
    private let now: @Sendable () -> Date

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

            let seeds = artists.filter { $0.weight >= 1.0 }.map { NodeID(kind: .artist, id: $0.id) }
            let edges = edgeRecords.map {
                GraphEdge(
                    from: NodeID(kind: $0.fromKind, id: $0.fromID),
                    to: NodeID(kind: $0.toKind, id: $0.toID),
                    kind: $0.kind
                )
            }

            var adjustments: [WeightAdjustment] = []
            let releasesByID = Dictionary(uniqueKeysWithValues: releases.map { ($0.id, $0) })

            for decision in decisions {
                guard let release = releasesByID[decision.releaseID], let labelID = release.labelID else { continue }
                let delta = decision.kind.weightDelta
                guard delta != 0 else { continue }
                adjustments.append(WeightAdjustment(node: NodeID(kind: .label, id: labelID), delta: delta))
            }
            for release in releases where release.owned {
                guard let labelID = release.labelID else { continue }
                adjustments.append(
                    WeightAdjustment(node: NodeID(kind: .label, id: labelID), delta: Self.collectionWeightDelta)
                )
            }

            let weights = WeightPropagator.propagate(seeds: seeds, edges: edges, adjustments: adjustments)

            let latestDecision = Dictionary(
                decisions.map { ($0.releaseID, $0) },
                uniquingKeysWith: { $0.decidedAt >= $1.decidedAt ? $0 : $1 }
            )
            let artistIDsByName = Dictionary(
                artists.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first }
            )
            let labelNames = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

            let candidates = releases.map { release in
                ScoringCandidate(
                    releaseID: release.id,
                    artistIDs: artistIDsByName[release.artistName].map { [$0] } ?? [],
                    labelID: release.labelID,
                    want: release.want,
                    isDecided: latestDecision[release.id] != nil,
                    isOwned: release.owned,
                    revisitAt: latestDecision[release.id]?.revisitAt
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
                    tracklist: videos.compactMap(\.title)
                ))
            }

            return cards
        }
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

    // MARK: - Expansion

    public func expand(from releaseID: Int) async throws {
        let release = try await client.release(id: releaseID)

        for artistRef in release.artists {
            let artist = try await client.artist(id: artistRef.id)

            try database.write { db in
                var record = ArtistRecord(
                    id: artist.id, name: artist.name, weight: 0.0, refreshedAt: self.now()
                )
                try record.save(db)

                for alias in artist.aliases {
                    var aliasRecord = ArtistRecord(id: alias.id, name: alias.name, weight: 0.0, refreshedAt: nil)
                    try aliasRecord.save(db)
                    var edge = EdgeRecord(
                        id: nil, fromKind: .artist, fromID: artist.id,
                        toKind: .artist, toID: alias.id, kind: .alias
                    )
                    try? edge.insert(db)
                }

                for group in artist.groups {
                    var groupRecord = ArtistRecord(id: group.id, name: group.name, weight: 0.0, refreshedAt: nil)
                    try groupRecord.save(db)
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
                    guard try ReleaseRecord.fetchOne(db, key: summary.id) == nil else { continue }
                    var record = ReleaseRecord(
                        id: summary.id, title: summary.title,
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
                var record = LabelRecord(id: labelRef.id, name: labelRef.name, weight: 0.0, refreshedAt: nil)
                try record.save(db)
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
