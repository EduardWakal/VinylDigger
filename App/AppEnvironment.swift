import Foundation
import SwiftUI
import DiggerKit

@MainActor
final class AppEnvironment: ObservableObject {
    @Published var cards: [QueueCard] = []
    @Published var currentIndex = 0
    @Published var status = "bereit"

    let player = PlayerController()

    private var database: AppDatabase?
    private var service: QueueService?

    var currentCard: QueueCard? {
        cards.indices.contains(currentIndex) ? cards[currentIndex] : nil
    }

    func start() async {
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

            try await bootstrapIfEmpty(database)

            status = "Sammlung wird abgeglichen…"
            let owned = try await service.syncCollection()

            cards = try service.rebuildQueue(limit: 50)
            currentIndex = 0
            status = "\(cards.count) in der Queue · \(owned) in der Sammlung"
            loadCurrentCard()
        } catch {
            status = "Fehler: \(error)"
        }
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

    private func loadCurrentCard() {
        guard let card = currentCard else {
            player.load(videoIDs: [])
            return
        }
        player.load(videoIDs: card.videoIDs)
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
