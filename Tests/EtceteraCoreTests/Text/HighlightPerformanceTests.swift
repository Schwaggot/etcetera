import Foundation
import Testing

@testable import EtceteraCore

private let isOptimizedBuild: Bool = {
    #if DEBUG
        false
    #else
        true
    #endif
}()

/// SPEC 6.8: highlight a 1 MB JSON value in 150 ms.
@Suite("Highlighting performance", .tags(.slow))
struct HighlightPerformanceTests {
    let document = generatedJSON(approximateBytes: 1_000_000)

    private func highlightDuration() -> Duration {
        ContinuousClock().measure {
            let cache = HighlightCache(text: document, tokenizer: JSONTokenizer())
            _ = cache.tokens()
        }
    }

    @Test("A 1 MB document highlights within the 150 ms budget", .enabled(if: isOptimizedBuild, "budget applies to optimized builds"))
    func meetsBudget() {
        #expect(document.utf8.count >= 1_000_000)
        #expect(highlightDuration() < .milliseconds(150))
    }

    @Test("A 1 MB document highlights within a loose debug bound")
    func debugBound() {
        #expect(highlightDuration() < .seconds(3))
    }
}
