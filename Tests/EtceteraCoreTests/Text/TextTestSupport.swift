import Foundation

@testable import EtceteraCore

/// A seeded PRNG so property tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Tokens as (kind, source text) pairs for readable assertions.
func tokenTexts(_ text: String) -> [(TokenKind, String)] {
    let units = Array(text.utf16)
    return HighlightCache(text: text, tokenizer: JSONTokenizer()).tokens().map { token in
        let slice = units[token.range.location..<token.range.upperBound]
        return (token.kind, String(decoding: slice, as: UTF16.self))
    }
}

/// A deterministic pretty-printed JSON document of roughly `bytes` bytes.
func generatedJSON(approximateBytes bytes: Int) -> String {
    var lines = ["["]
    var size = 2
    var index = 0
    while size < bytes {
        let entry = """
              {
                "id": \(index),
                "name": "service-\(index)",
                "enabled": \(index % 2 == 0 ? "true" : "false"),
                "ratio": \(Double(index) / 7.0),
                "owner": null,
                "tags": ["alpha", "beta", "gamma"],
                "limits": {"cpu": "500m", "memory": "\(index % 64)Mi"}
              },
            """
        lines.append(entry)
        size += entry.utf8.count + 1
        index += 1
    }
    lines.append("  {}")
    lines.append("]")
    return lines.joined(separator: "\n")
}
