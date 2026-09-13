import Foundation
import Testing

@testable import EtcdKit

private let environment = ProcessInfo.processInfo.environment
private let scenario = environment["ETCETERA_SCENARIO"] ?? "main"

/// Runs the gateway scenario against a real etcd and, when asked, records
/// fixtures. Driven by Tools/record-fixtures.sh across every supported version.
/// Serialized because every test shares one etcd instance.
@Suite(
    "Gateway against real etcd", .tags(.integration), .serialized, .timeLimit(.minutes(1)),
    .enabled(
        if: environment["ETCETERA_ETCD_ENDPOINT"] != nil,
        "needs ETCETERA_ETCD_ENDPOINT; see Tools/record-fixtures.sh"))
struct IntegrationTests {
    private func makeClient() async throws -> EtcdClient {
        let endpoint = try #require(environment["ETCETERA_ETCD_ENDPOINT"].flatMap(URL.init(string:)))
        let recorder = environment["ETCETERA_RECORD_TO"].map {
            FixtureRecorder(writingTo: URL(fileURLWithPath: $0))
        }
        let transport = try HTTPTransport(endpoint: endpoint, recorder: recorder)
        return try await EtcdClient(configuration: .init(endpoint: endpoint, transport: transport))
    }

    @Test("Read, write, lease, and watch paths", .enabled(if: scenario == "main"))
    func main() async throws {
        let observations = try await GatewayScenario.run(try await makeClient())
        try GatewayScenario.verify(observations, expectedVersion: environment["ETCETERA_ETCD_VERSION"])
    }

    @Test("Authentication against a cluster with auth enabled", .enabled(if: scenario == "auth"))
    func auth() async throws {
        GatewayScenario.verifyAuth(try await GatewayScenario.runAuth(try await makeClient()))
    }

    @Test("A cluster without the gateway is reported plainly", .enabled(if: scenario == "gateway-off"))
    func gatewayOff() async throws {
        GatewayScenario.verifyGatewayOff(await GatewayScenario.runGatewayOff(try await makeClient()))
    }
}
