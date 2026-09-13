import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

// SPEC 4.5: every save is a transaction; a stale mod revision produces the
// conflict state and never a bare put.

@MainActor
@Suite("Saving edits", .tags(.unit))
struct SaveFlowTests {
    let transport = MockTransport()
    let value = ValueModel()
    let key = Data("/config/app".utf8)

    /// A value loaded at mod revision 7, then edited to "mine".
    private func edited(lease: Int64 = 0) async throws -> ConnectionModel {
        let connection = try await connectedModel(transport)
        transport.enqueue(
            path: "/v3/kv/range",
            json: Gateway.range([Gateway.kv(key, value: Data("theirs-0".utf8), modRevision: 7, lease: lease)]))
        await value.load(key: key, from: connection)
        value.text = "mine"
        return connection
    }

    /// Edited, then saved into a conflict with a value written at 11.
    private func conflicted() async throws -> ConnectionModel {
        let connection = try await edited()
        transport.enqueue(
            path: "/v3/kv/txn",
            json: Gateway.txnConflict(current: Gateway.kv(key, value: Data("theirs-1".utf8), modRevision: 11)))
        await value.save(to: connection)
        return connection
    }

    private func compare(_ index: Int) throws -> [String: Any] {
        let body = try #require(Gateway.txnBodies(transport).dropFirst(index).first)
        return try #require((body["compare"] as? [[String: Any]])?.first)
    }

    private func put(_ index: Int) throws -> [String: Any] {
        let body = try #require(Gateway.txnBodies(transport).dropFirst(index).first)
        let success = try #require(body["success"] as? [[String: Any]])
        return try #require(success.first?["request_put"] as? [String: Any])
    }

    @Test("Saving is a transaction on the loaded mod revision, never a bare put")
    func saveIsGuarded() async throws {
        let connection = try await edited()
        #expect(value.isDirty)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 10))
        await value.save(to: connection)

        #expect(transport.requests(for: "/v3/kv/put").isEmpty)
        #expect(try compare(0)["mod_revision"] as? String == "7")
        #expect(try put(0)["value"] as? String == Gateway.base64("mine"))
        guard case .saved = value.saveState else {
            Issue.record("expected saved, got \(value.saveState)")
            return
        }
        #expect(value.loaded?.modRevision == 10)
        #expect(value.loaded?.value == Data("mine".utf8))
        #expect(!value.isDirty)
    }

    private func whileSaving(_ connection: ConnectionModel, _ body: () async -> Void) async {
        let saving = Task { await value.save(to: connection) }
        _ = await eventually {
            if case .saving = value.saveState { true } else { false }
        }
        await body()
        await saving.value
    }

