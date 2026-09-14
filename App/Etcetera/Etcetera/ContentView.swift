import AppKit
import EtceteraCore
import Foundation
import SwiftUI

/// The three-pane shell: connection and key tree, key table, value tabs.
/// See SPEC 4.1.
struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var isCreatingKey = false
    @State private var showsLeases = false
    @AppStorage("editor.showsInspector") private var showsInspector = false
    @AppStorage("editor.historyWidth") private var historyWidth: Double = 320

    private static let sidebarMinWidth: CGFloat = 220
    private static let tableMinWidth: CGFloat = 300
    /// The header with all four formats, and the footer untruncated.
    private static let editorMinWidth: CGFloat = 460
    private static let inspectorMinWidth: CGFloat = 260
    private static let dividerWidth: CGFloat = 1

    /// The value column: the editor, and the history beside it when shown.
    private static func detailMinWidth(inspector: Bool) -> CGFloat {
        editorMinWidth + (inspector ? dividerWidth + inspectorMinWidth : 0)
    }

    /// The sidebar overlays the table, so only the table has a divider.
    private static func minWidth(inspector: Bool) -> CGFloat {
        sidebarMinWidth + tableMinWidth + dividerWidth + detailMinWidth(inspector: inspector)
    }

    /// Only beside a tab; the setting survives closing the last one.
    private var isInspectorShown: Bool { showsInspector && workspace.tabs.selected != nil }

    /// The editor keeps its minimum in a value column this wide.
    private func historyWidthRange(in columnWidth: CGFloat) -> ClosedRange<CGFloat> {
        Self.inspectorMinWidth...max(Self.inspectorMinWidth, columnWidth - Self.editorMinWidth - Self.dividerWidth)
    }

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView {
            SidebarView(workspace: workspace, selection: $workspace.selectedSource)
                .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 280)
        } content: {
            KeyTableView(
                connection: workspace.connection, source: workspace.selectedSource,
                selectedKey: $workspace.selectedKey,
                onNamed: { target, new in workspace.keyNamed(target, to: new) }
            )
            .navigationSplitViewColumnWidth(min: Self.tableMinWidth, ideal: 400)
        } detail: {
            // Not `.inspector`, whose column overlaps the content's safe area: a minimum width here grows
            // with the inspector, and dragging its divider loops on constraints until AppKit aborts. Not
            // `HSplitView` either, which keeps the history's width after the history closes.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ValueDetailView(workspace: workspace)
                        .frame(maxWidth: .infinity)
                    if isInspectorShown, let tab = workspace.tabs.selected {
                        let range = historyWidthRange(in: proxy.size.width)
                        HistoryResizeHandle(width: $historyWidth, range: range)
                        HistoryInspector(connection: workspace.connection, model: tab.value)
                            .id(tab.key)
                            .frame(width: min(max(CGFloat(historyWidth), range.lowerBound), range.upperBound))
                    }
                }
            }
            // Fixed, so resizing the history never moves the split view's minimums.
            .frame(minWidth: Self.detailMinWidth(inspector: isInspectorShown), maxWidth: .infinity)
        }
        // Every column fits at its minimum, so none collapses or cramps.
        .frame(minWidth: Self.minWidth(inspector: isInspectorShown), minHeight: 500)
        .onChange(of: isInspectorShown) { _, shown in
            // SwiftUI raises the minimum but leaves a narrower window as it is, which clips
            // the outer columns. A sheet can be key, such as New Key opening the first tab.
            guard shown, let key = NSApp.keyWindow else { return }
            let window = key.sheetParent ?? key
            // Resizing inside a view update is not allowed.
            Task { window.widenContent(to: Self.minWidth(inspector: true)) }
        }
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

/// The divider before the history; dragging it resizes the history.
private struct HistoryResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<CGFloat>
    @State private var startWidth: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        // Global, because the handle moves with the drag.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = startWidth ?? min(max(CGFloat(width), range.lowerBound), range.upperBound)
                                startWidth = start
                                width = Double(min(max(start - drag.translation.width, range.lowerBound), range.upperBound))
                            }
                            .onEnded { _ in startWidth = nil })
            }
            // Above the history, which would take the half of the grip that overlaps it.
            .zIndex(1)
    }
}

private extension NSWindow {
    /// Widens the window to `width` points of content, staying on its screen.
    func widenContent(to width: CGFloat) {
        let current = contentRect(forFrameRect: frame)
        guard current.width < width else { return }
        var target = frameRect(
            forContentRect: NSRect(origin: current.origin, size: NSSize(width: width, height: current.height)))
        if let visible = screen?.visibleFrame {
            // Grows to the right, moving left where the screen ends.
            target.origin.x = max(visible.minX, min(target.minX, visible.maxX - target.width))
        }
        setFrame(target, display: true, animate: true)
    }
}

#Preview {
    ContentView()
}
