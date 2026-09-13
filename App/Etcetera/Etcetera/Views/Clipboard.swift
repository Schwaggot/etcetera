//
//  Clipboard.swift
//  Etcetera
//

import AppKit
import EtceteraCore
import SwiftUI

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Fetches and copies a key's value; returns why it failed, if it did.
    static func copyValue(of key: Data, from connection: ConnectionModel) async -> String? {
        do {
            copy(try await connection.clipboardValue(forKey: key))
            return nil
        } catch {
            return ConnectionModel.message(for: error)
        }
    }
}

/// The Copy submenu of a tree node's context menu; the table builds the
/// same one in AppKit. See SPEC 4.1.
struct CopyKeyMenu: View {
    var key: Data
    var separator: Character
    var hasValue: Bool
    var copyValue: () -> Void

    var body: some View {
        let parts = KeyParts(key, separator: separator)
        Menu("Copy") {
            Button("Prefix + Key") { Clipboard.copy(parts.full) }
            Button("Prefix") { Clipboard.copy(parts.prefix) }
                .disabled(parts.prefix.isEmpty)
            Button("Key") { Clipboard.copy(parts.name) }
                .disabled(parts.name.isEmpty)
            Button("Value", action: copyValue)
                .disabled(!hasValue)
        }
    }
}
