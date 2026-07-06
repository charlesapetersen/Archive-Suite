import Foundation

/// Why a pairing attempt failed — so the connect UI can name the cause + the fix instead of a bare
/// "couldn't connect". `unreachable` = timeout / no route (the client-isolation case, and on iOS also
/// a refused connection, which surfaces as cannotConnectToHost); `refused` = reached a server but its
/// reply wasn't our happy path; `unauthorized` = reached the Mac but the token was rejected (HTTP 401).
/// Mirrors the Android `Reachability` enum + the plan's `ConnectPhase` causes.
enum ConnectResult { case ok, unauthorized, refused, unreachable }

/// Protocol-v2 client for the Archive Processor Live Capture receiver (raw JPEG body + X-* headers).
/// Mirrors the Android `MacClient` and the Mac's `CaptureServer` routes exactly.
struct MacClient {
    let endpoint: MacEndpoint

    /// `timeout` is parametrized so the pre-pairing reachability probe can fail fast (~3.5s) while photo
    /// uploads keep the full 30s — never shorten the upload timeout to speed up the probe.
    private func makeRequest(_ path: String, method: String, timeout: TimeInterval = 30) -> URLRequest? {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func isSuccess(_ resp: URLResponse?) -> Bool {
        (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }

    func ping() async -> Bool {
        guard let req = makeRequest("/ping", method: "GET") else { return false }
        do { let (_, resp) = try await URLSession.shared.data(for: req); return Self.isSuccess(resp) }
        catch { return false }
    }

    /// Classify reachability of the Mac for a clear pairing diagnostic. Uses a short timeout so a
    /// black-holed SYN (client-isolation) fails fast; the 30s upload timeout is deliberately untouched.
    func reachability(timeout: TimeInterval = 3.5) async -> ConnectResult {
        guard let req = makeRequest("/ping", method: "GET", timeout: timeout) else { return .unreachable }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .refused }
            if (200..<300).contains(http.statusCode) { return .ok }
            if http.statusCode == 401 { return .unauthorized }
            return .refused
        } catch {
            // A thrown URLError (timedOut / cannotConnectToHost / networkConnectionLost / no route) means
            // we never got an HTTP reply — the client-isolation / no-route / server-not-started signature.
            // iOS can't reliably split "refused" from "unreachable" (a refused TCP connection also surfaces
            // as cannotConnectToHost), so we report unreachable, whose guidance also covers "start Live
            // Capture". `refused` is reserved for a reached-but-non-happy HTTP response.
            return .unreachable
        }
    }

    /// POST one JPEG (raw body) with grouping + minimal-tag headers. Returns true on 2xx.
    /// The Mac requires a non-empty X-Group and a numeric X-Seq (else 400), so both are always sent.
    func postPhoto(jpeg: Data, group: String, seq: Int, type: String,
                   priority: String?, year: Int?, month: Int?, device: String,
                   replaces: String? = nil) async -> Bool {
        guard var req = makeRequest("/photo", method: "POST") else { return false }
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue(group, forHTTPHeaderField: "X-Group")
        req.setValue(String(seq), forHTTPHeaderField: "X-Seq")
        req.setValue(type, forHTTPHeaderField: "X-Type")
        req.setValue(device, forHTTPHeaderField: "X-Device")
        // The old group this photo replaces (reclassify) — the Mac drops the orphaned old copy.
        if let replaces, !replaces.isEmpty { req.setValue(replaces, forHTTPHeaderField: "X-Replaces") }
        if let p = priority, !p.trimmingCharacters(in: .whitespaces).isEmpty {
            req.setValue(p, forHTTPHeaderField: "X-Priority")
        }
        if let y = year { req.setValue(String(y), forHTTPHeaderField: "X-Year") }
        if let m = month { req.setValue(String(m), forHTTPHeaderField: "X-Month") }
        do { let (_, resp) = try await URLSession.shared.upload(for: req, from: jpeg); return Self.isSuccess(resp) }
        catch { return false }
    }

    func sessionComplete() async -> Bool {
        guard let req = makeRequest("/session/complete", method: "POST") else { return false }
        do { let (_, resp) = try await URLSession.shared.upload(for: req, from: Data()); return Self.isSuccess(resp) }
        catch { return false }
    }

    /// End of a document segment: its pages already streamed in via `postPhoto`; this tells the Mac the
    /// group is complete (so its tag card can appear) and carries the segment's tags. No image bytes.
    func segmentComplete(group: String, priority: String?, year: Int?, month: Int?) async -> Bool {
        guard var req = makeRequest("/segment/complete", method: "POST") else { return false }
        req.setValue(group, forHTTPHeaderField: "X-Group")
        if let p = priority, !p.trimmingCharacters(in: .whitespaces).isEmpty {
            req.setValue(p, forHTTPHeaderField: "X-Priority")
        }
        if let y = year { req.setValue(String(y), forHTTPHeaderField: "X-Year") }
        if let m = month { req.setValue(String(m), forHTTPHeaderField: "X-Month") }
        do { let (_, resp) = try await URLSession.shared.upload(for: req, from: Data()); return Self.isSuccess(resp) }
        catch { return false }
    }

    /// Best-effort notice that the phone is re-pairing, so the Mac re-shows the pairing QR instead of
    /// sitting on a stale "paired" state. Fire-and-forget (may not reach the Mac if the link is already down).
    func sessionDisconnect() async -> Bool {
        guard let req = makeRequest("/session/disconnect", method: "POST") else { return false }
        do { let (_, resp) = try await URLSession.shared.upload(for: req, from: Data()); return Self.isSuccess(resp) }
        catch { return false }
    }
}
