import Foundation

/// gRPC status codes as reported by the gateway's JSON error body.
public enum GRPCStatusCode: Int, Sendable, Codable, Hashable {
    case ok = 0
    case cancelled = 1
    case unknown = 2
    case invalidArgument = 3
    case deadlineExceeded = 4
    case notFound = 5
    case alreadyExists = 6
    case permissionDenied = 7
    case resourceExhausted = 8
    case failedPrecondition = 9
    case aborted = 10
    case outOfRange = 11
    case unimplemented = 12
    case internalError = 13
    case unavailable = 14
    case dataLoss = 15
    case unauthenticated = 16
}

/// TLS failures that deserve a precise user-facing explanation.
public enum TLSFailure: Sendable {
    case untrustedServerCertificate(reason: String)
    case clientIdentityRejected
    case invalidPKCS12(reason: String)
    case invalidRootCertificate(reason: String)
}

public enum EtcdError: Error, Sendable {
    case transport(underlying: any Error)
    case tls(TLSFailure)
    /// 404 on every probed prefix: the cluster runs without the JSON gateway.
    case gatewayUnavailable
    case unauthenticated
    case permissionDenied
    case status(code: GRPCStatusCode, message: String)
    case compacted(revision: Int64)
    case decoding(String)
    case unsupported(feature: String, requires: String)
}

extension EtcdError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let underlying):
            return String(localized: "Network failure: \(underlying.localizedDescription)", bundle: .module)
        case .tls(let failure):
            switch failure {
            case .untrustedServerCertificate(let reason):
                return String(localized: "The server certificate is not trusted: \(reason)", bundle: .module)
            case .clientIdentityRejected:
                return String(localized: "The server rejected the client certificate.", bundle: .module)
            case .invalidPKCS12(let reason):
                return String(localized: "The PKCS#12 file could not be read: \(reason)", bundle: .module)
            case .invalidRootCertificate(let reason):
                return String(localized: "The CA certificate could not be read: \(reason)", bundle: .module)
            }
        case .gatewayUnavailable:
            return String(
                localized: "This etcd cluster was started without the JSON gateway (--enable-grpc-gateway=false), so etcetera cannot connect to it.",
                bundle: .module)
        case .unauthenticated:
            return String(localized: "Authentication is required or the credentials were rejected.", bundle: .module)
        case .permissionDenied:
            return String(localized: "The user lacks permission for this operation.", bundle: .module)
        case .status(let code, let message):
            return String(localized: "etcd error (\(String(describing: code))): \(message)", bundle: .module)
        case .compacted(let revision):
            return String(
                localized: "The requested revision has been compacted away (compact revision \(revision)).",
                bundle: .module)
        case .decoding(let detail):
            return String(localized: "Unexpected response from the gateway: \(detail)", bundle: .module)
        case .unsupported(let feature, let requires):
            return String(localized: "\(feature) requires etcd \(requires) or later.", bundle: .module)
        }
    }
}

/// A non-2xx HTTP response whose body is not a gateway error envelope.
/// Version probing relies on seeing the raw 404.
public struct HTTPStatusError: Error, Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// Maps a gateway HTTP response to a typed error.
///
/// The gateway reports gRPC failures as an HTTP status with a JSON body
/// carrying `error`, `code`, and `message`. The server's message is kept
/// verbatim.
public enum GatewayErrorMapper {
    struct ErrorBody: Decodable {
        var error: String?
        var code: Int?
        /// Mid-stream errors from grpc-gateway v1 (etcd 3.2 to 3.5) carry this instead of `code`.
        var grpcCode: Int?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case error, code, message
            case grpcCode = "grpc_code"
        }
    }

    public static func error(status: Int, body: Data) -> any Error {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body),
            let error = error(from: parsed)
        {
            return error
        }
        // Proxies in front of the gateway reject auth without a gRPC body.
        switch status {
        case 401: return EtcdError.unauthenticated
        case 403: return EtcdError.permissionDenied
        default: return HTTPStatusError(status: status, body: body)
        }
    }

    /// A raw HTTP status that reached a call after connect, with the gRPC
    /// code the gateway would have used for it.
    static func etcdError(for error: HTTPStatusError) -> EtcdError {
        let code: GRPCStatusCode =
            switch error.status {
            case 400: .invalidArgument
            case 408, 504: .deadlineExceeded
            case 429: .resourceExhausted
            case 501: .unimplemented
            case 502, 503: .unavailable
            default: .unknown
            }
        let text = String(decoding: error.body.prefix(200), as: UTF8.self)
        return .status(code: code, message: String(localized: "HTTP \(error.status): \(text)", bundle: .module))
    }

    /// Nil when the body carries no gRPC code.
    static func error(from body: ErrorBody) -> EtcdError? {
        guard let rawCode = body.code ?? body.grpcCode else { return nil }
        let message = body.message ?? body.error ?? ""
        // "required revision has been compacted" arrives as OUT_OF_RANGE.
        let code = GRPCStatusCode(rawValue: rawCode) ?? .unknown
        switch code {
        case .unauthenticated:
            return .unauthenticated
        case .permissionDenied:
            return .permissionDenied
        default:
            return .status(code: code, message: message)
        }
    }
}
