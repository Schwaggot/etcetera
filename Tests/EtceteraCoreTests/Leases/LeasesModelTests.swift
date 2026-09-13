import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Leases", .tags(.unit))
struct LeasesModelTests {
    let transport = MockTransport()
    let leases = LeasesModel()

    @Test("Leases list with their remaining time and attached keys")
    func list() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/lease/leases", json: #"{"leases": [{"ID": "7"}, {"ID": "3"}]}"#)
        transport.enqueue(
            path: "/v3/kv/lease/timetolive",
            json: #"{"ID": "7", "TTL": "30", "grantedTTL": "60", "keys": ["\#(Gateway.base64("a"))"]}"#)
        transport.enqueue(path: "/v3/kv/lease/timetolive", json: #"{"ID": "3", "TTL": "-1", "grantedTTL": "10"}"#)
        await leases.load(from: connection)

        #expect(leases.errorMessage == nil)
        #expect(leases.leases.map(\.id) == [3, 7])
        #expect(leases.leases[1].ttl == 30)
        #expect(leases.leases[1].grantedTTL == 60)
        #expect(leases.leases[1].keys == [Data("a".utf8)])
        #expect(leases.leases[0].ttl == -1)
        let body = try #require(transport.requests(for: "/v3/kv/lease/timetolive").first?.json)
        #expect(body["keys"] as? Bool == true)
    }

    @Test("Revoking a lease removes it and counts as a write")
    func revoke() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/lease/leases", json: #"{"leases": [{"ID": "7"}]}"#)
        transport.enqueue(path: "/v3/kv/lease/timetolive", json: #"{"ID": "7", "TTL": "30", "grantedTTL": "60"}"#)
        await leases.load(from: connection)
        transport.enqueue(path: "/v3/kv/lease/revoke", json: "{}")
        await leases.revoke(7, from: connection)
        #expect(leases.leases.isEmpty)
        #expect(transport.requests(for: "/v3/kv/lease/revoke").count == 1)
        #expect(connection.writeCount == 1)
    }

    @Test("A server too old to list leases says which version it needs")
    func tooOld() async throws {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.2.32"}"#)
        transport.enqueue(path: "/v3alpha/kv/range", json: Gateway.range([]))
        let connection = ConnectionModel(transport: transport)
        await connection.connect()
        #expect(!connection.canListLeases)
        await leases.load(from: connection)
        #expect(leases.errorMessage?.contains("3.3") == true)
    }
}
