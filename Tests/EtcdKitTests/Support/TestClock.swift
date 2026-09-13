import Foundation
import Synchronization

/// A clock whose sleeps return immediately. Tests never wait on real time.
struct NoSleepClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
    }
}

/// Records every requested sleep. With `holdsSleeps` a sleep returns only
/// when its task is cancelled, so a test can act while the client waits.
final class RecordingClock: Clock, Sendable {
    typealias Instant = NoSleepClock.Instant

    private struct State {
        var sleeps: [Swift.Duration] = []
        var held: [AsyncStream<Never>.Continuation] = []
    }

    private let state = Mutex(State())
    private let holdsSleeps: Bool
    private let started: AsyncStream<Swift.Duration>.Continuation
    /// Yields each sleep's duration as it begins.
    let sleepStarted: AsyncStream<Swift.Duration>

    init(holdsSleeps: Bool = false) {
        self.holdsSleeps = holdsSleeps
        (sleepStarted, started) = AsyncStream.makeStream()
    }

    var sleeps: [Swift.Duration] { state.withLock { $0.sleeps } }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let (gate, continuation) = AsyncStream<Never>.makeStream()
        state.withLock {
            $0.sleeps.append(deadline.offset)
            // Holding the continuation keeps the gate open until cancellation.
            if holdsSleeps { $0.held.append(continuation) }
        }
        started.yield(deadline.offset)
        if holdsSleeps {
            for await _ in gate {}
        }
        try Task.checkCancellation()
    }
}
