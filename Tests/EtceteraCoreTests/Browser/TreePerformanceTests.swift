import EtcdKit
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

/// SPEC 6.8: expand a tree node of 1000 keys in 200 ms after the response.
@MainActor
@Suite("Tree expansion performance", .tags(.slow))
struct TreePerformanceTests {
    /// 1000 keys under one node, a third of them branches.
    let response = Data(
        Gateway.range(keys: (0..<1000).map { $0 % 3 == 0 ? "a/k\($0)/child" : "a/k\($0)" }).utf8)

    private func expandDuration() -> Duration {
        ContinuousClock().measure {
            guard let decoded = try? JSONDecoder().decode(RangeResponse.self, from: response) else { return }
            let node = KeyNode.root()
            node.merge(buildChildren(keys: decoded.kvs.compactMap(\.keyString), prefix: "a/", separator: "/"))
            precondition(node.children?.count == 1000)
        }
    }

    @Test("A node of 1000 keys expands within the 200 ms budget", .enabled(if: isOptimizedBuild, "budget applies to optimized builds"))
    func meetsBudget() {
        #expect(expandDuration() < .milliseconds(200))
    }

    @Test("A node of 1000 keys expands within a loose debug bound")
    func debugBound() {
        #expect(expandDuration() < .seconds(2))
    }
}
