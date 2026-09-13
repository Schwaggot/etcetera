import Foundation

// The facade the application calls: protobuf bytes to editable JSON and back,
// behind the safeguards in SPEC 5.6.

/// The no-op check: the unmodified decoded value re-encoded through the same
/// JSON path an edit takes, compared with the original bytes.
public struct RoundTripReport: Sendable, Equatable {
    public let originalLength: Int
    public let reencodedLength: Int
    /// Byte-for-byte identical. When false the editor must be read-only.
    public let isFaithful: Bool
}

public struct DecodedProtobufValue: Sendable {
    public let message: DynamicMessage
    /// Pretty-printed proto3 JSON.
    public let json: String
    public let roundTrip: RoundTripReport
}

/// Runs work on a thread with a large stack. Recursing to the nesting limits
/// overflows a 512 KB worker thread in a debug build, and hostile input
/// reaches those limits.
enum DeepStack {
    /// Virtual size; pages are committed only as recursion touches them.
    static let size = 64 << 20

    private final class Outcome<T>: @unchecked Sendable {
        var result: Result<T, any Error>?
    }

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.result = Result(catching: body)
            done.signal()
        }
        thread.stackSize = size
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
        done.wait()
        return try outcome.result!.get()
    }
}

public struct ProtobufValueCodec: Sendable {
    public let registry: SchemaRegistry
    public let codec: WireCodec

    public init(registry: SchemaRegistry, maxDepth: Int = 100) {
        self.registry = registry
        self.codec = WireCodec(registry: registry, maxDepth: maxDepth)
    }

    private var mapper: ProtoJSONMapper { ProtoJSONMapper(registry: registry, codec: codec) }

    private func descriptor(_ messageName: String) throws -> MessageDescriptor {
        guard let descriptor = registry.message(named: messageName) else {
            throw SchemaError.unknownMessage(messageName)
        }
        return descriptor
    }

    /// Decodes and renders as JSON. Throws on any decode failure rather than
    /// returning a partial message.
    public func decodeToJSON(_ bytes: Data, messageName: String) throws -> DecodedProtobufValue {
        try DeepStack.run {
            let descriptor = try descriptor(messageName)
            let message = try codec.decode(bytes, as: descriptor)
            let json = try mapper.project(message)
            let reencoded = try encode(json: json, descriptor: descriptor, preserving: message)
            let report = RoundTripReport(
                originalLength: bytes.count, reencodedLength: reencoded.count, isFaithful: reencoded == bytes)
            return DecodedProtobufValue(message: message, json: json.rendered(), roundTrip: report)
        }
    }

    /// Encodes edited JSON. Unknown fields from `originalBytes` are re-appended
    /// so a schema that lags the writer does not destroy data. The result is
    /// read back as `decodeToJSON` would, so nothing is saved that cannot be
    /// opened again, such as nesting past the depth limit.
    public func encodeFromJSON(_ json: String, messageName: String, originalBytes: Data?) throws -> Data {
        try DeepStack.run {
            let descriptor = try descriptor(messageName)
            let original = try originalBytes.map { try codec.decode($0, as: descriptor) }
            let encoded = try encode(json: JSONValue.parse(json), descriptor: descriptor, preserving: original)
            do {
                _ = try mapper.project(codec.decode(encoded, as: descriptor))
            } catch {
                throw ProtoJSONError(path: "", reason: String(localized: "the edited value could not be read back: \(String(describing: error))", bundle: .module))
            }
            return encoded
        }
    }

    public func roundTripCheck(_ bytes: Data, messageName: String) throws -> RoundTripReport {
        try decodeToJSON(bytes, messageName: messageName).roundTrip
    }

    /// JSON text for an already decoded message.
    public func json(for message: DynamicMessage) throws -> String {
        try DeepStack.run { try mapper.project(message).rendered() }
    }

    public func message(fromJSON json: String, messageName: String) throws -> DynamicMessage {
        try DeepStack.run { try mapper.parse(JSONValue.parse(json), as: descriptor(messageName)) }
    }

    private func encode(json: JSONValue, descriptor: MessageDescriptor, preserving original: DynamicMessage?) throws -> Data {
        var edited = try mapper.parse(json, as: descriptor)
        if let missing = Self.missingRequiredField(in: edited, path: "") {
            throw ProtoJSONError(path: missing, reason: String(localized: "required field is missing", bundle: .module))
        }
        if let original {
            try graftUnknownFields(from: original, into: &edited)
        }
        return codec.encode(edited)
    }

