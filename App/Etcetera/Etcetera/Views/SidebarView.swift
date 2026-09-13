//
//  SidebarView.swift
//  Etcetera
//

import EtcdSchema
import EtceteraCore
import SwiftUI

/// Connection controls above the lazily loaded key tree. See SPEC 4.1.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    @Binding var selection: TableSource?
    @State private var query = ""
    @State private var search = ServerKeySearch()
    @State private var deleteTarget: DeleteTarget?
    @State private var editingProfile: ConnectionProfile?
    @State private var isDeletingProfile = false
    @State private var isImporting = false
    @State private var exportingProfile: ConnectionProfile?
    @State private var profileError: String?
    @State private var copyError: String?
    @State private var nameTarget: KeyNameTarget?
    @State private var exportRequest: ExportRequest?

    private var connection: ConnectionModel { workspace.connection }

    /// Connected or connecting: the bar must name that cluster, whatever is selected.
    private var isAttached: Bool {
        connection.isConnected || connection.phase == .connecting
    }

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            tree
        }
        .sheet(item: $editingProfile) { profile in
            editor(for: profile)
        }
        .sheet(isPresented: $isImporting) {
            ImportConnectionView { imported in
                let added = try workspace.profiles.importConnection(imported)
                if !isAttached { workspace.selectedProfileID = added.id }
            }
        }
        .sheet(item: $exportingProfile) { profile in
            ExportConnectionView(profile: profile)
        }
        .sheet(item: $nameTarget) { target in
            KeyNameSheet(connection: connection, target: target) { named in
                workspace.keyNamed(target, to: named)
            }
        }
        .keyExporter($exportRequest, connection: connection)
        .alert(
            "Could Not Delete the Connection",
            isPresented: Binding(get: { profileError != nil }, set: { if !$0 { profileError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(profileError ?? "")
        }
        .alert(
            "Could Not Copy the Value",
            isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(copyError ?? "")
        }
        .confirmationDialog(deleteProfileTitle, isPresented: $isDeletingProfile) {
            Button("Delete Connection", role: .destructive) { deleteSelectedProfile() }
        } message: {
            Text("Its saved password and passphrase are removed from the Keychain too.")
        }
    }

    private var deleteProfileTitle: Text {
        if let name = workspace.selectedProfile?.name {
            Text("Delete \(name)?")
        } else {
            Text("Delete this connection?")
        }
    }

    /// Completion and mapping tests need the compiled schema, so they are
    /// offered only for the live connection's profile.
    private func editor(for profile: ConnectionProfile) -> ConnectionEditorView {
        let isLive = connection.isConnected && connection.profile?.id == profile.id
        var tester: MappingTester?
        if isLive {
            let connection = connection
            tester = { key, rules in await connection.testMapping(key: key, rules: rules) }
        }
        return ConnectionEditorView(
            profile: profile, profiles: workspace.profiles,
            registry: isLive ? connection.schemaRegistry : nil, testMapping: tester
        ) { saved in
            Task { await workspace.profileSaved(saved) }
        }
    }

    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // One pop-up for choosing and managing connections, like Xcode's scheme menu.
                Menu {
                    Picker("Connection", selection: $workspace.selectedProfileID) {
                        ForEach(workspace.profiles.profiles) { profile in
                            Text(profile.name).tag(String?(profile.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(isAttached)
                    if !workspace.profiles.profiles.isEmpty { Divider() }
                    Button("New Connection...") { editingProfile = workspace.profiles.newProfile() }
                    Button("Edit Connection...") { editingProfile = workspace.selectedProfile }
                        .disabled(workspace.selectedProfile == nil)
                    Button("Delete Connection...", role: .destructive) { isDeletingProfile = true }
                        .disabled(!canDeleteSelectedProfile)
                    Divider()
                    Button("Import Connection...") { isImporting = true }
                    Button("Export Connection...") { exportingProfile = workspace.selectedProfile }
                        .disabled(workspace.selectedProfile == nil)
                } label: {
                    if let name = (isAttached ? connection.profile : workspace.selectedProfile)?.name {
                        Text(name)
                    } else {
                        Text("No Connections")
                    }
                }
                .fixedSize()
                .help("Choose or manage connections")
                switch connection.phase {
                case .disconnected, .failed:
                    Button("Connect") { connect() }
                        .disabled(workspace.selectedProfile == nil)
                        .help("Connect to the chosen connection")
                case .connecting:
                    ProgressView()
                        .controlSize(.small)
                        .help("Connecting...")
                case .connected:
                    Button("Disconnect") { workspace.requestDisconnect() }
                        .help("Disconnect from the cluster")
                }
            }
            // Below the row, which has no room for it next to Disconnect.
            if connection.isConnected {
                HStack(spacing: 8) {
                    if let version = connection.serverVersion {
                        Text("etcd \(version)")
                    }
                    schemaBadge
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                schemaProblems
            }
            if connection.isConnected && connection.skipsServerVerification {
                Label("Server certificate verification is off.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let message = workspace.profiles.loadError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if case .failed(let message) = connection.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let message = connection.lastError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        // Full width, or the sidebar centers the bar.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    /// Files protoc rejected; the rest of the schema works without them.
    private var skippedSchemaFiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(connection.skippedSchemaFiles.count) files left out", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("protoc rejected these files or files they import, so their types are not available")
            ScrollView {
                Text(connection.skippedSchemaFiles.map { "\($0.path): \($0.reason)" }.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        }
    }

    /// Whether values can decode as protobuf; Value > Refresh Schema compiles again.
    @ViewBuilder
    private var schemaBadge: some View {
        switch connection.schemaState {
        case .compiling:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Compiling schema...")
            }
        case .ready(let registry):
            Label {
                Text(verbatim: "Protobuf")
            } icon: {
                Image(systemName: "curlybraces")
            }
            .help("\(registry.allMessageNames.count) message types. Refresh Schema in the Value menu compiles the schema again.")
        case .notConfigured, .failed:
            EmptyView()
        }
    }

    /// Compile problems; protoc's output verbatim.
    @ViewBuilder
    private var schemaProblems: some View {
        switch connection.schemaState {
        case .notConfigured, .compiling:
            EmptyView()
        case .ready:
            if !connection.skippedSchemaFiles.isEmpty {
                skippedSchemaFiles
                    .font(.caption)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("The schema did not compile", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await workspace.refreshSchema() } }
                        .buttonStyle(.link)
                        .help("Compile the schema again")
                }
                ScrollView {
                    Text(message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
            .font(.caption)
        }
        if workspace.schemaFilesChanged {
            HStack(spacing: 6) {
                Text("Schema files changed.")
                    .foregroundStyle(.secondary)
                Button("Recompile") { Task { await workspace.refreshSchema() } }
                    .buttonStyle(.link)
                    .help("Compile the changed schema files")
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var tree: some View {
        if connection.isConnected {
            List(selection: $selection) {
                if query.isEmpty {
                    let top = connection.topNode
                    Label("All Keys", systemImage: "tray.full")
                        .tag(TableSource.allKeys)
                    ForEach(connection.displayedChildren(of: top)) { node in
                        KeyNodeRow(
                            connection: connection, node: node, onCopyValue: copyValue, onNameAction: requestName,
                            onExport: { exportRequest = $0 }, onDelete: requestDelete)
                    }
                    if top.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    searchResults
                }
            }
            .listStyle(.sidebar)
            // A live update can create the unnamed top node before it has loaded.
            .task(id: ObjectIdentifier(connection.topNode)) {
                let top = connection.topNode
                if top.children == nil { await connection.loadChildren(of: top) }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search keys and names")
            .task(id: SearchRequest(query: query, session: connection.session, writes: connection.writeCount)) {
                // Waits for a pause in typing.
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                await search.search(query, in: connection)
            }
            .deleteConfirmation($deleteTarget, connection: connection) { plan in
                guard let path = String(data: plan.key, encoding: .utf8) else { return }
                if case .node(let selected)? = selection,
                    selected == path || selected.hasPrefix(connection.childPrefix(for: path))
                {
                    selection = nil
                }
                Task { await connection.reload(path: connection.parentPath(of: path)) }
            }
        } else {
            ContentUnavailableView(
                "Not Connected",
                systemImage: "bolt.slash",
                description: Text("Choose a connection and connect to browse the keyspace."))
            // Fills the sidebar, which keeps the connection bar at the top.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        Label("All keys containing \"\(query)\"", systemImage: "magnifyingglass")
            .tag(TableSource.search(query))
            .help("Show every match in the table")
        if KeySearch.looksLikeKeyPath(query, separator: connection.separatorCharacter) {
            Label("Keys starting with \"\(query)\"", systemImage: "magnifyingglass")
                .tag(TableSource.prefixScan(query))
                .help("Scan the server for every key with this prefix")
        }
        Section("Matches") {
            ForEach(search.hits) { hit in
                Label {
                    NamedKeyText(name: connection.displayNames[Data(hit.path.utf8)], key: hit.path)
                } icon: {
                    Image(systemName: KeyNodeRow.icon(isLeaf: hit.isKey, hasChildren: hit.isFolder))
                }
                    .tag(TableSource.node(hit.path))
            }
            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if let message = search.errorMessage {
                Text(message)
                    .foregroundStyle(.secondary)
            } else if search.query == query, search.hits.isEmpty {
                Text("No key or name contains \"\(query)\".")
                    .foregroundStyle(.secondary)
            } else if search.total > search.hits.count {
                Text("Showing the first \(search.hits.count) of \(search.total) matches.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the search reruns on: the query, a reconnect, and writes made here.
    private struct SearchRequest: Equatable {
        var query: String
        var session: Int
        var writes: Int
    }

    private func connect() {
        query = ""
        workspace.requestConnect()
    }

    /// The connection in use cannot be deleted; disconnect first.
    private var canDeleteSelectedProfile: Bool {
        guard let id = workspace.selectedProfile?.id else { return false }
        return !(isAttached && connection.profile?.id == id)
    }

    private func deleteSelectedProfile() {
        // A connect can finish while the confirmation is open.
        guard canDeleteSelectedProfile, let id = workspace.selectedProfileID else { return }
        do {
            try workspace.profiles.delete(id)
            workspace.selectedProfileID = workspace.profiles.profiles.first?.id
        } catch {
            profileError = error.localizedDescription
            workspace.profiles.load()
        }
    }

    private func requestName(_ node: KeyNode, _ action: KeyNameAction) {
        nameTarget = KeyNameTarget(key: Data(node.path.utf8), action: action, hasChildren: node.hasChildren)
    }

    private func copyValue(_ key: Data) {
        Task { copyError = await Clipboard.copyValue(of: key, from: connection) }
    }

    private func requestDelete(_ node: KeyNode) {
        deleteTarget = DeleteTarget(
            key: Data(node.path.utf8),
            subtreePrefix: node.hasChildren ? connection.childPrefix(for: node.path) : nil)
    }
}

/// One tree row. Branches expand lazily: the first expansion loads the
/// children with a per-node spinner, never a modal sheet. See SPEC 4.2.
struct KeyNodeRow: View {
    var connection: ConnectionModel
    var node: KeyNode
    var onCopyValue: (Data) -> Void
    var onNameAction: (KeyNode, KeyNameAction) -> Void
    var onExport: (ExportRequest) -> Void
    var onDelete: (KeyNode) -> Void
    @State private var isExpanded = false

    var body: some View {
        if node.hasChildren {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(connection.displayedChildren(of: node)) { child in
                    KeyNodeRow(
                        connection: connection, node: child, onCopyValue: onCopyValue, onNameAction: onNameAction,
                        onExport: onExport, onDelete: onDelete)
                }
                if node.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            } label: {
                label
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded, node.children == nil {
                    Task { await connection.loadChildren(of: node) }
                }
            }
        } else {
            label
        }
    }

    private var label: some View {
        Label {
            // Empty segments come from a leading or doubled separator.
            NamedKeyText(
                name: node.isLeaf ? connection.displayNames[Data(node.path.utf8)] : nil,
                key: node.name.isEmpty ? String(localized: "(empty)") : node.name,
                isPlaceholder: node.name.isEmpty)
        } icon: {
            Image(systemName: Self.icon(for: node))
        }
            .tag(TableSource.node(node.path))
            .contextMenu {
                let key = Data(node.path.utf8)
                CopyKeyMenu(key: key, separator: connection.separatorCharacter, hasValue: node.isLeaf) {
                    onCopyValue(key)
                }
                Divider()
                if node.isLeaf {
                    Button("Rename Key...") { onNameAction(node, .rename) }
                    Button("Duplicate Key...") { onNameAction(node, .duplicate) }
                }
                ExportKeyMenu(node: node, connection: connection, onExport: onExport)
                Button(
                    node.hasChildren ? String(localized: "Delete Subtree...") : String(localized: "Delete Key..."),
                    role: .destructive
                ) {
                    onDelete(node)
                }
            }
    }

    static func icon(for node: KeyNode) -> String {
        icon(isLeaf: node.isLeaf, hasChildren: node.hasChildren)
    }

    static func icon(isLeaf: Bool, hasChildren: Bool) -> String {
        // A node can hold a value and have children at the same time.
        if hasChildren && isLeaf { return "doc.on.folder" }
        if hasChildren { return "folder" }
        return "doc.text"
    }
}
