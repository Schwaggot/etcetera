//
//  KeyExport.swift
//  Etcetera
//

import EtceteraCore
import SwiftUI
import UniformTypeIdentifiers

/// What to export: one key's value, or everything below a folder.
struct ExportRequest: Identifiable {
    enum Scope {
        case key(Data)
        case subtree(prefix: String, name: String)
    }

    var scope: Scope
    var format: ExportFormat
    let id = UUID()
}

extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .json: .json
        case .text: .plainText
        case .raw: .data
        }
    }
}

/// A prepared export: one file, or a folder of files.
nonisolated struct ExportDocument: FileDocument {
    enum Content {
        case file(Data)
        case folder([ExportedFile])
    }

    static let readableContentTypes: [UTType] = [.data, .folder]
    var content: Content

    init(content: Content) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch content {
        case .file(let data): FileWrapper(regularFileWithContents: data)
        case .folder(let files): Self.folder(files)
        }
    }

    private static func folder(_ files: [ExportedFile]) -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        // By path, since a clashing name gets renamed when it is added.
        var directories: [[String]: FileWrapper] = [[]: root]
        for file in files {
            var parent = root
            for depth in 1..<file.path.count {
                let path = Array(file.path.prefix(depth))
                if let existing = directories[path] {
                    parent = existing
                } else {
                    let directory = FileWrapper(directoryWithFileWrappers: [:])
                    directory.preferredFilename = path.last
                    parent.addFileWrapper(directory)
                    directories[path] = directory
                    parent = directory
                }
            }
            let leaf = FileWrapper(regularFileWithContents: file.contents)
            leaf.preferredFilename = file.path.last
            parent.addFileWrapper(leaf)
        }
        return root
    }
}

/// The Export submenu of a tree node: its own value and, for a folder,
/// everything below it. The table builds the key part in AppKit.
struct ExportKeyMenu: View {
    var node: KeyNode
    var connection: ConnectionModel
    var onExport: (ExportRequest) -> Void

    var body: some View {
        Menu("Export") {
            if node.isLeaf {
                Section("Key") {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button("As \(format.title)...") {
                            onExport(ExportRequest(scope: .key(Data(node.path.utf8)), format: format))
                        }
                    }
                }
            }
            if node.hasChildren {
                Section("Folder") {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Button("As \(format.title) Files...") {
                            let name = node.name.isEmpty ? "export" : exportFileName(node.name)
                            onExport(
                                ExportRequest(
                                    scope: .subtree(prefix: connection.childPrefix(for: node.path), name: name),
                                    format: format))
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// Reads what `request` names, then asks where to save it.
    func keyExporter(_ request: Binding<ExportRequest?>, connection: ConnectionModel) -> some View {
        modifier(KeyExporter(request: request, connection: connection))
    }
}

private struct KeyExporter: ViewModifier {
    struct Notice {
        var title: String
        var message: String
    }

    @Binding var request: ExportRequest?
    var connection: ConnectionModel

    @State private var document: ExportDocument?
    @State private var filename = ""
    @State private var contentType: UTType = .data
    @State private var isSaving = false
    @State private var isPreparing = false
    @State private var skipped = 0
    @State private var notice: Notice?

    func body(content: Content) -> some View {
        content
            .task(id: request?.id) { await prepare() }
            .overlay {
                if isPreparing {
                    ProgressView("Reading values...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .fileExporter(
                isPresented: $isSaving, document: document, contentType: contentType, defaultFilename: filename
            ) { result in
                document = nil
                switch result {
                case .success where skipped > 0:
                    notice = Notice(
                        title: String(localized: "\(skipped) Keys Were Not Exported"),
                        message: String(localized: "Their values are too large to read through the etcd gateway."))
                case .success:
                    break
                case .failure(let error):
                    notice = Notice(title: String(localized: "Export Failed"), message: error.localizedDescription)
                }
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notice?.message ?? "")
            }
    }

    private func prepare() async {
        guard let request else { return }
        isPreparing = true
        defer {
            isPreparing = false
            self.request = nil
        }
        do {
            switch request.scope {
            case .key(let key):
                let data = try await connection.exportKey(key, as: request.format)
                document = ExportDocument(content: .file(data))
                filename =
                    exportPath(for: key, under: Data(), separator: connection.separatorCharacter, format: request.format)
                    .last ?? "value"
                contentType = request.format.contentType
                skipped = 0
            case .subtree(let prefix, let name):
                let export = try await connection.exportSubtree(prefix: prefix, as: request.format)
                document = ExportDocument(content: .folder(export.files))
                filename = name
                contentType = .folder
                skipped = export.skipped.count
            }
            isSaving = true
        } catch {
            notice = Notice(title: String(localized: "Export Failed"), message: ConnectionModel.message(for: error))
        }
    }
}
