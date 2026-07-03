import Foundation

/// Connection info for the Mac receiver, decoded from the pairing QR JSON: {host, port, token, name}.
/// Mirrors the Android `MacEndpoint` so the same QR works for both companions.
struct MacEndpoint: Codable, Equatable {
    let host: String
    let port: Int
    let token: String
    let name: String

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
        return MacEndpoint(host: host, port: port, token: token, name: (obj["name"] as? String) ?? "Mac")
    }
}
