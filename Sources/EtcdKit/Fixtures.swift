import Foundation
import Synchronization

/// One recorded exchange: what was sent, what came back.
public struct FixtureExchange: Codable, Sendable {
    public var path: String
    public var method: String
    /// Request body as a UTF-8 JSON string, empty for GET.
    public var request: String
    public var status: Int
    /// Response body as a UTF-8 JSON string. Empty for streams.
    public var response: String
    /// For streaming exchanges, one element per response line.
    public var streamLines: [String]?
    /// The client closed the stream while the server still held it open.
    public var streamStayedOpen: Bool?

    public init(
        path: String, method: String = "POST", request: String = "", status: Int = 200,
        response: String, streamLines: [String]? = nil, streamStayedOpen: Bool? = nil
    ) {
        self.path = path
        self.method = method
        self.request = request
        self.status = status
        self.response = response
        self.streamLines = streamLines
        self.streamStayedOpen = streamStayedOpen
    }
}

/// Record mode for `HTTPTransport`: captures every exchange to a JSON Lines
/// file so fixtures come from real etcd instances, not from imagination.
/// Re-recording is a script, not a manual task. Passwords are redacted.
public final class FixtureRecorder: @unchecked Sendable {
    private let fileURL: URL
    private let lock = Mutex<Void>(())

    public init(writingTo fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(path: String, method: String, requestBody: Data?, status: Int, responseBody: Data) {
        append(
            FixtureExchange(
                path: path,
                method: method,
                request: Self.redacted(requestBody),
                status: status,
                response: String(decoding: responseBody, as: UTF8.self)))
    }

    func recordStream(path: String, requestBody: Data?, status: Int, lines: [String], stayedOpen: Bool) {
        append(
            FixtureExchange(
                path: path,
                request: Self.redacted(requestBody),
                status: status,
                response: "",
                streamLines: lines,
                streamStayedOpen: stayedOpen))
    }

    private func append(_ exchange: FixtureExchange) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(exchange) else { return }
        line.append(0x0A)
        lock.withLock { _ in
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    static func redacted(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "" }
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            object["password"] != nil
        else {
            return String(decoding: body, as: UTF8.self)
        }
        object["password"] = "<redacted>"
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func load(from fileURL: URL) throws -> [FixtureExchange] {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            try decoder.decode(FixtureExchange.self, from: Data($0.utf8))
        }
    }
}
