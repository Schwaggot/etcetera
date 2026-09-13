import EtcdSchema
import Foundation

/// How exported values are written to files. See SPEC 4.1.
public enum ExportFormat: String, CaseIterable, Sendable {
    case json
    case text
    case raw

    public var title: String {
        switch self {
        case .json: String(localized: "JSON", bundle: .module, comment: "Export format")
        case .text: String(localized: "Text", bundle: .module, comment: "Export format")
        case .raw: String(localized: "Raw Bytes", bundle: .module, comment: "Export format")
        }
    }

    public var fileExtension: String {
        switch self {
        case .json: "json"
        case .text: "txt"
        case .raw: "bin"
        }
    }
}

/// One exported file: its path below the export's folder, and its contents.
public struct ExportedFile: Equatable, Sendable {
    public let path: [String]
    public let contents: Data
}

/// A folder export, and the keys left out because their values were too
/// large for the gateway.
public struct SubtreeExport: Sendable {
    public let files: [ExportedFile]
    public let skipped: [Data]
}

/// A file name for one key segment. "%" and "/" are percent-escaped, since a
/// separator other than "/" leaves "/" inside segments. A leading "." is
/// escaped so nothing is hidden and "." and ".." stay files; an empty segment
/// becomes "%00".
public func exportFileName(_ segment: String) -> String {
    guard !segment.isEmpty else { return "%00" }
    var name = segment.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    if name.hasPrefix(".") { name = "%2E" + name.dropFirst() }
    return name
}

/// Where a key's file goes below an exported folder: a directory per
/// segment, and the last segment with the format's extension, so a key and
/// the keys below it never collide.
public func exportPath(for key: Data, under prefix: Data, separator: Character, format: ExportFormat) -> [String] {
    let rest = displayString(for: Data(key.dropFirst(prefix.count)))
    var names = rest.split(separator: separator, omittingEmptySubsequences: false).map { exportFileName(String($0)) }
    names[names.count - 1] += "." + format.fileExtension
    return names
}

extension ConnectionModel {
    /// A value as an exported file's contents. JSON decodes a mapped protobuf
    /// value and pretty-prints a JSON value; anything else becomes a JSON
    /// string. Text is what Copy Value gives, and raw is the bytes.
    public func exportContents(of value: Data, key: Data, as format: ExportFormat) -> Data {
        switch format {
        case .raw: value
        case .text: Data(clipboardText(for: value).utf8)
        case .json: Data(jsonText(of: value, key: key).utf8)
        }
    }

    private func jsonText(of value: Data, key: Data) -> String {
        if case .mapped(let message, _) = mapping(forKey: key), !MessageCheck.isJSONObject(value),
            let registry = schemaRegistry,
            let decoded = try? ProtobufValueCodec(registry: registry).decodeToJSON(value, messageName: message)
        {
            return decoded.json
        }
        // The formatter also formats invalid JSON, so it only gets valid JSON.
        if (try? JSONSerialization.jsonObject(with: value, options: .fragmentsAllowed)) != nil {
            return JSONFormatter().prettyPrint(String(decoding: value, as: UTF8.self))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(clipboardText(for: value))) ?? Data(), as: UTF8.self)
    }

    /// One key's value as a file's contents.
    public func exportKey(_ key: Data, as format: ExportFormat) async throws -> Data {
        guard let kv = try await value(forKey: key) else { throw KeyNotFoundError(key: key) }
        return exportContents(of: kv.value, key: key, as: format)
    }

    /// Every key below `prefix`, as files in one folder.
    public func exportSubtree(prefix: String, as format: ExportFormat) async throws -> SubtreeExport {
        let prefixData = Data(prefix.utf8)
        var files: [ExportedFile] = []
        var skipped: [Data] = []
        var cursor: Data?
        var more = true
        while more {
            let page = try await valuePage(under: prefix, after: cursor)
            for kv in page.kvs {
                if page.withoutValues.contains(kv.key) {
                    skipped.append(kv.key)
                    continue
                }
                let path = exportPath(for: kv.key, under: prefixData, separator: separatorCharacter, format: format)
                files.append(ExportedFile(path: path, contents: exportContents(of: kv.value, key: kv.key, as: format)))
            }
            cursor = page.kvs.last?.key
            more = page.more && cursor != nil
        }
        return SubtreeExport(files: files, skipped: skipped)
    }
}
