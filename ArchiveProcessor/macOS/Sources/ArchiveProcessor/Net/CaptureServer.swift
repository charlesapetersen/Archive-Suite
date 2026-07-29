import Foundation
import Network

/// Minimal HTTP/1.1 receiver for the phone companion app, built on Network.framework.
/// Routes: `GET /ping`, `POST /photo` (raw JPEG body + `X-*` metadata headers), and
/// `POST /session/complete`. All requests must carry `Authorization: Bearer <session token>`.
/// `POST /photo` header contract (body = raw JPEG): REQUIRED `X-Group` (must pass `isSafeGroupId`) and
/// `X-Seq` (Int ≥ 0); OPTIONAL `X-Type` (CaptureGroupType rawValue, default `document`), `X-Device`,
/// `X-Priority`, `X-Year`/`X-Month` (Int), and `X-Replaces` (comma-joined reclassify chain of prior group ids
/// to tombstone, per SPEC A3; each id `isSafeGroupId`-checked individually).
/// Same (group, seq) replaces idempotently. This contract is a shared hotspot — keep it in sync with the
/// phones' `MacClient` (iOS `ArchiveCaptureiOS` + Android `ArchiveCapture`).
/// One request per connection (responses set `Connection: close`); the phone opens a fresh
/// connection per photo, which keeps framing trivial and robust.
/// Mutable listener/connection/budget state is only touched on the serial `queue`, and `session` is a
/// `@MainActor` object always reached via `Task { @MainActor }`, so this is safe to treat as
/// Sendable for the Network.framework callbacks.
final class CaptureServer: @unchecked Sendable, CaptureReceiver {
    private weak var session: CaptureSession?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "capture.server")
    /// The LAN/USB bearer this receiver authenticates: the session's high-entropy `lanToken`, NOT the
    /// SPEC-pinned Drive-relay `token` (W16.lan2 split the two). Constant for the receiver's lifetime.
    private let token: String
    /// All entries are owned by `queue`. Holding the declared body reservation until the response send
    /// completes accounts for bytes that have left the socket buffer but are still retained by a
    /// MainActor ingest task.
    private struct ConnectionState {
        let connection: NWConnection
        var reservedBodyBytes: Int
    }
    private final class BodyAccumulator: @unchecked Sendable {
        var data: Data
        init(_ data: Data) { self.data = data }
    }
    private final class TimeoutHandle: @unchecked Sendable {
        let workItem: DispatchWorkItem
        init(_ workItem: DispatchWorkItem) { self.workItem = workItem }
        func cancel() { workItem.cancel() }
    }
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var aggregateReservedBodyBytes = 0
    /// Per-source failed-auth throttle (owned by `queue`, like the maps above). W16.lan2.
    private var authThrottle = AuthThrottle()

    init(session: CaptureSession) {
        self.session = session
        self.token = session.lanToken
    }

    /// Fixed listen port so the phone's saved pairing (host/port/token) keeps working across Mac
    /// launches. Falls back to a system-assigned port only if this one is already in use.
    private static let preferredPort: UInt16 = 48627

    func start() {
        queue.async { [self] in
            guard self.listener == nil else { return }   // already listening/starting — don't leak a second NWListener
            self.startListening(on: Self.preferredPort)
        }
    }

    private func startListening(on port: UInt16?) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener: NWListener
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: params, on: nwPort)
            } else {
                listener = try NWListener(using: params)   // system-assigned fallback
            }
            listener.service = NWListener.Service(name: "Archive Processor", type: "_archivecap._tcp")

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let boundPort = listener.port?.rawValue ?? 0
                    Task { @MainActor in self?.session?.serverDidStart(port: boundPort) }
                case .failed(let error):
                    if port != nil {
                        // Fixed port busy → fall back to a system-assigned port once.
                        self?.queue.async { [weak self] in self?.retryWithSystemPort() }
                    } else {
                        Task { @MainActor in self?.session?.serverDidFail(error.localizedDescription) }
                    }
                case .cancelled:
                    Task { @MainActor in self?.session?.serverDidStop() }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            if port != nil {
                queue.async { [weak self] in self?.retryWithSystemPort() }
            } else {
                Task { @MainActor in self.session?.serverDidFail(error.localizedDescription) }
            }
        }
    }

    private func retryWithSystemPort() {
        listener?.stateUpdateHandler = nil   // suppress the spurious .cancelled → serverDidStop
        listener?.cancel()
        listener = nil
        startListening(on: nil)
    }

    func stop() {
        queue.async { [self] in
            self.listener?.cancel()
            self.listener = nil
            let openConnections = self.connections.values.map(\.connection)
            self.connections.removeAll()
            self.aggregateReservedBodyBytes = 0
            for connection in openConnections { connection.cancel() }
        }
    }

    // MARK: - Connection handling

    /// How long a connection may remain idle (no complete request received) before we cancel it.
    /// 30 s is generous for a single-request-per-connection protocol over LAN/USB.
    private static let connectionTimeoutSeconds: Int = 30

    /// Bound aggregate file descriptors and declared/retained request bodies, not just each connection.
    /// Eight concurrent phone requests is well above the companion clients' normal fan-out while keeping
    /// a hostile LAN peer from multiplying the per-photo cap into process-wide memory exhaustion.
    static let maxConcurrentConnections = 8
    static let maxAggregateBodyBytes = 96 * 1024 * 1024
    static let maxHeaderBytes = 64 * 1024
    static let headerReadChunkBytes = 16 * 1024
    static let maxPhotoBodyBytes = 64 * 1024 * 1024
    static let maxControlBodyBytes = 64 * 1024

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)

        guard connections.count < Self.maxConcurrentConnections else {
            respond(conn, status: "503 Service Unavailable", json: ["error": "receiver busy"])
            return
        }
        connections[ObjectIdentifier(conn)] = ConnectionState(connection: conn, reservedBodyBytes: 0)

        // Schedule an idle timeout — if no complete request arrives within the deadline,
        // cancel the connection so it doesn't leak an FD + buffers for the process lifetime.
        let timeout = TimeoutHandle(DispatchWorkItem { [weak self, weak conn] in
            guard let conn else { return }
            self?.close(conn)
        })
        queue.asyncAfter(
            deadline: .now() + .seconds(Self.connectionTimeoutSeconds), execute: timeout.workItem)

        readHeaders(conn, buffer: Data(), timeout: timeout)
    }

    /// Read only a small bounded header prefix first. Authentication, route-specific size checks, and an
    /// aggregate reservation all happen before `readBody` is allowed to accumulate the declared payload.
    private func readHeaders(_ conn: NWConnection, buffer: Data, timeout: TimeoutHandle) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.headerReadChunkBytes) { [weak self] data, _, isComplete, error in
            guard let self else { timeout.cancel(); conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch Self.parseHead(buffer) {
            case .parsed(let head, let bodyPrefix):
                // Per-source failed-auth throttle (W16.lan2): a source that has burned through its free
                // 401s is refused BEFORE admission runs, so a hostile LAN peer can't sweep tokens at
                // connection speed. Fail-open for an undeterminable source so a real phone is never
                // collaterally locked out. Belt-and-suspenders atop the ~158-bit `lanToken`.
                let source = Self.sourceKey(for: conn)
                let now = Self.nowMonotonic()
                if self.authThrottle.isThrottled(source, now: now) {
                    timeout.cancel()
                    self.respond(conn, status: "429 Too Many Requests", json: ["error": "too many failed attempts"])
                    return
                }
                let outcome = Self.admission(
                    for: head, token: self.token,
                    aggregateAvailable: Self.maxAggregateBodyBytes - self.aggregateReservedBodyBytes)
                if outcome == .unauthorized {
                    self.authThrottle.recordFailure(source, now: now)
                } else {
                    // Any non-unauthorized outcome means the bearer matched (admission authenticates
                    // first), so this source proved the token — clear its streak so a legit phone that
                    // trips a size/route limit, or re-scans after rotation, recovers immediately.
                    self.authThrottle.recordSuccess(source)
                }
                switch outcome {
                case .unauthorized:
                    timeout.cancel()
                    self.respond(conn, status: "401 Unauthorized", json: ["error": "bad token"])
                case .unknownRoute:
                    timeout.cancel()
                    self.respond(conn, status: "404 Not Found", json: ["error": "unknown route"])
                case .tooLarge:
                    timeout.cancel()
                    self.respond(conn, status: "413 Payload Too Large", json: ["error": "request too large"])
                case .overloaded:
                    timeout.cancel()
                    self.respond(conn, status: "503 Service Unavailable", json: ["error": "receiver memory budget busy"])
                case .accept:
                    guard bodyPrefix.count <= head.contentLength,
                          self.reserveBodyBytes(head.contentLength, for: conn) else {
                        timeout.cancel()
                        self.respond(conn, status: "400 Bad Request", json: ["error": "malformed request"])
                        return
                    }
                    if bodyPrefix.count == head.contentLength {
                        timeout.cancel()
                        self.process(ParsedRequest(head: head, body: bodyPrefix), on: conn)
                    } else {
                        self.readBody(
                            conn, head: head, accumulator: BodyAccumulator(bodyPrefix), timeout: timeout)
                    }
                }
            case .tooLarge:
                timeout.cancel()
                self.respond(conn, status: "413 Payload Too Large", json: ["error": "request too large"])
            case .bad:
                timeout.cancel()
                self.respond(conn, status: "400 Bad Request", json: ["error": "malformed request"])
            case .need:
                if error != nil || isComplete {
                    timeout.cancel()
                    self.respond(conn, status: "400 Bad Request", json: ["error": "incomplete request"])
                } else {
                    self.readHeaders(conn, buffer: buffer, timeout: timeout)
                }
            }
        }
    }

    private func readBody(
        _ conn: NWConnection,
        head: ParsedHead,
        accumulator: BodyAccumulator,
        timeout: TimeoutHandle
    ) {
        let remaining = head.contentLength - accumulator.data.count
        guard remaining > 0 else {
            timeout.cancel()
            process(ParsedRequest(head: head, body: accumulator.data), on: conn)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: min(1 << 20, remaining)) {
            [weak self] data, _, isComplete, error in
            guard let self else { timeout.cancel(); conn.cancel(); return }
            if let data { accumulator.data.append(data) }
            guard accumulator.data.count <= head.contentLength else {
                timeout.cancel()
                self.respond(conn, status: "400 Bad Request", json: ["error": "malformed request"])
                return
            }
            if accumulator.data.count == head.contentLength {
                timeout.cancel()
                self.process(ParsedRequest(head: head, body: accumulator.data), on: conn)
            } else if error != nil || isComplete {
                timeout.cancel()
                self.respond(conn, status: "400 Bad Request", json: ["error": "incomplete request"])
            } else {
                self.readBody(conn, head: head, accumulator: accumulator, timeout: timeout)
            }
        }
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased keys
        let body: Data

        init(head: ParsedHead, body: Data) {
            method = head.method
            path = head.path
            headers = head.headers
            self.body = body
        }
    }

    private struct ParsedHead {
        let method: String
        let path: String
        let headers: [String: String]
        let contentLength: Int
    }

    private enum HeadParseOutcome {
        case need
        case parsed(ParsedHead, bodyPrefix: Data)
        case tooLarge
        case bad
    }

    private enum AdmissionOutcome: String {
        case accept, unauthorized, unknownRoute, tooLarge, overloaded
    }

    /// Parse only the HTTP head and return whatever bounded body prefix arrived in the same socket read.
    /// Critically, this does not wait for `Content-Length` bytes; authorization runs on the result first.
    private static func parseHead(_ buffer: Data) -> HeadParseOutcome {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else {
            return buffer.count > maxHeaderBytes ? .tooLarge : .need
        }
        guard buffer.distance(from: buffer.startIndex, to: range.lowerBound) <= maxHeaderBytes else {
            return .tooLarge
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .bad }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .bad }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .bad }
        let method = String(parts[0])
        let path = String(parts[1])
        guard !path.isEmpty, path.first == "/" else { return .bad }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { return .bad }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[key] == nil,
                  key != "transfer-encoding" else { return .bad }
            headers[key] = value
        }

        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .bad }
        guard let contentLength = Int(rawLength), contentLength >= 0 else { return .tooLarge }
        let bodyStart = range.upperBound
        let bodyPrefix = buffer.subdata(in: bodyStart..<buffer.endIndex)
        return .parsed(
            ParsedHead(method: method, path: path, headers: headers, contentLength: contentLength),
            bodyPrefix: bodyPrefix)
    }

    /// Decide whether a parsed head is allowed to reserve/read a body. Authentication deliberately comes
    /// before route and size disclosure, and aggregate capacity is checked before any recursive body read.
    private static func admission(
        for head: ParsedHead,
        token: String,
        aggregateAvailable: Int
    ) -> AdmissionOutcome {
        let auth = head.headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "),
              constantTimeEquals(String(auth.dropFirst(7)), token) else { return .unauthorized }

        let route = "\(head.method) \(head.path.split(separator: "?").first ?? "")"
        let bodyLimit: Int
        switch route {
        case "POST /photo":
            bodyLimit = maxPhotoBodyBytes
        case "GET /ping", "POST /segment/complete", "POST /session/complete",
             "POST /phone/status", "POST /session/disconnect":
            bodyLimit = maxControlBodyBytes
        default:
            return .unknownRoute
        }
        guard head.contentLength <= bodyLimit else { return .tooLarge }
        guard head.contentLength <= max(0, aggregateAvailable) else { return .overloaded }
        return .accept
    }

    /// Pure no-network regression hook used by the manifest/safety test driver.
    static func _testAdmission(
        requestPrefix: Data,
        token: String,
        aggregateAvailable: Int = maxAggregateBodyBytes
    ) -> String {
        switch parseHead(requestPrefix) {
        case .need: return "need"
        case .tooLarge: return "headerTooLarge"
        case .bad: return "bad"
        case .parsed(let head, let bodyPrefix):
            guard bodyPrefix.count <= head.contentLength else { return "bad" }
            return admission(for: head, token: token, aggregateAvailable: aggregateAvailable).rawValue
        }
    }

    /// Test hook: the bearer the LAN receiver authenticates against — the session's high-entropy
    /// `lanToken`, never the SPEC-pinned Drive-relay `token` (W16.lan2). Read-only.
    var _testActiveToken: String { token }

    // MARK: - Failed-auth throttle (W16.lan2)

    /// Monotonic clock for the throttle (immune to wall-clock adjustments; never runs backward).
    private static func nowMonotonic() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Stable per-remote-host key for the throttle. The ephemeral source PORT is intentionally ignored so
    /// a peer's many short-lived (one-request-per-connection) sockets share ONE bucket. Returns "unknown"
    /// when the remote endpoint can't be determined — callers treat that as fail-open (never throttled).
    private static func sourceKey(for conn: NWConnection) -> String {
        guard case let .hostPort(host, _) = (conn.currentPath?.remoteEndpoint ?? conn.endpoint) else {
            return "unknown"
        }
        switch host {
        case .ipv4(let a): return "v4:\(a.debugDescription)"
        case .ipv6(let a): return "v6:\(a.debugDescription)"
        case .name(let n, _): return "name:\(n)"
        @unknown default: return "unknown"
        }
    }

    /// Per-source failed-auth throttle. Value type; all state is owned by `CaptureServer.queue` (the serial
    /// queue every connection callback runs on), so it needs no extra locking. Belt-and-suspenders on top of
    /// the high-entropy `lanToken`: it bounds the *rate* of token guesses from any one LAN peer and stops a
    /// misconfigured / stale phone from hammering the receiver with a dead credential. A source that has
    /// proven the token (any authenticated request) is cleared immediately, so recovery after a QR re-scan
    /// is bounded by at most one backoff window (`maxBackoff`).
    struct AuthThrottle {
        /// Failed 401s a source may accrue before any backoff applies.
        static let freeAttempts = 5
        /// First backoff once the free attempts are spent; doubles each further failure, capped at `maxBackoff`.
        static let baseBackoff: Double = 2
        static let maxBackoff: Double = 30
        /// A source with no failure for this long is forgotten (its counter resets).
        static let idleReset: Double = 300

        private struct Entry { var failures: Int; var blockedUntil: Double; var lastFailure: Double }
        private var entries: [String: Entry] = [:]

        /// True while `source` is inside a backoff window. Unknown sources fail open (never throttled).
        func isThrottled(_ source: String, now: Double) -> Bool {
            guard source != "unknown", let e = entries[source] else { return false }
            return now < e.blockedUntil
        }

        /// Record a failed auth from `source` and, once past `freeAttempts`, arm an exponential backoff.
        mutating func recordFailure(_ source: String, now: Double) {
            guard source != "unknown" else { return }
            pruneExpired(now: now)   // also resets a long-idle source: its stale entry is dropped here
            var e = entries[source] ?? Entry(failures: 0, blockedUntil: 0, lastFailure: now)
            e.failures += 1
            e.lastFailure = now
            if e.failures > Self.freeAttempts {
                let over = e.failures - Self.freeAttempts
                e.blockedUntil = now + min(Self.maxBackoff, Self.baseBackoff * pow(2, Double(over - 1)))
            }
            entries[source] = e
        }

        /// Clear a source's streak after any authenticated request (it proved the token).
        mutating func recordSuccess(_ source: String) { entries[source] = nil }

        /// Drop sources idle past `idleReset` so the map stays bounded on a busy/hostile LAN.
        private mutating func pruneExpired(now: Double) {
            entries = entries.filter { now - $0.value.lastFailure <= Self.idleReset }
        }
    }

    private func reserveBodyBytes(_ count: Int, for conn: NWConnection) -> Bool {
        let key = ObjectIdentifier(conn)
        guard count >= 0, var state = connections[key], state.reservedBodyBytes == 0,
              count <= Self.maxAggregateBodyBytes - aggregateReservedBodyBytes else { return false }
        state.reservedBodyBytes = count
        connections[key] = state
        aggregateReservedBodyBytes += count
        return true
    }

    private func close(_ conn: NWConnection) {
        if let state = connections.removeValue(forKey: ObjectIdentifier(conn)) {
            aggregateReservedBodyBytes = max(0, aggregateReservedBodyBytes - state.reservedBodyBytes)
        }
        conn.cancel()
    }

    // MARK: - Routing

    private func process(_ req: ParsedRequest, on conn: NWConnection) {
        // Auth: require the exact "Bearer <token>" scheme and a constant-time token match.
        let auth = req.headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "),
              Self.constantTimeEquals(String(auth.dropFirst(7)), token) else {
            respond(conn, status: "401 Unauthorized", json: ["error": "bad token"])
            return
        }

        let route = "\(req.method) \(req.path.split(separator: "?").first ?? "")"
        switch route {
        case "GET /ping":
            Task { @MainActor [weak self] in self?.session?.markPaired() }   // phone paired → hide QR
            respond(conn, status: "200 OK", json: ["ok": true, "app": "ArchiveProcessor"])

        case "POST /photo":
            guard !req.body.isEmpty else {
                respond(conn, status: "400 Bad Request", json: ["error": "empty body"])
                return
            }
            // Require an explicit group + numeric seq. Without this, malformed or rogue uploads collapse
            // to a shared (group:"default", seq:0) key and the idempotent-replace logic silently overwrites
            // a real photo — a "photo is never lost" violation. The Android client always sends both.
            guard let groupId = req.headers["x-group"], !groupId.isEmpty, CaptureValidation.isSafeGroupId(groupId),
                  let seq = (req.headers["x-seq"]).flatMap({ Int($0) }), seq >= 0 else {
                respond(conn, status: "400 Bad Request", json: ["error": "missing or invalid X-Group/X-Seq"])
                return
            }
            let type = CaptureGroupType(rawValue: req.headers["x-type"] ?? "document") ?? .document
            let device = req.headers["x-device"]
            // Minimal on-phone tagging (all optional).
            let priority = (req.headers["x-priority"]).flatMap { $0.isEmpty ? nil : $0 }
            let year = (req.headers["x-year"]).flatMap { Int($0) }
            let month = (req.headers["x-month"]).flatMap { Int($0) }
            // Optional: the reclassify chain (SPEC A3) — comma-joined prior group ids whose (group, seq)
            // copies the Mac should tombstone. Reject if any id is unsafe (matches FileRelayReceiver).
            let rawReplaces: [String] = (req.headers["x-replaces"])
                .map { $0.split(separator: ",").map(String.init).filter { !$0.isEmpty } } ?? []
            guard rawReplaces.allSatisfy({ CaptureValidation.isSafeGroupId($0) }) else {
                respond(conn, status: "400 Bad Request", json: ["error": "unsafe id in X-Replaces chain"])
                return
            }
            let replacesChain = rawReplaces
            let jpeg = req.body
            Task { @MainActor [weak self] in
                let url = self?.session?.ingest(jpeg: jpeg, groupId: groupId, seq: seq, type: type,
                                                priority: priority, year: year, month: month, deviceName: device)
                if url != nil {
                    for rg in replacesChain where rg != groupId {
                        self?.session?.removePhotoIfSafe(groupId: rg, seq: seq)
                    }
                }
                self?.respond(conn, status: url != nil ? "200 OK" : "500 Internal Server Error",
                              json: ["ok": url != nil, "seq": seq])
            }

        case "POST /segment/complete":
            // The phone ended a document segment. Its pages already streamed in (POST /photo, as shot);
            // this signal carries the segment's tags + tells the Mac the group is complete so its tag
            // card can appear (see CaptureSession.markSegmentComplete / pendingTagGroup).
            guard let groupId = req.headers["x-group"], !groupId.isEmpty, CaptureValidation.isSafeGroupId(groupId) else {
                respond(conn, status: "400 Bad Request", json: ["error": "missing or invalid X-Group"])
                return
            }
            let priority = (req.headers["x-priority"]).flatMap { $0.isEmpty ? nil : $0 }
            let year = (req.headers["x-year"]).flatMap { Int($0) }
            let month = (req.headers["x-month"]).flatMap { Int($0) }
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                let durable = self.session?.markSegmentComplete(
                    groupId: groupId, priority: priority, year: year, month: month) ?? false
                self.respond(conn, status: durable ? "200 OK" : "500 Internal Server Error",
                             json: ["ok": durable])
            }

        case "POST /session/complete":
            // Phone finished capturing. Surface the tag card for any still-open document segment (e.g. a
            // last segment the operator didn't tap End segment on) so nothing is stranded, then nudge.
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                let durable = self.session?.completeAllOpenDocGroups() ?? false
                if durable {
                    self.session?.statusMessage = "Phone finished capturing — review any remaining tag cards, then Finish session."
                }
                self.respond(conn, status: durable ? "200 OK" : "500 Internal Server Error",
                             json: ["ok": durable])
            }

        case "POST /phone/status":
            // Heartbeat: how many photos the phone still has un-sent. Lets the Mac surface "phone still
            // has N to send" and hold Finish until the phone has drained.
            let pending = (req.headers["x-pending"]).flatMap { Int($0) } ?? 0
            Task { @MainActor [weak self] in self?.session?.updatePhonePending(max(0, pending)) }
            respond(conn, status: "200 OK", json: ["ok": true])

        case "POST /session/disconnect":
            // The phone re-paired (best-effort notice; there's no persistent connection for the Mac to
            // sense the drop). Reset the pairing + connection indicators and re-show the pairing QR so the
            // operator can immediately re-scan — instead of being stuck on a stale "paired / connected"
            // state having to find "Show QR" (B4-i). Also re-asserts the USB reverse tunnel (B4-iii).
            Task { @MainActor [weak self] in self?.session?.phoneDidDisconnect() }
            respond(conn, status: "200 OK", json: ["ok": true])

        default:
            respond(conn, status: "404 Not Found", json: ["error": "unknown route"])
        }
    }

    // MARK: - Validation helpers

    /// `isSafeGroupId` now lives in `CaptureValidation` (shared with `FileRelayReceiver`).

    /// Length-checked constant-time compare so the Bearer token isn't leaked via response timing.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    // MARK: - Response

    private func respond(_ conn: NWConnection, status: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [weak self, weak conn] _ in
            guard let conn else { return }
            if let self { self.close(conn) } else { conn.cancel() }
        })
    }
}
