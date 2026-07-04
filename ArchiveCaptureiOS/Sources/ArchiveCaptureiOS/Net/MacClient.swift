import Foundation

/// Protocol-v2 client for the Archive Processor Live Capture receiver (raw JPEG body + X-* headers).
/// Mirrors the Android `MacClient` and the Mac's `CaptureServer` routes exactly.
struct MacClient {
    let endpoint: MacEndpoint

    private func makeRequest(_ path: String, method: String) -> URLRequest? {
        guard let url = URL(string: "\(endpoint.baseURL)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 30)
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
}
