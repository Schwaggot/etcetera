import Foundation

/// A byte count for display: whole bytes below 1 KB, then up to three
/// significant digits in decimal units, as Finder counts.
public func formatByteSize(_ bytes: Int, locale: Locale = .current) -> String {
    guard bytes >= 1000 else { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes) / 1000
    var unit = 0
    // Rounding would show 999,999 B as "1000 KB", so that moves up a unit too.
    while value >= 999.5, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    let number = value.formatted(.number.precision(.significantDigits(1...3)).locale(locale))
    return "\(number) \(units[unit])"
}
