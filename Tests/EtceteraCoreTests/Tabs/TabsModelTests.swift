import EtcdKit
import Foundation
import Testing

@testable import EtceteraCore

@MainActor
@Suite("Value tabs", .tags(.unit))
struct TabsModelTests {
    let transport = MockTransport()
    let tabs = TabsModel()
    let a = Data("a".utf8)
    let b = Data("b".utf8)
    let c = Data("c".utf8)

    private func open(_ keys: [Data], _ connection: ConnectionModel) async {
        for key in keys {
            transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(key, value: Data("v".utf8))]))
            await tabs.open(key, from: connection)
        }
    }

    @Test("Opening a key adds a tab, selects it, and loads the value")
    func openAddsTab() async throws {
        let connection = try await connectedModel(transport)
        await open([a], connection)
        #expect(tabs.tabs.map(\.key) == [a])
        #expect(tabs.selectedKey == a)
        #expect(tabs.selected?.value.loaded?.value == Data("v".utf8))
    }

    @Test("Opening a key that already has a tab selects it without reloading")
    func openExisting() async throws {
        let connection = try await connectedModel(transport)
        await open([a, b], connection)
        tabs.selected?.value.text = "edited"
        await tabs.open(a, from: connection)
        #expect(tabs.tabs.count == 2)
        #expect(tabs.selectedKey == a)
        #expect(Gateway.rangeBodies(transport).count == 3)
    }

    @Test("Closing a tab with unsaved edits asks first; forcing closes it")
    func closeDirty() async throws {
        let connection = try await connectedModel(transport)
        await open([a], connection)
        tabs.selected?.value.text = "edited"
        #expect(tabs.hasUnsavedChanges)
        #expect(tabs.close(a) == .needsConfirmation)
        #expect(tabs.tabs.count == 1)
        #expect(tabs.close(a, force: true) == .closed)
        #expect(tabs.tabs.isEmpty)
        #expect(tabs.selectedKey == nil)
    }

    @Test("Closing the selected tab selects its right neighbor, else the left")
    func closeSelectsNeighbor() async throws {
        let connection = try await connectedModel(transport)
        await open([a, b, c], connection)
        tabs.selectedKey = b
        tabs.close(b)
        #expect(tabs.selectedKey == c)
        tabs.close(c)
        #expect(tabs.selectedKey == a)
    }

    @Test("Cycling wraps around in both directions")
    func cycling() async throws {
        let connection = try await connectedModel(transport)
        await open([a, b, c], connection)
        tabs.selectNext()
        #expect(tabs.selectedKey == a)
        tabs.selectPrevious()
        #expect(tabs.selectedKey == c)
        tabs.selectPrevious()
        #expect(tabs.selectedKey == b)
    }

    @Test("A snapshot restores tabs by key and flags values that changed since")
    func restore() async throws {
        let connection = try await connectedModel(transport)
        let snapshot = TabsSnapshot(
            entries: [
                .init(key: a, modRevision: 5, format: .text),
                .init(key: b, modRevision: 7, format: nil),
            ],
            selected: b)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(a, value: Data("{}".utf8), modRevision: 5)]))
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([Gateway.kv(b, modRevision: 9)]))
        await tabs.restore(snapshot, from: connection)

        #expect(tabs.tabs.map(\.key) == [a, b])
        #expect(tabs.selectedKey == b)
        #expect(!tabs.tabs[0].changedSinceLastSession)
        #expect(tabs.tabs[1].changedSinceLastSession)
        // The view mode is restored over the fresh guess.
        #expect(tabs.tabs[0].value.format == .text)
        tabs.tabs[1].acknowledgeChange()
        #expect(!tabs.tabs[1].changedSinceLastSession)
    }

    @Test("A tab restored for a deleted key shows it missing and flags the change")
    func restoreDeleted() async throws {
        let connection = try await connectedModel(transport)
        transport.enqueue(path: "/v3/kv/range", json: Gateway.range([]))
        await tabs.restore(TabsSnapshot(entries: [.init(key: a, modRevision: 5, format: nil)]), from: connection)
        #expect(tabs.tabs[0].changedSinceLastSession)
        guard case .missing = tabs.tabs[0].value.state else {
            Issue.record("expected missing, got \(tabs.tabs[0].value.state)")
            return
        }
    }

    @Test("The snapshot records keys, loaded revisions, and view modes, never content")
    func snapshotContents() async throws {
        let connection = try await connectedModel(transport)
        await open([a], connection)
        tabs.selected?.value.format = .hex
        let snapshot = tabs.snapshot
        #expect(snapshot == TabsSnapshot(entries: [.init(key: a, modRevision: 1, format: .hex)], selected: a))
        let decoded = try JSONDecoder().decode(TabsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
    }
}
