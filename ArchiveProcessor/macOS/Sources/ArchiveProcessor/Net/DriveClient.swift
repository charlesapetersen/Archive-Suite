import Foundation

/// Blocking HTTP execution seam so `DriveClient` (and the whole Drive path) is unit-testable against a
/// mock responder with NO network — the live `URLSessionHTTP` impl is exercised only in the owner-gated
/// integration test. Returns status + body + lowercased response headers; throws only on transport failure.
protocol HTTPExecuting: Sendable {
    func execute(method: String, url: String, headers: [String: String], body: Data?) throws
        -> (status: Int, data: Data, headers: [String: String])
}

/// A URLSession-backed blocking executor (a semaphore bridges async URLSession to the sync `RelayObjectStore`
/// surface; calls run on the receiver's background queue, never the main actor).
struct URLSessionHTTP: HTTPExecuting {
    func execute(method: String, url: String, headers: [String: String], body: Data?) throws
        -> (status: Int, data: Data, headers: [String: String]) {
        guard let u = URL(string: url) else { throw DriveError.badURL(url) }
        var req = URLRequest(url: u, timeoutInterval: 60)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let sem = DispatchSemaphore(value: 0)
        let box = HTTPResultBox()
        URLSession.shared.dataTask(with: req) { data, resp, e in
            if let e { box.error = e }
            else if let http = resp as? HTTPURLResponse {
                var h: [String: String] = [:]
                for (k, v) in http.allHeaderFields { if let ks = k as? String, let vs = v as? String { h[ks.lowercased()] = vs } }
                box.result = (http.statusCode, data ?? Data(), h)
            } else {
                // Neither an error nor an HTTPURLResponse — capture what we DID get, so the failure is
                // legible (a nil/nil completion is the classic App-Sandbox outgoing-connection-denied signature).
                box.diag = "resp=\(String(describing: resp)) dataBytes=\(data?.count ?? -1)"
            }
            sem.signal()
        }.resume()
        sem.wait()
        if let e = box.error { throw e }
        guard let r = box.result else { throw DriveError.transport("no HTTPURLResponse — \(box.diag ?? "resp=nil, err=nil")") }
        return r
    }
}

/// Reference holder so the URLSession completion closure mutates a captured `let` object (not a captured
/// `var`), keeping the semaphore bridge clean under Swift 6 strict concurrency.
private final class HTTPResultBox: @unchecked Sendable {
    var result: (status: Int, data: Data, headers: [String: String])?
    var error: Error?
    var diag: String?
}

enum DriveError: Error, LocalizedError, CustomStringConvertible {
    case badURL(String), noResponse, transport(String), http(status: Int, body: String), decode(String), notSignedIn
    case oauthStateMismatch
    var description: String {
        switch self {
        case .badURL(let u): return "bad URL \(u)"
        case .noResponse: return "no HTTP response"
        case .transport(let m): return "transport error: \(m)"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .decode(let m): return "decode: \(m)"
        case .notSignedIn: return "not signed in to Google Drive"
        case .oauthStateMismatch: return "OAuth redirect state did not match (possible CSRF); sign-in aborted"
        }
    }
    // Surface the human-readable message through LocalizedError so the UI shows "transport error: …" /
    // "HTTP 401: …" instead of the opaque "The operation couldn't be completed. (…DriveError error N)".
    var errorDescription: String? { description }
}

/// Thin Google Drive REST v3 client for the relay backend — exactly the calls `DriveObjectStore` needs.
/// Auth is a token provider closure (refreshes/mints access tokens via `DriveAuth`), so this stays testable.
/// All methods are blocking (sync) to fit the `RelayObjectStore` protocol; they run off the main actor.
final class DriveClient: @unchecked Sendable {
    private let http: HTTPExecuting
    private let token: @Sendable () throws -> String
    private static let api = "https://www.googleapis.com/drive/v3"
    private static let upload = "https://www.googleapis.com/upload/drive/v3"

    init(http: HTTPExecuting = URLSessionHTTP(), token: @escaping @Sendable () throws -> String) {
        self.http = http
        self.token = token
    }

    struct DriveFile: Decodable { let id: String; let name: String?; let appProperties: [String: String]?; let modifiedTime: String? }
    private struct FileList: Decodable { let files: [DriveFile]?; let nextPageToken: String? }
    private struct CreatedFile: Decodable { let id: String }
    private struct StartToken: Decodable { let startPageToken: String }
    private struct ChangeList: Decodable {
        struct Change: Decodable { let fileId: String?; let removed: Bool?; let file: DriveFile? }
        let changes: [Change]?; let nextPageToken: String?; let newStartPageToken: String?
    }

