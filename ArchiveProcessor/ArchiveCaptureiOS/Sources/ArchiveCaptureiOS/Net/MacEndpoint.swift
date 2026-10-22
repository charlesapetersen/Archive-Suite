import Foundation

/// Connection info for the Mac receiver. Mirrors the Android `MacEndpoint` so the same QR works for both
/// companions.
///
/// - **Wi-Fi** (`isCloud == false`): decoded from the pairing QR `{host, port, token, name}`; the phone talks
///   HTTP to `baseURL`, with `token` as the Bearer pairing code.
/// - **Cloud** (`isCloud == true`): the operator chose Cloud. `host`/`port` are unused and `token` is the Drive
///   relay token `DriveRelayTransport` uses to find the Mac's shared folder. Reached from the combined QR's
///   optional `relay` key, from a `{mode:"cloud", token, account?}` QR, or from a typed relay token.
///
/// `account` is an optional Google-account hint for sign-in, carried only by a cloud QR. Foundation only, so the
/// host tests (`scripts/test-ios-capture-queue.sh`) compile it standalone.
struct MacEndpoint: Codable, Equatable {
    let host: String
    let port: Int
    let token: String
    let name: String
    /// OPTIONAL Drive-relay token from the combined pairing QR (`relay` key). Absent on a LAN-only QR → nil (LAN
    /// pairing is unaffected); present when the Mac is signed into Drive. Today it equals `token`.
    var relay: String? = nil
    var isCloud: Bool = false
    var account: String? = nil

    var baseURL: String { "http://\(host):\(port)" }

    /// The relay token for the Cloud transport: the combined QR's `relay`, else the token itself when this is
    /// already a cloud endpoint. Nil for a LAN-only QR, from which Cloud can't be reached.
    var relayToken: String? { relay ?? (isCloud ? token : nil) }

    /// A Cloud pairing to the Mac whose Drive folder carries `relayToken`.
    static func cloud(relayToken: String, name: String = "Mac", account: String? = nil) -> MacEndpoint {
        MacEndpoint(host: "", port: 0, token: relayToken, name: name, relay: nil, isCloud: true,
                    account: account.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func fromQRPayload(_ payload: String) -> MacEndpoint? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else { return nil }
        let name = (obj["name"] as? String) ?? "Mac"
        let relay = (obj["relay"] as? String).flatMap { $0.isEmpty ? nil : $0 }   // tolerate absence
        if (obj["mode"] as? String) == "cloud" {
            var ep = cloud(relayToken: token, name: name, account: obj["account"] as? String)
            ep.relay = relay
            return ep
        }
        guard let host = obj["host"] as? String, !host.isEmpty else { return nil }
        let port: Int
        if let p = obj["port"] as? Int { port = p }
        else if let s = obj["port"] as? String, let p = Int(s) { port = p }
        else { return nil }
        guard port > 0 else { return nil }
        return MacEndpoint(host: host, port: port, token: token, name: name, relay: relay)
    }
}
