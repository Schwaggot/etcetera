import Foundation
import Testing

@testable import EtcdKit

// The etcd JSON encoding rules from SPEC 3.5, one suite per rule.

@Suite("64-bit integers cross the gateway as JSON strings", .tags(.unit))
struct Int64EncodingTests {
    @Test("Decodes revision fields from strings",
        arguments: [
            ("\"1\"", Int64(1)),
            ("\"4021\"", Int64(4021)),
            ("\"9223372036854775807\"", Int64.max),
            ("\"-1\"", Int64(-1)),
        ])
    func decodesFromString(json: String, expected: Int64) throws {
        let kv = try JSONDecoder().decode(
            KeyValue.self, from: Data("{\"mod_revision\": \(json)}".utf8))
        #expect(kv.modRevision == expected)
    }

    @Test("Tolerates a bare number, which some proxies emit")
    func decodesFromNumber() throws {
        let kv = try JSONDecoder().decode(
            KeyValue.self, from: Data("{\"mod_revision\": 7}".utf8))
        #expect(kv.modRevision == 7)
    }

    @Test("Rejects garbage in an int64 field")
    func rejectsGarbage() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                KeyValue.self, from: Data("{\"mod_revision\": \"seven\"}".utf8))
        }
    }

    @Test("Encodes int64 request fields as strings")
    func encodesAsString() throws {
        let request = RangeRequest(key: Data("k".utf8), limit: 1000)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(json["limit"] as? String == "1000")
    }

    @Test("uint64 fields hold values above Int64.max")
    func uint64AboveInt64Max() throws {
        let header = try JSONDecoder().decode(
            ResponseHeader.self,
            from: Data("{\"cluster_id\": \"17237436991929493444\"}".utf8))
        #expect(header.clusterID == 17_237_436_991_929_493_444)
    }
}

@Suite("Bytes fields cross the gateway as padded base64", .tags(.unit))
struct Base64EncodingTests {
    @Test("Decodes keys and values from base64")
    func decodes() throws {
        let kv = try JSONDecoder().decode(
            KeyValue.self, from: Data("{\"key\": \"Zm9v\", \"value\": \"YmFy\"}".utf8))
        #expect(kv.key == Data("foo".utf8))
        #expect(kv.value == Data("bar".utf8))
    }

    @Test("Encodes keys as padded base64")
    func encodes() throws {
        let request = PutRequest(key: Data("foo".utf8), value: Data("bargh".utf8))
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(json["key"] as? String == "Zm9v")
        #expect(json["value"] as? String == "YmFyZ2g=")
    }

    @Test("Rejects a bytes field that is not base64")
    func rejectsGarbage() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(KeyValue.self, from: Data("{\"key\": \"%%%\"}".utf8))
        }
    }

    @Test("Round trips arbitrary non-UTF-8 bytes")
    func roundTripsArbitraryBytes() throws {
        let key = Data([0x00, 0xFF, 0x80, 0x01])
        let encoded = try JSONEncoder().encode(PutRequest(key: key, value: Data()))
        let decoded = try JSONDecoder().decode(PutRequest.self, from: encoded)
        #expect(decoded.key == key)
    }
}

@Suite("Absent fields mean proto3 defaults", .tags(.unit))
struct AbsentFieldTests {
    @Test("An empty object decodes to a KeyValue of defaults")
    func keyValueDefaults() throws {
        let kv = try JSONDecoder().decode(KeyValue.self, from: Data("{}".utf8))
        #expect(kv.key.isEmpty)
        #expect(kv.value.isEmpty)
        #expect(kv.createRevision == 0)
        #expect(kv.modRevision == 0)
        #expect(kv.version == 0)
        #expect(kv.lease == 0)
    }

    @Test("A RangeResponse without kvs, more, or count uses defaults")
    func rangeResponseDefaults() throws {
        let response = try JSONDecoder().decode(
            RangeResponse.self, from: Data("{\"header\": {\"revision\": \"5\"}}".utf8))
        #expect(response.kvs.isEmpty)
        #expect(response.more == false)
        #expect(response.count == 0)
        #expect(response.header.revision == 5)
    }

    @Test("A TxnResponse without succeeded means the compare failed")
    func txnSucceededDefaultsToFalse() throws {
        let response = try JSONDecoder().decode(
            TxnResponse.self, from: Data("{\"header\": {}}".utf8))
        #expect(response.succeeded == false)
    }
}

