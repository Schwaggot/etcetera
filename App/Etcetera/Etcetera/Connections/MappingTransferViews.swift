//
//  MappingTransferViews.swift
//  Etcetera
//

import EtcdSchema
import EtceteraCore
import SwiftUI

/// A profile's mappings as JSON, to copy or save.
struct ExportMappingsView: View {
    let mappings: [SchemaMappingRule]
    let connectionName: String

    var body: some View {
        TransferExportView(
            title: String(localized: "Export Mappings"),
            export: Result { try MappingTransfer.export(mappings) },
            defaultFilename: connectionName.isEmpty
                ? String(localized: "Mappings") : String(localized: "\(connectionName) Mappings"),
            copyHelp: "Copy the mappings as JSON", saveHelp: "Save the mappings as a JSON file")
    }
}

/// Mappings from a mappings or connection export, added to the current
/// ones or replacing them.
struct ImportMappingsView: View {
    var onImport: (_ mappings: [SchemaMappingRule], _ replacing: Bool) -> Void

    var body: some View {
        TransferImportView(
            title: "Import Mappings", dropPrompt: "Drop exported mappings or a connection file here",
            pasteHelp: "Paste exported mappings", openHelp: "Open exported mappings or a connection file",
            clearHelp: "Start over with other mappings", parse: MappingTransfer.parse
        ) { mappings in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(mappings.count) mappings")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(mappings.enumerated()), id: \.offset) { _, rule in
                            MappingRuleLabel(rule: rule)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        } actions: { mappings, complete in
            Button("Replace All") {
                if let mappings { complete { onImport(mappings, true) } }
            }
            .disabled(mappings == nil)
            .help("Use these mappings instead of the current ones")
            Button("Add") {
                if let mappings { complete { onImport(mappings, false) } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(mappings == nil)
            .help("Add these mappings; one with the same pattern replaces the current one")
        }
    }
}

/// A rule on one line, such as "Prefix /config/ -> app.Config".
struct MappingRuleLabel: View {
    let rule: SchemaMappingRule

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if case .prefix = rule.pattern { Text("Prefix") } else { Text("Key") }
            }
            .foregroundStyle(.secondary)
            Text(verbatim: rule.pattern.text)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(verbatim: rule.message)
            if let nameField = rule.nameField {
                Text("named by \(nameField)")
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }
}
