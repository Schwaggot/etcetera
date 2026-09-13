import Foundation
import Testing

@testable import EtcdKit

private func makeClient(
    _ transport: MockTransport, clock: any Clock<Duration> = NoSleepClock()
) async throws -> EtcdClient {
    transport.enqueue(path: "/version", json: "{\"etcdserver\": \"3.5.21\"}")
    return try await EtcdClient(
        configuration: .init(
            endpoint: URL(string: "http://localhost:2379")!, transport: transport,
            clock: clock))
}

private func startRevisions(_ transport: MockTransport) -> [String?] {
    transport.requests(for: "/v3/watch").map {
        ($0.json?["create_request"] as? [String: Any])?["start_revision"] as? String
    }
}

private func collect(_ count: Int, from client: EtcdClient, _ request: WatchCreateRequest) async throws
    -> [WatchEvent]
{
    var events: [WatchEvent] = []
    for try await event in client.watch(request) {
        events.append(event)
        if events.count == count { break }
    }
    return events
}

private let connectionLost = EtcdError.transport(underlying: URLError(.networkConnectionLost))

private let createdLine = "{\"result\": {\"header\": {\"revision\": \"5\"}, \"created\": true}}"

private func eventLine(key: String, value: String, revision: Int64, type: String? = nil) -> String {
    let typeField = type.map { "\"type\": \"\($0)\", " } ?? ""
    return """
        {"result": {"header": {"revision": "\(revision)"}, "events": [{\(typeField)"kv": \
        {"key": "\(Data(key.utf8).base64EncodedString())", \
        "value": "\(Data(value.utf8).base64EncodedString())", \
        "mod_revision": "\(revision)"}}]}}
        """
}

@Suite("Watch", .tags(.unit))
struct WatchTests {
    @Test("Yields decoded events from the result envelope")
    func yieldsEvents() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [
                createdLine,
                eventLine(key: "/k/a", value: "1", revision: 6),
                eventLine(key: "/k/b", value: "", revision: 7, type: "DELETE"),
            ],
            thenError: CancellationError())

        var events: [WatchEvent] = []
        do {
            for try await event in client.watch(WatchCreateRequest(key: Data("/k/".utf8))) {
                events.append(event)
                if events.count == 2 { break }
            }
        } catch {}

        try #require(events.count == 2)
        #expect(events[0].kind == .put)
        #expect(events[0].kv.keyString == "/k/a")
        #expect(events[0].revision == 6)
        #expect(events[1].kind == .delete)
        #expect(events[1].kv.keyString == "/k/b")
    }

    @Test("An absent event type means PUT")
    func absentTypeMeansPut() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [eventLine(key: "/k", value: "v", revision: 2)],
            thenError: CancellationError())
        for try await event in client.watch(WatchCreateRequest(key: Data("/k".utf8))) {
            #expect(event.kind == .put)
            break
        }
    }

    @Test("Reconnects after a transport failure, resuming past the last seen revision")
    func reconnectsAndResumes() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        // First connection sees revision 6 and dies; second delivers revision 7.
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [eventLine(key: "/k/a", value: "1", revision: 6)],
            thenError: EtcdError.transport(underlying: URLError(.networkConnectionLost)))
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [eventLine(key: "/k/b", value: "2", revision: 7)],
            thenError: CancellationError())

        var events: [WatchEvent] = []
        do {
            for try await event in client.watch(WatchCreateRequest(key: Data("/k/".utf8))) {
                events.append(event)
                if events.count == 2 { break }
            }
        } catch {}

        try #require(events.count == 2)
        #expect(events[1].kv.keyString == "/k/b")

        let watchBodies = transport.requests(for: "/v3/watch")
        try #require(watchBodies.count == 2)
        let second = try #require(watchBodies[1].json)
        let createRequest = try #require(second["create_request"] as? [String: Any])
        // Resumes from the last observed revision plus one; no events lost.
        #expect(createRequest["start_revision"] as? String == "7")
    }

    @Test("Compaction past the resume point ends the stream with a typed error")
    func compactionEndsStream() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [
                "{\"result\": {\"header\": {\"revision\": \"100\"}, \"compact_revision\": \"90\", \"canceled\": true}}"
            ])

        await #expect(throws: EtcdError.self) {
            for try await _ in client.watch(
                WatchCreateRequest(key: Data("/k/".utf8), startRevision: 50))
            {}
        }
    }

    @Test("The create request wraps in a create_request envelope with the prefix range")
    func createRequestShape() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(path: "/v3/watch", lines: [createdLine], thenError: CancellationError())

        let prefix = Data("/k/".utf8)
        do {
            for try await _ in client.watch(
                WatchCreateRequest(key: prefix, rangeEnd: prefixEnd(prefix)))
            {}
        } catch {}

        let body = try #require(transport.requests(for: "/v3/watch").first?.json)
        let createRequest = try #require(body["create_request"] as? [String: Any])
        #expect(createRequest["key"] as? String == prefix.base64EncodedString())
        #expect(createRequest["range_end"] as? String == prefixEnd(prefix).base64EncodedString())
    }
}

