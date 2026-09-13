import EtcdKit
import Foundation
import Observation

/// One open value. Tabs hold values, not connections, and a key has at
/// most one tab. See SPEC 4.1.
@MainActor
@Observable
public final class ValueTab: Identifiable {
    public let key: Data
    public let value = ValueModel()
    /// Restored from a previous session with a different revision, or gone.
    public internal(set) var changedSinceLastSession = false

    public nonisolated var id: Data { key }
    public var title: String { displayString(for: key) }

    init(key: Data) {
        self.key = key
    }

    /// The user has seen that the value changed since the last session.
    public func acknowledgeChange() {
        changedSinceLastSession = false
    }
}

/// What persists across relaunch: keys and view modes, never content, so a
/// reopened tab shows the current value.
public struct TabsSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var key: Data
        public var modRevision: Int64
        public var format: ValueFormat?

        public init(key: Data, modRevision: Int64, format: ValueFormat?) {
            self.key = key
            self.modRevision = modRevision
            self.format = format
        }
    }

    public var entries: [Entry]
    public var selected: Data?

    public init(entries: [Entry] = [], selected: Data? = nil) {
        self.entries = entries
        self.selected = selected
    }
}

@MainActor
@Observable
public final class TabsModel {
    public enum CloseResult: Sendable {
        case closed
        /// The tab has unsaved edits; close again with `force` to drop them.
        case needsConfirmation
    }

    public private(set) var tabs: [ValueTab] = []
    public var selectedKey: Data?

    public init() {}

    public var selected: ValueTab? { tabs.first { $0.key == selectedKey } }
    public var hasUnsavedChanges: Bool { tabs.contains { $0.value.isDirty } }

    /// Selects the key's tab, or adds one and loads the value.
    public func open(_ key: Data, from connection: ConnectionModel) async {
        if tabs.contains(where: { $0.key == key }) {
            selectedKey = key
            return
        }
        let tab = ValueTab(key: key)
        tabs.append(tab)
        selectedKey = key
        await tab.value.load(key: key, from: connection)
    }

    /// Closing the selected tab selects its right neighbor, else the left.
    @discardableResult
    public func close(_ key: Data, force: Bool = false) -> CloseResult {
        guard let index = tabs.firstIndex(where: { $0.key == key }) else { return .closed }
        if tabs[index].value.isDirty && !force { return .needsConfirmation }
        tabs.remove(at: index)
        if selectedKey == key {
            selectedKey = tabs.indices.contains(index) ? tabs[index].key : tabs.last?.key
        }
        return .closed
    }

    public func closeAll() {
        tabs = []
        selectedKey = nil
    }

    public func selectNext() {
        cycle(by: 1)
    }

    public func selectPrevious() {
        cycle(by: -1)
    }

    private func cycle(by step: Int) {
        guard !tabs.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.key == selectedKey }) else {
            selectedKey = (step > 0 ? tabs.first : tabs.last)?.key
            return
        }
        selectedKey = tabs[(index + step + tabs.count) % tabs.count].key
    }

    public var snapshot: TabsSnapshot {
        TabsSnapshot(
            entries: tabs.map {
                TabsSnapshot.Entry(key: $0.key, modRevision: $0.value.loaded?.modRevision ?? 0, format: $0.value.format)
            },
            selected: selectedKey)
    }

    /// Reopens tabs by key and loads current values, flagging any that
    /// changed since the snapshot was taken.
    public func restore(_ snapshot: TabsSnapshot, from connection: ConnectionModel) async {
        tabs = snapshot.entries.map { ValueTab(key: $0.key) }
        selectedKey = snapshot.selected ?? tabs.first?.key
        for (tab, entry) in zip(tabs, snapshot.entries) {
            await tab.value.load(key: tab.key, from: connection)
            if let format = entry.format, tab.value.loaded != nil { tab.value.format = format }
            tab.changedSinceLastSession = tab.value.loaded?.modRevision != entry.modRevision
        }
    }
}
