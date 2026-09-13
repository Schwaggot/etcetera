import EtcdKit
import Foundation
import Synchronization

/// Holds unary requests while closed, so a test can act while one is in flight.
final class GatedTransport: EtcdTransport, Sendable {
    private struct State {
        var closed = false
        var held: [CheckedContinuation<Void, Never>] = []
    }

    private let inner: MockTransport
    private let state = Mutex(State())

    init(_ inner: MockTransport) {
        self.inner = inner
    }

    var heldCount: Int { state.withLock { $0.held.count } }

    func close() {
        state.withLock { $0.closed = true }
    }

    func open() {
        let held = state.withLock { state in
            state.closed = false
            defer { state.held = [] }
            return state.held
        }
        for continuation in held { continuation.resume() }
    }

    func unary(path: String, body: Data) async throws -> Data {
        await withCheckedContinuation { continuation in
            let hold = state.withLock { state in
                if state.closed { state.held.append(continuation) }
                return state.closed
            }
            if !hold { continuation.resume() }
        }
        return try await inner.unary(path: path, body: body)
    }

    func get(path: String) async throws -> Data {
        try await inner.get(path: path)
    }

    func stream(path: String, body: Data) -> AsyncThrowingStream<Data, any Error> {
        inner.stream(path: path, body: body)
    }

    func setAuthToken(_ token: String?) async {
        await inner.setAuthToken(token)
    }
}
