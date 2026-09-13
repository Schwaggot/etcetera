import Foundation

public actor EtcdClient {
    public struct Configuration: Sendable {
        public var endpoint: URL
        public var tls: TLSConfiguration
        /// Skips detection when set; useful behind proxies that rewrite paths.
        public var pinnedPrefix: String?
        /// Injected transport for tests and recording; nil builds HTTPTransport.
        public var transport: (any EtcdTransport)?
        /// Injected time for backoff. Tests supply a controlled clock.
        public var clock: any Clock<Duration>

        public init(
            endpoint: URL,
            tls: TLSConfiguration = TLSConfiguration(),
            pinnedPrefix: String? = nil,
            transport: (any EtcdTransport)? = nil,
            clock: any Clock<Duration> = ContinuousClock()
        ) {
            self.endpoint = endpoint
            self.tls = tls
            self.pinnedPrefix = pinnedPrefix
            self.transport = transport
            self.clock = clock
        }
    }

    /// The resolved gateway path prefix, cached for the client's lifetime.
    public nonisolated let apiPrefix: String
    /// Server version from detection, nil when the prefix was pinned and
    /// `/version` was unreachable.
    public nonisolated let serverVersion: ServerVersion?
    public nonisolated var capabilities: ServerCapabilities {
        ServerCapabilities(version: serverVersion)
    }

    let transport: any EtcdTransport
    private let clock: any Clock<Duration>
    private var credentials: (name: String, password: String)?
    /// Bumped when a re-authentication starts; calls sent before it share it.
    private var tokenGeneration = 0
    private var renewal: Task<Void, any Error>?

    /// Connecting runs version detection once. See SPEC 3.4.
    public init(configuration: Configuration) async throws {
        let transport = try configuration.transport
            ?? HTTPTransport(endpoint: configuration.endpoint, tls: configuration.tls)
        self.transport = transport
        self.clock = configuration.clock

        // Stage one: GET /version, which needs no auth and predates the gateway.
        let detected: ServerVersion? = try await Self.detectVersion(transport: transport)

        if let pinned = configuration.pinnedPrefix {
            self.apiPrefix = pinned
            self.serverVersion = detected
            return
        }

        if let detected {
            self.apiPrefix = PrefixResolver.prefix(for: detected)
            self.serverVersion = detected
            return
        }

        // Stage two: probe prefixes newest first with a status call and take
        // the first that is not 404.
        self.apiPrefix = try await Self.probePrefix(transport: transport)
        self.serverVersion = nil
    }

    /// Nil when `/version` answers with something unparseable. TLS failures
    /// throw: probing would only fail the same way with a vaguer message.
    private static func detectVersion(transport: any EtcdTransport) async throws -> ServerVersion? {
        let data: Data
        do {
            data = try await transport.get(path: "/version")
        } catch let error as EtcdError {
            if case .tls = error { throw error }
            return nil
        } catch {
            return nil
        }
        guard let info = try? JSONDecoder().decode(VersionInfo.self, from: data) else {
            return nil
        }
        return ServerVersion(parsing: info.etcdserver)
    }

    private static func probePrefix(transport: any EtcdTransport) async throws -> String {
        let body = Data("{}".utf8)
        for prefix in PrefixResolver.probeOrder {
            do {
                _ = try await transport.unary(path: "\(prefix)/maintenance/status", body: body)
                return prefix
            } catch let error as HTTPStatusError where error.status == 404 {
                continue
            } catch is HTTPStatusError {
                // Any other status, even a proxy's, means the path is served.
                return prefix
            } catch let error as EtcdError {
                if case .transport = error { throw error }
                if case .tls = error { throw error }
                // A gateway error (even unauthenticated) proves the prefix exists.
                return prefix
            }
        }
        throw EtcdError.gatewayUnavailable
    }

    // MARK: - Request plumbing

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw EtcdError.decoding("failed to encode request: \(error)")
        }
    }

    private func decodeResponse<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EtcdError.decoding("failed to decode \(Response.self): \(error)")
        }
    }

    private func send<Response: Decodable>(
        _ path: String, _ body: Data, as type: Response.Type
    ) async throws -> Response {
        let data: Data
        do {
            data = try await transport.unary(path: apiPrefix + path, body: body)
        } catch let error as HTTPStatusError {
            // `/version` predates the gateway, so detection can succeed
            // against a cluster whose gateway is off.
            if error.status == 404 { throw EtcdError.gatewayUnavailable }
            throw GatewayErrorMapper.etcdError(for: error)
        }
        return try decodeResponse(type, from: data)
    }

    /// One unary call with the resolved prefix applied. A 401 triggers one
    /// transparent re-authentication and one retry; a second failure
    /// propagates. See SPEC 3.9.
    func call<Response: Decodable>(
        _ path: String, _ request: some Encodable, as type: Response.Type
    ) async throws -> Response {
        let body = try encode(request)
        let generation = tokenGeneration
        do {
            return try await send(path, body, as: type)
        } catch EtcdError.unauthenticated where credentials != nil {
            try await reauthenticate(after: generation)
            return try await send(path, body, as: type)
        }
    }

    /// Concurrent 401s share one renewal, so none clears the token another
    /// just installed.
    private func reauthenticate(after generation: Int) async throws {
        guard let credentials else { throw EtcdError.unauthenticated }
        if generation == tokenGeneration {
            tokenGeneration += 1
            renewal = Task {
                // Older servers check the token even on Authenticate and reject the expired one.
                await transport.setAuthToken(nil)
                try await fetchToken(name: credentials.name, password: credentials.password)
            }
        }
        try await renewal?.value
    }

    private func fetchToken(name: String, password: String) async throws {
        let body = try encode(AuthenticateRequest(name: name, password: password))
        let response = try await send("/auth/authenticate", body, as: AuthenticateResponse.self)
        guard let token = response.token else {
            throw EtcdError.decoding("authenticate response carried no token")
        }
        await transport.setAuthToken(token)
    }

    // MARK: - Key and value

    public func range(_ request: RangeRequest) async throws -> RangeResponse {
        try await call("/kv/range", request, as: RangeResponse.self)
    }

    public func put(_ request: PutRequest) async throws -> PutResponse {
        try await call("/kv/put", request, as: PutResponse.self)
    }

    public func delete(_ request: DeleteRangeRequest) async throws -> DeleteRangeResponse {
        try await call("/kv/deleterange", request, as: DeleteRangeResponse.self)
    }

    public func txn(_ request: TxnRequest) async throws -> TxnResponse {
        try await call("/kv/txn", request, as: TxnResponse.self)
    }

    public func compact(revision: Int64, physical: Bool = false) async throws {
        _ = try await call(
            "/kv/compaction",
            CompactionRequest(revision: revision, physical: physical),
            as: EmptyMessage.self)
    }

    // MARK: - Lease

    public func leaseGrant(ttl: Int64, id: Int64 = 0) async throws -> LeaseGrantResponse {
        try await call("/lease/grant", LeaseGrantRequest(ttl: ttl, id: id), as: LeaseGrantResponse.self)
    }

    public func leaseRevoke(id: Int64) async throws {
        _ = try await call("/kv/lease/revoke", LeaseRevokeRequest(id: id), as: EmptyMessage.self)
    }

    public func leaseTimeToLive(id: Int64, keys: Bool = false) async throws -> LeaseTimeToLiveResponse {
        try await call(
            "/kv/lease/timetolive",
            LeaseTimeToLiveRequest(id: id, keys: keys ? true : nil),
            as: LeaseTimeToLiveResponse.self)
    }

    public func leases() async throws -> [Int64] {
        guard capabilities.canListLeases || serverVersion == nil else {
            throw EtcdError.unsupported(
                feature: String(
                    localized: "Listing leases", bundle: .module,
                    comment: "Feature name, shown as: <feature> requires etcd 3.3 or later."),
                requires: "3.3")
        }
        // 3.3 serves only the /kv/lease spelling; later versions keep it as an alias.
        let response = try await call("/kv/lease/leases", EmptyMessage(), as: LeaseLeasesResponse.self)
        return (response.leases ?? []).compactMap { $0.id?.wrappedValue }
    }

    // MARK: - Cluster and maintenance

    public func status() async throws -> StatusResponse {
        try await call("/maintenance/status", EmptyMessage(), as: StatusResponse.self)
    }

    public func members() async throws -> [Member] {
        let response = try await call("/cluster/member/list", EmptyMessage(), as: MemberListResponse.self)
        return response.members ?? []
    }

    // MARK: - Auth

    /// Fetches a token and holds the credentials for transparent re-auth.
    /// Credentials are never written anywhere.
    public func authenticate(name: String, password: String) async throws {
        try await fetchToken(name: name, password: password)
        credentials = (name, password)
    }

    // MARK: - Watch

    /// One HTTP connection per watch; cancelling the consuming task closes
    /// it. Reconnects with backoff on transport failure or server-side
    /// unavailability, resuming from the last observed revision plus one, so
    /// no events are lost. A rejected token gets one re-authentication, as
    /// for unary calls. Ends with `EtcdError.compacted` when the server
    /// compacted past the resume point.
    public nonisolated func watch(_ request: WatchCreateRequest) -> AsyncThrowingStream<WatchEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runWatch(request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runWatch(
        _ request: WatchCreateRequest,
        continuation: AsyncThrowingStream<WatchEvent, any Error>.Continuation
    ) async {
        var request = request
        var attempt = 0
        var reauthenticated = false
        while !Task.isCancelled {
            let generation = tokenGeneration
            do {
                let body = try encode(["create_request": request])
                let lines = transport.stream(path: apiPrefix + "/watch", body: body)
                for try await line in lines {
                    guard !line.isEmpty else { continue }
                    let parsed = try JSONDecoder().decode(WatchStreamLine.self, from: line)
                    if let errorBody = parsed.error {
                        throw GatewayErrorMapper.error(from: errorBody)
                            ?? EtcdError.status(
                                code: .unknown, message: errorBody.message ?? errorBody.error
                                    ?? String(localized: "watch failed", bundle: .module))
                    }
                    guard let result = parsed.result else { continue }
                    if let compact = result.compactRevision?.wrappedValue, compact > 0 {
                        // Compacted past the resume point: the caller must do
                        // a fresh range read.
                        continuation.finish(throwing: EtcdError.compacted(revision: compact))
                        return
                    }
                    // Watch auth is checked only at creation, and fails as a cancel rather than a 401.
                    if result.canceled == true, result.cancelReason == "etcdserver: invalid auth token" {
                        throw EtcdError.unauthenticated
                    }
                    if result.canceled == true {
                        continuation.finish(
                            throwing: EtcdError.status(
                                code: .cancelled, message: result.cancelReason ?? String(localized: "watch canceled", bundle: .module)))
                        return
                    }
                    let headerRevision = result.header?.revision ?? 0
                    let events = result.events ?? []
                    if let last = events.last?.kv, last.modRevision > 0 {
                        // Header revisions run ahead of replayed history, so
                        // only delivered events move the resume point.
                        request.startRevision = last.modRevision + 1
                    } else if request.startRevision == 0, headerRevision > 0 {
                        request.startRevision = headerRevision + 1
                    }
                    attempt = 0
                    reauthenticated = false
                    for event in events {
                        guard let kv = event.kv else { continue }
                        continuation.yield(
                            WatchEvent(
                                kind: event.type ?? .put, kv: kv, prevKv: event.prevKv,
                                revision: kv.modRevision > 0 ? kv.modRevision : headerRevision))
                    }
                }
                // Server closed the stream cleanly; reconnect from the resume point.
            } catch is CancellationError {
                continuation.finish()
                return
            } catch let error as HTTPStatusError where error.status == 404 {
                continuation.finish(throwing: EtcdError.gatewayUnavailable)
                return
            } catch EtcdError.unauthenticated where credentials != nil && !reauthenticated {
                do {
                    try await reauthenticate(after: generation)
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? nil : error)
                    return
                }
                reauthenticated = true
                continue  // the new token needs no backoff
            } catch {
                guard Self.isRetryable(error) else {
                    let mapped = (error as? HTTPStatusError).map(GatewayErrorMapper.etcdError(for:)) ?? error
                    continuation.finish(throwing: mapped)
                    return
                }
            }
            if Task.isCancelled { break }
            attempt += 1
            let backoff = Duration.milliseconds(min(200 << min(attempt - 1, 5), 5000))
            do {
                try await clock.sleep(for: backoff)
            } catch {
                break
            }
        }
        continuation.finish()
    }

    /// Transport failures and a server that is briefly unavailable are worth
    /// a reconnect; anything else would fail the same way again.
    private static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case let error as HTTPStatusError:
            return (500...599).contains(error.status) && error.status != 501
        case EtcdError.transport:
            return true
        case EtcdError.status(let code, _):
            return code == .unavailable || code == .deadlineExceeded
        default:
            return false
        }
    }
}
