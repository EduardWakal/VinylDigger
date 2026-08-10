import Foundation
import GRDB

public enum DiscoveryError: Error, Equatable {
    case noStyles
}

/// Fills the discovery tab from the Discogs style charts.
///
/// Separate from `QueueService` on purpose: the two share no state, and the
/// queue path is already long enough. What they do share is the decision
/// record — a love here goes through `QueueService.decide`, which is how a
/// discovered record finds its way into the taste graph.
public actor DiscoveryService {
    /// How many exhausted axes to skip before reporting an empty refresh.
    private static let maxEmptyAxes = 3

    private let database: AppDatabase
    private let client: DiscogsClient
    private let styles: [String]
    private let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        client: DiscogsClient,
        styles: [String],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.client = client
        self.styles = styles
        self.now = now
    }

    @discardableResult
    public func refresh(limit: Int = 50) async throws -> [QueueCard] {
        guard !styles.isEmpty else { throw DiscoveryError.noStyles }
        let current = now()

        for _ in 0..<Self.maxEmptyAxes {
            var cursor = try readCursor()
            guard let step = DiscoveryRotation.next(styles: styles, cursor: cursor, now: current) else {
                throw DiscoveryError.noStyles
            }

            let hits = try await client.searchByStyle(
                style: step.axis.style,
                yearFrom: step.axis.window.from,
                yearTo: step.axis.window.to,
                page: step.axis.page
            )

            // The cursor only moves once the call came back. A failed search must
            // not silently burn an axis.
            cursor = step.next
            try writeCursor(cursor)

            let ranked = try rank(hits, limit: limit, now: current)
            guard !ranked.isEmpty else { continue }

            try store(ranked, hits: hits, axis: step.axis, at: current)
            return try currentBatch()
        }

        return []
    }

    public nonisolated func currentBatch() throws -> [QueueCard] {
        try database.read { db in
            let items = try DiscoveryItemRecord
                .order(Column("rank"))
                .fetchAll(db)

            return try items.map { item in
                let release = try ReleaseRecord.fetchOne(db, key: item.releaseID)
                let videos = try VideoRecord
                    .filter(Column("releaseID") == item.releaseID && Column("unavailable") == false)
                    .order(Column("position"))
                    .fetchAll(db)

                return QueueCard(
                    releaseID: item.releaseID,
                    title: release?.title ?? item.title,
                    artistName: release?.artistName ?? item.artistName,
                    labelName: item.labelName,
                    catno: item.catno,
                    year: item.year,
                    styles: item.styles,
                    want: item.want,
                    reason: Self.reason(for: item),
                    videoIDs: videos.map(\.youtubeID),
                    rating: (release?.ratingCount ?? 0) > 0 ? release?.rating : nil,
                    ratingCount: release?.ratingCount ?? 0,
                    coverURL: release?.coverURL,
                    tracks: videos.map {
                        QueueTrack(
                            youtubeID: $0.youtubeID, title: $0.title,
                            position: $0.trackPosition, duration: $0.duration
                        )
                    }
                )
            }
        }
    }

    /// "Deep House · All-Time · 1.204 wollen's"
    private static func reason(for item: DiscoveryItemRecord) -> String {
        let parts = item.axisKey.split(separator: "|", omittingEmptySubsequences: false)
        let style = parts.first.map(String.init) ?? ""
        let window = parts.count > 1 ? String(parts[1]) : ""
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "de_DE")
        let want = formatter.string(from: NSNumber(value: item.want)) ?? "\(item.want)"
        return "\(style) \u{00B7} \(window) \u{00B7} \(want) wollen's"
    }

    // MARK: - Steps

    private func readCursor() throws -> DiscoveryCursor {
        try database.read { db in
            guard let record = try DiscoveryCursorRecord.fetchOne(
                db, key: DiscoveryCursorRecord.singletonID
            ) else { return .start }
            return DiscoveryCursor(
                styleIndex: record.styleIndex, windowIndex: record.windowIndex, page: record.page
            )
        }
    }

    private func writeCursor(_ cursor: DiscoveryCursor) throws {
        try database.write { db in
            var record = DiscoveryCursorRecord(
                styleIndex: cursor.styleIndex, windowIndex: cursor.windowIndex, page: cursor.page
            )
            try record.save(db)
        }
    }

    private func rank(
        _ hits: [DiscogsSearchHit], limit: Int, now: Date
    ) throws -> [RankedDiscovery] {
        let candidates = try database.read { db -> [DiscoveryCandidate] in
            let knownArtists = Set(
                try ArtistRecord.fetchAll(db).map { Self.normalise($0.name) }
            )

            return try hits.map { hit in
                let release = try ReleaseRecord.fetchOne(db, key: hit.id)
                let decision = try DecisionRecord
                    .filter(Column("releaseID") == hit.id)
                    .order(Column("decidedAt").desc)
                    .fetchOne(db)

                return DiscoveryCandidate(
                    releaseID: hit.id,
                    masterID: hit.masterID,
                    artistName: hit.artistName,
                    labelName: hit.label,
                    want: hit.want,
                    styles: hit.styles,
                    isKnownArtist: knownArtists.contains(Self.normalise(hit.artistName)),
                    isOwned: release?.owned ?? false,
                    isDecided: decision != nil,
                    revisitAt: decision?.revisitAt
                )
            }
        }
        return DiscoveryRanker.rank(candidates, limit: limit, now: now)
    }

    /// A search hit carries no artist id, so the graph is matched by name.
    /// Discogs disambiguates duplicates with a trailing counter — "Wulf (20)" is
    /// the same name as "Wulf" for this purpose.
    private static func normalise(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let counter = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            if counter.allSatisfy(\.isNumber) {
                trimmed = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed.lowercased()
    }

    private func store(
        _ ranked: [RankedDiscovery], hits: [DiscogsSearchHit],
        axis: DiscoveryAxis, at stamp: Date
    ) throws {
        let hitsByID = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        try database.write { db in
            try DiscoveryItemRecord.deleteAll(db)

            for (rank, entry) in ranked.enumerated() {
                guard let hit = hitsByID[entry.releaseID] else { continue }

                var item = DiscoveryItemRecord(
                    releaseID: hit.id, masterID: hit.masterID, title: hit.recordTitle,
                    artistName: hit.artistName, styles: hit.styles, have: hit.have,
                    want: hit.want, year: hit.year, labelName: hit.label,
                    catno: hit.catno, axisKey: axis.key, score: entry.score,
                    rank: rank, fetchedAt: stamp
                )
                try item.insert(db)

                // Filing a stub is what lets the existing machinery work on these
                // records: hydrateRelease fills them in, refreshedCard reads them,
                // and a love decision has something to point at.
                guard try ReleaseRecord.fetchOne(db, key: hit.id) == nil else { continue }
                var release = ReleaseRecord(
                    id: hit.id, title: hit.recordTitle, artistName: hit.artistName,
                    year: hit.year, catno: hit.catno, labelID: nil,
                    styles: hit.styles, want: hit.want, have: hit.have, hydrated: false
                )
                try release.save(db)
            }
        }
    }
}
