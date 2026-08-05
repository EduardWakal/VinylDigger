import XCTest
import GRDB
@testable import DiggerKit

final class RecordingWantlistWriter: WantlistWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private let error: Error
    private(set) var acceptedReleaseIDs: [Int] = []

    init(failuresBeforeSuccess: Int = 0, error: Error = DiscogsError.transport) {
        self.failures = failuresBeforeSuccess
        self.error = error
    }

    func addToWantlist(username: String, releaseID: Int) async throws {
        lock.lock(); defer { lock.unlock() }
        if failures > 0 {
            failures -= 1
            throw error
        }
        acceptedReleaseIDs.append(releaseID)
    }
}

final class OutboxProcessorTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000_000)

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    func testEnqueueStoresPendingEntry() throws {
        let db = try AppDatabase.inMemory()
        let processor = OutboxProcessor(
            database: db, writer: RecordingWantlistWriter(),
            username: "schakal", now: { Date() }
        )

        try processor.enqueue(releaseID: 2831)

        let entries = try db.read { try OutboxRecord.fetchAll($0) }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].releaseID, 2831)
    }

    func testEnqueueIsIdempotent() throws {
        let db = try AppDatabase.inMemory()
        let processor = OutboxProcessor(
            database: db, writer: RecordingWantlistWriter(),
            username: "schakal", now: { Date() }
        )

        try processor.enqueue(releaseID: 2831)
        try processor.enqueue(releaseID: 2831)

        let entries = try db.read { try OutboxRecord.fetchAll($0) }
        XCTAssertEqual(entries.count, 1)
    }

    func testDrainSendsAndRemovesEntry() async throws {
        let db = try AppDatabase.inMemory()
        let writer = RecordingWantlistWriter()
        let processor = OutboxProcessor(database: db, writer: writer, username: "schakal", now: { Date() })
        try processor.enqueue(releaseID: 2831)

        let result = await processor.drain()

        XCTAssertEqual(result, OutboxDrainResult(succeeded: 1, retried: 0, abandoned: 0))
        XCTAssertEqual(writer.acceptedReleaseIDs, [2831])
        XCTAssertTrue(try db.read { try OutboxRecord.fetchAll($0) }.isEmpty)
    }

    func testFailureSchedulesRetryWithBackoff() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let processor = OutboxProcessor(
            database: db, writer: RecordingWantlistWriter(failuresBeforeSuccess: 1),
            username: "schakal", now: clock.now
        )
        try processor.enqueue(releaseID: 2831)

        let result = await processor.drain()

        XCTAssertEqual(result, OutboxDrainResult(succeeded: 0, retried: 1, abandoned: 0))
        let entry = try db.read { try OutboxRecord.fetchAll($0) }[0]
        XCTAssertEqual(entry.attempts, 1)
        XCTAssertEqual(entry.nextAttemptAt, clock.now().addingTimeInterval(2))
        XCTAssertNotNil(entry.lastError)
    }

    func testEntryIsSkippedUntilBackoffElapses() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let writer = RecordingWantlistWriter(failuresBeforeSuccess: 1)
        let processor = OutboxProcessor(database: db, writer: writer, username: "schakal", now: clock.now)
        try processor.enqueue(releaseID: 2831)

        _ = await processor.drain()
        let skipped = await processor.drain()

        XCTAssertEqual(skipped, OutboxDrainResult(succeeded: 0, retried: 0, abandoned: 0))

        clock.advance(3)
        let retried = await processor.drain()
        XCTAssertEqual(retried, OutboxDrainResult(succeeded: 1, retried: 0, abandoned: 0))
    }

    func testEntryIsAbandonedAfterMaxAttempts() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let processor = OutboxProcessor(
            database: db, writer: RecordingWantlistWriter(failuresBeforeSuccess: 99),
            username: "schakal", now: clock.now
        )
        try processor.enqueue(releaseID: 2831)

        for _ in 0..<OutboxProcessor.maxAttempts {
            _ = await processor.drain()
            clock.advance(600)
        }

        let final = await processor.drain()
        XCTAssertEqual(final.abandoned + final.retried + final.succeeded, 0)
        XCTAssertTrue(try db.read { try OutboxRecord.fetchAll($0) }.isEmpty)
    }

    func testUnauthorizedIsRetriedNotDropped() async throws {
        let db = try AppDatabase.inMemory()
        let clock = TestClock()
        let processor = OutboxProcessor(
            database: db, writer: RecordingWantlistWriter(failuresBeforeSuccess: 1, error: DiscogsError.unauthorized),
            username: "schakal", now: clock.now
        )
        try processor.enqueue(releaseID: 2831)

        let result = await processor.drain()

        XCTAssertEqual(result.retried, 1)
        XCTAssertEqual(try db.read { try OutboxRecord.fetchAll($0) }.count, 1)
    }
}
