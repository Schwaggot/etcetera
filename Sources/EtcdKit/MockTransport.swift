import Foundation
import Synchronization

/// A transport that replays queued or recorded responses. Tests run against
/// this; no network, no Docker.
public final class MockTransport: EtcdTransport, Sendable {
    /// A request the mock has seen, for asserting on what was sent.
    public struct SeenRequest: Sendable {
        public var path: String
        public var method: String
        public var body: Data
        public var token: String?

        /// The request body decoded as JSON, for convenient assertions.
        public var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    private struct QueuedStream {
        var results: [Result<Data, any Error>]
        /// After the last line the stream stays open, like a live watch.
        var staysOpen: Bool
    }

    private struct State {
        var queues: [String: [Result<Data, any Error>]] = [:]
        var streamQueues: [String: [QueuedStream]] = [:]
        var seen: [SeenRequest] = []
        var token: String?
        var tokenChanges: [String?] = []
        var holds: [String: [RequestHold]] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Replays fixtures recorded by `FixtureRecorder`, in order, per path.
    public convenience init(fixtures: [FixtureExchange]) {
        self.init()
        for fixture in fixtures {
            if let lines = fixture.streamLines {
                if fixture.status == 200 {
                    enqueueStream(
                        path: fixture.path, lines: lines, staysOpen: fixture.streamStayedOpen ?? false)
                } else {
                    let body = Data(lines.joined(separator: "\n").utf8)
                    enqueueStream(
                        path: fixture.path, lines: [],
                        thenError: GatewayErrorMapper.error(status: fixture.status, body: body))
                }
            } else if fixture.status == 200 {
                enqueue(path: fixture.path, response: Data(fixture.response.utf8))
            } else {
                enqueue(
                    path: fixture.path,
                    error: GatewayErrorMapper.error(
                        status: fixture.status, body: Data(fixture.response.utf8)))
            }
        }
    }

    // MARK: Arranging

    public func enqueue(path: String, response: Data) {
        state.withLock { $0.queues[path, default: []].append(.success(response)) }
    }

    public func enqueue(path: String, json: String) {
        enqueue(path: path, response: Data(json.utf8))
    }

    public func enqueue(path: String, error: any Error) {
        state.withLock { $0.queues[path, default: []].append(.failure(error)) }
    }

    /// Queues one whole stream: each element is one line the stream yields,
    /// then an optional error that terminates it. With `staysOpen` the
    /// stream neither finishes nor fails after the last line.
    public func enqueueStream(
        path: String, lines: [String], thenError: (any Error)? = nil, staysOpen: Bool = false
    ) {
        var results: [Result<Data, any Error>] = lines.map { .success(Data($0.utf8)) }
        if let thenError {
            results.append(.failure(thenError))
        }
        let queued = QueuedStream(results: results, staysOpen: staysOpen && thenError == nil)
        state.withLock { $0.streamQueues[path, default: []].append(queued) }
    }

    /// Makes the next unary request on `path` wait until the hold is released,
    /// so a test can look at state while that request is in flight.
    public func hold(path: String) -> RequestHold {
        let hold = RequestHold()
        state.withLock { $0.holds[path, default: []].append(hold) }
        return hold
    }

    // MARK: Asserting

    public var requests: [SeenRequest] {
        state.withLock { $0.seen }
    }

    public func requests(for path: String) -> [SeenRequest] {
        state.withLock { $0.seen.filter { $0.path == path } }
    }

    /// Every token value passed to `setAuthToken`, in order.
    public var tokenChanges: [String?] {
        state.withLock { $0.tokenChanges }
    }

    /// Queued responses nobody asked for, per path. Empty after a faithful replay.
    public var unconsumedPaths: [String] {
        state.withLock { state in
            (state.queues.filter { !$0.value.isEmpty }.map(\.key)
                + state.streamQueues.filter { !$0.value.isEmpty }.map(\.key)).sorted()
        }
    }

    // MARK: EtcdTransport

    /// Cancelled callers fail as they would with URLSession.
    public func unary(path: String, body: Data) async throws -> Data {
        try Task.checkCancellation()
        await waitForHold(on: path)
        return try next(path: path, method: "POST", body: body).get()
    }

    public func get(path: String) async throws -> Data {
        try Task.checkCancellation()
        await waitForHold(on: path)
        return try next(path: path, method: "GET", body: Data()).get()
    }

    private func waitForHold(on path: String) async {
        let hold: RequestHold? = state.withLock { state in
            state.holds[path, default: []].isEmpty ? nil : state.holds[path]!.removeFirst()
        }
        await hold?.wait()
    }

    public func stream(path: String, body: Data) -> AsyncThrowingStream<Data, any Error> {
        let queued: QueuedStream? = state.withLock { state in
            state.seen.append(SeenRequest(path: path, method: "POST", body: body, token: state.token))
            guard !state.streamQueues[path, default: []].isEmpty else { return nil }
            return state.streamQueues[path]!.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard let queued else {
                continuation.finish(
                    throwing: EtcdError.transport(
                        underlying: MockTransportError.unexpectedRequest(path: path)))
                return
            }
            for result in queued.results {
                switch result {
                case .success(let data):
                    continuation.yield(data)
                case .failure(let error):
                    continuation.finish(throwing: error)
                    return
                }
            }
            if !queued.staysOpen {
                continuation.finish()
            }
        }
    }

    public func setAuthToken(_ token: String?) async {
        state.withLock {
            $0.token = token
            $0.tokenChanges.append(token)
        }
    }

    private func next(path: String, method: String, body: Data) -> Result<Data, any Error> {
        state.withLock { state in
            state.seen.append(SeenRequest(path: path, method: method, body: body, token: state.token))
            guard !state.queues[path, default: []].isEmpty else {
                return .failure(
                    EtcdError.transport(
                        underlying: MockTransportError.unexpectedRequest(path: path)))
            }
            return state.queues[path]!.removeFirst()
        }
    }
}

public enum MockTransportError: Error, Sendable {
    case unexpectedRequest(path: String)
}

/// One request held back by `MockTransport.hold(path:)`.
public final class RequestHold: Sendable {
    private struct State {
        var arrived = false
        var released = false
        var arrivalWaiter: CheckedContinuation<Void, Never>?
        var releaseWaiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    /// Returns once the held request has been made.
    public func arrived() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.arrived { continuation.resume() } else { state.arrivalWaiter = continuation }
            }
        }
    }

    /// Lets the held request continue to its queued response.
    public func release() {
        state.withLock { state in
            state.released = true
            state.releaseWaiter?.resume()
            state.releaseWaiter = nil
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                state.arrived = true
                state.arrivalWaiter?.resume()
                state.arrivalWaiter = nil
                if state.released { continuation.resume() } else { state.releaseWaiter = continuation }
            }
        }
    }
}
