import Foundation
import Testing

@testable import EtcdKit

/// Replays exchanges recorded from real etcd, one set per supported version,
/// and asserts what the integration suite asserts. No network.
@Suite("Recorded gateway fixtures replay offline", .tags(.unit))
struct FixtureReplayTests {
    static let versions = ["3.2.32", "3.3.27", "3.4.35", "3.5.21", "3.6.4"]

    private func replaying(_ name: String) async throws -> (EtcdClient, MockTransport) {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "missing \(name).jsonl; run Tools/record-fixtures.sh")
        let transport = MockTransport(fixtures: try FixtureRecorder.load(from: url))
        let client = try await EtcdClient(
            configuration: .init(
                endpoint: URL(string: "http://fixture.invalid:2379")!,
                transport: transport, clock: NoSleepClock()))
        return (client, transport)
    }

    @Test("Read, write, lease, and watch paths behave on every version", arguments: versions)
    func main(version: String) async throws {
        let (client, transport) = try await replaying("etcd-\(version)")
        let observations = try await GatewayScenario.run(client)
        try GatewayScenario.verify(observations, expectedVersion: version)
        #expect(transport.unconsumedPaths.isEmpty)
    }

    @Test("Authentication behaves on every version", arguments: versions)
    func auth(version: String) async throws {
        let (client, transport) = try await replaying("etcd-\(version)-auth")
        GatewayScenario.verifyAuth(try await GatewayScenario.runAuth(client))
        #expect(transport.unconsumedPaths.isEmpty)
        let authenticated = transport.requests(for: "/v3/kv/put") + transport.requests(for: "/v3beta/kv/put")
            + transport.requests(for: "/v3alpha/kv/put")
        #expect(authenticated.allSatisfy { $0.token != nil })
    }

    @Test("A cluster started without the gateway reports gatewayUnavailable")
    func gatewayOff() async throws {
        let (client, _) = try await replaying("etcd-3.6.4-gateway-off")
        GatewayScenario.verifyGatewayOff(await GatewayScenario.runGatewayOff(client))
    }
}
