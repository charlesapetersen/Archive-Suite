import Foundation

// MARK: - Transport abstraction

/// Injected HTTP transport so tests never touch the network.
protocol ZoteroTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by an ephemeral URLSession.
struct URLSessionZoteroTransport: ZoteroTransport {
    let session: URLSession

    init(timeout: TimeInterval = 10) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        session = URLSession(configuration: cfg)
    }

    /// Dependency-injection seam: run the real transport over a caller-supplied
    /// session. Tests pass a session whose `protocolClasses` intercept requests
    /// (so the production `send` path is exercised without any network egress).
    init(session: URLSession) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// MARK: - CSL model

/// Minimal CSL-JSON item representation (00-overview §D.4).
struct ZoteroCSLItem: Codable, Sendable, Equatable {
    var type: String?
    var title: String?
    var author: [CSLName]?
    var issued: CSLDate?
    var itemType: String?

    struct CSLName: Codable, Sendable, Equatable {
        var family: String?
        var given: String?
        var literal: String?

        var displayName: String {
            if let lit = literal, !lit.isEmpty { return lit }
            return [given, family].compactMap { $0 }.joined(separator: " ")
        }
    }

    struct CSLDate: Codable, Sendable, Equatable {
        var dateParts: [[Int]]?
        var raw: String?

        enum CodingKeys: String, CodingKey {
            case dateParts = "date-parts"
            case raw
        }

        init(dateParts: [[Int]]? = nil, raw: String? = nil) {
            self.dateParts = dateParts
            self.raw = raw
        }

        /// CSL allows a date part to be a number or a numeric string, and Zotero's local API writes strings
        /// (`"date-parts": [["1843"]]`). Each row keeps its parts up to the first one that is not a whole
        /// number, so a year survives an unreadable month rather than the whole item failing to decode.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            raw = try? container.decodeIfPresent(String.self, forKey: .raw)
            let rows = try? container.decodeIfPresent([[DatePart]].self, forKey: .dateParts)
            dateParts = rows.map { rows in
                rows.map { row in Array(row.prefix { $0.value != nil }.compactMap(\.value)) }
            }
        }

        private struct DatePart: Decodable {
            let value: Int?

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) {
                    value = number
                } else if let text = try? container.decode(String.self) {
                    value = Int(text.trimmingCharacters(in: .whitespaces))
                } else {
                    value = nil
                }
            }
        }
    }
}

// MARK: - ZoteroClient actor

