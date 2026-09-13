import CryptoKit
import Foundation

@testable import EtcdSchema

/// Loads the committed fixtures produced by Tools/make-schema-fixtures.sh.
enum Fixtures {
    static let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    /// Every message fixture; each has .txtpb, .bin, and .decoded.txt files
    /// and a golden/<name>.json projection.
    static let messageNames = [
        "scalars", "scalars_extremes", "scalars_empty", "nested", "maps", "repeated",
        "oneof_text", "oneof_number", "oneof_message", "optionals", "legacy",
        "wellknown", "unresolved_any", "record_new",
    ]

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: root.appending(path: path))
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    static func registry() throws -> SchemaRegistry {
        try SchemaRegistry(descriptorSet: data("schema.pb"))
    }

    static func codec() throws -> ProtobufValueCodec {
        ProtobufValueCodec(registry: try registry())
    }

    static func bytes(_ name: String) throws -> Data {
        try data("messages/\(name).bin")
    }

    /// The type named on the fixture's "# proto-message:" line.
    static func messageType(_ name: String) throws -> String {
        let source = try text("messages/\(name).txtpb")
        for line in source.split(separator: "\n") where line.hasPrefix("# proto-message: ") {
            return String(line.dropFirst("# proto-message: ".count))
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    /// Whether the fixture was encoded with a newer schema than schema.pb.
    static func usesNewerSchema(_ name: String) throws -> Bool {
        try text("messages/\(name).txtpb").contains("# schema: protos-new")
    }
}

/// The repository root, for tools such as the pinned protoc.
enum Repository {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // EtcdSchemaTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    static let protoc = root.appending(path: "Tools/protoc/bin/protoc")
    static let protocChecksum = root.appending(path: "Tools/protoc/protoc.sha256")
    static let googleapis = root.appending(path: "Tools/googleapis")

    static var hasProtoc: Bool {
        FileManager.default.isExecutableFile(atPath: protoc.path)
    }

    /// The vendored protoc, once it matches its recorded checksum; hashed
    /// once per run. See SPEC 6.1.
    static func verifiedProtoc() throws -> URL {
        try protocVerification.get()
    }

    private static let protocVerification = Result { try verify(protoc, against: protocChecksum) }

    static func verify(_ binary: URL, against checksumFile: URL) throws -> URL {
        let expected = try String(contentsOf: checksumFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = SHA256.hash(data: try Data(contentsOf: binary, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw ChecksumMismatch(file: binary.path, expected: expected, actual: actual)
        }
        return binary
    }

    struct ChecksumMismatch: Error, CustomStringConvertible {
        let file: String
        let expected: String
        let actual: String

        var description: String {
            "\(file) does not match its recorded checksum (expected \(expected), got \(actual)). "
                + "Run Tools/protoc/fetch-protoc.sh."
        }
    }
}

/// A unique temporary directory removed when the value is discarded.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory, create: true)
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A seeded SplitMix64 generator so fuzz runs are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Prints a decoded message the way `protoc --decode` does, so protoc's
/// output can serve as the reference for our decoder.
enum TextFormat {
    static func render(_ message: DynamicMessage, registry: SchemaRegistry, level: Int = 0) -> String {
        var output = ""
        let pad = String(repeating: "  ", count: level)
        for field in message.descriptor.fieldsByNumber {
            for value in message.value(forField: field.number)?.values ?? [] {
                if case .message(let nested) = value {
                    output += "\(pad)\(field.name) {\n"
                    output += render(nested, registry: registry, level: level + 1)
                    output += "\(pad)}\n"
                } else {
                    output += "\(pad)\(field.name): \(scalar(value, field: field, registry: registry))\n"
                }
            }
        }
        return output
    }

    static func scalar(_ value: DynamicValue, field: FieldDescriptor, registry: SchemaRegistry) -> String {
        switch value {
        case .int32(let x): return String(x)
        case .int64(let x): return String(x)
        case .uint32(let x): return String(x)
        case .uint64(let x): return String(x)
        case .float(let x): return ProtoJSONMapper.format(x)
        case .double(let x): return ProtoJSONMapper.format(x)
        case .bool(let x): return x ? "true" : "false"
        case .enumeration(let x):
            return registry.enumeration(named: field.typeName ?? "")?.name(for: x) ?? String(x)
        case .string(let x): return cEscape(Data(x.utf8))
        case .bytes(let x): return cEscape(x)
        case .message: return ""
        }
    }

    /// protoc's CEscape: named escapes, printable ASCII as is, octal otherwise.
    static func cEscape(_ data: Data) -> String {
        var output = "\""
        for byte in data {
            switch byte {
            case 0x0A: output += "\\n"
            case 0x0D: output += "\\r"
            case 0x09: output += "\\t"
            case 0x22: output += "\\\""
            case 0x27: output += "\\'"
            case 0x5C: output += "\\\\"
            case 0x20..<0x7F: output.append(Character(UnicodeScalar(byte)))
            default: output += String(format: "\\%03o", byte)
            }
        }
        return output + "\""
    }
}