@Suite("Watch reconnection", .tags(.unit))
struct WatchReconnectionTests {
    @Test(
        "Server-side unavailability reconnects with backoff from the last revision plus one",
        arguments: [
            HTTPStatusError(status: 500, body: Data("internal error".utf8)),
            HTTPStatusError(status: 502, body: Data("bad gateway".utf8)),
            HTTPStatusError(status: 503, body: Data("unavailable".utf8)),
            HTTPStatusError(status: 504, body: Data("timeout".utf8)),
            EtcdError.status(code: .unavailable, message: "etcdserver: leader changed"),
            EtcdError.status(code: .deadlineExceeded, message: "context deadline exceeded"),
        ] as [any Error])
    func reconnectsAfterAServerError(_ failure: any Error) async throws {
        let transport = MockTransport()
        let clock = RecordingClock()
        let client = try await makeClient(transport, clock: clock)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/a", value: "1", revision: 6)], thenError: failure)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/b", value: "2", revision: 7)], staysOpen: true)

        let events = try await collect(2, from: client, WatchCreateRequest(key: Data("/k/".utf8)))

        #expect(events.map(\.revision) == [6, 7])
        #expect(startRevisions(transport) == ["0", "7"])
        #expect(clock.sleeps == [.milliseconds(200)])
    }

    // grpc-gateway v2 (etcd 3.6) writes `code`; v1 (3.2 to 3.5) writes `grpc_code`.
    @Test(
        "An unavailable error line in the stream reconnects rather than ending the watch",
        arguments: [
            #"{"error": {"code": 14, "message": "etcdserver: leader changed"}}"#,
            #"{"error": {"grpc_code": 14, "http_code": 503, "message": "etcdserver: leader changed", "http_status": "Service Unavailable"}}"#,
        ])
    func reconnectsAfterAnUnavailableErrorLine(errorLine: String) async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [
                eventLine(key: "/k/a", value: "1", revision: 6),
                errorLine,
            ])
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/b", value: "2", revision: 7)], staysOpen: true)

        let events = try await collect(2, from: client, WatchCreateRequest(key: Data("/k/".utf8)))

        #expect(events.map(\.revision) == [6, 7])
        #expect(startRevisions(transport) == ["0", "7"])
    }

    @Test(
        "A non-retryable HTTP status ends the watch with a typed error and no reconnect",
        arguments: [(400, GRPCStatusCode.invalidArgument), (501, .unimplemented)])
    func nonRetryableStatusEndsTheWatch(status: Int, code: GRPCStatusCode) async throws {
        let transport = MockTransport()
        let clock = RecordingClock()
        let client = try await makeClient(transport, clock: clock)
        transport.enqueueStream(
            path: "/v3/watch", lines: [], thenError: HTTPStatusError(status: status, body: Data("nope".utf8)))

        await #expect(
            performing: {
                for try await _ in client.watch(WatchCreateRequest(key: Data("/k".utf8))) {}
            },
            throws: { error in
                guard case EtcdError.status(let thrown, _) = error else { return false }
                return thrown == code
            })
        #expect(transport.requests(for: "/v3/watch").count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("Backoff doubles from 200 ms on the injected clock and caps at 5 s")
    func backoffDoublesUpToACap() async throws {
        let transport = MockTransport()
        let clock = RecordingClock()
        let client = try await makeClient(transport, clock: clock)
        for _ in 0..<7 {
            transport.enqueueStream(path: "/v3/watch", lines: [], thenError: connectionLost)
        }
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/a", value: "1", revision: 6)], staysOpen: true)

        _ = try await collect(1, from: client, WatchCreateRequest(key: Data("/k/".utf8)))

        #expect(clock.sleeps == [200, 400, 800, 1600, 3200, 5000, 5000].map { .milliseconds($0) })
    }

    @Test("Backoff starts over once a reconnected stream delivers a result")
    func backoffResetsAfterAResult() async throws {
        let transport = MockTransport()
        let clock = RecordingClock()
        let client = try await makeClient(transport, clock: clock)
        transport.enqueueStream(path: "/v3/watch", lines: [], thenError: connectionLost)
        transport.enqueueStream(path: "/v3/watch", lines: [], thenError: connectionLost)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/a", value: "1", revision: 6)], thenError: connectionLost)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/b", value: "2", revision: 7)], staysOpen: true)

        _ = try await collect(2, from: client, WatchCreateRequest(key: Data("/k/".utf8)))

        #expect(clock.sleeps == [200, 400, 200].map { .milliseconds($0) })
    }

    @Test("An expired token on the watch triggers one re-authentication and an immediate reconnect")
    func reauthenticatesOnceOnUnauthenticated() async throws {
        let transport = MockTransport()
        let clock = RecordingClock()
        let client = try await makeClient(transport, clock: clock)
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "token-1"}"#)
        try await client.authenticate(name: "root", password: "secret")

        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/a", value: "1", revision: 6)],
            thenError: GatewayErrorMapper.error(status: 401, body: Data("Unauthorized".utf8)))
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "token-2"}"#)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/b", value: "2", revision: 7)], staysOpen: true)

        let events = try await collect(2, from: client, WatchCreateRequest(key: Data("/k/".utf8)))

        #expect(events.map(\.revision) == [6, 7])
        #expect(transport.tokenChanges == ["token-1", nil, "token-2"])
        #expect(transport.requests(for: "/v3/watch").map(\.token) == ["token-1", "token-2"])
        #expect(startRevisions(transport) == ["0", "7"])
        #expect(clock.sleeps.isEmpty)
    }

    @Test("A watch reopened with an expired token is canceled by the server and re-authenticates")
    func reauthenticatesOnInvalidTokenCancel() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "token-1"}"#)
        try await client.authenticate(name: "root", password: "secret")

        // etcd checks watch auth only at creation and answers with a cancel, not a 401.
        transport.enqueueStream(
            path: "/v3/watch",
            lines: [
                #"{"result": {"header": {"revision": "5"}, "created": true, "canceled": true, "cancel_reason": "etcdserver: invalid auth token"}}"#
            ])
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "token-2"}"#)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/a", value: "1", revision: 6)], staysOpen: true)

        let events = try await collect(1, from: client, WatchCreateRequest(key: Data("/k/".utf8)))

        #expect(events.map(\.revision) == [6])
        #expect(transport.requests(for: "/v3/watch").map(\.token) == ["token-1", "token-2"])
    }

    @Test("A second consecutive unauthenticated on the watch propagates")
    func secondUnauthenticatedPropagates() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "token-1"}"#)
        try await client.authenticate(name: "root", password: "secret")

        transport.enqueueStream(path: "/v3/watch", lines: [], thenError: EtcdError.unauthenticated)
        transport.enqueue(path: "/v3/auth/authenticate", json: #"{"token": "token-2"}"#)
        transport.enqueueStream(path: "/v3/watch", lines: [], thenError: EtcdError.unauthenticated)

        await #expect(
            performing: {
                for try await _ in client.watch(WatchCreateRequest(key: Data("/k".utf8))) {}
            },
            throws: { error in
                if case EtcdError.unauthenticated = error { return true }
                return false
            })
        #expect(transport.requests(for: "/v3/watch").count == 2)
        #expect(transport.requests(for: "/v3/auth/authenticate").count == 2)
    }

    @Test("Without stored credentials an unauthenticated watch ends at once")
    func unauthenticatedWithoutCredentialsEnds() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(path: "/v3/watch", lines: [], thenError: EtcdError.unauthenticated)

        await #expect(throws: EtcdError.self) {
            for try await _ in client.watch(WatchCreateRequest(key: Data("/k".utf8))) {}
        }
        #expect(transport.requests(for: "/v3/watch").count == 1)
        #expect(transport.requests(for: "/v3/auth/authenticate").isEmpty)
    }

    @Test("Cancelling the consuming task finishes the stream without another request")
    func cancellingTheConsumerFinishes() async throws {
        let transport = MockTransport()
        let client = try await makeClient(transport)
        transport.enqueueStream(
            path: "/v3/watch", lines: [eventLine(key: "/k/a", value: "1", revision: 6)], staysOpen: true)

        let (received, signal) = AsyncStream<Void>.makeStream()
        let consumer = Task {
            var count = 0
            for try await _ in client.watch(WatchCreateRequest(key: Data("/k/".utf8))) {
                count += 1
                signal.yield()
            }
            return count
        }
        for await _ in received { break }
        consumer.cancel()

        #expect(try await consumer.value == 1)
        #expect(transport.requests(for: "/v3/watch").count == 1)
    }

    @Test("Cancelling during backoff stops reconnecting")
    func cancellingDuringBackoffStops() async throws {
        let transport = MockTransport()
        let clock = RecordingClock(holdsSleeps: true)
        let client = try await makeClient(transport, clock: clock)
        transport.enqueueStream(path: "/v3/watch", lines: [], thenError: connectionLost)

        let consumer = Task {
            for try await _ in client.watch(WatchCreateRequest(key: Data("/k/".utf8))) {}
        }
        for await _ in clock.sleepStarted { break }
        consumer.cancel()

        try await consumer.value
        #expect(transport.requests(for: "/v3/watch").count == 1)
        #expect(clock.sleeps == [.milliseconds(200)])
    }
}
