import XCTest
@testable import DiggerKit

final class RateLimiterTests: XCTestCase {
    /// A clock the test advances by hand, so no test ever sleeps in real time.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 0)

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    func testAllowsBurstUpToCapacity() async {
        let clock = TestClock()
        let limiter = RateLimiter(capacity: 3, refillPerSecond: 1, now: clock.now)

        for _ in 0..<3 {
            let waited = await limiter.reserve()
            XCTAssertEqual(waited, 0, accuracy: 0.0001)
        }
    }

    func testFourthRequestMustWaitForRefill() async {
        let clock = TestClock()
        let limiter = RateLimiter(capacity: 3, refillPerSecond: 1, now: clock.now)

        for _ in 0..<3 { _ = await limiter.reserve() }
        let waited = await limiter.reserve()
        XCTAssertEqual(waited, 1.0, accuracy: 0.0001)
    }

    func testTokensRefillOverTime() async {
        let clock = TestClock()
        let limiter = RateLimiter(capacity: 3, refillPerSecond: 1, now: clock.now)

        for _ in 0..<3 { _ = await limiter.reserve() }
        clock.advance(3)
        let waited = await limiter.reserve()
        XCTAssertEqual(waited, 0, accuracy: 0.0001)
    }

    func testRefillNeverExceedsCapacity() async {
        let clock = TestClock()
        let limiter = RateLimiter(capacity: 2, refillPerSecond: 1, now: clock.now)

        clock.advance(100)
        _ = await limiter.reserve()
        _ = await limiter.reserve()
        let waited = await limiter.reserve()
        XCTAssertEqual(waited, 1.0, accuracy: 0.0001)
    }

    func testObserveRemainingLowersAvailableTokens() async {
        let clock = TestClock()
        let limiter = RateLimiter(capacity: 10, refillPerSecond: 1, now: clock.now)

        await limiter.observeRemaining(0)
        let waited = await limiter.reserve()
        XCTAssertEqual(waited, 1.0, accuracy: 0.0001)
    }

    func testObserveRemainingNeverRaisesAboveCapacity() async {
        let clock = TestClock()
        let limiter = RateLimiter(capacity: 2, refillPerSecond: 1, now: clock.now)

        await limiter.observeRemaining(99)
        _ = await limiter.reserve()
        _ = await limiter.reserve()
        let waited = await limiter.reserve()
        XCTAssertEqual(waited, 1.0, accuracy: 0.0001)
    }
}
