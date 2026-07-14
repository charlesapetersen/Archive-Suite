import Foundation

// MARK: - Transport abstraction

/// Injected HTTP transport so tests never touch the network.
protocol ZoteroTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by an ephemeral URLSession.
struct URLSessionZoteroTransport: ZoteroTransport {
    let session: URLSession

    init(timeout: TimeInterval = 1.5) {
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
    }
}

// MARK: - ZoteroClient actor

/// Off-main-actor client for probing Zotero's localhost API and fetching
/// CSL metadata. All network calls go through an injected `ZoteroTransport`
/// so tests use a stub (00-overview §D.3).
actor ZoteroClient {

    struct Config: Sendable {
        var host = "127.0.0.1"
        var port = 23119
        var timeout: TimeInterval = 1.5
    }

    enum Backend: Sendable, Equatable {
        case betterBibTeX
        case localAPI
        case unavailable
    }

    enum ClientError: Error, Sendable {
        case unavailable
        case itemNotFound
        case unexpectedResponse
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

    /// Returns the best available backend, caching the result for 30s.
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
        // 1. Try Better BibTeX JSON-RPC ping.
        if await probeBBT() { return .betterBibTeX }
        // 2. Try Zotero 7 local API.
        if await probeLocalAPI() { return .localAPI }
        return .unavailable
    }

    private func probeBBT() async -> Bool {
        let url = baseURL(path: "/better-bibtex/json-rpc")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.search",
            "params": [""],
            "id": 1,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await transport.send(req)
            guard resp.statusCode == 200 else { return false }
            // Any well-formed JSON-RPC reply (even -32601) proves BBT is present.
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["jsonrpc"] != nil else { return false }
            return true
        } catch {
            return false
        }
    }

    private func probeLocalAPI() async -> Bool {
        let url = baseURL(path: "/api/users/0/items?limit=1")
        let req = URLRequest(url: url)
        do {
            let (_, resp) = try await transport.send(req)
            return resp.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Fetch CSL metadata

    /// Fetch CSL-JSON metadata for a Zotero reference. Uses the best available
    /// backend, falling through from BBT → local API → error.
    func fetchCSL(_ ref: ZoteroRef) async throws -> ZoteroCSLItem {
        let cacheKey = metaCacheKey(ref)
        if let cached = metaCache[cacheKey] { return cached }

        let backend = await availability()
        let item: ZoteroCSLItem

        switch backend {
        case .betterBibTeX:
            if let bbt = try? await fetchCSLviaBBT(ref) {
                item = bbt
            } else if let local = try? await fetchCSLviaLocalAPI(ref) {
                item = local
            } else {
                throw ClientError.itemNotFound
            }
        case .localAPI:
            item = try await fetchCSLviaLocalAPI(ref)
        case .unavailable:
            throw ClientError.unavailable
        }

        metaCache[cacheKey] = item
        return item
    }

    // MARK: - Fetch formatted citation

    /// Fetch a formatted bibliography citation string.
    func fetchCitation(_ ref: ZoteroRef, styleID: String = "chicago-note-bibliography") async throws -> String {
        let cacheKey = "\(metaCacheKey(ref))|\(styleID)"
        if let cached = citationCache[cacheKey] { return cached }

        let backend = await availability()
        let citation: String

        switch backend {
        case .betterBibTeX:
            if let bbt = try? await fetchCitationViaBBT(ref, styleID: styleID) {
                citation = bbt
            } else if let local = try? await fetchCitationViaLocalAPI(ref, styleID: styleID) {
                citation = local
            } else {
                throw ClientError.itemNotFound
            }
        case .localAPI:
            citation = try await fetchCitationViaLocalAPI(ref, styleID: styleID)
        case .unavailable:
            throw ClientError.unavailable
        }

        citationCache[cacheKey] = citation
        return citation
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

        // Export with the requested style
        let exportBody: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "item.export",
            "params": [[citekey], styleID],
            "id": 4,
        ]
        let expData = try await jsonRPC(exportBody)
        guard let bibStr = expData["result"] as? String else {
            throw ClientError.unexpectedResponse
        }
        return stripHTMLTags(bibStr)
    }

    // MARK: - Local API fetch internals

    private func fetchCSLviaLocalAPI(_ ref: ZoteroRef) async throws -> ZoteroCSLItem {
        let path = localAPIItemPath(ref)
        let url = baseURL(path: "\(path)?include=csljson")
        let req = URLRequest(url: url)

        let (data, resp) = try await transport.send(req)
        guard resp.statusCode == 200 else { throw ClientError.itemNotFound }

        // Local API returns a JSON object with a "csljson" key.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cslJSON = json["csljson"] else {
            throw ClientError.unexpectedResponse
        }
        let cslData = try JSONSerialization.data(withJSONObject: cslJSON)
        return try JSONDecoder().decode(ZoteroCSLItem.self, from: cslData)
    }

    private func fetchCitationViaLocalAPI(_ ref: ZoteroRef, styleID: String) async throws -> String {
        let path = localAPIItemPath(ref)
        let url = baseURL(path: "\(path)?include=bib&style=\(styleID)&linkwrap=0")
        let req = URLRequest(url: url)

        let (data, resp) = try await transport.send(req)
        guard resp.statusCode == 200 else { throw ClientError.itemNotFound }

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

    private func jsonRPC(_ body: [String: Any]) async throws -> [String: Any] {
        let url = baseURL(path: "/better-bibtex/json-rpc")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await transport.send(req)
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
        let items = try JSONDecoder().decode([ZoteroCSLItem].self, from: data)
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
