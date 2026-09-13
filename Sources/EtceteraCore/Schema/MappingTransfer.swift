import EtcdSchema
import Foundation

/// A profile's key mappings as portable JSON, like a connection export. The
/// schema folder stays behind; its bookmark resolves only on the Mac that
/// made it. See SPEC 5.5.
public enum MappingTransfer {
    static let version = 1

    public static func export(_ mappings: [SchemaMappingRule]) throws -> String {
        let file = MappingFile(format: "etcetera-mappings", version: version, mappings: mappings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(file), as: UTF8.self)
    }

    /// Reads a mappings export, or the mappings of a connection export.
    public static func parse(_ text: String) throws -> [SchemaMappingRule] {
        let data = Data(text.utf8)
        let decoder = JSONDecoder()
        let mappings: [SchemaMappingRule]
        do {
            let file = try decoder.decode(MappingFile.self, from: data)
            if let written = file.version, written > version { throw newerVersion }
            mappings = file.mappings
        } catch let error as MappingImportError {
            throw error
        } catch {
            guard let connection = try? decoder.decode(TransferFile.self, from: data) else {
                throw MappingImportError(
                    reason: String(
                        localized: "These are not etcetera mappings: \(ConnectionTransfer.detail(error))", bundle: .module))
            }
            if let written = connection.version, written > ConnectionTransfer.version { throw newerVersion }
            mappings = connection.connection.schemaMappings ?? []
        }
        guard !mappings.isEmpty else {
            throw MappingImportError(reason: String(localized: "The file has no mappings.", bundle: .module))
        }
        if let index = mappings.firstIndex(where: { $0.message.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw MappingImportError(
                reason: String(localized: "Mapping \(index + 1) has no message.", bundle: .module))
        }
        return mappings
    }

    /// `imported` added to `existing`; an imported mapping whose pattern is
    /// already there replaces that mapping in place.
    public static func merge(_ imported: [SchemaMappingRule], into existing: [SchemaMappingRule]) -> [SchemaMappingRule] {
        var merged = existing
        for rule in imported {
            if let index = merged.firstIndex(where: { $0.pattern == rule.pattern }) {
                merged[index] = rule
            } else {
                merged.append(rule)
            }
        }
        return merged
    }

    private static var newerVersion: MappingImportError {
        MappingImportError(
            reason: String(localized: "The mappings were exported by a newer version of etcetera.", bundle: .module))
    }
}

public struct MappingImportError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
}

struct MappingFile: Codable {
    var format: String?
    var version: Int?
    var mappings: [SchemaMappingRule]
}
