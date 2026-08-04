import Foundation

/// Token bucket guarding the Discogs rate limit.
///
/// `reserve()` returns the number of seconds the caller must wait and is what
/// tests drive; `acquire()` wraps it and actually sleeps. Splitting the two keeps
/// the arithmetic testable without any test sleeping in real time.
public actor RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private let now: @Sendable () -> Date

    private var tokens: Double
    private var lastRefill: Date

    public init(
        capacity: Int = 60,
        refillPerSecond: Double = 1.0,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capacity = Double(capacity)
        self.refillPerSecond = refillPerSecond
        self.now = now
        self.tokens = Double(capacity)
        self.lastRefill = now()
    }

    private func refill() {
        let current = now()
        let elapsed = current.timeIntervalSince(lastRefill)
        guard elapsed > 0 else { return }
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = current
    }

    /// Consumes one token. Returns how long the caller should wait before proceeding.
    public func reserve() -> TimeInterval {
        refill()
        if tokens >= 1 {
            tokens -= 1
            return 0
        }
        let deficit = 1 - tokens
        tokens = 0
        return deficit / refillPerSecond
    }

    public func acquire() async {
        let wait = reserve()
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Corrects the bucket from the `X-Discogs-Ratelimit-Remaining` response header.
    /// Only ever lowers the count — the server knows better than we do how many
    /// requests are left, but it must never hand us more headroom than our capacity.
    public func observeRemaining(_ remaining: Int) {
        refill()
        tokens = min(tokens, min(Double(remaining), capacity))
    }
}
