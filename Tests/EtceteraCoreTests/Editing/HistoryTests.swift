import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

// SPEC 4.7: reading an older revision is free; restoring writes the old
// value as a new one through the normal transaction path.

@MainActor
@Suite("Revision history", .tags(.unit))
struct HistoryTests {
    let transport = MockTransport()
    let history = HistoryModel()
    let key = Data("/config/app".utf8)

    private func version(_ value: String, mod: Int64) -> String {
        """
        {"key": "\(key.base64EncodedString())", "value": "\(Gateway.base64(value))", \
        "create_revision": "2", "mod_revision": "\(mod)", "version": "1"}
        """
    }

    private var current: KeyValue {
        KeyValue(key: key, createRevision: 2, modRevision: 9, version: 3, value: Data("v3".utf8))
    }

    @Test("History walks back through the key's versions by reading older revisions")
    func walksBack() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([version("v2", mod: 5)]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([version("v1", mod: 2)]))
        await history.load(current, from: connection)
        #expect(history.versions.map(\.modRevision) == [9, 5, 2])
        #expect(!history.reachedCompaction)
        let revisions = Gateway.rangeBodies(transport).dropFirst().map { $0["revision"] as? String }
        #expect(revisions == ["8", "4"])
    }

    @Test("History stops at compaction and says so")
    func stopsAtCompaction() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            error: EtcdError.status(code: .outOfRange, message: "etcdserver: mvcc: required revision has been compacted"))
        await history.load(current, from: connection)
        #expect(history.versions.map(\.modRevision) == [9])
        #expect(history.reachedCompaction)
        #expect(history.errorMessage == nil)
    }

    @Test("Comparing with current diffs the selected version against the current value")
    func compareWithCurrent() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([version("v2", mod: 5)]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await history.load(current, from: connection)
        history.selectedRevision = 5
        let diff = history.diffAgainstCurrent { String(decoding: $0, as: UTF8.self) }
        #expect(diff.map(\.kind) == [.deleted, .inserted])
        #expect(diff.map(\.text) == ["v2", "v3"])
    }

    @Test("Restoring an old version writes it as a new value through the guarded transaction")
    func restore() async throws {
        let connection = try await connectedModel(transport)
        let value = ValueModel()
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([version("v3", mod: 9)]))
        await value.load(key: key, from: connection)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 10))
        await value.restore(KeyValue(key: key, createRevision: 2, modRevision: 5, value: Data("v2".utf8)), to: connection)

        let body = try #require(Gateway.txnBodies(transport).first)
        let compare = try #require((body["compare"] as? [[String: Any]])?.first)
        #expect(compare["mod_revision"] as? String == "9")
        let put = try #require((body["success"] as? [[String: Any]])?.first?["request_put"] as? [String: Any])
        #expect(put["value"] as? String == Gateway.base64("v2"))
        #expect(value.loaded?.value == Data("v2".utf8))
        #expect(value.loaded?.modRevision == 10)
    }

    /// A value loaded at 9, then a restore of non-UTF-8 bytes that conflicts with 11.
    private func restoreConflict(_ old: Data) async throws -> (ConnectionModel, ValueModel) {
        let connection = try await connectedModel(transport)
        let value = ValueModel()
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([version("v3", mod: 9)]))
        await value.load(key: key, from: connection)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnConflict(current: version("v4", mod: 11)))
        await value.restore(KeyValue(key: key, createRevision: 2, modRevision: 5, value: old), to: connection)
        guard case .conflict = value.saveState else {
            Issue.record("expected a conflict, got \(value.saveState)")
            throw CancellationError()
        }
        return (connection, value)
    }

    @Test("Overwriting after a restore conflict writes the restored version's exact bytes")
    func restoreConflictOverwrite() async throws {
        let old = Data([0xFF, 0x01])
        let (connection, value) = try await restoreConflict(old)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 12))
        await value.overwrite(to: connection)
        let body = try #require(Gateway.txnBodies(transport).last)
        let put = try #require((body["success"] as? [[String: Any]])?.first?["request_put"] as? [String: Any])
        #expect(put["value"] as? String == old.base64EncodedString())
        #expect(value.loaded?.value == old)
    }

    @Test("Cancelling a restore conflict leaves the buffer untouched")
    func restoreConflictCancel() async throws {
        let (_, value) = try await restoreConflict(Data([0xFF, 0x01]))
        value.cancelConflict()
        #expect(value.text == "v3")
        #expect(!value.isDirty)
    }
}
