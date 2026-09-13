//
//  NewKeySheet.swift
//  Etcetera
//

import EtcdSchema
import EtceteraCore
import SwiftUI

/// Creates a key. The write compares createRevision == 0, so an existing
/// key is refused rather than overwritten. See SPEC 4.5.
struct NewKeySheet: View {
    var connection: ConnectionModel
    var onCreated: (Data) -> Void

    @State private var key: String
    @State private var value = ""
    @State private var errorMessage: String?
    @State private var check: SchemaCheck?
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    init(connection: ConnectionModel, initialKey: String, onCreated: @escaping (Data) -> Void) {
        self.connection = connection
        self.onCreated = onCreated
        _key = State(initialValue: initialKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Key")
                .font(.headline)
            TextField("Key", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            TextEditor(text: $value)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            if let mappingNote {
                Text(mappingNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .mismatch(let reason)? = check {
                Label("Does not match the message: \(reason)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || isCreating)
                    .help("Create the key; an existing key is not replaced")
            }
        }
        .padding(20)
        .frame(minWidth: 480)
        .task(id: "\(key)\n\(value)") {
            // Once typing pauses.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            check = await connection.checkValue(value, forKey: Data(key.utf8))
        }
    }

    private var mappingNote: String? {
        switch connection.mapping(forKey: Data(key.utf8)) {
        case .unmapped: nil
        case .mapped(let message, _): String(
                localized: "Keys here hold \(message) messages. The value is saved as you enter it and checked against the message.")
        case .misconfigured(_, let reason): reason
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let keyData = Data(key.utf8)
        Task {
            defer { isCreating = false }
            do {
                try await connection.createKey(keyData, text: value)
                onCreated(keyData)
                dismiss()
            } catch {
                errorMessage = ConnectionModel.message(for: error)
            }
        }
    }
}