    /// Carries unknown fields from the decoded original onto the edited
    /// message: at the root, into singular nested messages, into map values
    /// by key, into Any payloads whose type URL is unchanged, and into
    /// repeated messages as `pairElements` decides.
    func graftUnknownFields(
        from original: DynamicMessage, into edited: inout DynamicMessage, path: String = "", depth: Int = 0
    ) throws {
        edited.unknownFields = original.unknownFields
        if edited.descriptor.fullName == "google.protobuf.Any" {
            try graftAnyPayload(from: original, into: &edited, path: path, depth: depth)
            return
        }
        for field in edited.descriptor.fields where field.type == .message {
            guard let editedValue = edited.value(forField: field.number),
                let originalValue = original.value(forField: field.number)
            else { continue }
            let fieldPath = WireCodec.join(path, field.jsonName)
            switch (editedValue, originalValue) {
            case (.single(.message(var target)), .single(.message(let source))):
                try graftUnknownFields(from: source, into: &target, path: fieldPath, depth: depth + 1)
                edited.set(.single(.message(target)), forField: field.number)
            case (.repeated(var targets), .repeated(let sources)):
                let pairs = field.isMap
                    ? Self.pairMapEntries(sources, targets)
                    : try pairElements(sources, targets, path: fieldPath, depth: depth + 1)
                for (targetIndex, sourceIndex) in pairs {
                    guard case .message(var target) = targets[targetIndex],
                        case .message(let source) = sources[sourceIndex]
                    else { continue }
                    let elementPath = field.isMap
                        ? "\(fieldPath)[\"\(Self.mapKey(of: target))\"]" : "\(fieldPath)[\(targetIndex)]"
                    try graftUnknownFields(from: source, into: &target, path: elementPath, depth: depth + 1)
                    targets[targetIndex] = .message(target)
                }
                edited.set(.repeated(targets), forField: field.number)
            default:
                continue
            }
        }
    }

    private static func mapKey(of entry: DynamicMessage) -> String {
        ProtoJSONMapper.mapKeyString(entry.value(forField: 1)?.values.first ?? .string(""))
    }

    private static func pairMapEntries(_ sources: [DynamicValue], _ targets: [DynamicValue]) -> [(Int, Int)] {
        var sourceByKey: [String: Int] = [:]
        for (index, source) in sources.enumerated() {
            if let entry = source.message { sourceByKey[mapKey(of: entry)] = index }
        }
        return targets.indices.compactMap { index in
            targets[index].message.flatMap { sourceByKey[mapKey(of: $0)] }.map { (index, $0) }
        }
    }

    /// proto2 readers reject a message without its required fields.
    private static func missingRequiredField(in message: DynamicMessage, path: String) -> String? {
        for field in message.descriptor.fields {
            let fieldPath = WireCodec.join(path, field.name)
            guard let value = message.value(forField: field.number) else {
                if field.isRequired { return fieldPath }
                continue
            }
            for (offset, element) in value.values.enumerated() {
                guard let nested = element.message else { continue }
                let elementPath = field.isRepeated ? "\(fieldPath)[\(offset)]" : fieldPath
                if let missing = missingRequiredField(in: nested, path: elementPath) { return missing }
            }
        }
        return nil
    }