    @Test("Text typed while a save is in flight is kept and leaves the value edited")
    func typingDuringSave() async throws {
        let connection = try await edited()
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 10))
        await whileSaving(connection) { value.text = "mine, more" }

        #expect(try put(0)["value"] as? String == Gateway.base64("mine"))
        #expect(value.text == "mine, more")
        #expect(value.isDirty)
        #expect(value.loaded?.modRevision == 10)
    }

    @Test("A second save while one is in flight sends nothing, so it cannot conflict with the first")
    func saveWhileSaving() async throws {
        let connection = try await edited()
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 10))
        await whileSaving(connection) { await value.save(to: connection) }

        #expect(Gateway.txnBodies(transport).count == 1)
        guard case .saved = value.saveState else {
            Issue.record("expected saved, got \(value.saveState)")
            return
        }
    }

    @Test("A stale mod revision produces the conflict state and keeps the local edits")
    func staleRevisionConflicts() async throws {
        _ = try await conflicted()
        guard case .conflict(let current) = value.saveState else {
            Issue.record("expected conflict, got \(value.saveState)")
            return
        }
        #expect(current?.modRevision == 11)
        #expect(value.text == "mine")
        #expect(value.loaded?.modRevision == 7)
        #expect(LineDiff.hasChanges(value.conflictDiff))
        #expect(transport.requests(for: "/v3/kv/put").isEmpty)
        #expect(Gateway.txnBodies(transport).count == 1)
    }

    @Test("Overwrite after a conflict compares against the revision just seen")
    func overwrite() async throws {
        let connection = try await conflicted()
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 13))
        await value.overwrite(to: connection)
        #expect(try compare(1)["mod_revision"] as? String == "11")
        #expect(value.loaded?.modRevision == 13)
        #expect(!value.isDirty)
    }

    @Test("Discarding local edits adopts the current value")
    func discard() async throws {
        _ = try await conflicted()
        value.discardLocalEdits()
        #expect(value.text == "theirs-1")
        #expect(value.loaded?.modRevision == 11)
        #expect(!value.isDirty)
        guard case .idle = value.saveState else {
            Issue.record("expected idle, got \(value.saveState)")
            return
        }
    }

    @Test("Cancelling the conflict sheet keeps the edits and the loaded revision")
    func cancelConflict() async throws {
        _ = try await conflicted()
        value.cancelConflict()
        #expect(value.text == "mine")
        #expect(value.loaded?.modRevision == 7)
        guard case .idle = value.saveState else {
            Issue.record("expected idle, got \(value.saveState)")
            return
        }
    }

    @Test("Merging puts both versions in the buffer and saves against the current revision")
    func merge() async throws {
        let connection = try await conflicted()
        value.openMerge()
        #expect(value.text.contains("<<<<<<< local\nmine\n=======\ntheirs-1\n>>>>>>> remote"))
        #expect(value.isDirty)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 14))
        await value.save(to: connection)
        #expect(try compare(1)["mod_revision"] as? String == "11")
    }

    @Test("Overwriting a key deleted meanwhile recreates it only if it is still absent")
    func overwriteDeletedKey() async throws {
        let connection = try await edited()
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnConflict(current: nil))
        await value.save(to: connection)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 15))
        await value.overwrite(to: connection)
        #expect(try compare(1)["target"] as? String == "CREATE")
        #expect(try compare(1)["create_revision"] as? String == "0")
    }

    @Test("A save keeps the key's lease")
    func keepsLease() async throws {
        let connection = try await edited(lease: 99)
        transport.enqueue(path: "/v3/kv/txn", json: Gateway.txnWritten(revision: 10))
        await value.save(to: connection)
        #expect(try put(0)["lease"] as? String == "99")
    }

    @Test("A value shown as hex is read-only and a save sends nothing")
    func hexIsReadOnly() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: Data([0xFF, 0x00]))]))
        await value.load(key: key, from: connection)
        #expect(value.format == .hex)
        #expect(!value.isEditable)
        value.text = "edited"
        await value.save(to: connection)
        #expect(Gateway.txnBodies(transport).isEmpty)
    }

    private func reconnect(_ connection: ConnectionModel) async throws {
        transport.enqueue(path: "/version", json: #"{"etcdserver": "3.5.21"}"#)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await connection.connect()
        try #require(connection.phase == .connected)
    }

    @Test("A value loaded on an earlier connection is never saved through a new one")
    func refusesAfterReconnect() async throws {
        let connection = try await edited()
        try await reconnect(connection)
        await value.save(to: connection)
        #expect(Gateway.txnBodies(transport).isEmpty)
        guard case .failed = value.saveState else {
            Issue.record("expected a failed save, got \(value.saveState)")
            return
        }
    }

    @Test("Overwrite after a reconnect sends nothing")
    func overwriteRefusesAfterReconnect() async throws {
        let connection = try await conflicted()
        try await reconnect(connection)
        await value.overwrite(to: connection)
        #expect(Gateway.txnBodies(transport).count == 1)
    }

    @Test("Saving without edits sends nothing")
    func cleanSave() async throws {
        let connection = try await edited()
        value.text = "theirs-0"
        #expect(!value.isDirty)
        await value.save(to: connection)
        #expect(Gateway.txnBodies(transport).isEmpty)
    }
}
