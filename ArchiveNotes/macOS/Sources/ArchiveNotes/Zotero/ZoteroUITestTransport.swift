import Foundation

/// A launch-argument-gated, in-process Zotero response source for the GUI harness. It never opens a
/// socket: all supported requests receive deterministic local JSON, while every normal launch continues
/// to use the production localhost client. This lets the VM prove the full confirmation/write path.
#if DEBUG
private struct ZoteroUITestTransport: ZoteroTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let include = query.first(where: { $0.name == "include" })?.value
        let style = query.first(where: { $0.name == "style" })?.value ?? ""

        if url.path == "/better-bibtex/json-rpc" { return response(url, status: 404, object: [:]) }
        if query.contains(where: { $0.name == "limit" }) { return response(url, status: 200, object: [:]) }
        switch include {
        case "csljson":
            return response(url, status: 200, object: ["csljson": [
                "title": "Analytical Engine Notes",
                "author": [["family": "Lovelace", "given": "Ada"]],
                "issued": ["date-parts": [[1843]]],
            ]])
        case "bib":
            return response(url, status: 200, object: [
                "bib": "<div class=\"csl-entry\">Citation for \(style).</div>",
            ])
        default:
            throw URLError(.resourceUnavailable)
        }
    }

    private func response(_ url: URL, status: Int, object: [String: Any]) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}
#endif

extension ZoteroClient {
    nonisolated static func appClient(config: Config) -> ZoteroClient {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ANUITestZoteroStub") {
            return ZoteroClient(transport: ZoteroUITestTransport(), config: config)
        }
        #endif
        return ZoteroClient(config: config)
    }
}
