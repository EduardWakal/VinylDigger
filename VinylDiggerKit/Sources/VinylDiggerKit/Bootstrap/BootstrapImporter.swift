import Foundation
import GRDB

public struct BootstrapSummary: Equatable, Sendable {
    public let artists: Int
    public let labels: Int
    public let releases: Int
    public let edges: Int
    public let videos: Int
}

/// Seeds the database from the JSON dumps produced by the manual research round,
/// so the app starts with a live graph instead of an empty one.
public struct BootstrapImporter {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    private struct ProfileDump: Decodable {
        struct Seed: Decodable {
            let id: Int
            let discogs_name: String
        }
        let profile: [String: Seed]
    }

    private struct LabelsDump: Decodable {
        struct Pick: Decodable {
            let id: Int
            let catno: String?
            let artist: String
            let title: String
            let year: Int?
            let want: Int
            let have: Int
            let styles: [String]
            let videos: [String]
        }
        struct Entry: Decodable {
            let id: Int
            let picks: [Pick]
        }
    }

    /// Puts the seed weights back. Runs on every launch, not just on an empty
    /// database: expansion used to overwrite them, and without seeds the propagator
    /// has nothing to start from and the queue comes back empty. Returns how many
    /// seeds the profile holds.
    @discardableResult
    public func restoreSeedWeights(profile: Data) throws -> Int {
        let dump = try JSONDecoder().decode(ProfileDump.self, from: profile)

        return try database.write { db in
            for seed in dump.profile.values {
                try db.execute(
                    sql: """
                        INSERT INTO artist (id, name, weight) VALUES (?, ?, 1.0)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, weight = 1.0
                        """,
                    arguments: [seed.id, seed.discogs_name]
                )
            }
            return dump.profile.count
        }
    }

    public func importDumps(profile: Data, labels: Data) throws -> BootstrapSummary {
        let decoder = JSONDecoder()
        let profileDump = try decoder.decode(ProfileDump.self, from: profile)
        let labelsDump = try decoder.decode([String: LabelsDump.Entry].self, from: labels)

        var artistCount = 0
        var labelCount = 0
        var releaseCount = 0
        var edgeCount = 0
        var videoCount = 0

        try database.write { db in
            for seed in profileDump.profile.values {
                var record = ArtistRecord(
                    id: seed.id, name: seed.discogs_name, weight: 1.0, refreshedAt: nil
                )
                try record.save(db)
            }
            artistCount = try ArtistRecord.fetchCount(db)

            for (labelName, entry) in labelsDump.sorted(by: { $0.key < $1.key }) {
                var label = LabelRecord(id: entry.id, name: labelName, weight: 0.0, refreshedAt: nil)
                try label.save(db)

                for pick in entry.picks {
                    var release = ReleaseRecord(
                        id: pick.id, title: pick.title, artistName: pick.artist,
                        year: pick.year, catno: pick.catno, labelID: entry.id,
                        styles: pick.styles, want: pick.want, have: pick.have, hydrated: true
                    )
                    try release.save(db)

                    for (index, uri) in pick.videos.enumerated() {
                        guard let youtubeID = DiscogsVideo(uri: uri, title: nil).youtubeID else { continue }
                        var video = VideoRecord(
                            id: nil, releaseID: pick.id, youtubeID: youtubeID,
                            title: nil, position: index, unavailable: false
                        )
                        // The dumps repeat releases across labels; ignore the duplicate.
                        try? video.insert(db)
                    }
                }
            }
            labelCount = try LabelRecord.fetchCount(db)
            releaseCount = try ReleaseRecord.fetchCount(db)
            videoCount = try VideoRecord.fetchCount(db)

            // Link every seed artist to every label that already holds one of their releases.
            let seedIDs = profileDump.profile.values.map(\.id)
            let seedNames = try ArtistRecord.fetchAll(db).reduce(into: [Int: String]()) { $0[$1.id] = $1.name }

            for seedID in seedIDs.sorted() {
                guard let name = seedNames[seedID] else { continue }
                // The dumps credit collaborations as one string ("Carl A. Finlow,
                // Ralph Lawson & Domenic Capello*"), so an exact match misses them.
                let labelIDs = try Int.fetchAll(db, sql: """
                    SELECT DISTINCT labelID FROM release
                    WHERE labelID IS NOT NULL AND (artistName = ? OR artistName LIKE ?)
                    ORDER BY labelID
                    """, arguments: [name, "%\(name)%"])

                for labelID in labelIDs {
                    var edge = EdgeRecord(
                        id: nil, fromKind: .artist, fromID: seedID,
                        toKind: .label, toID: labelID, kind: .artistToLabel
                    )
                    try? edge.insert(db)
                }
            }
            edgeCount = try EdgeRecord.fetchCount(db)
        }

        return BootstrapSummary(
            artists: artistCount, labels: labelCount, releases: releaseCount,
            edges: edgeCount, videos: videoCount
        )
    }
}