/// Off-main-actor client for probing Zotero's localhost API and fetching
/// CSL metadata. All network calls go through an injected `ZoteroTransport`
/// so tests use a stub (00-overview §D.3).
///
/// A fetch asks Zotero for the one item by key and classifies what comes back; it never consults the
/// availability probe. W40.fix-notes-zotero-fetch: on the owner's Mac (a 190 MB library with Better
/// BibTeX) the old probe, a BBT `item.search ""` that lists every item and then `items?limit=1`, timed out
/// at 1.5 s, and every fetch threw `.unavailable` from that cached verdict while Zotero answered a shell.
actor ZoteroClient {

    struct Config: Sendable {
        var host = "127.0.0.1"
        var port = 23119
        /// A fetch's limit. Generous, because a busy Zotero (a large library, a sync) answers slowly.
        var timeout: TimeInterval = 10
        /// The availability probe's limit (never longer than `timeout`).
        var probeTimeout: TimeInterval = 3
    }

    enum Backend: Sendable, Equatable {
        case betterBibTeX
        case localAPI
        case unavailable
    }

    /// Every failure a caller sees. Each says what to check, because the sheet shows it to the user.
    enum ClientError: Error, Sendable, Equatable, LocalizedError {
        /// Zotero integration is switched off in Notes' own Settings.
        case off
        /// Nothing answered at the configured host and port.
        case unavailable
        /// Zotero accepted the connection but did not answer in time.
        case timedOut
        /// Zotero answered that its local API is switched off (HTTP 403).
        case localAPIOff
        case itemNotFound
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .off:
                "Zotero is switched off in Notes. Turn on “Enable Zotero integration” in Notes' Settings (⌘,)."
            case .unavailable:
                "Notes could not reach Zotero. Check that Zotero is running, and that “Allow other applications "
                    + "on this computer to communicate with Zotero” is on in Zotero's Settings ▸ Advanced. "
                    + "Notes looks for it at the host and port in Notes' Settings (⌘,)."
            case .timedOut:
                "Zotero did not answer in time. It may be busy with a large library or a sync; try again in a moment."
            case .localAPIOff:
                "Zotero is running, but it does not let other applications read it. In Zotero's Settings ▸ "
                    + "Advanced, turn on “Allow other applications on this computer to communicate with Zotero”."
            case .itemNotFound:
                "Zotero has no item with this link's key. The item may have been deleted, or be in another library."
            case .unexpectedResponse:
                "Zotero answered in a form Notes cannot read. Notes needs Zotero 7 or later."
            }
        }

        /// Failures that mean another backend could still answer (the local API is off or missing, or it does
        /// not know the item). An unreachable or slow Zotero is not retried: BBT runs in the same process.
        var worthTryingBBT: Bool {
            switch self {
            case .localAPIOff, .itemNotFound, .unexpectedResponse: true
            case .off, .unavailable, .timedOut: false
            }
        }
    }

    private let transport: ZoteroTransport
    private let config: Config

    // Probe cache: (backend, timestamp). TTL = 30s.
    private var cachedBackend: (Backend, Date)?
    private let probeTTL: TimeInterval = 30

    // Per-session in-memory caches.
    private var metaCache: [String: ZoteroCSLItem] = [:]
    private var citationCache: [String: String] = [:]

    init(transport: ZoteroTransport, config: Config = Config()) {
        self.transport = transport
        self.config = config
    }

    /// Convenience: production client with URLSession transport.
    init(config: Config = Config()) {
        self.transport = URLSessionZoteroTransport(timeout: config.timeout)
        self.config = config
    }

    // MARK: - Availability probe

    /// Returns the best available backend, caching the result for 30s. Only a status signal: fetches
    /// do not depend on it.
    func availability() async -> Backend {
        if let (backend, stamp) = cachedBackend,
           Date().timeIntervalSince(stamp) < probeTTL {
            return backend
        }
        let result = await probe()
        cachedBackend = (result, Date())
        return result
    }

    /// Force-refresh the probe cache (for tests / settings change).
    func resetProbeCache() {
        cachedBackend = nil
    }

    private func probe() async -> Backend {
        // Both probes are constant-cost; neither lists the library.
        if await probeLocalAPI() { return .localAPI }
        if await probeBBT() { return .betterBibTeX }
        return .unavailable
    }

    /// `GET /api/` is the local API's root (200 when it is on, 403 when off). A Zotero that does not
    /// answer the root with 200 gets one listing request, `items?limit=1`, before the local API is
    /// written off.
    private func probeLocalAPI() async -> Bool {
        for path in ["/api/", "/api/users/0/items?limit=1"] {
            do {
                let (_, resp) = try await send(request(path: path, timeout: probeTimeout))
                if resp.statusCode == 200 { return true }
                if resp.statusCode == 403 { return false }
            } catch {
                return false
            }
        }
        return false
    }

    /// `api.ready` costs Better BibTeX nothing. Any well-formed JSON-RPC reply (even -32601, an older BBT
    /// without the method) proves BBT is present.
    private func probeBBT() async -> Bool {
        var req = request(path: "/better-bibtex/json-rpc", timeout: probeTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["jsonrpc": "2.0", "method": "api.ready", "params": [] as [Any], "id": 1]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await send(req)
            guard resp.statusCode == 200 else { return false }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["jsonrpc"] != nil else { return false }
            return true
        } catch {
            return false
        }
    }

    private var probeTimeout: TimeInterval { min(config.probeTimeout, config.timeout) }

    // MARK: - Fetch CSL metadata

    /// Fetch CSL-JSON metadata for a Zotero reference: the local API by key first, then Better BibTeX when
    /// the local API cannot answer for this item. Throws a `ClientError`.
    func fetchCSL(_ ref: ZoteroRef) async throws -> ZoteroCSLItem {
        let cacheKey = metaCacheKey(ref)
        if let cached = metaCache[cacheKey] { return cached }
        let item = try await localThenBBT(local: { try await $0.fetchCSLviaLocalAPI(ref) },
                                          bbt: { try await $0.fetchCSLviaBBT(ref) })
        metaCache[cacheKey] = item
        return item
    }

    // MARK: - Fetch formatted citation

    /// Fetch a formatted bibliography citation string, in the same backend order as `fetchCSL`.
    func fetchCitation(_ ref: ZoteroRef, styleID: String = "chicago-note-bibliography") async throws -> String {
        let cacheKey = "\(metaCacheKey(ref))|\(styleID)"
        if let cached = citationCache[cacheKey] { return cached }
        let citation = try await localThenBBT(
            local: { try await $0.fetchCitationViaLocalAPI(ref, styleID: styleID) },
            bbt: { try await $0.fetchCitationViaBBT(ref, styleID: styleID) })
        citationCache[cacheKey] = citation
        return citation
    }

    /// Runs the local-API attempt, falls back to BBT only when that could help, and reports the local
    /// API's error when BBT fails too (it names the setting the user can change). A success refreshes
    /// the availability cache, so the status signal never contradicts a fetch that just worked.
    private func localThenBBT<T: Sendable>(
        local: (isolated ZoteroClient) async throws -> T,
        bbt: (isolated ZoteroClient) async throws -> T
    ) async throws -> T {
        let localError: ClientError
        do {
            let value = try await local(self)
            cachedBackend = (.localAPI, Date())
            return value
        } catch let error as ClientError {
            localError = error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            localError = .unexpectedResponse
        }
        guard localError.worthTryingBBT else { throw localError }
        do {
            let value = try await bbt(self)
            cachedBackend = (.betterBibTeX, Date())
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw localError
        }
    }

    // MARK: - BBT fetch internals

    private func fetchCSLviaBBT(_ ref: ZoteroRef) async throws -> ZoteroCSLItem {
        // Step A: itemKey → citekey
        let libID = bbtLibraryID(ref.library)
        let bbtID = "\(libID):\(ref.itemKey)"

        let ckBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.citationkey",
            "params": [[bbtID]],
            "id": 1,
        ]
        let ckData = try await jsonRPC(ckBody)

        guard let result = ckData["result"] as? [String: String],
              let citekey = result[bbtID] else {
            throw ClientError.itemNotFound
        }

        // Step B: citekey → CSL-JSON via item.export
        let exportBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.export",
            "params": [[citekey], "Better CSL JSON"],
            "id": 2,
        ]
        let expData = try await jsonRPC(exportBody)

        guard let resultStr = expData["result"] as? String else {
            // Retry with translator ID
            let retryBody: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "item.export",
                "params": [[citekey], "f4b52ab0-f878-4556-85a0-c7aeedd09dfc"],
                "id": 3,
            ]
            let retryData = try await jsonRPC(retryBody)
            guard let retryStr = retryData["result"] as? String else {
                throw ClientError.unexpectedResponse
            }
            return try parseCSLArray(retryStr)
        }

        return try parseCSLArray(resultStr)
    }

    private func fetchCitationViaBBT(_ ref: ZoteroRef, styleID: String) async throws -> String {
        let libID = bbtLibraryID(ref.library)
        let bbtID = "\(libID):\(ref.itemKey)"

        // Get citekey first
        let ckBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.citationkey",
            "params": [[bbtID]],
            "id": 1,
        ]
        let ckData = try await jsonRPC(ckBody)
        guard let result = ckData["result"] as? [String: String],
              let citekey = result[bbtID] else {
            throw ClientError.itemNotFound
        }

        // `item.export` takes a translator, not a style; `item.bibliography` renders a CSL style, which it
        // names by the style's full URI (the local API accepts the short ID).
        let styleURI = styleID.contains("://") ? styleID : "http://www.zotero.org/styles/\(styleID)"
        let bibBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.bibliography",
            "params": [[citekey], ["id": styleURI, "contentType": "text"]] as [Any],
            "id": 4,
        ]
        let bibData = try await jsonRPC(bibBody)
        guard let bibStr = bibData["result"] as? String, !bibStr.isEmpty else {
            throw ClientError.unexpectedResponse
        }
        return stripHTMLTags(bibStr)
    }

    // MARK: - Local API fetch internals

    private func fetchCSLviaLocalAPI(_ ref: ZoteroRef) async throws -> ZoteroCSLItem {
        let path = localAPIItemPath(ref)
        let (data, resp) = try await send(request(path: "\(path)?include=csljson", timeout: config.timeout))
        try checkLocalAPIStatus(resp)

        // Local API returns a JSON object with a "csljson" key. Zotero 7+ puts a string there that holds
        // a CSL array (measured on 10.0.6, W40.d10); an object or an array is accepted too.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.unexpectedResponse
        }
        switch json["csljson"] {
        case let text as String:
            return try parseCSLArray(text)
        case let items as [Any]:
            guard let first = items.first else { throw ClientError.itemNotFound }
            return try decodeCSLObject(first)
        case let object as [String: Any]:
            return try decodeCSLObject(object)
        default:
            throw ClientError.unexpectedResponse
        }
    }

    /// `data(withJSONObject:)` raises an Objective-C exception (an abort) on a value it cannot encode,
    /// so only a validated dictionary ever reaches it.
    private func decodeCSLObject(_ value: Any) throws -> ZoteroCSLItem {
        guard let object = value as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw ClientError.unexpectedResponse
        }
        guard let cslData = try? JSONSerialization.data(withJSONObject: object),
              let item = try? JSONDecoder().decode(ZoteroCSLItem.self, from: cslData) else {
            throw ClientError.unexpectedResponse
        }
        return item
    }

    private func fetchCitationViaLocalAPI(_ ref: ZoteroRef, styleID: String) async throws -> String {
        let path = localAPIItemPath(ref)
        let (data, resp) = try await send(request(path: "\(path)?include=bib&style=\(styleID)&linkwrap=0",
                                                  timeout: config.timeout))
        try checkLocalAPIStatus(resp)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bibHTML = json["bib"] as? String else {
            throw ClientError.unexpectedResponse
        }
        return stripHTMLTags(bibHTML)
    }

    // MARK: - Helpers

    private func baseURL(path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = config.host
        components.port = config.port
        // Preserve query from path string if present
        if let qIdx = path.firstIndex(of: "?") {
            components.path = String(path[path.startIndex..<qIdx])
            components.query = String(path[path.index(after: qIdx)...])
        } else {
            components.path = path
        }
        return components.url!
    }

    private func request(path: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: baseURL(path: path))
        req.timeoutInterval = timeout
        return req
    }

    /// The only call into the transport. Whatever the transport throws comes out as a `ClientError`
    /// (or a cancellation), so the user never sees a raw `URLError` or an enum's case number.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw ClientError.timedOut
            default: throw ClientError.unavailable
            }
        } catch {
            throw ClientError.unavailable
        }
    }

    /// 403 is Zotero's answer when "Allow other applications…" is off; 404 is an unknown item (or a
    /// Zotero without the local API, which the BBT fallback then covers).
    private func checkLocalAPIStatus(_ resp: HTTPURLResponse) throws {
        switch resp.statusCode {
        case 200: return
        case 403: throw ClientError.localAPIOff
        case 404: throw ClientError.itemNotFound
        default: throw ClientError.unexpectedResponse
        }
    }

    private func jsonRPC(_ body: [String: Any]) async throws -> [String: Any] {
        var req = request(path: "/better-bibtex/json-rpc", timeout: config.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await send(req)
        guard resp.statusCode == 200 else { throw ClientError.unexpectedResponse }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.unexpectedResponse
        }

        // JSON-RPC error → throw
        if let error = json["error"] as? [String: Any],
           let code = error["code"] as? Int,
           code == -32601 {
            throw ClientError.unexpectedResponse
        }

        return json
    }

    private func localAPIItemPath(_ ref: ZoteroRef) -> String {
        switch ref.library {
        case .user:
            return "/api/users/0/items/\(ref.itemKey)"
        case .group(let gid):
            return "/api/groups/\(gid)/items/\(ref.itemKey)"
        }
    }

    private func bbtLibraryID(_ library: ZoteroLibrary) -> Int {
        switch library {
        case .user: return 1
        case .group(let gid): return gid
        }
    }

    private func parseCSLArray(_ jsonString: String) throws -> ZoteroCSLItem {
        guard let data = jsonString.data(using: .utf8) else {
            throw ClientError.unexpectedResponse
        }
        guard let items = try? JSONDecoder().decode([ZoteroCSLItem].self, from: data) else {
            throw ClientError.unexpectedResponse
        }
        guard let first = items.first else {
            throw ClientError.itemNotFound
        }
        return first
    }

    /// Lightweight regex-based HTML tag stripping (stays off @MainActor).
    private func stripHTMLTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func metaCacheKey(_ ref: ZoteroRef) -> String {
        let libToken: String
        switch ref.library {
        case .user: libToken = "library"
        case .group(let gid): libToken = String(gid)
        }
        return "\(libToken)/\(ref.itemKey)"
    }
}
