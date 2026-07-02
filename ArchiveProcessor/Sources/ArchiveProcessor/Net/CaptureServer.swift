import Foundation
import Network

/// Minimal HTTP/1.1 receiver for the phone companion app, built on Network.framework.
/// Routes: `GET /ping`, `POST /photo` (raw JPEG body + `X-*` metadata headers), and
/// `POST /session/complete`. All requests must carry `Authorization: Bearer <session token>`.
/// One request per connection (responses set `Connection: close`); the phone opens a fresh
/// connection per photo, which keeps framing trivial and robust.
/// Mutable state (`listener`) is only touched on the serial `queue`, and `session` is a
/// `@MainActor` object always reached via `Task { @MainActor }`, so this is safe to treat as
/// Sendable for the Network.framework callbacks.
final class CaptureServer: @unchecked Sendable {
    private weak var session: CaptureSession?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "capture.server")
    private let token: String

    init(session: CaptureSession) {
        self.session = session
        self.token = session.token
    }

    /// Fixed listen port so the phone's saved pairing (host/port/token) keeps working across Mac
    /// launches. Falls back to a system-assigned port only if this one is already in use.
    private static let preferredPort: UInt16 = 48627

    func start() {
        startListening(on: Self.preferredPort)
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
                        self?.queue.async { self?.retryWithSystemPort() }
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
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// Accumulate bytes until the full request (headers + Content-Length body) is available.
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let parsed = Self.tryParse(buffer) {
                self.process(parsed, on: conn)
                return
            }
            if error != nil || isComplete {
                self.respond(conn, status: "400 Bad Request", json: ["error": "incomplete request"])
                return
            }
            self.readRequest(conn, buffer: buffer)   // need more bytes
        }
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased keys
        let body: Data
    }

    /// Returns a ParsedRequest once headers + full Content-Length body are present, else nil.
    private static func tryParse(_ buffer: Data) -> ParsedRequest? {
        let sep = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: sep) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }   // wait for full body
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        return ParsedRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Routing

    private func process(_ req: ParsedRequest, on conn: NWConnection) {
        // Auth: Bearer token must match.
        let auth = req.headers["authorization"] ?? ""
        let presented = auth.replacingOccurrences(of: "Bearer ", with: "")
        guard presented == token else {
            respond(conn, status: "401 Unauthorized", json: ["error": "bad token"])
            return
        }

        let route = "\(req.method) \(req.path.split(separator: "?").first ?? "")"
        switch route {
        case "GET /ping":
            respond(conn, status: "200 OK", json: ["ok": true, "app": "ArchiveProcessor"])

        case "POST /photo":
            guard !req.body.isEmpty else {
                respond(conn, status: "400 Bad Request", json: ["error": "empty body"])
                return
            }
            let groupId = req.headers["x-group"] ?? "default"
            let seq = Int(req.headers["x-seq"] ?? "") ?? 0
            let type = CaptureGroupType(rawValue: req.headers["x-type"] ?? "document") ?? .document
            let device = req.headers["x-device"]
            // Minimal on-phone tagging (all optional).
            let priority = (req.headers["x-priority"]).flatMap { $0.isEmpty ? nil : $0 }
            let year = (req.headers["x-year"]).flatMap { Int($0) }
            let month = (req.headers["x-month"]).flatMap { Int($0) }
            let jpeg = req.body
            Task { @MainActor [weak self] in
                let url = self?.session?.ingest(jpeg: jpeg, groupId: groupId, seq: seq, type: type,
                                                priority: priority, year: year, month: month, deviceName: device)
                self?.respond(conn, status: url != nil ? "200 OK" : "500 Internal Server Error",
                              json: ["ok": url != nil, "seq": seq])
            }

        case "POST /session/complete":
            Task { @MainActor [weak self] in self?.session?.statusMessage = "Session complete — ready to process." }
            respond(conn, status: "200 OK", json: ["ok": true])

        default:
            respond(conn, status: "404 Not Found", json: ["error": "unknown route"])
        }
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
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
