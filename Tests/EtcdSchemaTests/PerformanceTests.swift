import Foundation
import Testing

@testable import EtcdSchema

// Budgets from SPEC 6.8, measured with a real clock. Measuring elapsed time
// is not sleeping; nothing here waits.

@Suite("Performance budgets", .tags(.slow), .serialized)
struct PerformanceTests {
    /// The fastest of a few runs, to keep scheduler noise out.
    private func fastest(runs: Int = 3, _ body: () throws -> Void) rethrows -> Duration {
        var best = Duration.seconds(3600)
        for _ in 0..<runs {
            let elapsed = try ContinuousClock().measure(body)
            best = min(best, elapsed)
        }
        return best
    }

    @Test("Decodes a 100 KB message within 50 ms")
    func decodeBudget() throws {
        let registry = try Fixtures.registry()
        var writer = WireWriter()
        let name = Array(String(repeating: "k", count: 45).utf8)
        while writer.bytes.count < 100_000 {
            var inner = WireWriter()
            inner.writeTag(fieldNumber: 1, wireType: .lengthDelimited)
            inner.writeLengthDelimited(name)
            writer.writeTag(fieldNumber: 3, wireType: .lengthDelimited)
            writer.writeLengthDelimited(inner.bytes)
        }
        let bytes = writer.data
        let codec = WireCodec(registry: registry)
        let elapsed = try fastest {
            _ = try codec.decode(bytes, as: "fixtures.v1.Nested")
        }
        #expect(elapsed < .milliseconds(50), "took \(elapsed)")
    }

    @Test("Loads a 500-message descriptor set within 500 ms")
    func descriptorBudget() throws {
        let data = try Fixtures.data("large.pb")
        var registry: SchemaRegistry?
        let elapsed = try fastest {
            registry = try SchemaRegistry(descriptorSet: data)
        }
        #expect(registry?.allMessageNames.filter { $0.hasPrefix("perf.v1.M") }.count ?? 0 >= 500)
        #expect(elapsed < .milliseconds(500), "took \(elapsed)")
    }
}
