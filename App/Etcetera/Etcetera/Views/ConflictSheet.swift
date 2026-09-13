//
//  ConflictSheet.swift
//  Etcetera
//

import EtcdKit
import EtceteraCore
import SwiftUI

/// Shown when a save finds the key changed since it was loaded: a diff and
/// the three ways out. Nothing is ever written blind. See SPEC 4.5.
struct ConflictSheet: View {
    var model: ValueModel
    var connection: ConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This key changed since you loaded it")
                .font(.headline)
            Text(explanation)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Label("In etcd now", systemImage: "minus.square")
                    .foregroundStyle(.red)
                Label("Your edits", systemImage: "plus.square")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.conflictDiff.enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(6)
            }
            .frame(minHeight: 200, maxHeight: 420)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Cancel", role: .cancel) { model.cancelConflict() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Discard My Edits") { model.discardLocalEdits() }
                    .help("Drop your edits and show the value now stored")
                Button("Merge") { model.openMerge() }
                    .disabled(current == nil)
                    .help("Open both versions in the editor with conflict markers")
                Button("Overwrite") {
                    Task { await model.overwrite(to: connection) }
                }
                .keyboardShortcut(.defaultAction)
                .help("Save your edits over the value now stored")
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680)
    }

    private var current: KeyValue? {
        if case .conflict(let current) = model.saveState { return current }
        return nil
    }

    private var explanation: String {
        // Revisions as String, so they are not digit-grouped.
        let loaded = String(model.loaded?.modRevision ?? 0)
        guard let current else {
            return String(localized: "The key was deleted after you loaded revision \(loaded). Overwrite recreates it.")
        }
        return String(localized: "Revision \(String(current.modRevision)) was written after you loaded revision \(loaded).")
    }
}

struct DiffLineView: View {
    var line: DiffLine

    var body: some View {
        Text(marker + line.text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(line.kind == .unchanged ? 0 : 0.12))
    }

    private var marker: String {
        switch line.kind {
        case .unchanged: "  "
        case .deleted: "- "
        case .inserted: "+ "
        }
    }

    private var color: Color {
        switch line.kind {
        case .unchanged: .primary
        case .deleted: .red
        case .inserted: .green
        }
    }
}
