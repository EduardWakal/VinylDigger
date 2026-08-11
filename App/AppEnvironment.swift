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
    @Published var selectedTab = 0

    @Published var discoveryCards: [QueueCard] = []
    @Published var discoveryIndex = 0
    @Published var discoveryStatus = "noch nichts geholt"

    /// The player shows either the queue (digging) or one record picked from the
    /// library. Same card view either way — only the controls below it change.
    enum PlayerMode { case dig, inspect }
    @Published var mode: PlayerMode = .dig
    @Published var inspected: QueueCard?

    var displayedCard: QueueCard? {
        mode == .inspect ? inspected : currentCard
    }

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
            try await service.syncWantlist()

            cards = try service.rebuildQueue(limit: 50)
            currentIndex = 0
            status = "\(cards.count) in der Queue · \(owned) in der Sammlung"
            loadCurrentCard()

            // Wantlist records never reach the queue, so nothing would ever fetch
            // their covers. Fill them in quietly behind the first cards.
            Task { await hydrateLibrary(limit: 40) }
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

    /// Steps through the queue without judging anything — the decision keys are
    /// separate, so a record can be revisited.
    func goBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        loadCurrentCard()
    }

    func goForward() {
        guard currentIndex + 1 < cards.count else { return }
        currentIndex += 1
        loadCurrentCard()
    }

    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex + 1 < cards.count }

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

    // MARK: - Library

    func library(kind: DecisionKind?) -> [LibraryEntry] {
        guard let service else { return [] }
        return (try? service.library(kind: kind)) ?? []
    }

    func likedTracks() -> [LikedTrack] {
        guard let service else { return [] }
        return (try? service.likedTracks()) ?? []
    }

    /// Flips the like on one track and refreshes whichever card is showing it.
    func toggleLike(releaseID: Int, youtubeID: String) {
        guard let service else { return }
        _ = try? service.toggleTrackLike(releaseID: releaseID, youtubeID: youtubeID)

        if let index = cards.firstIndex(where: { $0.releaseID == releaseID }),
           let refreshed = try? service.refreshedCard(cards[index]) {
            cards[index] = refreshed
        }
        if let inspected, inspected.releaseID == releaseID,
           let refreshed = try? service.refreshedCard(inspected) {
            self.inspected = refreshed
        }
    }

    /// Marks whatever is playing, which is not always a track of the card on screen.
    func likeCurrentlyPlaying() {
        guard let id = player.currentVideoID else { return }
        guard let card = cards.first(where: { $0.videoIDs.contains(id) }) else { return }
        toggleLike(releaseID: card.releaseID, youtubeID: id)
    }

    /// Takes a record out of its list. The wantlist also lives on Discogs, so that
    /// side is deleted too — see QueueService.remove.
    func remove(releaseID: Int) async {
        guard let service else { return }
        do {
            try await service.remove(releaseID: releaseID)
            if inspected?.releaseID == releaseID {
                backToDig()
            }
            status = "aus der Liste entfernt"
        } catch {
            status = "Entfernen fehlgeschlagen: \(error)"
        }
    }

    /// Opens one record from the library in the player: fetches whatever is still
    /// missing, shows its tracks, and leaves the queue untouched.
    func openInPlayer(releaseID: Int) async {
        guard let service else { return }
        try? await service.hydrateRelease(releaseID: releaseID)

        guard let card = try? service.card(forReleaseID: releaseID) else {
            status = "Platte nicht gefunden"
            return
        }
        inspected = card
        mode = .inspect
        selectedTab = 0
        loadIntoPlayer(card)
    }

    /// Back to the queue, at the card that was open before.
    func backToDig() {
        mode = .dig
        inspected = nil
        if let card = currentCard { loadIntoPlayer(card) }
    }

    private func loadIntoPlayer(_ card: QueueCard) {
        player.load(
            videoIDs: card.videoIDs,
            labels: card.tracks.map { track in
                let position = track.position.map { "\($0) \u{00B7} " } ?? ""
                return position + (track.title ?? "ohne Titel")
            },
            context: "\(card.artistName) \u{2014} \(card.title)"
        )
    }

    /// Wantlist records never pass through the queue, so nothing ever fetched their
    /// covers. This walks them in the background, bounded by the rate limiter.
    func hydrateLibrary(limit: Int = 8) async {
        guard let service else { return }
        let pending = library(kind: nil)
            .filter { !$0.release.detailFetched }
            .prefix(limit)
            .map(\.release.id)

        for releaseID in pending {
            _ = try? await service.hydrateRelease(releaseID: releaseID)
        }
        if !pending.isEmpty {
            status = "\(pending.count) Platten nachgeladen"
        }
    }

    /// Uses the wantlist and the marked tracks as the seed for the next round.
    func suggestFromWantlist() async {
        guard let service else { return }
        status = "Vorschläge werden abgeleitet…"
        do {
            let expanded = try await service.expandFromTaste()
            cards = try service.rebuildQueue(limit: 50)
            currentIndex = 0
            loadCurrentCard()
            status = "\(expanded) Platten ausgewertet · \(cards.count) in der Queue"
        } catch {
            status = "Fehler: \(error)"
        }
    }

    func setManualWeight(_ weight: Double?, artist id: Int) {
        try? service?.setManualWeight(weight, artist: id)
    }

    func setManualWeight(_ weight: Double?, label id: Int) {
        try? service?.setManualWeight(weight, label: id)
    }

    // MARK: - Discovery

    var discoveryCard: QueueCard? {
        discoveryCards.indices.contains(discoveryIndex) ? discoveryCards[discoveryIndex] : nil
    }

    /// Pulls the next slice of the style charts. The service is rebuilt on every
    /// call so a style added in settings takes effect at once instead of on the
    /// next launch; it carries no state, so this costs nothing.
    func refreshDiscovery() async {
        guard let database, let client else {
            discoveryStatus = "Noch keine Verbindung — Token prüfen"
            return
        }
        let service = DiscoveryService(
            database: database, client: client, styles: DiscoveryStyles.load()
        )

        discoveryStatus = "Charts werden geholt…"
        do {
            discoveryCards = try await service.refresh(limit: 50)
            discoveryIndex = 0
            if discoveryCards.isEmpty {
                discoveryStatus = "nichts Neues gefunden — nochmal versuchen"
            } else {
                discoveryStatus = "\(discoveryCards.count) Platten"
                loadDiscoveryCard()
            }
        } catch DiscoveryError.noStyles {
            discoveryStatus = "Keine Styles gesetzt — in den Einstellungen eintragen"
        } catch {
            discoveryStatus = "Fehler: \(error)"
        }
    }

    func decideDiscovery(_ kind: DecisionKind) async {
        guard let service, let card = discoveryCard else { return }
        do {
            try await service.decide(releaseID: card.releaseID, kind: kind)
            if discoveryIndex + 1 < discoveryCards.count {
                discoveryIndex += 1
                loadDiscoveryCard()
            } else {
                await refreshDiscovery()
            }
        } catch {
            discoveryStatus = "Fehler: \(error)"
        }
    }

    private func loadDiscoveryCard() {
        guard let card = discoveryCard else { return }
        loadIntoPlayer(card)
        Task {
            guard let service else { return }
            try? await service.hydrateRelease(releaseID: card.releaseID)
            guard
                let index = discoveryCards.firstIndex(where: { $0.releaseID == card.releaseID }),
                let refreshed = try? service.refreshedCard(discoveryCards[index])
            else { return }
            discoveryCards[index] = refreshed
        }
    }

    // MARK: - Obsidian

    /// Two notes for two jobs: the search list is what gets taken to Soulseek, the
    /// record list is what is on a record once it is bought.
    func exportToObsidian(_ document: ObsidianDocument) async {
        guard let service else {
            status = "Noch keine Verbindung — Token prüfen"
            return
        }
        do {
            let now = Date()
            let text: String
            switch document {
            case .searchList:
                text = ObsidianRenderer.renderSearchList(
                    likes: try service.likedTracks(), generatedAt: now
                )
            case .records:
                text = ObsidianRenderer.renderRecords(
                    library: try service.library(kind: nil),
                    likes: try service.likedTracks(),
                    generatedAt: now
                )
            }
            try await ObsidianWriter(directory: ObsidianWriter.defaultDirectory)
                .write(text, to: document)
            status = "\(document.rawValue) geschrieben"
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
        player.load(
            videoIDs: card.videoIDs,
            labels: card.tracks.map { track in
                let position = track.position.map { "\($0) \u{00B7} " } ?? ""
                return position + (track.title ?? "ohne Titel")
            },
            context: "\(card.artistName) \u{2014} \(card.title)"
        )
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