@Suite("Enums are strings", .tags(.unit))
struct EnumEncodingTests {
    @Test("sort_order encodes as ASCEND, not a number")
    func sortOrder() throws {
        let request = RangeRequest(
            key: Data("k".utf8), sortOrder: .ascend, sortTarget: .key)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(json["sort_order"] as? String == "ASCEND")
        #expect(json["sort_target"] as? String == "KEY")
    }

    @Test("Compare encodes target and result as strings")
    func compare() throws {
        let compare = Compare.modRevision(Data("k".utf8), .equal, 42)
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(compare)) as! [String: Any]
        #expect(json["target"] as? String == "MOD")
        #expect(json["result"] as? String == "EQUAL")
        #expect(json["mod_revision"] as? String == "42")
    }
}

@Suite("Field names follow the proto, not lowerCamelCase", .tags(.unit))
struct FieldNameTests {
    @Test("LeaseGrantRequest declares TTL and ID")
    func leaseGrantUsesUpperCaseNames() throws {
        let json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(LeaseGrantRequest(ttl: 60, id: 5))) as! [String: Any]
        #expect(json["TTL"] as? String == "60")
        #expect(json["ID"] as? String == "5")
        #expect(json["ttl"] == nil)
    }

    @Test("KeyValue uses snake_case revision fields")
    func keyValueSnakeCase() throws {
        let kv = try JSONDecoder().decode(
            KeyValue.self,
            from: Data("{\"create_revision\": \"2\", \"mod_revision\": \"3\", \"version\": \"1\"}".utf8))
        #expect(kv.createRevision == 2)
        #expect(kv.modRevision == 3)
        #expect(kv.version == 1)
    }

    @Test("Member uses the proto's ID and peerURLs spellings")
    func memberFieldNames() throws {
        let member = try JSONDecoder().decode(
            Member.self,
            from: Data(
                "{\"ID\": \"10501334649042878790\", \"name\": \"node1\", \"peerURLs\": [\"http://a:2380\"], \"clientURLs\": [\"http://a:2379\"]}"
                    .utf8))
        #expect(member.id == 10_501_334_649_042_878_790)
        #expect(member.name == "node1")
        #expect(member.peerURLs == ["http://a:2380"])
    }
}

@Suite("Real gateway response shapes decode", .tags(.unit))
struct GatewayResponseShapeTests {
    @Test("A real range response body decodes completely")
    func rangeResponse() throws {
        // Captured shape from etcd 3.5: curl .../v3/kv/range -d '{"key":"Zm9v"}'
        let body = """
            {"header":{"cluster_id":"14841639068965178418","member_id":"10276657743932975437",
            "revision":"2","raft_term":"2"},
            "kvs":[{"key":"Zm9v","create_revision":"2","mod_revision":"2","version":"1","value":"YmFy"}],
            "count":"1"}
            """
        let response = try JSONDecoder().decode(RangeResponse.self, from: Data(body.utf8))
        #expect(response.count == 1)
        #expect(response.more == false)
        let kv = try #require(response.kvs.first)
        #expect(kv.keyString == "foo")
        #expect(kv.value == Data("bar".utf8))
        #expect(kv.modRevision == 2)
    }

    @Test("A status response without db_size_in_use leaves it nil")
    func statusWithoutDbSizeInUse() throws {
        let body = """
            {"header":{"cluster_id":"1","member_id":"2","revision":"1","raft_term":"2"},
            "version":"3.3.27","dbSize":"24576","leader":"2","raftIndex":"10","raftTerm":"2"}
            """
        let status = try JSONDecoder().decode(StatusResponse.self, from: Data(body.utf8))
        #expect(status.version == "3.3.27")
        #expect(status.dbSize == 24576)
        #expect(status.dbSizeInUse == nil)
    }

    @Test("A status response with dbSizeInUse carries it through")
    func statusWithDbSizeInUse() throws {
        let body = """
            {"version":"3.5.21","dbSize":"24576","dbSizeInUse":"16384"}
            """
        let status = try JSONDecoder().decode(StatusResponse.self, from: Data(body.utf8))
        #expect(status.dbSizeInUse == 16384)
    }
}
