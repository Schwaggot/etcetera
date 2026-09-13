//
//  Workspace.swift
//  Etcetera
//

import AppKit
import EtceteraCore
import Foundation
import Observation
import SwiftUI

/// One window's state: saved connections, the live connection, its value
/// tabs, and the selection. Published to menu commands as a focused scene
/// value.
@Observable
final class Workspace {
    enum PendingAction {
        case connect(ConnectionProfile)
        case disconnect
    }

    let profiles: ProfilesModel
    let connection: ConnectionModel
    let tabs = TabsModel()
    var selectedProfileID: String?
    var selectedSource: TableSource?
    var selectedKey: Data?
    /// A dirty tab the user asked to close; the window asks first.
    var pendingClose: Data?
    /// A switch that would drop unsaved edits; the window asks first.
    var pendingAction: PendingAction?
    /// The schema folder changed on disk since the last compile.
    var schemaFilesChanged = false
    /// Logs key names in the clear; for this window's session only.
    var verboseLogging = false

    /// Whose tabs are shown; nil while switching.
    private var tabsOwner: String?
    private var watcher: SchemaFolderWatcher?

    init() {
        let secrets = KeychainSecretStore()
        profiles = ProfilesModel(store: ProfileStore(directory: ProfileStore.applicationSupport), secrets: secrets)
        connection = ConnectionModel(
            secrets: secrets, files: SecurityScopedFileAccess(), schemaLoader: AppSchemaLoader())
        profiles.load()
        let last = UserDefaults.standard.string(forKey: Self.lastProfileKey)
        selectedProfileID = last.flatMap { profiles.profile(withID: $0)?.id } ?? profiles.profiles.first?.id
    }

    var selectedProfile: ConnectionProfile? {
        selectedProfileID.flatMap { profiles.profile(withID: $0) }
    }

    // MARK: Connecting

    /// One connection at a time: switching tears the current one down, and
    /// unsaved edits block it until confirmed. See SPEC 4.1.
    func requestConnect() {
        guard let profile = selectedProfile else { return }
        UserDefaults.standard.set(profile.id, forKey: Self.lastProfileKey)
        if tabs.hasUnsavedChanges {
            pendingAction = .connect(profile)
        } else {
            Task { await connect(profile) }
        }
    }

    func requestDisconnect() {
        if tabs.hasUnsavedChanges {
            pendingAction = .disconnect
        } else {
            disconnect()
        }
    }

    func confirmPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case .connect(let profile): Task { await connect(profile) }
        case .disconnect: disconnect()
        }
    }

    private func connect(_ profile: ConnectionProfile) async {
        // Before the first await, so no old tab can be saved into the new cluster.
        selectedSource = nil
        selectedKey = nil
        tabsOwner = nil
        tabs.closeAll()
        await connection.connect(to: profile)
        if case .failed(let message) = connection.phase {
            AppLog.event("Connection failed: \(message)", verbose: verboseLogging)
        } else {
            AppLog.event("Connected, etcd \(connection.serverVersion ?? "unknown")", verbose: verboseLogging)
        }
    }

    private func disconnect() {
        selectedSource = nil
        selectedKey = nil
        tabsOwner = nil
        tabs.closeAll()
        watcher = nil
        schemaFilesChanged = false
        connection.disconnect()
    }

    /// A saved profile edit reaches the live connection's schema at once.
    func profileSaved(_ profile: ConnectionProfile) async {
        selectedProfileID = profile.id
        guard connection.profile?.id == profile.id else { return }
        await connection.profileChanged(profile)
        await reinterpretTabs()
        watchSchemaFolder()
    }

    // MARK: Schema

    /// Recompiles the schema, then re-decodes every tab without edits.
    func refreshSchema() async {
        schemaFilesChanged = false
        await connection.loadSchema(force: true)
        await reinterpretTabs()
    }

    private func reinterpretTabs() async {
        for tab in tabs.tabs {
            await tab.value.schemaChanged(on: connection)
        }
    }

    private func watchSchemaFolder() {
        watcher = nil
        schemaFilesChanged = false
        guard let source = connection.profile?.schema.source else { return }
        watcher = SchemaFolderWatcher(reference: source) { [weak self] in
            Task { @MainActor in self?.schemaFilesChanged = true }
        }
    }

    // MARK: Tabs

    func saveSelected() async {
        guard let tab = tabs.selected else { return }
        await tab.value.save(to: connection)
        AppLog.event("Save finished for", key: tab.key, verbose: verboseLogging)
    }

    func requestClose(_ key: Data) {
        if tabs.close(key) == .needsConfirmation {
            pendingClose = key
        }
    }

    /// After a rename or duplicate the new key opens. A renamed key's clean
    /// tab closes; one with edits stays, and saving it reports the old key
    /// as deleted.
    func keyNamed(_ target: KeyNameTarget, to new: Data) {
        var changed = [new]
        if target.action == .rename {
            let old = target.key
            if let tab = tabs.tabs.first(where: { $0.key == old }), !tab.value.isDirty {
                tabs.close(old)
            }
            if case .node(let path)? = selectedSource, Data(path.utf8) == old {
                selectedSource = .node(String(decoding: new, as: UTF8.self))
            }
            changed.append(old)
        }
        selectedKey = new
        let parents = Set(changed.map { connection.parentPath(of: String(decoding: $0, as: UTF8.self)) })
        Task {
            for path in parents { await connection.reload(path: path) }
        }
    }

    /// Closes the selected tab, or the window when there is none.
    func closeSelectedTab() {
        guard let key = tabs.selectedKey else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        requestClose(key)
    }

    /// Tabs belong to a connection: connecting swaps them for the ones saved
    /// for it, restored by key. See SPEC 4.1.
    func connectionChanged() async {
        guard connection.isConnected, let owner = tabsOwnerKey, tabsOwner != owner else { return }
        watchSchemaFolder()
        tabsOwner = nil
        tabs.closeAll()
        let session = connection.session
        if let data = UserDefaults.standard.data(forKey: "tabs.\(owner)"),
            let snapshot = try? JSONDecoder().decode(TabsSnapshot.self, from: data)
        {
            await tabs.restore(snapshot, from: connection)
        }
        // A restore outlived by a reconnect must not claim the new connection's tabs.
        guard connection.session == session else { return }
        tabsOwner = owner
    }

    func persist(_ snapshot: TabsSnapshot) {
        guard let tabsOwner, let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: "tabs.\(tabsOwner)")
    }

    private var tabsOwnerKey: String? {
        guard let profile = connection.profile else { return nil }
        return profile.id.isEmpty ? profile.endpoint : profile.id
    }

    private static let lastProfileKey = "lastProfile"
    static let connectOnLaunchKey = "connectOnLaunch"

    func connectOnLaunchIfWanted() {
        guard !connection.isConnected else { return }
        // UI tests name an endpoint at launch; saved profiles stay untouched.
        if let endpoint = UserDefaults.standard.string(forKey: "uiTestEndpoint") {
            Task { await connect(ConnectionProfile(id: "", name: "UI test", endpoint: endpoint, watchEnabled: false)) }
            return
        }
        guard UserDefaults.standard.bool(forKey: Self.connectOnLaunchKey) else { return }
        requestConnect()
    }
}

extension FocusedValues {
    @Entry var workspace: Workspace?
}
