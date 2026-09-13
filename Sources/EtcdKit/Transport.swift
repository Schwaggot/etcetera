import Foundation

/// The narrow seam all requests pass through. `HTTPTransport` is the real
/// implementation; tests replay fixtures through `MockTransport`.
public protocol EtcdTransport: Sendable {
    /// POST `body` to `path` and return the response body.
    /// Gateway errors surface as thrown `EtcdError` or `HTTPStatusError`.
    func unary(path: String, body: Data) async throws -> Data

    /// POST `body` to `path` and yield one element per top-level JSON value
    /// of the streaming response. etcd 3.2 does not newline-delimit them.
    func stream(path: String, body: Data) -> AsyncThrowingStream<Data, any Error>

    /// GET `path` with no body. Needed for `/version`, which predates the
    /// gateway and is not POST-shaped.
    func get(path: String) async throws -> Data

    /// Attach or clear the auth token sent on subsequent requests.
    func setAuthToken(_ token: String?) async
}

extension EtcdTransport {
    /// Transports without auth state may ignore tokens.
    public func setAuthToken(_ token: String?) async {}
}
