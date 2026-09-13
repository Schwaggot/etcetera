import Foundation

// Text forms of Timestamp, Duration, and FieldMask in the proto3 JSON
// mapping. Calendar math is done by hand so no Calendar or Date is involved.

enum WellKnownFormats {
    static let minTimestampSeconds: Int64 = -62_135_596_800  // 0001-01-01T00:00:00Z
    static let maxTimestampSeconds: Int64 = 253_402_300_799  // 9999-12-31T23:59:59Z
    static let maxDurationSeconds: Int64 = 315_576_000_000

    // MARK: Timestamp

    static func formatTimestamp(seconds: Int64, nanos: Int64, path: String) throws -> String {
        guard seconds >= minTimestampSeconds, seconds <= maxTimestampSeconds, nanos >= 0, nanos < 1_000_000_000 else {
            throw ProtoJSONError(path: path, reason: String(localized: "Timestamp is outside 0001-01-01 to 9999-12-31", bundle: .module))
        }
        let days = floorDivide(seconds, 86_400)
        let secondOfDay = seconds - days * 86_400
        let (year, month, day) = civilFromDays(days)
        return String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld",
            year, month, day, secondOfDay / 3600, secondOfDay / 60 % 60, secondOfDay % 60)
            + fraction(nanos) + "Z"
    }

    static func parseTimestamp(_ text: String, path: String) throws -> (Int64, Int32) {
        let invalid = ProtoJSONError(path: path, reason: String(localized: "\(text) is not an RFC 3339 timestamp", bundle: .module))
        let chars = Array(text.utf8)
        func number(_ from: Int, _ count: Int) throws -> Int64 {
            guard from + count <= chars.count else { throw invalid }
            var value: Int64 = 0
            for byte in chars[from..<(from + count)] {
                guard (0x30...0x39).contains(byte) else { throw invalid }
                value = value * 10 + Int64(byte - 0x30)
            }
            return value
        }
        func expect(_ index: Int, _ allowed: String) throws {
            guard index < chars.count, allowed.utf8.contains(chars[index]) else { throw invalid }
        }
        let year = try number(0, 4)
        try expect(4, "-")
        let month = try number(5, 2)
        try expect(7, "-")
        let day = try number(8, 2)
        try expect(10, "Tt")
        let hour = try number(11, 2)
        try expect(13, ":")
        let minute = try number(14, 2)
        try expect(16, ":")
        let second = try number(17, 2)
        var index = 19
        var nanos: Int64 = 0
        if index < chars.count, chars[index] == UInt8(ascii: ".") {
            index += 1
            let start = index
            while index < chars.count, (0x30...0x39).contains(chars[index]) { index += 1 }
            let digits = index - start
            guard (1...9).contains(digits) else { throw invalid }
            nanos = try number(start, digits) * pow10(9 - digits)
        }
        var offset: Int64 = 0
        guard index < chars.count else { throw invalid }
        switch chars[index] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            index += 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            let sign: Int64 = chars[index] == UInt8(ascii: "-") ? -1 : 1
            let offsetHours = try number(index + 1, 2)
            try expect(index + 3, ":")
            let offsetMinutes = try number(index + 4, 2)
            guard offsetHours < 24, offsetMinutes < 60 else { throw invalid }
            offset = sign * (offsetHours * 3600 + offsetMinutes * 60)
            index += 6
        default:
            throw invalid
        }
        guard index == chars.count, (1...12).contains(month), day >= 1, day <= daysInMonth(year, month),
            hour < 24, minute < 60, second < 60
        else { throw invalid }
        let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset
        guard seconds >= minTimestampSeconds, seconds <= maxTimestampSeconds else { throw invalid }
        return (seconds, Int32(nanos))
    }

    // MARK: Duration

    static func formatDuration(seconds: Int64, nanos: Int64, path: String) throws -> String {
        // Range tests, not abs(), which traps on Int64.min.
        guard (-maxDurationSeconds...maxDurationSeconds).contains(seconds), (-999_999_999...999_999_999).contains(nanos),
            !(seconds > 0 && nanos < 0), !(seconds < 0 && nanos > 0)
        else {
            throw ProtoJSONError(path: path, reason: String(localized: "Duration is out of range or has mixed signs", bundle: .module))
        }
        let negative = seconds < 0 || nanos < 0
        return (negative ? "-" : "") + String(abs(seconds)) + fraction(abs(nanos)) + "s"
    }

    static func parseDuration(_ text: String, path: String) throws -> (Int64, Int32) {
        let invalid = ProtoJSONError(path: path, reason: String(localized: "\(text) is not a duration like \"1.5s\"", bundle: .module))
        guard text.hasSuffix("s") else { throw invalid }
        var body = Substring(text.dropLast())
        let negative = body.hasPrefix("-")
        if negative { body = body.dropFirst() }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isASCIIDigitCharacter),
            let seconds = Int64(whole), seconds <= maxDurationSeconds
        else { throw invalid }
        var nanos: Int64 = 0
        if parts.count == 2 {
            let fractionText = parts[1]
            guard (1...9).contains(fractionText.count), fractionText.allSatisfy(\.isASCIIDigitCharacter),
                let value = Int64(fractionText)
            else { throw invalid }
            nanos = value * pow10(9 - fractionText.count)
        }
        return negative ? (-seconds, Int32(-nanos)) : (seconds, Int32(nanos))
    }

    // MARK: FieldMask

    static func camelPath(_ snake: String, path: String) throws -> String {
        var result = ""
        var upperNext = false
        for character in snake {
            if character == "_" {
                upperNext = true
                continue
            }
            if upperNext {
                guard character.isLowercase else {
                    throw ProtoJSONError(path: path, reason: String(localized: "field mask path \(snake) has no JSON form", bundle: .module))
                }
                result += character.uppercased()
                upperNext = false
            } else {
                guard !character.isUppercase else {
                    throw ProtoJSONError(path: path, reason: String(localized: "field mask path \(snake) has no JSON form", bundle: .module))
                }
                result.append(character)
            }
        }
        guard !upperNext else { throw ProtoJSONError(path: path, reason: String(localized: "field mask path \(snake) has no JSON form", bundle: .module)) }
        return result
    }

    static func snakePath(_ camel: String, path: String) throws -> String {
        var result = ""
        for character in camel {
            if character == "_" {
                throw ProtoJSONError(path: path, reason: String(localized: "field mask path \(camel) must be lowerCamelCase", bundle: .module))
            }
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: Calendar

    static func fraction(_ nanos: Int64) -> String {
        if nanos == 0 { return "" }
        if nanos % 1_000_000 == 0 { return String(format: ".%03lld", nanos / 1_000_000) }
        if nanos % 1_000 == 0 { return String(format: ".%06lld", nanos / 1_000) }
        return String(format: ".%09lld", nanos)
    }

    static func pow10(_ exponent: Int) -> Int64 {
        (0..<exponent).reduce(1) { value, _ in value * 10 }
    }

    static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    static func daysInMonth(_ year: Int64, _ month: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    static func daysFromCivil(_ year: Int64, _ month: Int64, _ day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}

extension Character {
    fileprivate var isASCIIDigitCharacter: Bool {
        isASCII && isWholeNumber
    }
}
