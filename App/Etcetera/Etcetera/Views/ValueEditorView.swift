//
//  ValueEditorView.swift
//  Etcetera
//

import EtcdKit
import EtcdSchema
import EtceteraCore
import SwiftUI

/// The detail pane: the tab bar over the selected tab's editor.
struct ValueDetailView: View {
    var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.tabs.isEmpty {
                TabBarView(workspace: workspace)
                Divider()
            }
            if let tab = workspace.tabs.selected {
                ValueEditorView(connection: workspace.connection, tab: tab)
                    .id(tab.key)
            } else {
                ContentUnavailableView(
                    "No Key Selected",
                    systemImage: "doc.text",
                    description: Text("Select a key to open it in a tab."))
            }
        }
    }
}

/// One tab's value: a format switcher over the editor, with the guarded
/// save and the conflict sheet. See SPEC 4.3 to 4.5.
struct ValueEditorView: View {
    var connection: ConnectionModel
    var tab: ValueTab

    @AppStorage("editor.softWrap") private var softWrap = true
    @AppStorage("editor.showsInspector") private var showsInspector = false

    private var model: ValueModel { tab.value }

    var body: some View {
        content
            .sheet(isPresented: conflictPresented) {
                ConflictSheet(model: model, connection: connection)
            }
            .inspector(isPresented: $showsInspector) {
                HistoryInspector(connection: connection, model: model)
                    .inspectorColumnWidth(min: 260, ideal: 320)
            }
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: {
                if case .conflict = model.saveState { return true }
                return false
            },
            set: { presented in
                if !presented { model.cancelConflict() }
            })
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            ContentUnavailableView(
                "Key Not Found",
                systemImage: "questionmark.circle",
                description: Text("\(tab.title) does not exist."))
        case .failed(let message):
            ContentUnavailableView(
                "Load Failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .loaded(let kv):
            VStack(spacing: 0) {
                header(for: kv)
                banners(for: kv)
                Divider()
                valueBody(for: kv)
                Divider()
                footer(for: kv)
            }
        }
    }

    private func header(for kv: KeyValue) -> some View {
        @Bindable var model = model
        return HStack {
            NamedKeyText(name: connection.displayNames[kv.key], key: displayString(for: kv.key))
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if model.isDirty {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Format", selection: $model.format) {
                ForEach(model.availableFormats) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How the value is shown")
            Button {
                copy(kv)
            } label: {
                headerIcon("doc.on.doc")
            }
            // A protobuf value that did not decode shows nothing to copy.
            .disabled(model.format == .protobuf && model.protobuf == nil)
            .help("Copy the value as shown")
            MenuButton(items: [
                .action(String(localized: "Format JSON"), { model.formatJSON() }),
                .action(String(localized: "Minify JSON"), { model.minifyJSON() }),
                .separator,
                .toggle(String(localized: "Soft Wrap"), isOn: softWrap, { softWrap = $0 }),
            ]) {
                headerIcon("text.alignleft")
            }
            .disabled(!model.isEditable)
            .help("Formatting")
            Button("Save") {
                Task { await model.save(to: connection) }
            }
            .disabled(!model.isDirty || !model.isEditable || isSaving)
            .help("Write your edits to etcd")
            Toggle(isOn: $showsInspector) {
                headerIcon("clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .help("Inspector and history")
        }
        .padding(10)
    }

    /// Buttons size to their content, and symbols differ in height, so every
    /// header icon gets the tallest one's frame.
    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(minWidth: 18, minHeight: 18)
    }

    /// Copies what the current format shows, unsaved edits included.
    private func copy(_ kv: KeyValue) {
        let text: String
        switch model.format {
        case .hex:
            text = hexString(kv.value)
        case .protobuf:
            guard model.protobuf != nil else { return }
            text = model.text
        default:
            text = model.isEditable ? model.text : String(decoding: kv.value, as: UTF8.self)
        }
        Clipboard.copy(text)
    }

    @ViewBuilder
    private func banners(for kv: KeyValue) -> some View {
        if let problem = model.schemaProblem {
            Banner(systemImage: "exclamationmark.triangle", text: Text("Schema mapping problem: \(problem)")) {
                EmptyView()
            }
        }
        if case .mismatch(let reason)? = model.schemaCheck, let message = model.mappedMessage {
            Banner(systemImage: "exclamationmark.triangle", text: Text("Does not match \(message): \(reason)")) {
                EmptyView()
            }
            .help("The value is saved as typed; this is only a warning")
        }
        if let error = model.protobufError, model.format == .protobuf {
            let text =
                if let message = model.mappedMessage {
                    Text("Not a valid \(message): \(error)")
                } else {
                    Text("Not a valid message: \(error)")
                }
            Banner(systemImage: "xmark.octagon", text: text) {
                Button("Show Hex") { model.format = .hex }
                    .help("Show the stored bytes")
            }
        }
        if let reason = model.readOnlyReason {
            Banner(systemImage: "lock", text: Text(reason)) {
                EmptyView()
            }
        }
        if tab.changedSinceLastSession {
            Banner(systemImage: "exclamationmark.circle", text: Text("This value changed since your last session.")) {
                Button("Dismiss") { tab.acknowledgeChange() }
                    .help("Hide this notice")
            }
        }
        if model.isLarge && !model.isEditable {
            Banner(
                systemImage: "doc.badge.ellipsis",
                text: Text("This value is \(formatByteSize(kv.value.count)) and opened read-only.")
            ) {
                Button("Load Into Editor") { model.openInEditor() }
                    .help("Edit the whole value, which can be slow for large values")
            }
        }
    }

    @ViewBuilder
    private func valueBody(for kv: KeyValue) -> some View {
        @Bindable var model = model
        if model.format == .hex {
            HexInspectorView(data: kv.value)
        } else if model.format == .protobuf {
            if model.protobuf != nil {
                CodeEditorView(text: $model.text, isEditable: model.isEditable, wrapsLines: softWrap, language: .json)
            } else {
                ContentUnavailableView(
                    "Cannot Decode", systemImage: "xmark.octagon", description: Text(model.protobufError ?? ""))
            }
        } else if model.isEditable {
            CodeEditorView(
                text: $model.text, isEditable: true, wrapsLines: softWrap,
                language: model.format == .json ? .json : .plainText)
        } else {
            CodeEditorView(
                text: .constant(String(decoding: kv.value, as: UTF8.self)), isEditable: false,
                wrapsLines: softWrap, language: .plainText)
        }
    }

    private var isSaving: Bool {
        if case .saving = model.saveState { return true }
        return false
    }

    private func footer(for kv: KeyValue) -> some View {
        HStack(spacing: 16) {
            metadataItem("Create", String(kv.createRevision))
            metadataItem("Mod", String(kv.modRevision))
            metadataItem("Version", String(kv.version))
            metadataItem("Lease", kv.lease == 0 ? String(localized: "none", comment: "No lease on the key") : String(kv.lease, radix: 16))
            Spacer()
            saveStatus
            if model.isStoredAsJSON, let message = model.mappedMessage {
                metadataItem("Message", message)
                    .help("The value is checked against this message and saved as typed")
            }
            if let report = model.protobuf?.roundTrip {
                metadataItem("Encoded", String(localized: "\(report.originalLength) / \(report.reencodedLength) bytes"))
                    .help("Stored length, and the length after re-encoding the unchanged message")
            }
            sizeItem(kv.value.count)
        }
        .font(.caption)
        .padding(8)
    }

    @ViewBuilder
    private var saveStatus: some View {
        switch model.saveState {
        case .saving:
            ProgressView()
                .controlSize(.mini)
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        case .idle, .conflict:
            EmptyView()
        }
    }

    /// The readable size, then the exact count once they differ.
    private func sizeItem(_ bytes: Int) -> some View {
        HStack(spacing: 4) {
            Text("Size")
                .foregroundStyle(.secondary)
            if bytes < 1000 {
                Text("\(bytes) bytes")
                    .monospacedDigit()
            } else {
                Text(formatByteSize(bytes))
                    .monospacedDigit()
                Text("(\(bytes) bytes)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metadataItem(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
    }
}

/// The read-only byte inspector with offsets and an ASCII gutter. The dump
/// is built once per value, off the view update.
struct HexInspectorView: View {
    var data: Data
    @State private var dump: String?

    var body: some View {
        Group {
            if let dump {
                CodeEditorView(text: .constant(dump), isEditable: false, wrapsLines: false, language: .plainText)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: data) {
            let data = data
            dump = await Task.detached { HexDump.render(data) }.value
        }
    }
}

struct Banner<Actions: View>: View {
    var systemImage: String
    var text: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            text
            Spacer()
            actions
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
    }
}
