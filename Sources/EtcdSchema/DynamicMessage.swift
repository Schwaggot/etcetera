import Foundation

// A message decoded from a runtime descriptor: a tree of values keyed by
// field number. Designed to back a structured editor later. See SPEC 5.4.

/// Only the wide cases are boxed, so scalars sit inline in a 16-byte value;
/// a packed field of one-byte varints would otherwise cost a heap box each.
public enum DynamicValue: Sendable, Equatable {
    case int32(Int32)
    case int64(Int64)
    case uint32(UInt32)
    case uint64(UInt64)
    case float(Float)
    case double(Double)
    case bool(Bool)
    indirect case string(String)
    indirect case bytes(Data)
    case enumeration(Int32)
    indirect case message(DynamicMessage)

    public static func == (lhs: DynamicValue, rhs: DynamicValue) -> Bool {
        switch (lhs, rhs) {
        case (.int32(let a), .int32(let b)): return a == b
        case (.int64(let a), .int64(let b)): return a == b
        case (.uint32(let a), .uint32(let b)): return a == b
        case (.uint64(let a), .uint64(let b)): return a == b
        // Bit equality, so NaN equals itself and -0 differs from 0.
        case (.float(let a), .float(let b)): return a.bitPattern == b.bitPattern
        case (.double(let a), .double(let b)): return a.bitPattern == b.bitPattern
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.bytes(let a), .bytes(let b)): return a == b
        case (.enumeration(let a), .enumeration(let b)): return a == b
        case (.message(let a), .message(let b)): return a == b
        default: return false
        }
    }

    public var message: DynamicMessage? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public enum FieldValue: Sendable, Equatable {
    case single(DynamicValue)
    /// Repeated fields and maps; map entries are messages with fields 1 and 2.
    case repeated([DynamicValue])

    public var values: [DynamicValue] {
        switch self {
        case .single(let value): return [value]
        case .repeated(let values): return values
        }
    }
}

/// A field present in the bytes but absent from the descriptor, kept
/// verbatim, tag included, so a lagging schema does not destroy data.
public struct UnknownField: Sendable, Equatable {
    public let fieldNumber: Int
    public let raw: Data

    public init(fieldNumber: Int, raw: Data) {
        self.fieldNumber = fieldNumber
        self.raw = raw
    }
}

public struct DynamicMessage: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        let number: Int
        var value: FieldValue
    }

    public let descriptor: MessageDescriptor
    /// Set fields, ascending by number. A sorted array rather than a
    /// dictionary, which costs over a hundred bytes even for one field.
    private var entries: [Entry] = []
    public var unknownFields: [UnknownField] = []

    public init(descriptor: MessageDescriptor) {
        self.descriptor = descriptor
    }

    public var values: [Int: FieldValue] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.number, $0.value) })
    }

    public var isEmpty: Bool { entries.isEmpty && unknownFields.isEmpty }

    /// Where `number` is or would be inserted. Decoding mostly arrives in
    /// ascending order, so the end is tried first.
    private func position(of number: Int) -> Int {
        guard let last = entries.last, last.number >= number else { return entries.count }
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].number < number { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func index(of number: Int) -> Int? {
        let index = position(of: number)
        return index < entries.count && entries[index].number == number ? index : nil
    }

    public func value(forField number: Int) -> FieldValue? {
        index(of: number).map { entries[$0].value }
    }

    public func value(named name: String) -> FieldValue? {
        descriptor.field(named: name).flatMap { value(forField: $0.number) }
    }

    /// Sets or clears a field. Setting a oneof member clears its siblings.
    public mutating func set(_ value: FieldValue?, forField number: Int) {
        if value != nil, let oneof = descriptor.field(number: number)?.oneofIndex {
            for sibling in descriptor.fields where sibling.oneofIndex == oneof && sibling.number != number {
                set(nil, forField: sibling.number)
            }
        }
        switch (value, index(of: number)) {
        case (let value?, let index?): entries[index].value = value
        case (let value?, nil): entries.insert(Entry(number: number, value: value), at: position(of: number))
        case (nil, let index?): entries.remove(at: index)
        case (nil, nil): break
        }
    }

    /// Appends one element to a repeated field.
    public mutating func append(_ value: DynamicValue, toField number: Int) {
        guard let index = index(of: number), case .repeated(var existing) = entries[index].value else {
            set(.repeated([value]), forField: number)
            return
        }
        entries[index].value = .repeated([])  // keep the array uniquely referenced
        existing.append(value)
        entries[index].value = .repeated(existing)
    }

    /// Appends elements to a repeated field, keeping a fresh array's capacity.
    mutating func append(contentsOf elements: [DynamicValue], toField number: Int) {
        guard let index = index(of: number), case .repeated(var existing) = entries[index].value else {
            set(.repeated(elements), forField: number)
            return
        }
        entries[index].value = .repeated([])  // keep the array uniquely referenced
        existing.append(contentsOf: elements)
        entries[index].value = .repeated(existing)
    }

    public static func == (lhs: DynamicMessage, rhs: DynamicMessage) -> Bool {
        lhs.descriptor == rhs.descriptor && lhs.entries == rhs.entries
            && lhs.unknownFields == rhs.unknownFields
    }
}
