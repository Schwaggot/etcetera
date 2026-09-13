import Foundation
import Testing

@testable import EtcdKit

private func makeClient(_ transport: MockTransport, version: String = "3.6.4") async throws -> EtcdClient {
    transport.enqueue(path: "/version", json: "{\"etcdserver\": \"\(version)\"}")
    return try await EtcdClient(
        configuration: .init(
            endpoint: URL(string: "http://localhost:2379")!, transport: transport,
            clock: NoSleepClock()))
}

private func isGatewayUnavailable(_ error: any Error) -> Bool {
    if case EtcdError.gatewayUnavailable = error { return true }
    return false
}

@Suite("Gateway availability after detection", .tags(.unit))
struct GatewayAvailabilityTests {
    @Test("A 404 on an API call means the gateway is off, even though /version answered")
    func apiCall404() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(
            path: "/v3/maintenance/status",
            error: HTTPStatusError(status: 404, body: Data("404 page not found".utf8)))
        await #expect(performing: { _ = try await client.status() }, throws: isGatewayUnavailable)
    }

    @Test("A 404 when opening a watch means the gateway is off")
    func watch404() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch", lines: [],
            thenError: HTTPStatusError(status: 404, body: Data("404 page not found".utf8)))
        await #expect(
            performing: {
                for try await _ in client.watch(WatchCreateRequest(key: Data("/k".utf8))) {}
            }, throws: isGatewayUnavailable)
    }

    @Test("A server error line in the watch stream keeps its message")
    func watchErrorLine() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [#"{"error": {"code": 9, "message": "etcdserver: no leader"}}"#])
        await #expect(
            performing: {
                for try await _ in client.watch(WatchCreateRequest(key: Data("/k".utf8))) {}
            },
            throws: { error in
                guard case EtcdError.status(let code, let message) = error else { return false }
                return code == .failedPrecondition && message == "etcdserver: no leader"
            })
    }
}

@Suite("Watch resume point", .tags(.unit))
struct WatchResumeTests {
    @Test("A created header ahead of replayed history does not skip undelivered events")
    func createdHeaderDoesNotAdvanceResume() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        let key = Data("/k/a".utf8).base64EncodedString()
        // Replaying from 5 while the store is at 100: the connection drops
        // after the created line, before any event arrives.
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [#"{"result": {"header": {"revision": "100"}, "created": true}}"#],
            thenError: EtcdError.transport(underlying: URLError(.networkConnectionLost)))
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [
                #"{"result": {"header": {"revision": "100"}, "events": [{"kv": {"key": "\#(key)", "mod_revision": "5"}}]}}"#
            ],
            staysOpen: true)

        for try await event in client.watch(WatchCreateRequest(key: Data("/k/".utf8), startRevision: 5)) {
            #expect(event.revision == 5)
            break
        }

        let bodies = transport.requests(for: "/v3/watch")
        try #require(bodies.count == 2)
        let resumed = try #require(bodies[1].json?["create_request"] as? [String: Any])
        #expect(resumed["start_revision"] as? String == "5")
    }

    @Test("A watch from now resumes after the created header's revision")
    func watchFromNowResumesAfterHeader() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [#"{"result": {"header": {"revision": "42"}, "created": true}}"#],
            thenError: EtcdError.transport(underlying: URLError(.networkConnectionLost)))
        let key = Data("/k/a".utf8).base64EncodedString()
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [#"{"result": {"header": {"revision": "43"}, "events": [{"kv": {"key": "\#(key)", "mod_revision": "43"}}]}}"#],
            staysOpen: true)

        for try await _ in client.watch(WatchCreateRequest(key: Data("/k/".utf8))) { break }

        let resumed = try #require(transport.requests(for: "/v3/watch").last?.json?["create_request"] as? [String: Any])
        #expect(resumed["start_revision"] as? String == "43")
    }
}

@Suite("Fixture recording", .tags(.unit))
struct FixtureRecordingTests {
    @Test("Passwords never reach a fixture file")
    func redactsPasswords() throws {
        let body = Data(#"{"name": "root", "password": "hunter2"}"#.utf8)
        let recorded = FixtureRecorder.redacted(body)
        #expect(!recorded.contains("hunter2"))
        #expect(recorded.contains("root"))
    }

    @Test("Bodies without a password are recorded verbatim")
    func keepsOtherBodies() {
        let body = #"{"key":"Zm9v"}"#
        #expect(FixtureRecorder.redacted(Data(body.utf8)) == body)
    }

    @Test("A recorded stream that stayed open replays without ending")
    func openStreamReplay() async throws {
        let transport = MockTransport(fixtures: [
            FixtureExchange(path: "/version", method: "GET", response: #"{"etcdserver":"3.6.4"}"#),
            FixtureExchange(
                path: "/v3/watch", response: "",
                streamLines: [
                    #"{"result":{"header":{"revision":"3"},"events":[{"kv":{"key":"YQ==","mod_revision":"3"}}]}}"#
                ],
                streamStayedOpen: true),
        ])
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://localhost:2379")!, transport: transport,
                clock: NoSleepClock()))
        for try await event in client.watch(WatchCreateRequest(key: Data("a".utf8))) {
            #expect(event.kv.key == Data("a".utf8))
            break
        }
        // Staying open means no reconnect was attempted.
        #expect(transport.requests(for: "/v3/watch").count == 1)
    }
}

@Suite("Lease paths", .tags(.unit))
struct LeasePathTests {
    @Test("Listing leases uses the path 3.3 serves, which later versions keep")
    func leasesPath() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport, version: "3.3.27")
        transport.enqueue(path: "/v3beta/kv/lease/leases", json: #"{"leases": [{"ID": "7"}]}"#)
        #expect(try await client.leases() == [7])
    }

    @Test("Listing leases on 3.2 is refused before any request")
    func leasesUnsupported() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport, version: "3.2.32")
        await #expect(throws: EtcdError.self) { _ = try await client.leases() }
        #expect(transport.requests.map(\.path) == ["/version"])
    }
}

@Suite("Counting keys", .tags(.unit))
struct CountTests {
    @Test("count(prefix:) asks for the count only, over the prefix range")
    func countOnly() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/kv/range", json: #"{"count": "17"}"#)
        let count = try await client.count(prefix: Data("/config/".utf8))
        #expect(count == 17)
        let body = try #require(transport.requests(for: "/v3/kv/range").first?.json)
        #expect(body["count_only"] as? Bool == true)
        #expect(body["range_end"] as? String == Data("/config0".utf8).base64EncodedString())
    }
}
