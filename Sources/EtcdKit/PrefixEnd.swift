import Foundation

/// The exclusive range end for a prefix scan: the prefix with its last
/// incrementable byte incremented. A result of `[0]` means the whole
/// keyspace, which is what the empty prefix must map to.
public func prefixEnd(_ key: [UInt8]) -> [UInt8] {
    for i in stride(from: key.count - 1, through: 0, by: -1) where key[i] < 0xFF {
        var end = Array(key[0...i])
        end[i] += 1
        return end
    }
    return [0]
}

public func prefixEnd(_ key: Data) -> Data {
    Data(prefixEnd([UInt8](key)))
}

/// The key that starts a prefix scan. The empty prefix scans from `\0`.
public func prefixStart(_ key: Data) -> Data {
    key.isEmpty ? Data([0]) : key
}
