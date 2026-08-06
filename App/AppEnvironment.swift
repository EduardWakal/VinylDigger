import Foundation
import SwiftUI
import GRDB
import VinylDiggerKit

@MainActor
final class AppEnvironment: ObservableObject {
    private static let prefetchDepth = 3

    @Published var cards: [QueueCard] = []
    @Published var currentIndex = 0
    @Published var status = "bereit"

    let player = PlayerController()
    let covers = CoverStore(
        directory: CoverStore.defaultDirectory, transport: URLSessionTransport()
    )

    private(set) var database: AppDatabase?
    private var service: QueueService?
    private var client: DiscogsClient?
    /// QueueView sits in a tab, and SwiftUI re-runs its task every time the tab
    /// comes back. Without this the whole sync would restart on each switch.
    private var started = false

    var currentCard: QueueCard? {
        cards.indices.contains(currentIndex) ? cards[currentIndex] : nil
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let secrets = KeychainSecretStore()
            guard let username = try secrets.read(.discogsUsername), !username.isEmpty else {
                status = "Discogs-Benutzername fehlt — in den Einstellungen eintragen"
                return
            }
            guard let token = try secrets.read(.discogsToken), !token.isEmpty else {
                status = "Token fehlt — in den Einstellungen eintragen"
                return
            }
            _ = token

            let database = try AppDatabase(path: AppDatabase.defaultPath)
            self.database = database

            let client = DiscogsClient(
                transport: URLSessionTransport(),
                secrets: secrets,
                limiter: RateLimiter(capacity: 60, refillPerSecond: 1)
            )
            let outbox = OutboxProcessor(database: database, writer: client, username: username)
            let service = QueueService(
                database: database, client: client, outbox: outbox, username: username
            )
            self.service = service
            self.client = client

            try await bootstrapIfEmpty(database)
            restoreSeeds(database)

            status = "Sammlung wird abgeglichen…"
            let owned = try await service.syncCollection()

            cards = try service.rebuildQueue(limit: 50)
            currentIndex = 0
            status = "\(cards.count) in der Queue · \(owned) in der Sammlung"
            loadCurrentCard()
        } catch {
            started = false
            status = "Fehler: \(error)"
        }
    }

    /// Expansion used to wipe seed weights, which empties the queue. Putting them
    /// back on every launch is cheap and repairs databases that already lost them.
    private func restoreSeeds(_ database: AppDatabase) {
        guard let url = Bundle.main.url(forResource: "dig_profile", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        try? BootstrapImporter(database: database).restoreSeedWeights(profile: data)
    }

    /// Records the chosen tracks, then files the release on the wantlist.
    func loveWithTracks(_ youtubeIDs: [String]) async {
        guard let service, let card = currentCard else { return }
        for id in youtubeIDs where !(card.tracks.first { $0.youtubeID == id }?.liked ?? false) {
            _ = try? service.toggleTrackLike(releaseID: card.releaseID, youtubeID: id)
        }
        await decide(.love)
    }

    func decide(_ kind: DecisionKind) async {
        guard let service, let card = currentCard else { return }
        do {
            try await service.decide(releaseID: card.releaseID, kind: kind)
            if currentIndex + 1 < cards.count {
                currentIndex += 1
                loadCurrentCard()
            } else {
                cards = try service.rebuildQueue(limit: 50)
                currentIndex = 0
                loadCurrentCard()
            }
            status = "\(cards.count - currentIndex) verbleibend"
        } catch {
            status = "Fehler: \(error)"
        }
    }

    func reload() async {
        guard let service else { return }
        do {
            cards = try service.rebuildQueue(limit: 50)
            currentIndex = 0
            loadCurrentCard()
            status = "\(cards.count) in der Queue"
        } catch {
            status = "Fehler: \(error)"
        }
    }

    func undoLastDecision() async {
        guard let database else { return }
        do {
            try database.write { db in
                if let last = try DecisionRecord.order(Column("decidedAt").desc).fetchOne(db) {
                    _ = try last.delete(db)
                }
            }
            await reload()
        } catch {
            status = "Fehler: \(error)"
        }
    }

    // MARK: - Library

    func library(kind: DecisionKind?) -> [LibraryEntry] {
        guard let service else { return [] }
        return (try? service.library(kind: kind)) ?? []
    }

    func likedTracks() -> [LikedTrack] {
        guard let service else { return [] }
        return (try? service.likedTracks()) ?? []
    }

    /// Flips the like on one track of the card on screen and refreshes just that card.
    func toggleLike(releaseID: Int, youtubeID: String) {
        guard let service else { return }
        _ = try? service.toggleTrackLike(releaseID: releaseID, youtubeID: youtubeID)
        guard
            let index = cards.firstIndex(where: { $0.releaseID == releaseID }),
            let refreshed = try? service.refreshedCard(cards[index])
        else { return }
        cards[index] = refreshed
    }

    func setManualWeight(_ weight: Double?, artist id: Int) {
        try? service?.setManualWeight(weight, artist: id)
    }

    func setManualWeight(_ weight: Double?, label id: Int) {
        try? service?.setManualWeight(weight, label: id)
    }

    // MARK: - Obsidian

    func exportToObsidian() async {
        guard let service else {
            status = "Noch keine Verbindung — Token pr\u{00FC}fen"
            return
        }
        do {
            let export = ObsidianRenderer.render(
                library: try service.library(kind: nil),
                likes: try service.likedTracks(),
                generatedAt: Date()
            )
            try await ObsidianWriter(directory: ObsidianWriter.defaultDirectory).write(export)
            status = "Obsidian aktualisiert"
        } catch {
            status = "Obsidian: \(error)"
        }
    }

    // MARK: - Dig list

    func searchDigLine(_ line: DigLine) async -> [DiscogsReleaseSummary] {
        guard let client else { return [] }
        return (try? await client.searchReleases(artist: line.artist, title: line.title)) ?? []
    }

    func acceptDigMatch(releaseID: Int, summary: DiscogsReleaseSummary) async {
        guard let service else { return }
        do {
            try await service.importSearchHit(releaseID: releaseID, summary: summary)
            status = "\(summary.title) auf die Wantlist"
        } catch {
            status = "Fehler: \(error)"
        }
    }

    func nodeWeights() -> (artists: [ArtistRecord], labels: [LabelRecord]) {
        guard let database else { return ([], []) }
        let artists = (try? database.read { try ArtistRecord.order(Column("weight").desc).limit(50).fetchAll($0) }) ?? []
        let labels = (try? database.read { try LabelRecord.order(Column("weight").desc).limit(50).fetchAll($0) }) ?? []
        return (artists, labels)
    }

    func recentDecisions() -> [(decision: DecisionRecord, release: ReleaseRecord?)] {
        guard let database else { return [] }
        return (try? database.read { db in
            let decisions = try DecisionRecord.order(Column("decidedAt").desc).limit(100).fetchAll(db)
            return try decisions.map { ($0, try ReleaseRecord.fetchOne(db, key: $0.releaseID)) }
        }) ?? []
    }

    private func loadCurrentCard() {
        guard let card = currentCard else {
            player.load(videoIDs: [])
            return
        }
        player.load(videoIDs: card.videoIDs)
        Task {
            await hydrateCurrentCard(card.releaseID)
            await prefetchUpcoming()
        }
    }

    /// Pulls detail for the next few cards so they are already filled in by the time
    /// they come up. Bounded on purpose — the Discogs limiter allows 60 calls a
    /// minute and the queue is long.
    private func prefetchUpcoming() async {
        guard let service else { return }
        let upcoming = cards
            .dropFirst(currentIndex + 1)
            .prefix(Self.prefetchDepth)
            .map(\.releaseID)

        for releaseID in upcoming {
            guard (try? await service.hydrateRelease(releaseID: releaseID)) != nil else { continue }
            guard
                let index = cards.firstIndex(where: { $0.releaseID == releaseID }),
                let refreshed = try? service.refreshedCard(cards[index])
            else { continue }
            cards[index] = refreshed
        }
    }

    /// The extra detail costs one API call, so it is fetched only for the card on
    /// screen, and only the card itself is replaced afterwards — rebuilding the
    /// queue here would reorder it and swap the release out from under the player.
    private func hydrateCurrentCard(_ releaseID: Int) async {
        guard let service else { return }
        do {
            try await service.hydrateRelease(releaseID: releaseID)
        } catch {
            status = "Details nicht geladen: \(error)"
            return
        }
        guard
            let index = cards.firstIndex(where: { $0.releaseID == releaseID }),
            let refreshed = try? service.refreshedCard(cards[index])
        else { return }
        cards[index] = refreshed
    }

    private func bootstrapIfEmpty(_ database: AppDatabase) async throws {
        let isEmpty = try database.read { db in
            try ArtistRecord.fetchCount(db) == 0
        }
        guard isEmpty else { return }
        guard
            let profileURL = Bundle.main.url(forResource: "dig_profile", withExtension: "json"),
            let labelsURL = Bundle.main.url(forResource: "dig_labels", withExtension: "json")
        else {
            status = "Bootstrap-Dumps fehlen im App-Bundle"
            return
        }
        let summary = try BootstrapImporter(database: database).importDumps(
            profile: try Data(contentsOf: profileURL),
            labels: try Data(contentsOf: labelsURL)
        )
        status = "Bootstrap: \(summary.releases) Releases, \(summary.labels) Labels"
    }
}
