import Foundation
import Testing

@testable import EtcdKit

/// One scripted pass over the gateway. The integration suite runs it against
/// real etcd and records fixtures; the unit suite replays those fixtures and
/// asserts the same things. See SPEC 6.5.
enum GatewayScenario {
    static let root = "/etcetera-fixture/"
    static let rootKey = Data(root.utf8)
    static let appKey = Data((root + "config/app").utf8)
    static let dbKey = Data((root + "config/db").utf8)
    static let newKey = Data((root + "config/new").utf8)
    static let leasedKey = Data((root + "leased").utf8)
    /// Not valid UTF-8, and sorts before "config".
    static let binaryKey = Data(root.utf8) + Data([0x62, 0xFF, 0x00])
    static let appV1 = Data(#"{"name":"etcetera","replicas":3}"#.utf8)
    static let appV2 = Data(#"{"name":"etcetera","replicas":4}"#.utf8)
    static let dbValue = Data("postgres://db:5432".utf8)
    static let binaryValue = Data([0x00, 0x01, 0xFE, 0xFF])
    static let password = "etcetera-fixture"

    struct Observations {
        var apiPrefix: String
        var serverVersion: ServerVersion?
        var status: StatusResponse
        var loaded: KeyValue?
        var keysOnly: [KeyValue]
        var firstPage: (kvs: [KeyValue], more: Bool)
        var secondPage: (kvs: [KeyValue], more: Bool)
        var guarded: EtcdClient.SaveOutcome
        var stale: EtcdClient.SaveOutcome
        var createExisting: EtcdClient.SaveOutcome
        var createNew: EtcdClient.SaveOutcome
        var historical: KeyValue?
        var count: Int64
        var lease: LeaseGrantResponse
        var timeToLive: LeaseTimeToLiveResponse
        var leases: [Int64]?
        var watchEvents: [WatchEvent]
        var deleted: Int64
    }

    static func run(_ client: EtcdClient) async throws -> Observations {
        let status = try await client.status()
        let firstPut = try await client.put(PutRequest(key: appKey, value: appV1))
        _ = try await client.put(PutRequest(key: dbKey, value: dbValue))
        _ = try await client.put(PutRequest(key: binaryKey, value: binaryValue))

        let loaded = try await client.range(RangeRequest(key: appKey)).kvs.first
        let keysOnly = try await client.list(prefix: root, keysOnly: true)
        let firstPage = try await client.listPage(prefix: root, limit: 2)
        let secondPage = try await client.listPage(prefix: root, after: firstPage.kvs.last?.key, limit: 2)

        let loadedRevision = loaded?.modRevision ?? 0
        let guarded = try await client.save(key: appKey, value: appV2, expectedModRevision: loadedRevision)
        let stale = try await client.save(
            key: appKey, value: Data("stale".utf8), expectedModRevision: loadedRevision)
        let createExisting = try await client.save(key: dbKey, value: Data("dup".utf8), expectedModRevision: 0)
        let createNew = try await client.save(key: newKey, value: Data("fresh".utf8), expectedModRevision: 0)

        let historical = try await client.range(RangeRequest(key: appKey, revision: loadedRevision)).kvs.first
        let count = try await client.count(prefix: rootKey)

        let lease = try await client.leaseGrant(ttl: 300)
        _ = try await client.put(PutRequest(key: leasedKey, value: Data("temp".utf8), lease: lease.id))
        let timeToLive = try await client.leaseTimeToLive(id: lease.id, keys: true)
        var leases: [Int64]?
        if client.capabilities.canListLeases {
            leases = try await client.leases()
        }
        try await client.leaseRevoke(id: lease.id)

        var events: [WatchEvent] = []
        let watch = WatchCreateRequest(
            key: rootKey, rangeEnd: prefixEnd(rootKey), startRevision: firstPut.header.revision)
        for try await event in client.watch(watch) {
            events.append(event)
            if events.count == 3 { break }
        }

        let deleted = try await client.delete(
            DeleteRangeRequest(key: rootKey, rangeEnd: prefixEnd(rootKey))
        ).deleted

        return Observations(
            apiPrefix: client.apiPrefix, serverVersion: client.serverVersion, status: status,
            loaded: loaded, keysOnly: keysOnly, firstPage: firstPage, secondPage: secondPage,
            guarded: guarded, stale: stale, createExisting: createExisting, createNew: createNew,
            historical: historical, count: count, lease: lease, timeToLive: timeToLive,
            leases: leases, watchEvents: events, deleted: deleted)
    }

    static func verify(_ o: Observations, expectedVersion: String?) throws {
        let version = try #require(o.serverVersion)
        if let expectedVersion {
            #expect(version == ServerVersion(parsing: expectedVersion))
        }
        #expect(o.apiPrefix == PrefixResolver.prefix(for: version))
        #expect(!o.status.version.isEmpty)
        #expect((o.status.dbSizeInUse != nil) == ServerCapabilities(version: version).reportsDBSizeInUse)

        let loaded = try #require(o.loaded)
        #expect(loaded.value == appV1)
        #expect(loaded.version == 1)
        #expect(loaded.createRevision == loaded.modRevision)

        #expect(o.keysOnly.map(\.key) == [binaryKey, appKey, dbKey])
        #expect(o.keysOnly.allSatisfy { $0.value.isEmpty })
        #expect(o.firstPage.kvs.count == 2)
        #expect(o.firstPage.more)
        #expect(o.secondPage.kvs.map(\.key) == [dbKey])
        #expect(!o.secondPage.more)

        guard case .written = o.guarded else {
            Issue.record("a save at the loaded revision must succeed, got \(o.guarded)")
            return
        }
        guard case .conflict(let current) = o.stale else {
            Issue.record("a stale save must conflict, got \(o.stale)")
            return
        }
        #expect(current?.value == appV2)
        guard case .conflict(let existing) = o.createExisting else {
            Issue.record("creating an existing key must conflict, got \(o.createExisting)")
            return
        }
        #expect(existing?.value == dbValue)
        guard case .written = o.createNew else {
            Issue.record("creating a new key must succeed, got \(o.createNew)")
            return
        }

        #expect(o.historical?.value == appV1)
        #expect(o.count == 4)

        #expect(o.lease.id != 0)
        #expect(o.timeToLive.grantedTTL == 300)
        #expect(o.timeToLive.keys == [leasedKey])
        if let leases = o.leases {
            #expect(leases.contains(o.lease.id))
        } else {
            #expect(!ServerCapabilities(version: version).canListLeases)
        }

        #expect(o.watchEvents.map(\.kv.key) == [appKey, dbKey, binaryKey])
        #expect(o.watchEvents.allSatisfy { $0.kind == .put })
        #expect(o.watchEvents.map(\.revision) == o.watchEvents.map(\.kv.modRevision))
        #expect(o.deleted == 4)
    }

    struct AuthObservations {
        var anonymousError: (any Error)?
        var wrongPasswordError: (any Error)?
        var value: Data?
    }

    /// Runs against a cluster with auth enabled and a root user.
    static func runAuth(_ client: EtcdClient) async throws -> AuthObservations {
        var anonymous: (any Error)?
        do {
            _ = try await client.range(RangeRequest(key: appKey))
        } catch {
            anonymous = error
        }
        var wrongPassword: (any Error)?
        do {
            try await client.authenticate(name: "root", password: "wrong-password")
        } catch {
            wrongPassword = error
        }
        try await client.authenticate(name: "root", password: password)
        _ = try await client.put(PutRequest(key: appKey, value: appV1))
        let value = try await client.range(RangeRequest(key: appKey)).kvs.first?.value
        return AuthObservations(anonymousError: anonymous, wrongPasswordError: wrongPassword, value: value)
    }

    static func verifyAuth(_ o: AuthObservations) {
        #expect(o.anonymousError is EtcdError, "a request without a token must be refused")
        #expect(o.wrongPasswordError is EtcdError, "a wrong password must be refused")
        #expect(o.value == appV1)
    }

    /// Runs against a cluster started with --enable-grpc-gateway=false.
    static func runGatewayOff(_ client: EtcdClient) async -> (any Error)? {
        do {
            _ = try await client.status()
            return nil
        } catch {
            return error
        }
    }

    static func verifyGatewayOff(_ error: (any Error)?) {
        guard case EtcdError.gatewayUnavailable? = error as? EtcdError else {
            Issue.record("expected gatewayUnavailable, got \(String(describing: error))")
            return
        }
    }
}
