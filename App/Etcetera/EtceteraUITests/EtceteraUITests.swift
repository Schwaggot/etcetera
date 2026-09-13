//
//  EtceteraUITests.swift
//  EtceteraUITests
//

import XCTest

/// Connect, browse, edit, and save against a real etcd with the JSON
/// gateway, named by ETCETERA_UITEST_ENDPOINT. The test writes under
/// etcetera-uitest/. See SPEC 6.5.
@MainActor
final class EtceteraUITests: XCTestCase {
    private var endpoint: URL?

    override func setUp() async throws {
        continueAfterFailure = false
        guard let value = ProcessInfo.processInfo.environment["ETCETERA_UITEST_ENDPOINT"], let url = URL(string: value)
        else {
            throw XCTSkip("Set ETCETERA_UITEST_ENDPOINT to an etcd endpoint to run the UI tests")
        }
        endpoint = url
    }

    func testConnectBrowseEditSave() async throws {
        let key = "etcetera-uitest/value"
        try await put(key, #"{"step":1}"#)

        let app = XCUIApplication()
        app.launchArguments += ["-uiTestEndpoint", try XCTUnwrap(endpoint).absoluteString]
        app.launch()

        let node = app.outlines.staticTexts["etcetera-uitest"]
        XCTAssertTrue(node.waitForExistence(timeout: 15))
        node.click()

        let row = app.tables.staticTexts[key]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(#"{"step":2}"#)
        app.buttons["Save"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 15))
        let stored = try await get(key)
        XCTAssertEqual(stored, #"{"step":2}"#)
    }

    // MARK: Gateway

    private func call(_ path: String, _ body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(endpoint).appending(path: "v3/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func put(_ key: String, _ value: String) async throws {
        _ = try await call(
            "kv/put", ["key": Data(key.utf8).base64EncodedString(), "value": Data(value.utf8).base64EncodedString()])
    }

    private func get(_ key: String) async throws -> String? {
        let response = try await call("kv/range", ["key": Data(key.utf8).base64EncodedString()])
        guard let kvs = response["kvs"] as? [[String: Any]], let value = kvs.first?["value"] as? String,
            let data = Data(base64Encoded: value)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
