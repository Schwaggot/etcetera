import Foundation
import Testing

@testable import EtcdSchema

@Suite("Mapping keys to message types", .tags(.unit))
struct SchemaMappingTests {
    static let specExample = """
        {
          "schemaSource": "bookmark:...",
          "mappings": [
            { "prefix": "/registry/pods/",     "message": "k8s.io.api.core.v1.Pod" },
            { "prefix": "/registry/services/", "message": "k8s.io.api.core.v1.Service" },
            { "key": "/config/feature-flags",  "message": "acme.config.v1.FeatureFlags" }
          ]
        }
        """

    @Test("Reads and writes the configuration format from the spec")
    func specFormat() throws {
        let configuration = try JSONDecoder().decode(SchemaMappingConfiguration.self, from: Data(Self.specExample.utf8))
        #expect(configuration.schemaSource == "bookmark:...")
        #expect(configuration.mappings == [
            SchemaMappingRule(.prefix("/registry/pods/"), message: "k8s.io.api.core.v1.Pod"),
            SchemaMappingRule(.prefix("/registry/services/"), message: "k8s.io.api.core.v1.Service"),
            SchemaMappingRule(.key("/config/feature-flags"), message: "acme.config.v1.FeatureFlags"),
        ])
        let encoded = try JSONEncoder().encode(configuration)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let rules = try #require(object?["mappings"] as? [[String: String]])
        #expect(rules[2] == ["key": "/config/feature-flags", "message": "acme.config.v1.FeatureFlags"])
        #expect(try JSONDecoder().decode(SchemaMappingConfiguration.self, from: encoded) == configuration)
    }

    @Test("A rule with both or neither of prefix and key is rejected",
        arguments: [
            #"{"prefix": "/a", "key": "/a", "message": "M"}"#,
            #"{"message": "M"}"#,
        ])
    func ambiguousRule(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SchemaMappingRule.self, from: Data(json.utf8))
        }
    }

    @Test("An exact key beats any prefix")
    func exactKeyWins() {
        let configuration = SchemaMappingConfiguration(schemaSource: "", mappings: [
            SchemaMappingRule(.prefix("/config/"), message: "A"),
            SchemaMappingRule(.key("/config/feature-flags"), message: "B"),
        ])
        #expect(configuration.rule(forKey: "/config/feature-flags")?.message == "B")
        #expect(configuration.rule(forKey: "/config/other")?.message == "A")
    }

    @Test("The longest matching prefix wins regardless of rule order")
    func longestPrefixWins() {
        let configuration = SchemaMappingConfiguration(schemaSource: "", mappings: [
            SchemaMappingRule(.prefix("/registry/"), message: "Any"),
            SchemaMappingRule(.prefix("/registry/pods/"), message: "Pod"),
            SchemaMappingRule(.prefix("/reg"), message: "Short"),
        ])
        #expect(configuration.rule(forKey: "/registry/pods/default/web")?.message == "Pod")
        #expect(configuration.rule(forKey: "/registry/services/x")?.message == "Any")
    }

    @Test("No match falls back to the format guess")
    func noMatch() throws {
        let configuration = SchemaMappingConfiguration(schemaSource: "", mappings: [
            SchemaMappingRule(.prefix("/registry/"), message: "fixtures.v1.Scalars"),
        ])
        #expect(configuration.resolve(key: "/config/app", in: try Fixtures.registry()) == .unmapped)
    }

    @Test("A match whose message is in the registry resolves")
    func resolves() throws {
        let rule = SchemaMappingRule(.prefix("/s/"), message: "fixtures.v1.Scalars")
        let configuration = SchemaMappingConfiguration(schemaSource: "", mappings: [rule])
        #expect(configuration.resolve(key: "/s/1", in: try Fixtures.registry()) == .mapped(message: "fixtures.v1.Scalars", rule: rule))
    }

    @Test("A match whose message is missing is a configuration error on the key")
    func missingMessage() throws {
        let rule = SchemaMappingRule(.key("/flags"), message: "acme.Missing")
        let configuration = SchemaMappingConfiguration(schemaSource: "", mappings: [rule])
        let registry = try Fixtures.registry()
        guard case .misconfigured(let matched, let reason) = configuration.resolve(key: "/flags", in: registry) else {
            Issue.record("expected a configuration error")
            return
        }
        #expect(matched == rule)
        #expect(reason.contains("acme.Missing"))
        #expect(configuration.problems(in: registry) == [rule])
    }

    @Test("Without a compiled schema a matching key is misconfigured, not unmapped")
    func noRegistry() {
        let configuration = SchemaMappingConfiguration(schemaSource: "", mappings: [
            SchemaMappingRule(.prefix("/"), message: "M"),
        ])
        guard case .misconfigured = configuration.resolve(key: "/a", in: nil) else {
            Issue.record("expected a configuration error")
            return
        }
    }
}
