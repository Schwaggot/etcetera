import Foundation
import Synchronization

/// TLS behavior for a connection. See SPEC 3.10.
public struct TLSConfiguration: Sendable {
    /// DER or PEM certificates to install as trust anchors instead of the
    /// system roots; a PEM file may hold several. Empty means system trust.
    public var customRootCertificates: [Data]
    /// PKCS#12 blob and passphrase for client certificate authentication.
    public var clientIdentity: (blob: Data, passphrase: String)?
    /// Explicit, loud opt-out of server verification. Defaults to off and the
    /// application shows a persistent warning while it is on.
    public var skipServerVerification: Bool

    public init(
        customRootCertificates: [Data] = [],
        clientIdentity: (blob: Data, passphrase: String)? = nil,
        skipServerVerification: Bool = false
    ) {
        self.customRootCertificates = customRootCertificates
        self.clientIdentity = clientIdentity
        self.skipServerVerification = skipServerVerification
    }
}

/// The `URLSession`-backed transport. One instance per connection.
public final class HTTPTransport: NSObject, EtcdTransport, @unchecked Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let token = Mutex<String?>(nil)
    private let recorder: FixtureRecorder?
    private let tls: TLSConfiguration
    private let identity: ClientIdentity?
    private let delegate: TLSDelegate

    public init(
        endpoint: URL,
        tls: TLSConfiguration = TLSConfiguration(),
        recorder: FixtureRecorder? = nil
    ) throws {
        self.endpoint = endpoint
        self.tls = tls
        self.recorder = recorder
        if let clientIdentity = tls.clientIdentity {
            self.identity = try Self.loadIdentity(
                pkcs12: clientIdentity.blob, passphrase: clientIdentity.passphrase)
        } else {
            self.identity = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        // The 60 second default kills an idle watch.
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil

        let anchors = try Self.rootCertificates(from: tls.customRootCertificates)
        self.delegate = TLSDelegate(tls: tls, anchors: anchors, identity: identity)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func setAuthToken(_ newToken: String?) async {
        token.withLock { $0 = newToken }
    }

    func request(path: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The bare token, no Bearer prefix. etcd 3.2's gateway ignores
        // Authorization and only forwards Grpc-Metadata-Token.
        if let token = token.withLock({ $0 }) {
            request.setValue(token, forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "Grpc-Metadata-Token")
        }
        return request
    }

    private func perform(_ urlRequest: URLRequest, path: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw mapTransportError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        recorder?.record(
            path: path, method: urlRequest.httpMethod ?? "POST",
            requestBody: urlRequest.httpBody, status: status, responseBody: data)
        guard status == 200 else {
            throw GatewayErrorMapper.error(status: status, body: data)
        }
        return data
    }

    public func unary(path: String, body: Data) async throws -> Data {
        try await perform(request(path: path, method: "POST", body: body), path: path)
    }

    public func get(path: String) async throws -> Data {
        try await perform(request(path: path, method: "GET", body: nil), path: path)
    }

    func streamRequest(path: String, body: Data) -> URLRequest {
        var request = request(path: path, method: "POST", body: body)
        // The request's own 60 second default would override the session's.
        request.timeoutInterval = 3600
        return request
    }

    public func stream(path: String, body: Data) -> AsyncThrowingStream<Data, any Error> {
        let urlRequest = streamRequest(path: path, body: body)
        let session = self.session
        let recorder = self.recorder
        return AsyncThrowingStream { continuation in
            let task = Task {
                var status = 0
                var lines: [String] = []
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var collected = Data()
                        for try await byte in bytes { collected.append(byte) }
                        recorder?.recordStream(
                            path: path, requestBody: body, status: status,
                            lines: [String(decoding: collected, as: UTF8.self)], stayedOpen: false)
                        throw GatewayErrorMapper.error(status: status, body: collected)
                    }
                    var framer = JSONObjectFramer()
                    for try await byte in bytes {
                        guard let value = framer.append(byte) else { continue }
                        if recorder != nil { lines.append(String(decoding: value, as: UTF8.self)) }
                        continuation.yield(value)
                    }
                    recorder?.recordStream(
                        path: path, requestBody: body, status: status, lines: lines, stayedOpen: false)
                    continuation.finish()
                } catch {
                    if status == 200 {
                        recorder?.recordStream(
                            path: path, requestBody: body, status: status, lines: lines,
                            stayedOpen: Task.isCancelled)
                    }
                    continuation.finish(throwing: self.mapTransportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func mapTransportError(_ error: any Error) -> any Error {
        Self.mapTransportError(error, trustFailure: Task.isCancelled ? nil : delegate.trustFailure)
    }

    /// `trustFailure` is why the delegate rejected the server, which
    /// URLSession reports only as a cancellation.
    static func mapTransportError(_ error: any Error, trustFailure: String?) -> any Error {
        if error is EtcdError || error is HTTPStatusError { return error }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                if let trustFailure {
                    return EtcdError.tls(.untrustedServerCertificate(reason: trustFailure))
                }
            case NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorSecureConnectionFailed:
                return EtcdError.tls(.untrustedServerCertificate(reason: nsError.localizedDescription))
            case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return EtcdError.tls(.clientIdentityRejected)
            default:
                break
            }
        }
        return EtcdError.transport(underlying: error)
    }

    /// The identity plus the intermediates to send with it; a server that
    /// trusts only the root cannot build the chain from the leaf alone.
    static func loadIdentity(pkcs12: Data, passphrase: String) throws -> ClientIdentity {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(pkcs12 as CFData, options, &items)
        guard status == errSecSuccess,
            let array = items as? [[String: Any]],
            let first = array.first,
            let identityRef = first[kSecImportItemIdentity as String]
        else {
            let reason = status == errSecAuthFailed
                ? String(localized: "wrong passphrase", bundle: .module)
                : String(localized: "import failed (OSStatus \(Int(status)))", bundle: .module)
            throw EtcdError.tls(.invalidPKCS12(reason: reason))
        }
        let identity = identityRef as! SecIdentity
        var leaf: SecCertificate?
        SecIdentityCopyCertificate(identity, &leaf)
        let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate] ?? [])
            .filter { certificate in leaf.map { !CFEqual($0, certificate) } ?? true }
        return ClientIdentity(identity: identity, intermediates: chain)
    }

    /// Unreadable data throws rather than being dropped, which would leave
    /// the user trusting fewer CAs than they configured.
    static func rootCertificates(from files: [Data]) throws -> [SecCertificate] {
        var certificates: [SecCertificate] = []
        for (index, file) in files.enumerated() {
            for der in pemBlocks(in: file) ?? [file] {
                guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw EtcdError.tls(
                        .invalidRootCertificate(
                            reason: String(localized: "file \(index + 1) is neither a DER nor a PEM certificate", bundle: .module)))
                }
                certificates.append(certificate)
            }
        }
        return certificates
    }

    /// The DER bodies of every PEM certificate block, nil when there are none.
    private static func pemBlocks(in file: Data) -> [Data]? {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        let text = String(decoding: file, as: UTF8.self)
        var rest = text[...]
        var blocks: [Data] = []
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            blocks.append(Data(base64Encoded: String(body)) ?? Data())
            rest = rest[stop.upperBound...]
        }
        return blocks.isEmpty ? nil : blocks
    }
}

struct ClientIdentity {
    let identity: SecIdentity
    let intermediates: [SecCertificate]
}

/// Handles the two TLS concerns: custom trust anchors and client identity.
private final class TLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let tls: TLSConfiguration
    let anchors: [SecCertificate]
    let identity: ClientIdentity?
    private let lastTrustFailure = Mutex<String?>(nil)

    var trustFailure: String? { lastTrustFailure.withLock { $0 } }

    init(tls: TLSConfiguration, anchors: [SecCertificate], identity: ClientIdentity?) {
        self.tls = tls
        self.anchors = anchors
        self.identity = identity
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if tls.skipServerVerification {
                // Explicit opt-out; the application shows a persistent warning.
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            guard !anchors.isEmpty else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var evaluationError: CFError?
            let trusted = SecTrustEvaluateWithError(trust, &evaluationError)
            lastTrustFailure.withLock {
                $0 = trusted ? nil
                    : evaluationError.map { ($0 as Error).localizedDescription }
                        ?? String(localized: "the chain does not lead to the configured CA", bundle: .module)
            }
            if trusted {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            if let identity {
                completionHandler(
                    .useCredential,
                    URLCredential(
                        identity: identity.identity, certificates: identity.intermediates, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
