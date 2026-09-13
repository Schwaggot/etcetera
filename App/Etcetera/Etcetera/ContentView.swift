import EtceteraCore
import Foundation
import SwiftUI

/// The three-pane shell: connection and key tree, key table, value tabs.
/// See SPEC 4.1.
struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var isCreatingKey = false
    @State private var showsLeases = false

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView {
            SidebarView(workspace: workspace, selection: $workspace.selectedSource)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } content: {
            KeyTableView(
                connection: workspace.connection, source: workspace.selectedSource,
                selectedKey: $workspace.selectedKey,
                onNamed: { target, new in workspace.keyNamed(target, to: new) }
            )
            .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            ValueDetailView(workspace: workspace)
        }
        .frame(minWidth: 900, minHeight: 500)
        .focusedSceneValue(\.workspace, workspace)
        .task { workspace.connectOnLaunchIfWanted() }
        .onChange(of: workspace.selectedKey) { _, key in
            guard let key else { return }
            Task { await workspace.tabs.open(key, from: workspace.connection) }
        }
        .onChange(of: workspace.tabs.selectedKey) { _, key in
            workspace.selectedKey = key
        }
        .onChange(of: workspace.tabs.snapshot) { _, snapshot in
            workspace.persist(snapshot)
        }
        .onChange(of: workspace.connection.phase) {
            Task { await workspace.connectionChanged() }
        }
        .navigationSubtitle(subtitle)
        .sheet(isPresented: $showsLeases) {
            LeasesView(connection: workspace.connection)
        }
        .confirmationDialog("Discard unsaved edits?", isPresented: pendingActionPresented, titleVisibility: .visible) {
            Button("Discard Edits", role: .destructive) { workspace.confirmPendingAction() }
            Button("Cancel", role: .cancel) { workspace.pendingAction = nil }
        } message: {
            Text("Open tabs have edits that are not saved. Switching the connection drops them.")
        }
        .alert("Close without saving?", isPresented: closePresented) {
            Button("Don't Save", role: .destructive) {
                if let key = workspace.pendingClose { workspace.tabs.close(key, force: true) }
                workspace.pendingClose = nil
            }
            Button("Cancel", role: .cancel) { workspace.pendingClose = nil }
        } message: {
            Text("Your edits to this value will be lost.")
        }
        .toolbar {
            if workspace.connection.canListLeases {
                ToolbarItem {
                    Button("Leases", systemImage: "timer") { showsLeases = true }
                        .help("Leases and their keys")
                }
            }
            ToolbarItem {
                Button("New Key", systemImage: "plus") { isCreatingKey = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!workspace.connection.isConnected)
                    .help("Create a key")
            }
        }
        .sheet(isPresented: $isCreatingKey) {
            NewKeySheet(connection: workspace.connection, initialKey: newKeyPrefix) { key in
                workspace.selectedKey = key
                if let text = String(data: key, encoding: .utf8) {
                    Task { await workspace.connection.reload(path: workspace.connection.parentPath(of: text)) }
                }
            }
        }
    }

    /// Persistent warnings: verification off, verbose logging on.
    private var subtitle: String {
        var parts: [String] = []
        if workspace.connection.isConnected && workspace.connection.skipsServerVerification {
            parts.append(String(localized: "Certificate verification off"))
        }
        if workspace.verboseLogging {
            parts.append(String(localized: "Verbose logging on"))
        }
        return parts.formatted(.list(type: .and))
    }

    private var pendingActionPresented: Binding<Bool> {
        Binding(
            get: { workspace.pendingAction != nil },
            set: { if !$0 { workspace.pendingAction = nil } })
    }

    private var closePresented: Binding<Bool> {
        Binding(
            get: { workspace.pendingClose != nil },
            set: { if !$0 { workspace.pendingClose = nil } })
    }

    /// New keys start under whatever the table is showing.
    private var newKeyPrefix: String {
        switch workspace.selectedSource {
        case .node(let path): workspace.connection.childPrefix(for: path)
        case .prefixScan(let prefix): prefix
        case .allKeys, .search, nil: ""
        }
    }
}

#Preview {
    ContentView()
}
