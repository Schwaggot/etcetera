//
//  KeyTableView.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI

/// What the key table lists: a tree node, or a server-side prefix scan
/// offered by the search field.
enum TableSource: Hashable {
    case allKeys
    case node(String)
    case prefixScan(String)
    case search(String)
}

/// The keys under the selected tree node, with columns for key, size,
/// revision, and lease. See SPEC 4.1.
struct KeyTableView: View {
    var connection: ConnectionModel
    var source: TableSource?
    @Binding var selectedKey: Data?
    /// A rename or duplicate finished, with the new key.
    var onNamed: (KeyNameTarget, Data) -> Void

    @State private var model = KeyTableModel()
    @State private var deleteTarget: DeleteTarget?
    @State private var liveRefresh: Task<Void, Never>?
    @State private var copyError: String?
    @State private var nameTarget: KeyNameTarget?
    @State private var exportRequest: ExportRequest?

    var body: some View {
        if source == nil {
            // No empty table behind it: its placeholder rows read as loading.
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.left",
                description: Text("Select a node in the key tree."))
        } else {
            table
        }
    }

    private var table: some View {
        KeyTable(
            rows: model.rows, selection: $selectedKey, sortOrder: $model.sortOrder,
            separator: connection.separatorCharacter,
            showsNames: connection.namesKeys,
            onCopyValue: { key in
                Task { copyError = await Clipboard.copyValue(of: key, from: connection) }
            },
            onNameAction: { key, action in
                let below = key + Data(String(connection.separatorCharacter).utf8)
                nameTarget = KeyNameTarget(
                    key: key, action: action, hasChildren: model.rows.contains { $0.id.starts(with: below) })
            },
            onExport: { exportRequest = $0 },
            onDelete: { key in
                deleteTarget = DeleteTarget(key: key, subtreePrefix: nil)
            })
        // Rows still arriving would move under the pointer.
        .disabled(model.isFilling)
        .alert(
            "Could Not Copy the Value",
            isPresented: Binding(get: { copyError != nil }, set: { if !$0 { copyError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(copyError ?? "")
        }
        .sheet(item: $nameTarget) { target in
            KeyNameSheet(connection: connection, target: target) { named in
                onNamed(target, named)
            }
        }
        .keyExporter($exportRequest, connection: connection)
        .deleteConfirmation($deleteTarget, connection: connection) { plan in
            if selectedKey == plan.key { selectedKey = nil }
            if let key = String(data: plan.key, encoding: .utf8) {
                Task { await connection.reload(path: connection.parentPath(of: key)) }
            }
        }
        .onChange(of: connection.writeCount) {
            Task { await model.reload(from: connection) }
        }
        .onChange(of: connection.namingChangeCount) {
            Task { await model.reload(from: connection) }
        }
        .onChange(of: connection.changeCount) {
            // Live updates arrive in bursts; one reload per quiet moment.
            liveRefresh?.cancel()
            liveRefresh = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.reload(from: connection)
            }
        }
        .overlay { emptyState }
        .task(id: source) {
            selectedKey = nil
            switch source {
            case .allKeys:
                await model.loadAll(from: connection)
            case .node(let path):
                await model.load(path: path, from: connection)
                // A node with a value of its own opens it, sparing a second
                // click in the table.
                let own = Data(path.utf8)
                if !Task.isCancelled, !path.isEmpty, model.rows.contains(where: { $0.id == own }) {
                    selectedKey = own
                }
            case .prefixScan(let prefix):
                await model.scan(prefix: prefix, from: connection)
            case .search(let query):
                await model.search(query, from: connection)
            case nil:
                await model.load(path: nil, from: connection)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isFilling && !model.rows.isEmpty {
            fillingOverlay
        } else if model.isLoading && model.rows.isEmpty {
            ProgressView()
        } else if let message = model.errorMessage {
            ContentUnavailableView(
                "Load Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message))
        } else if model.rows.isEmpty, case .search(let query) = source {
            ContentUnavailableView(
                "No Matches",
                systemImage: "magnifyingglass",
                description: Text("No key or name contains \"\(query)\"."))
        } else if model.rows.isEmpty {
            ContentUnavailableView(
                "No Keys",
                systemImage: "key",
                description: Text("There are no keys under this prefix."))
        }
    }

    /// Dims the rows loaded so far and takes the clicks until the last page.
    private var fillingOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.background.opacity(0.6))
            VStack(spacing: 8) {
                ProgressView()
                Text("\(model.rows.count) keys loaded")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
        .transition(.opacity)
    }
}
