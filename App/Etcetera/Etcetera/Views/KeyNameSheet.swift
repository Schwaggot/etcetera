//
//  KeyNameSheet.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI

enum KeyNameAction {
    case rename
    case duplicate
}

/// A key to rename or duplicate.
struct KeyNameTarget: Identifiable {
    var key: Data
    var action: KeyNameAction
    /// Keys below it are neither moved nor copied; the sheet says so.
    var hasChildren: Bool
    var id: Data { key }
}

/// Asks for the new key of a rename or duplicate. An existing key is only
/// overwritten after asking. See SPEC 4.5.
struct KeyNameSheet: View {
    var connection: ConnectionModel
    var target: KeyNameTarget
    var onDone: (Data) -> Void

    @State private var newKey: String
    @State private var errorMessage: String?
    @State private var isWorking = false
    /// The mod revision of the existing key the user is asked to overwrite.
    @State private var existing: Int64?
    @Environment(\.dismiss) private var dismiss

    init(connection: ConnectionModel, target: KeyNameTarget, onDone: @escaping (Data) -> Void) {
        self.connection = connection
        self.target = target
        self.onDone = onDone
        let key = String(decoding: target.key, as: UTF8.self)
        _newKey = State(initialValue: target.action == .rename ? key : key + "-copy")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.action == .rename ? String(localized: "Rename Key") : String(localized: "Duplicate Key"))
                .font(.headline)
            TextField("New key", text: $newKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if target.hasChildren {
                Text(
                    target.action == .rename
                        ? String(localized: "Only this key is renamed. The keys below it keep their names.")
                        : String(localized: "Only this key is duplicated. The keys below it are not copied.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.action == .rename ? String(localized: "Rename") : String(localized: "Duplicate")) {
                    run(replacing: 0)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newKey.isEmpty || Data(newKey.utf8) == target.key || isWorking)
                .help(
                    target.action == .rename
                        ? String(localized: "Move the value and lease to the new key")
                        : String(localized: "Copy the value and lease to the new key"))
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .confirmationDialog(
            "\"\(newKey)\" already exists.",
            isPresented: Binding(get: { existing != nil }, set: { if !$0 { existing = nil } })
        ) {
            // Captured now; dismissing the dialog clears `existing`.
            Button("Overwrite", role: .destructive) { [existing] in
                if let existing { run(replacing: existing) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Overwriting replaces its current value.")
        }
    }

    private func run(replacing: Int64) {
        isWorking = true
        errorMessage = nil
        let named = Data(newKey.utf8)
        Task {
            defer { isWorking = false }
            do {
                let outcome: KeyCopyOutcome
                if target.action == .rename {
                    outcome = try await connection.renameKey(target.key, to: named, replacing: replacing)
                } else {
                    outcome = try await connection.duplicateKey(target.key, to: named, replacing: replacing)
                }
                switch outcome {
                case .done:
                    onDone(named)
                    dismiss()
                case .targetExists(let revision):
                    existing = revision
                }
            } catch {
                errorMessage = ConnectionModel.message(for: error)
            }
        }
    }
}
