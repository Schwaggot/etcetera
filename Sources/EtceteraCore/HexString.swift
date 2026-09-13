import Foundation

/// Bytes as uppercase hex digits without separators, fast enough for
/// multi-megabyte values.
public func hexString(_ data: Data) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(data.count * 2)
    for byte in data {
        bytes.append(digits[Int(byte >> 4)])
        bytes.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: bytes, as: UTF8.self)
}
