//
//  HistoryInspector.swift
//  Etcetera
//

import EtcdKit
import EtceteraCore
import SwiftUI

/// The value inspector: metadata, a revision slider over the key's earlier
/// versions, a comparison with the current value, and restore. See SPEC 4.7.
struct HistoryInspector: View {
    var connection: ConnectionModel
    var model: ValueModel

    @State private var history = HistoryModel()
    @State private var comparesWithCurrent = true
    @State private var isConfirmingRestore = false
    @State private var diff: [DiffLine]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let kv = model.loaded {
                metadata(kv)
            }
            Divider()
            Text("History")
                .font(.headline)
            if history.versions.count > 1 {
                Slider(value: sliderPosition, in: 0...Double(history.versions.count - 1), step: 1)
            }
            versionList
            if history.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if history.reachedCompaction {
                Text("Older versions were compacted away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = history.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let selected = history.selected, selected.modRevision != history.versions.first?.modRevision {
                selectedVersion(selected)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .task(id: model.loaded?.modRevision) {
            guard let kv = model.loaded else { return }
            await history.load(kv, from: connection)
        }
        .confirmationDialog(
            "Restore revision \(history.selectedRevision.map(String.init) ?? "")?", isPresented: $isConfirmingRestore
        ) {
            Button("Restore") {
                guard let selected = history.selected else { return }
                Task { await model.restore(selected, to: connection) }
            }
        } message: {
            Text("It is written as a new value, and refused if someone changed the key meanwhile.")
        }
    }

    private func metadata(_ kv: KeyValue) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Create revision", String(kv.createRevision))
            row("Mod revision", String(kv.modRevision))
            row("Version", String(kv.version))
            row("Lease", kv.lease == 0 ? String(localized: "none", comment: "No lease on the key") : String(kv.lease, radix: 16))
        }
        .font(.callout)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    private var versionList: some View {
        @Bindable var history = history
        return List(history.versions, id: \.modRevision, selection: $history.selectedRevision) { kv in
            VStack(alignment: .leading, spacing: 2) {
                // Revisions as String, so they are not digit-grouped.
                if kv.modRevision == history.versions.first?.modRevision {
                    Text("Revision \(String(kv.modRevision)), current")
                } else {
                    Text("Revision \(String(kv.modRevision))")
                }
                Text("Version \(kv.version), \(kv.value.count) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 120, maxHeight: 220)
    }

    @ViewBuilder
    private func selectedVersion(_ selected: KeyValue) -> some View {
        Toggle("Compare with current", isOn: $comparesWithCurrent)
            .help("Show how this version differs from the current value")
        Group {
            if comparesWithCurrent {
                diffView
            } else {
                CodeEditorView(
                    text: .constant(model.renderedText(for: selected.value)), isEditable: false, wrapsLines: true,
                    language: .plainText)
            }
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Diffing large values takes a while, so it runs off the main actor.
        .task(id: [selected.modRevision, history.versions.first?.modRevision ?? 0]) {
            diff = nil
            guard let current = history.versions.first else { return }
            let old = model.renderedText(for: selected.value)
            let new = model.renderedText(for: current.value)
            let lines = await Task.detached { LineDiff.diff(old: old, new: new) }.value
            if !Task.isCancelled { diff = lines }
        }
        Button("Restore This Version...") { isConfirmingRestore = true }
            .disabled(model.isDirty)
            .help(
                model.isDirty
                    ? String(localized: "Save or discard your edits first")
                    : String(localized: "Write this version as the current value"))
    }

    @ViewBuilder
    private var diffView: some View {
        if let diff {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(6)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Oldest at the left, current at the right.
    private var sliderPosition: Binding<Double> {
        Binding(
            get: {
                let index = history.versions.firstIndex { $0.modRevision == history.selectedRevision } ?? 0
                return Double(history.versions.count - 1 - index)
            },
            set: { position in
                let index = history.versions.count - 1 - Int(position.rounded())
                if history.versions.indices.contains(index) {
                    history.selectedRevision = history.versions[index].modRevision
                }
            })
    }
}
