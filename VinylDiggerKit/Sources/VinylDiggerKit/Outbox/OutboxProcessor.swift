import Foundation
import GRDB

public protocol WantlistWriter: Sendable {
    func addToWantlist(username: String, releaseID: Int) async throws
}

extension DiscogsClient: WantlistWriter {}

public struct OutboxDrainResult: Equatable, Sendable {
    public let succeeded: Int
    public let retried: Int
    public let abandoned: Int

    public init(succeeded: Int, retried: Int, abandoned: Int) {
        self.succeeded = succeeded
        self.retried = retried
        self.abandoned = abandoned
    }
}

/// Holds wantlist writes that could not be delivered and retries them later.
///
/// Every failure is treated as temporary — an expired token or a dropped
/// connection both come back once the user fixes the cause. Only the attempt
/// cap removes an entry.
public actor OutboxProcessor {
    public static let maxAttempts = 5

    private let database: AppDatabase
    private let writer: WantlistWriter
    private let username: String
    private let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        writer: WantlistWriter,
        username: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.writer = writer
        self.username = username
        self.now = now
    }

    public nonisolated func enqueue(releaseID: Int) throws {
        try database.write { db in
            let existing = try OutboxRecord
                .filter(Column("releaseID") == releaseID)
                .fetchOne(db)
            guard existing == nil else { return }

            var entry = OutboxRecord(
                id: nil, releaseID: releaseID, attempts: 0,
                lastError: nil, nextAttemptAt: self.now()
            )
            try entry.insert(db)
        }
    }

    @discardableResult
    public func drain() async -> OutboxDrainResult {
        let current = now()
        let due: [OutboxRecord]
        do {
            due = try database.read { db in
                try OutboxRecord
                    .filter(Column("nextAttemptAt") <= current)
                    .order(Column("id"))
                    .fetchAll(db)
            }
        } catch {
            return OutboxDrainResult(succeeded: 0, retried: 0, abandoned: 0)
        }

        var succeeded = 0
        var retried = 0
        var abandoned = 0

        for entry in due {
            do {
                try await writer.addToWantlist(username: username, releaseID: entry.releaseID)
                try? database.write { db in _ = try entry.delete(db) }
                succeeded += 1
            } catch {
                let attempts = entry.attempts + 1
                if attempts >= Self.maxAttempts {
                    try? database.write { db in _ = try entry.delete(db) }
                    abandoned += 1
                } else {
                    var updated = entry
                    updated.attempts = attempts
                    updated.lastError = String(describing: error)
                    updated.nextAttemptAt = current.addingTimeInterval(pow(2.0, Double(attempts)))
                    try? database.write { db in try updated.update(db) }
                    retried += 1
                }
            }
        }

        return OutboxDrainResult(succeeded: succeeded, retried: retried, abandoned: abandoned)
    }
}
