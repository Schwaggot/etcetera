import Foundation

/// A bracket next to the cursor and its partner, in UTF-16 offsets.
public struct BracketPair: Hashable, Sendable {
    public var bracket: Int
    public var match: Int
}

/// Finds matching brackets while ignoring brackets inside strings. Strings
/// end at a newline, as in the tokenizer.
public enum BracketMatcher {
    /// Checks the character before the cursor first, then the one after.
    public static func match(in text: String, cursor: Int) -> BracketPair? {
        match(in: Array(text.utf16), cursor: cursor)
    }

    public static func match(in units: [UInt16], cursor: Int) -> BracketPair? {
        for candidate in [cursor - 1, cursor] where candidate >= 0 && candidate < units.count {
            if let match = matchingOffset(in: units, at: candidate) {
                return BracketPair(bracket: candidate, match: match)
            }
        }
        return nil
    }

    /// The partner of the bracket at `position`; nil when `position` is not a
    /// bracket, sits in a string, or is unbalanced.
    public static func matchingOffset(in units: [UInt16], at position: Int) -> Int? {
        guard position >= 0, position < units.count, isBracket(units[position]) else { return nil }
        var stack: [(unit: UInt16, offset: Int)] = []
        var targetDepth: Int?
        var inString = false
        var i = 0
        while i < units.count {
            let c = units[i]
            if inString {
                if i == position { return nil }
                // The newline still ends the string, as in the tokenizer.
                if c == 0x5C, i + 1 < units.count, units[i + 1] != 0x0A {
                    if i + 1 == position { return nil }
                    i += 2
                    continue
                }
                if c == 0x22 || c == 0x0A { inString = false }
                i += 1
                continue
            }
            switch c {
            case 0x22:
                inString = true
            case 0x7B, 0x5B:
                stack.append((c, i))
                if i == position { targetDepth = stack.count }
            case 0x7D, 0x5D:
                let opener: UInt16 = c == 0x7D ? 0x7B : 0x5B
                if let depth = targetDepth, stack.count == depth {
                    return stack[depth - 1].unit == opener ? i : nil
                }
                if i == position {
                    guard let top = stack.last, top.unit == opener else { return nil }
                    return top.offset
                }
                if stack.last?.unit == opener { stack.removeLast() }
            default:
                break
            }
            i += 1
        }
        return nil
    }

    static func isBracket(_ c: UInt16) -> Bool {
        c == 0x7B || c == 0x7D || c == 0x5B || c == 0x5D
    }
}
