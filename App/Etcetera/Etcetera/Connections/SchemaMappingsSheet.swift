//
//  SchemaMappingsSheet.swift
//  Etcetera
//

import EtcdSchema
import EtceteraCore
import SwiftUI

/// Edits a copy of a profile's key-to-message mappings; Done hands the
/// rules back to the connection editor, whose Save stores them. See SPEC 5.5.
struct SchemaMappingsSheet: View {
    /// Names the export file.
    var connectionName: String
    /// The compiled schema, when the profile is the live connection.
    var registry: SchemaRegistry?
    var testMapping: MappingTester?
    var onDone: ([SchemaMappingRule]) -> Void

    @State private var rows: [Row]
    @State private var testKey = ""
    @State private var testResult: MappingTestResult?
    @State private var isTesting = false
    @State private var isExporting = false
    @State private var isImporting = false
    @Environment(\.dismiss) private var dismiss

    /// A stable identity, so a row's fields follow it when another is removed.
    private struct Row: Identifiable {
        let id = UUID()
        var rule: SchemaMappingRule
    }

    init(
        mappings: [SchemaMappingRule], connectionName: String, registry: SchemaRegistry?,
        testMapping: MappingTester?,
        onDone: @escaping ([SchemaMappingRule]) -> Void
    ) {
        self.connectionName = connectionName
        self.registry = registry
        self.testMapping = testMapping
        self.onDone = onDone
        _rows = State(initialValue: mappings.map { Row(rule: $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if rows.isEmpty {
                        Text("No mappings yet. Add one to decode matching keys as a protobuf message.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        mappingRow(binding(for: row))
                    }
                    Button("Add Mapping") {
                        rows.append(Row(rule: SchemaMappingRule(.prefix(""), message: "")))
                    }
                    .help("Decode the values of matching keys as a protobuf message")
                }
                Section("Test") {
                    if let testMapping {
                        HStack {
                            TextField("Key", text: $testKey, prompt: Text(verbatim: "/registry/pods/default/web"))
                                .onSubmit { runTest(testMapping) }
                            Button("Test") { runTest(testMapping) }
                                .disabled(testKey.isEmpty || isTesting)
                                .help("Show which mapping the key uses and decode its value with it")
                        }
                        testOutcome
                    } else {
                        Text("Connect with this profile to complete message names and test mappings.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Import...") { isImporting = true }
                    .help("Add mappings from an export or a connection file")
                Button("Export...") { isExporting = true }
                    .disabled(exportable.isEmpty)
                    .help("Copy or save these mappings as JSON")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    onDone(rows.map(\.rule))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .help("Keep these mappings; saving the connection stores them")
            }
            .padding(12)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 420, idealHeight: 520)
        .onChange(of: rows.map(\.rule)) { testResult = nil }
        .onChange(of: testKey) { testResult = nil }
        .sheet(isPresented: $isExporting) {
            ExportMappingsView(mappings: exportable, connectionName: connectionName)
        }
        .sheet(isPresented: $isImporting) {
            ImportMappingsView { imported, replacing in
                if replacing {
                    rows = imported.map { Row(rule: $0) }
                } else {
                    add(imported)
                }
            }
        }
    }

    @ViewBuilder
    private var testOutcome: some View {
        if isTesting {
            ProgressView()
                .controlSize(.small)
        } else {
            switch testResult {
            case .unmapped?:
                Text("No mapping matches this key, so its value shows with the format guess.")
                    .foregroundStyle(.secondary)
            case .decoded(let rule, let json)?:
                matched(rule)
                Text(json)
                    .font(.caption.monospaced())
                    .lineLimit(12)
                    .textSelection(.enabled)
            case .failed(let rule, let reason)?:
                matched(rule)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            case nil:
                Text("Enter a key to see which mapping it uses and how its value decodes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func matched(_ rule: SchemaMappingRule) -> some View {
        HStack(spacing: 6) {
            Text("Uses")
            MappingRuleLabel(rule: rule)
        }
    }

    /// Tests the rules as edited, not as saved.
    private func runTest(_ test: @escaping MappingTester) {
        guard !testKey.isEmpty, !isTesting else { return }
        let key = testKey
        let rules = rows.map(\.rule)
        isTesting = true
        Task {
            let result = await test(key, rules)
            isTesting = false
            // Edits during the test leave the result out of date.
            if key == testKey, rules == rows.map(\.rule) { testResult = result }
        }
    }

    /// Rows still missing a message would not import again.
    private var exportable: [SchemaMappingRule] {
        rows.map(\.rule).filter { !$0.message.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func add(_ imported: [SchemaMappingRule]) {
        // Merging keeps existing rules at their index, so rows keep their identity.
        let merged = MappingTransfer.merge(imported, into: rows.map(\.rule))
        for (index, rule) in merged.enumerated() {
            if index < rows.count {
                if rows[index].rule != rule { rows[index] = Row(rule: rule) }
            } else {
                rows.append(Row(rule: rule))
            }
        }
    }

    private func mappingRow(_ row: Binding<Row>) -> some View {
        HStack {
            Picker("Match", selection: isPrefix(row)) {
                Text("Prefix").tag(true)
                Text("Key").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .help("Match every key starting with the pattern, or only the exact key")
            TextField("Pattern", text: pattern(row), prompt: Text(verbatim: "/registry/pods/"))
            TextField("Message", text: row.rule.message, prompt: Text(verbatim: "package.Message"))
            TextField("Name field", text: nameField(row), prompt: Text("Name field"))
                .frame(maxWidth: 130)
                .help("Optional: a field of the value, such as name or info.name, whose text labels the key")
            if let registry {
                // An icon-only Menu comes out shorter than the buttons beside it.
                MenuButton(
                    items: MessageCompletion.suggestions(for: row.wrappedValue.rule.message, in: registry).map {
                        name in .action(name, { row.wrappedValue.rule.message = name })
                    }
                ) {
                    Image(systemName: "text.magnifyingglass")
                        .frame(minWidth: 18, minHeight: 18)
                }
                .help("Message types in the schema")
            }
            Button(role: .destructive) {
                rows.removeAll { $0.id == row.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this mapping")
        }
    }

    /// Looks the row up by id: an index-based binding outlives a removed last
    /// row for one more read and traps.
    private func binding(for row: Row) -> Binding<Row> {
        Binding(
            get: { rows.first { $0.id == row.id } ?? row },
            set: { new in
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = new }
            })
    }

    private func isPrefix(_ row: Binding<Row>) -> Binding<Bool> {
        Binding(
            get: {
                if case .prefix = row.wrappedValue.rule.pattern { return true }
                return false
            },
            set: { isPrefix in
                let text = row.wrappedValue.rule.pattern.text
                row.wrappedValue.rule.pattern = isPrefix ? .prefix(text) : .key(text)
            })
    }

    /// Empty means no name field.
    private func nameField(_ row: Binding<Row>) -> Binding<String> {
        Binding(
            get: { row.wrappedValue.rule.nameField ?? "" },
            set: { text in
                let field = text.trimmingCharacters(in: .whitespaces)
                row.wrappedValue.rule.nameField = field.isEmpty ? nil : field
            })
    }

    private func pattern(_ row: Binding<Row>) -> Binding<String> {
        Binding(
            get: { row.wrappedValue.rule.pattern.text },
            set: { text in
                switch row.wrappedValue.rule.pattern {
                case .prefix: row.wrappedValue.rule.pattern = .prefix(text)
                case .key: row.wrappedValue.rule.pattern = .key(text)
                }
            })
    }
}
