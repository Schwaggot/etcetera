import Foundation
import Testing

@testable import EtcdKit

private func makeClient(_ transport: MockTransport) async throws -> EtcdClient {
    transport.enqueue(path: "/version", json: "{\"etcdserver\": \"3.5.21\"}")
    return try await EtcdClient(
        configuration: .init(
            endpoint: URL(string: "http://localhost:2379")!, transport: transport))
}

@Suite("Authentication", .tags(.unit))
struct AuthTests {
    @Test("authenticate fetches a token and installs it on the transport")
    func authenticateInstallsToken() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"abc123\"}")
        try await client.authenticate(name: "root", password: "secret")
        #expect(transport.tokenChanges == ["abc123"])
        let body = try #require(transport.requests(for: "/v3/auth/authenticate").first?.json)
        #expect(body["name"] as? String == "root")
        #expect(body["password"] as? String == "secret")
    }

    @Test("One 401 triggers exactly one re-auth and one retry")
    func retriesOnceOn401() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-1\"}")
        try await client.authenticate(name: "root", password: "secret")

        // The first range call is rejected with an expired token, the
        // re-auth succeeds, the retried call goes through.
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.unauthenticated)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-2\"}")
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")

        _ = try await client.range(RangeRequest(key: Data("k".utf8)))

        // Older servers check the token even on Authenticate, so the expired one must not go along.
        #expect(transport.tokenChanges == ["token-1", nil, "token-2"])
        #expect(transport.requests(for: "/v3/auth/authenticate").map(\.token) == [nil, nil])
        #expect(transport.requests(for: "/v3/kv/range").map(\.token) == ["token-1", "token-2"])
    }

    @Test("Concurrent 401s share one re-auth, so no retry goes out without a token")
    func concurrentRetriesShareReauth() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-1\"}")
        try await client.authenticate(name: "root", password: "secret")

        // Both calls are in flight with the expired token before either re-authenticates.
        let holds = [transport.hold(path: "/v3/kv/range"), transport.hold(path: "/v3/kv/range")]
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.unauthenticated)
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.unauthenticated)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-2\"}")
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")

        async let first = client.range(RangeRequest(key: Data("a".utf8)))
        async let second = client.range(RangeRequest(key: Data("b".utf8)))
        for hold in holds { await hold.arrived() }
        for hold in holds { hold.release() }
        _ = try await (first, second)

        #expect(transport.requests(for: "/v3/auth/authenticate").count == 2)
        #expect(transport.requests(for: "/v3/kv/range").suffix(2).map(\.token) == ["token-2", "token-2"])
    }

    @Test("A bare HTTP 401 from a proxy also triggers one re-auth and one retry")
    func retriesOnBare401() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-1\"}")
        try await client.authenticate(name: "root", password: "secret")

        transport.enqueue(
            path: "/v3/kv/range", error: GatewayErrorMapper.error(status: 401, body: Data("Unauthorized".utf8)))
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-2\"}")
        transport.enqueue(path: "/v3/kv/range", json: "{\"count\": \"0\"}")

        _ = try await client.range(RangeRequest(key: Data("k".utf8)))
        #expect(transport.tokenChanges == ["token-1", nil, "token-2"])
    }

    @Test("A second 401 propagates instead of looping")
    func secondFailurePropagates() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-1\"}")
        try await client.authenticate(name: "root", password: "secret")

        transport.enqueue(path: "/v3/kv/range", error: EtcdError.unauthenticated)
        transport.enqueue(path: "/v3/auth/authenticate", json: "{\"token\": \"token-2\"}")
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.unauthenticated)

        await #expect(throws: EtcdError.self) {
            _ = try await client.range(RangeRequest(key: Data("k".utf8)))
        }
        // Exactly one retry: two range attempts, no more.
        #expect(transport.requests(for: "/v3/kv/range").count == 2)
    }

    @Test("Without stored credentials a 401 propagates immediately")
    func noCredentialsNoRetry() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/kv/range", error: EtcdError.unauthenticated)
        await #expect(throws: EtcdError.self) {
            _ = try await client.range(RangeRequest(key: Data("k".utf8)))
        }
        #expect(transport.requests(for: "/v3/kv/range").count == 1)
    }

    @Test("Bad credentials on authenticate propagate")
    func badCredentials() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/auth/authenticate",
            error: EtcdError.status(code: .invalidArgument, message: "etcdserver: authentication failed"))
        await #expect(throws: EtcdError.self) {
            try await client.authenticate(name: "root", password: "wrong")
        }
        #expect(transport.tokenChanges.isEmpty)
    }
}