    /// Pairs edited elements of a repeated message field with original ones.
    /// With as many elements as before, one whose known content is unchanged
    /// at its own index stays paired there, as after an in-place edit of
    /// another. The rest pair by identical known content, in order, then by
    /// position when as many remain on each side. A leftover original with
    /// unknown fields that cannot be placed makes the edit ambiguous, so it
    /// throws rather than guess or drop them.
    private func pairElements(
        _ sources: [DynamicValue], _ targets: [DynamicValue], path: String, depth: Int
    ) throws -> [(Int, Int)] {
        let sourceContent = sources.map { $0.message.map { knownContent($0, depth: depth) } }
        let targetContent = targets.map { $0.message.map { knownContent($0, depth: depth) } }
        let positional = sources.count != targets.count ? [] : Set(targets.indices.filter {
            targetContent[$0] != nil && targetContent[$0] == sourceContent[$0]
        })
        var pairs = positional.map { ($0, $0) }
        var claimed = positional
        var unclaimed: [Data: ArraySlice<Int>] = [:]
        for (index, content) in sourceContent.enumerated() where !claimed.contains(index) {
            if let content { unclaimed[content, default: []].append(index) }
        }
        var leftoverTargets: [Int] = []
        for (index, content) in targetContent.enumerated() where !positional.contains(index) {
            if let content, let source = unclaimed[content]?.popFirst() {
                pairs.append((index, source))
                claimed.insert(source)
            } else {
                leftoverTargets.append(index)
            }
        }
        let leftoverSources = sources.indices.filter { !claimed.contains($0) }
        if leftoverTargets.count == leftoverSources.count {
            return pairs + zip(leftoverTargets, leftoverSources).map { ($0, $1) }
        }
        let unplaced = leftoverSources.filter { sources[$0].message.map { hasUnknownFields($0, depth: depth) } ?? false }
        if !leftoverTargets.isEmpty, !unplaced.isEmpty {
            throw ProtoJSONError(
                path: path,
                reason: String(
                    localized: "elements carry fields this schema does not know, and this edit both changes elements and adds or removes others, so they cannot be matched up. Save those two kinds of change separately.",
                    bundle: .module))
        }
        // A removed element that looks like a kept one but differs in unknown fields: which one went is unknowable.
        for source in unplaced {
            guard let content = sourceContent[source], let message = sources[source].message else { continue }
            let bytes = codec.encode(message)
            let lookalike = claimed.contains { kept in
                sourceContent[kept] == content && sources[kept].message.map { codec.encode($0) } != bytes
            }
            if lookalike {
                throw ProtoJSONError(
                    path: path,
                    reason: String(
                        localized: "elements that look the same carry different fields this schema does not know, so it cannot tell which one was removed.",
                        bundle: .module))
            }
        }
        return pairs
    }

    /// Unknown fields inside the payload travel only while the type URL is
    /// unchanged; a new type has no claim on the old type's fields.
    private func graftAnyPayload(
        from original: DynamicMessage, into edited: inout DynamicMessage, path: String, depth: Int
    ) throws {
        guard case .string(let typeURL)? = edited.value(forField: 1)?.values.first,
            original.value(forField: 1) == edited.value(forField: 1),
            let inner = registry.message(named: ProtoJSONMapper.typeName(inAnyURL: typeURL)),
            case .bytes(let sourcePayload)? = original.value(forField: 2)?.values.first,
            let source = try? codec.decode(sourcePayload, as: inner, depth: depth + 1)
        else { return }
        var target = DynamicMessage(descriptor: inner)
        if case .bytes(let targetPayload)? = edited.value(forField: 2)?.values.first {
            target = try codec.decode(targetPayload, as: inner, depth: depth + 1)
        }
        try graftUnknownFields(from: source, into: &target, path: WireCodec.join(path, "value"), depth: depth + 1)
        let payload = codec.encode(target)
        edited.set(payload.isEmpty ? nil : .single(.bytes(payload)), forField: 2)
    }

    /// The message's bytes without unknown fields at any depth, Any payloads
    /// included; equal bytes mean equal known content.
    private func knownContent(_ message: DynamicMessage, depth: Int) -> Data {
        codec.encode(withoutUnknownFields(message, depth: depth))
    }

    private func hasUnknownFields(_ message: DynamicMessage, depth: Int) -> Bool {
        knownContent(message, depth: depth) != codec.encode(message)
    }

    private func withoutUnknownFields(_ message: DynamicMessage, depth: Int) -> DynamicMessage {
        var result = message
        result.unknownFields = []
        if message.descriptor.fullName == "google.protobuf.Any" {
            if case .string(let typeURL)? = message.value(forField: 1)?.values.first,
                case .bytes(let payload)? = message.value(forField: 2)?.values.first,
                let inner = registry.message(named: ProtoJSONMapper.typeName(inAnyURL: typeURL)),
                let decoded = try? codec.decode(payload, as: inner, depth: depth + 1)
            {
                let stripped = codec.encode(withoutUnknownFields(decoded, depth: depth + 1))
                result.set(stripped.isEmpty ? nil : .single(.bytes(stripped)), forField: 2)
            }
            return result
        }
        for field in message.descriptor.fields where field.type == .message {
            switch message.value(forField: field.number) {
            case .single(.message(let nested))?:
                result.set(.single(.message(withoutUnknownFields(nested, depth: depth + 1))), forField: field.number)
            case .repeated(let elements)?:
                result.set(
                    .repeated(elements.map { element in
                        element.message.map { .message(withoutUnknownFields($0, depth: depth + 1)) } ?? element
                    }),
                    forField: field.number)
            default:
                break
            }
        }
        return result
    }
}