    private func send(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil) throws -> Data {
        var h = headers
        h["Authorization"] = "Bearer " + (try token())
        let (status, data, _) = try http.execute(method: method, url: url, headers: h, body: body)
        guard (200..<300).contains(status) else { throw DriveError.http(status: status, body: String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DriveError.decode("\(T.self): \(error)") }
    }

    /// List files matching a Drive query `q`. Returns all pages.
    func listFiles(query: String) throws -> [DriveFile] {
        var result: [DriveFile] = []
        var pageToken: String?
        repeat {
            var url = "\(Self.api)/files?q=\(enc(query))&fields=\(enc("files(id,name,appProperties,modifiedTime),nextPageToken"))&pageSize=1000&spaces=drive"
            if let pageToken { url += "&pageToken=\(enc(pageToken))" }
            let list = try decode(FileList.self, send("GET", url))
            result.append(contentsOf: list.files ?? [])
            pageToken = list.nextPageToken
        } while pageToken != nil
        return result
    }

    /// Create a metadata-only file (used for folders: mimeType = application/vnd.google-apps.folder). Returns id.
    func createMetadata(name: String, parents: [String], appProperties: [String: String], mimeType: String?) throws -> String {
        var meta: [String: Any] = ["name": name, "appProperties": appProperties]
        if !parents.isEmpty { meta["parents"] = parents }   // empty → Drive root (My Drive)
        if let mimeType { meta["mimeType"] = mimeType }
        let body = try JSONSerialization.data(withJSONObject: meta)
        let data = try send("POST", "\(Self.api)/files?fields=id", headers: ["Content-Type": "application/json"], body: body)
        return try decode(CreatedFile.self, data).id
    }

    /// Create a file with content via multipart/related (metadata + media). Returns id.
    func createFile(name: String, parents: [String], appProperties: [String: String], media: Data, mimeType: String) throws -> String {
        let boundary = "arcap-\(UUID().uuidString)"
        var meta: [String: Any] = ["name": name, "appProperties": appProperties]
        if !parents.isEmpty { meta["parents"] = parents }
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metaData); add("\r\n")
        add("--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(media); add("\r\n--\(boundary)--\r\n")
        let data = try send("POST", "\(Self.upload)/files?uploadType=multipart&fields=id",
                            headers: ["Content-Type": "multipart/related; boundary=\(boundary)"], body: body)
        return try decode(CreatedFile.self, data).id
    }

    /// Replace an existing file's media (idempotent overwrite for a re-sent object).
    func updateMedia(fileId: String, media: Data, mimeType: String) throws {
        _ = try send("PATCH", "\(Self.upload)/files/\(fileId)?uploadType=media",
                     headers: ["Content-Type": mimeType], body: media)
    }

    /// Update just the appProperties of an existing file (e.g. mark a receipt/quarantine flag).
    func updateAppProperties(fileId: String, appProperties: [String: String]) throws {
        let body = try JSONSerialization.data(withJSONObject: ["appProperties": appProperties])
        _ = try send("PATCH", "\(Self.api)/files/\(fileId)?fields=id", headers: ["Content-Type": "application/json"], body: body)
    }

    func getMedia(fileId: String) throws -> Data { try send("GET", "\(Self.api)/files/\(fileId)?alt=media") }

    func delete(fileId: String) throws {
        let (status, data, _) = try http.execute(method: "DELETE", url: "\(Self.api)/files/\(fileId)",
                                                 headers: ["Authorization": "Bearer " + (try token())], body: nil)
        guard (200..<300).contains(status) || status == 404 else {   // 404 = already gone (idempotent)
            throw DriveError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Changes feed (the reliable way to detect new objects; §8)
    func startPageToken() throws -> String {
        try decode(StartToken.self, send("GET", "\(Self.api)/changes/startPageToken")).startPageToken
    }
    /// Returns (changed files, next page token to poll from). `newStartPageToken` (end of a page run) is
    /// returned as `next` when there are no more pages.
    func listChanges(pageToken: String) throws -> (files: [DriveFile], next: String) {
        var token = pageToken
        var files: [DriveFile] = []
        while true {
            let url = "\(Self.api)/changes?pageToken=\(enc(token))&fields=\(enc("changes(fileId,removed,file(id,name,appProperties,modifiedTime)),nextPageToken,newStartPageToken"))&pageSize=1000&spaces=drive"
            let cl = try decode(ChangeList.self, send("GET", url))
            for c in cl.changes ?? [] where c.removed != true { if let f = c.file { files.append(f) } }
            if let np = cl.nextPageToken { token = np; continue }
            return (files, cl.newStartPageToken ?? token)
        }
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
    }
}

private extension CharacterSet {
    /// Query-value-safe set (stricter than `.urlQueryAllowed`, which permits `&`, `+`, `=`).
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
}
