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
/// - **Cable** (`isCable == true`, W40.i-usb-app): the QR's `token` and `name`, reached through the local relay
///   (`USBRelay`, REFERENCE.md §Live Capture, USB local relay §2). It stores the MODE, not a port: `MacClient` asks the relay
///   for its bound port each request, so a relay that had to take a system port is followed. `host`/`port` keep
///   whatever the QR said and are not dialled.
///
/// A QR from a Mac with no network address carries an empty `host` (S-037): valid for Cable and Cloud, refused for
/// Wi-Fi (`hasHost`).
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
    var isCable: Bool = false

    private enum CodingKeys: String, CodingKey { case host, port, token, name, relay, isCloud, account, isCable }

    /// The flags a pairing saved before they existed decode as false (synthesized `Decodable` ignores a default
    /// and would throw, sending an already-paired phone back to the Connect screen on update).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        token = try c.decode(String.self, forKey: .token)
        name = try c.decode(String.self, forKey: .name)
        relay = try c.decodeIfPresent(String.self, forKey: .relay)
        isCloud = try c.decodeIfPresent(Bool.self, forKey: .isCloud) ?? false
        account = try c.decodeIfPresent(String.self, forKey: .account)
        isCable = try c.decodeIfPresent(Bool.self, forKey: .isCable) ?? false
    }

    init(host: String, port: Int, token: String, name: String, relay: String? = nil, isCloud: Bool = false,
         account: String? = nil, isCable: Bool = false) {
        self.host = host; self.port = port; self.token = token; self.name = name
        self.relay = relay; self.isCloud = isCloud; self.account = account; self.isCable = isCable
    }

    var baseURL: String { "http://\(host):\(port)" }

    /// False for a QR from a Mac with no network address: usable over Cable or Cloud, not Wi-Fi.
    var hasHost: Bool { !host.isEmpty }

    /// Where `MacClient` sends a request: the Wi-Fi host, or in Cable mode the local relay on whatever port it is
    /// bound to now (nil while the relay is not listening).
    func requestBaseURL(cableRelayPort: UInt16?) -> String? {
        guard isCable else { return baseURL }
        return cableRelayPort.map { "http://127.0.0.1:\($0)" }
    }

    /// A Cable pairing from a scanned LAN QR: its token, name and relay code, through the local relay.
    func asCable() -> MacEndpoint {
        MacEndpoint(host: host, port: port, token: token, name: name, relay: relay, isCloud: false,
                    account: nil, isCable: true)
    }

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
        // An empty host is the no-address QR (S-037); `hasHost` keeps it off Wi-Fi.
        guard let host = obj["host"] as? String else { return nil }
        let port: Int
        if let p = obj["port"] as? Int { port = p }
        else if let s = obj["port"] as? String, let p = Int(s) { port = p }
        else { return nil }
        guard port > 0 else { return nil }
        return MacEndpoint(host: host, port: port, token: token, name: name, relay: relay)
    }
}
