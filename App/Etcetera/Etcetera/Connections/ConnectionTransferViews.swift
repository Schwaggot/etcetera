//
//  ConnectionTransferViews.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI
import UniformTypeIdentifiers

/// One connection as JSON, to copy or save.
struct ExportConnectionView: View {
    let profile: ConnectionProfile

    var body: some View {
        TransferExportView(
            title: String(localized: "Export \(profile.name)"),
            export: Result { try ConnectionTransfer.export(profile) },
            defaultFilename: profile.name,
            copyHelp: "Copy the connection as JSON", saveHelp: "Save the connection as a JSON file",
            note: "The password, passphrase and access to certificate and schema files are not included. After an import, enter the password and pick the files again."
        )
    }
}

/// A connection from an export, added on confirmation.
struct ImportConnectionView: View {
    var onImport: (ImportedConnection) throws -> Void

    var body: some View {
        TransferImportView(
            title: "Import Connection", dropPrompt: "Drop an exported connection file here",
            pasteHelp: "Paste an exported connection", openHelp: "Open an exported connection file",
            clearHelp: "Start over with another connection", parse: ConnectionTransfer.parse
        ) { connection in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "\(connection.profile.name) - \(connection.profile.endpoint)")
                // A shared file must not turn verification off unnoticed.
                if connection.profile.tls.skipServerVerification {
                    Label(
                        "Server certificate verification is off for this connection.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                }
                if !connection.filesToReselect.isEmpty {
                    Text("Pick these files again with Edit Connection, then enter any passwords:")
                        .padding(.top, 4)
                    ForEach(connection.filesToReselect, id: \.self) { file in
                        Text(file)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } actions: { connection, complete in
            Button("Import") {
                if let connection { complete { try onImport(connection) } }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(connection == nil)
            .help("Add this connection")
        }
    }
}

/// JSON from an export, to copy or save.
struct TransferExportView: View {
    let title: String
    let export: Result<String, any Error>
    let defaultFilename: String
    let copyHelp: LocalizedStringKey
    let saveHelp: LocalizedStringKey
    var note: LocalizedStringKey?
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var copied = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            switch export {
            case .success(let json):
                JSONPreview(text: json)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy to Clipboard")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                        copied = true
                    }
                    .help(copyHelp)
                    Button("Save...") { isSaving = true }
                        .help(saveHelp)
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .fileExporter(
                    isPresented: $isSaving, document: JSONTextDocument(text: json), contentType: .json,
                    defaultFilename: defaultFilename
                ) { result in
                    if case .failure(let error) = result { saveError = error.localizedDescription }
                }
            case .failure(let error):
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Takes an export from a dropped or chosen file or the clipboard, shows
/// what it holds, and hands it on when the user confirms.
struct TransferImportView<Parsed, Summary: View, Actions: View>: View {
    let title: LocalizedStringKey
    let dropPrompt: LocalizedStringKey
    let pasteHelp: LocalizedStringKey
    let openHelp: LocalizedStringKey
    let clearHelp: LocalizedStringKey
    let parse: (String) throws -> Parsed
    @ViewBuilder let summary: (Parsed) -> Summary
    /// The confirming buttons, given the parsed export; `complete` runs one's
    /// action and closes the sheet unless it throws.
    @ViewBuilder let actions: (Parsed?, _ complete: @escaping (() throws -> Void) -> Void) -> Actions
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isTargeted = false
    @State private var isChoosingFile = false
    @State private var loadError: String?

    private var parsed: Result<Parsed, any Error>? {
        text.isEmpty ? nil : Result { try parse(text) }
    }

    private var parsedValue: Parsed? {
        if case .success(let value)? = parsed { value } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            dropArea
            HStack {
                Button("Paste from Clipboard") { paste() }
                    .keyboardShortcut("v", modifiers: .command)
                    .help(pasteHelp)
                Button("Open File...") { isChoosingFile = true }
                    .help(openHelp)
                if !text.isEmpty {
                    Button("Clear") { text = "" }
                        .help(clearHelp)
                }
            }
            outcome
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                actions(parsedValue, complete)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.json, .plainText]) { result in
            switch result {
            case .success(let url): load(url)
            case .failure(let error): loadError = error.localizedDescription
            }
        }
    }

    private var dropArea: some View {
        Group {
            if text.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.largeTitle)
                    Text(dropPrompt)
                    Text("or paste its contents from the clipboard.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JSONPreview(text: text)
            }
        }
        .frame(height: 260)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: text.isEmpty ? [6, 4] : []))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private var outcome: some View {
        if let loadError {
            Text(loadError)
                .foregroundStyle(.red)
        } else if let parsed {
            switch parsed {
            case .success(let value):
                summary(value)
                    .font(.callout)
            case .failure(let error):
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
            }
        }
    }

    private func complete(_ action: () throws -> Void) {
        do {
            try action()
            dismiss()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func paste() {
        let pasteboard = NSPasteboard.general
        if let url = pasteboard.readObjects(forClasses: [NSURL.self])?.first as? URL, url.isFileURL {
            load(url)
        } else if let string = pasteboard.string(forType: .string) {
            loadError = nil
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func load(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // An export is a few kilobytes; anything this big is the wrong file.
            guard size <= 5_000_000 else {
                loadError = String(localized: "\(url.lastPathComponent) is too large to be an etcetera export.")
                return
            }
            text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            loadError = nil
        } catch {
            loadError = String(localized: "\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
    }
}

private struct JSONPreview: View {
    let text: String

    var body: some View {
        // Vertical only: a two-axis scroll view centers narrow content.
        ScrollView(.vertical) {
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 260)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

nonisolated struct JSONTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
