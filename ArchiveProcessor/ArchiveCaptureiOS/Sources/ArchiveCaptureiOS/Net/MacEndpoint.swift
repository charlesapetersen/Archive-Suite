import Foundation

/// Connection info for the Mac receiver, decoded from the pairing QR JSON: `{host, port, token, name}`
/// PLUS an OPTIONAL `relay` token. Mirrors the Android `MacEndpoint` so the same QR works for both
/// companions.
struct MacEndpoint: Codable, Equatable {
    let host: String
    let port: Int
    let token: String
    let name: String
    /// OPTIONAL Drive-relay token from the combined pairing QR (`relay` key). Absent on an older Mac's
    /// LAN-only QR → nil (LAN pairing is unaffected). When present it carries the token the Drive cloud
    /// transport uses to find the Mac's shared folder; today it equals `token`. Optional so decoding a
    /// previously-persisted endpoint (no `relay`) still succeeds.
    var relay: String? = nil

    var baseURL: String { "http://\(host):\(port)" }

    static func fromQRPayload(_ payload: String) -> MacEndpoint? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = obj["host"] as? String, !host.isEmpty,
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        let port: Int
        if let p = obj["port"] as? Int { port = p }
        else if let s = obj["port"] as? String, let p = Int(s) { port = p }
        else { return nil }
        guard port > 0 else { return nil }
        let relay = (obj["relay"] as? String).flatMap { $0.isEmpty ? nil : $0 }   // tolerate absence
        return MacEndpoint(host: host, port: port, token: token,
                           name: (obj["name"] as? String) ?? "Mac", relay: relay)
    }
}
