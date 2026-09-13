import Foundation
import Testing

@testable import EtcdKit

@Suite("Gateway prefix detection", .tags(.unit))
struct PrefixDetectionTests {
    @Test("Server version maps to the right path prefix",
        arguments: [
            ("3.0.0", "/v3alpha"),
            ("3.2.11", "/v3alpha"),
            ("3.3.0", "/v3beta"),
            ("3.3.27", "/v3beta"),
            ("3.4.33", "/v3"),
            ("3.5.21", "/v3"),
            ("3.6.0", "/v3"),
            ("4.0.0", "/v3"),
        ])
    func prefix(for version: String, expected: String) throws {
        let detected = try PrefixResolver.prefix(forServerVersion: version)
        #expect(detected == expected)
    }

    @Test("Pre-release suffixes parse")
    func preReleaseSuffix() throws {
        #expect(try PrefixResolver.prefix(forServerVersion: "3.6.0-alpha.1") == "/v3")
    }

    @Test("An unparseable version throws", arguments: ["banana", "", "-"])
    func unparseable(version: String) {
        #expect(throws: EtcdError.self) {
            _ = try PrefixResolver.prefix(forServerVersion: version)
        }
    }

    @Test("Stage one: /version drives the prefix and no probe is sent")
    func stageOne() async throws {
        let transport = MockTransport()
        transport.enqueue(
            path: "/version",
            json: "{\"etcdserver\": \"3.3.27\", \"etcdcluster\": \"3.3.0\"}")
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        #expect(client.apiPrefix == "/v3beta")
        #expect(client.serverVersion == ServerVersion(major: 3, minor: 3, patch: 27))
        #expect(transport.requests.count == 1)
    }

    @Test("Stage two: probes /v3, /v3beta, /v3alpha in order and takes the first non-404")
    func stageTwoProbes() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotParseResponse)))
        transport.enqueue(path: "/v3/maintenance/status", error: HTTPStatusError(status: 404, body: Data()))
        transport.enqueue(path: "/v3beta/maintenance/status", json: "{\"version\": \"3.3.0\"}")
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        #expect(client.apiPrefix == "/v3beta")
        let probed = transport.requests.map(\.path)
        #expect(probed == ["/version", "/v3/maintenance/status", "/v3beta/maintenance/status"])
    }

    @Test("Stage two: an auth error on a probe still proves the prefix exists")
    func stageTwoAuthErrorCounts() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotParseResponse)))
        transport.enqueue(path: "/v3/maintenance/status", error: EtcdError.unauthenticated)
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        #expect(client.apiPrefix == "/v3")
    }

    @Test("Stage two: a raw non-404 status such as a proxy's 405 still proves the prefix")
    func stageTwoRawStatusCounts() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotParseResponse)))
        transport.enqueue(path: "/v3/maintenance/status", error: HTTPStatusError(status: 405, body: Data()))
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        #expect(client.apiPrefix == "/v3")
    }

    @Test("404 on every probed prefix means the gateway is off")
    func gatewayUnavailable() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotParseResponse)))
        for prefix in ["/v3", "/v3beta", "/v3alpha"] {
            transport.enqueue(
                path: "\(prefix)/maintenance/status",
                error: HTTPStatusError(status: 404, body: Data()))
        }
        await #expect(throws: EtcdError.self) {
            _ = try await EtcdClient(
                configuration: .init(
                    endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        }
    }

    @Test("A pinned prefix skips probing")
    func pinnedPrefix() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", error: EtcdError.transport(underlying: URLError(.cannotConnectToHost)))
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!,
                pinnedPrefix: "/v3",
                transport: transport))
        #expect(client.apiPrefix == "/v3")
        #expect(transport.requests.map(\.path) == ["/version"])
    }

    @Test("An unparseable /version body falls through to probing")
    func unparseableVersionBody() async throws {
        let transport = MockTransport()
        transport.enqueue(path: "/version", json: "gibberish not json")
        transport.enqueue(path: "/v3/maintenance/status", json: "{\"version\": \"3.5.0\"}")
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!, transport: transport))
        #expect(client.apiPrefix == "/v3")
    }
}

@Suite("Server capabilities gate features by version", .tags(.unit))
struct ServerCapabilitiesTests {
    @Test("Lease listing needs 3.3")
    func leaseListing() {
        #expect(!ServerCapabilities(version: ServerVersion(major: 3, minor: 2)).canListLeases)
        #expect(ServerCapabilities(version: ServerVersion(major: 3, minor: 3)).canListLeases)
    }

    @Test("dbSizeInUse needs 3.4")
    func dbSizeInUse() {
        #expect(!ServerCapabilities(version: ServerVersion(major: 3, minor: 3)).reportsDBSizeInUse)
        #expect(ServerCapabilities(version: ServerVersion(major: 3, minor: 4)).reportsDBSizeInUse)
    }
}
