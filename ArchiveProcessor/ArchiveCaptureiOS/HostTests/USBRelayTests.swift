import Foundation
import Network
import CryptoKit

// Host tests for the iPhone's cable relay (W40.i-usb-app; execution-plans/iphone-usb.md §5), compiled with swiftc
// against the app's real Net/USBRelay.swift, Net/MacEndpoint.swift and Net/MacClient.swift
// (scripts/test-ios-usb-relay.sh). A fake Mac connects into the relay's tunnel port and answers the AC1 handshake;
// a client sends through the relay port. Real sockets on 127.0.0.1, ports chosen by the system.

var failures = 0, passes = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("  [FAIL] line \(line): \(what)") }
}
func test(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("  [FAIL] \(name): threw \(error)") }
    print(failures == before ? "  [PASS] \(name)" : "  [FAIL] \(name)")
}
struct Unwrap: Error { let line: Int }
func unwrap<T>(_ v: T?, line: Int = #line) throws -> T { guard let v else { throw Unwrap(line: line) }; return v }

func eventually(_ timeout: Double = 3, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
    return cond()
}

/// A blocking TCP peer: the fake Mac's end of a tunnel, or a client of the relay. One receive loop fills a buffer
/// for its whole life, so a read that times out leaves nothing behind to eat the next bytes.
final class Peer {
    let conn: NWConnection
    private let q = DispatchQueue(label: "peer")
    private let lock = NSLock()
    private var buffer = Data()
    private var ended = false   // end of stream or error
    init(port: UInt16, host: NWEndpoint.Host = .ipv4(.loopback)) {
        conn = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.pump()
            case .failed, .cancelled: self?.lock.withLock { self?.ended = true }
            default: break
            }
        }
        conn.start(queue: q)
    }
    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] d, _, c, e in
            guard let self else { return }
            self.lock.withLock { if let d { self.buffer.append(d) }; if c || e != nil { self.ended = true } }
            if !c && e == nil { self.pump() }
        }
    }
    var isReady: Bool { if case .ready = conn.state { return true }; return false }
    func waitReady(_ t: Double = 2) -> Bool { eventually(t) { isReady } }
    private var snapshot: (Data, Bool) { lock.withLock { (buffer, ended) } }

    /// Exactly `n` bytes, or nil on end of stream or timeout.
    func read(_ n: Int, timeout: Double = 3) -> Data? {
        _ = eventually(timeout) { let (b, e) = snapshot; return b.count >= n || e }
        return lock.withLock {
            guard buffer.count >= n else { return nil }
            let out = buffer.prefix(n); buffer.removeFirst(n); return Data(out)
        }
    }

    /// Everything until end of stream: (bytes, true) once the stream has ended, (bytes so far, false) on timeout.
    func readToEOF(timeout: Double = 5) -> (Data, Bool) {
        let ended = eventually(timeout) { snapshot.1 }
        return lock.withLock { let out = buffer; buffer.removeAll(); return (out, ended) }
    }

    /// True once the far side has closed within `timeout`, with no data before it.
    func closedByPeer(timeout: Double = 3) -> Bool {
        let (d, eof) = readToEOF(timeout: timeout)
        return d.isEmpty && eof
    }

    /// Data as a complete default message, then the end of stream as an empty final one (see USBRelay.send).
    func send(_ d: Data?, final: Bool = false) {
        let s = DispatchSemaphore(value: 0)
        if let d { conn.send(content: d, completion: .contentProcessed { _ in s.signal() }); _ = s.wait(timeout: .now() + 3) }
        if final {
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in s.signal() })
            _ = s.wait(timeout: .now() + 3)
        }
    }
    func close() { conn.cancel() }
}

let token = "lan-token-0123456789abcdef"
func hmac(_ nonce: Data, _ key: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: Data(key.utf8))))
}

/// The fake Mac's side of a new tunnel: connect, read `AC1` + nonce, answer with `answer(nonce)`.
func macTunnel(_ relay: USBRelay, answer: (Data) -> Data? = { hmac($0, token) }) throws -> Peer {
    let p = Peer(port: try unwrap(relay.tunnelPort))
    check(p.waitReady(), "tunnel connects")
    let hello = try unwrap(p.read(19))
    check(hello.prefix(3) == Data("AC1".utf8), "hello starts AC1")
    if let a = answer(Data(hello.dropFirst(3))) { p.send(a) }
    return p
}

func makeRelay(_ tweak: (inout USBRelay.Config) -> Void = { _ in }) throws -> USBRelay {
    var c = USBRelay.Config(); c.tunnelPort = 0; c.relayPort = 0
    tweak(&c)
    let r = USBRelay(config: c)
    r.start()
    check(eventually { r.tunnelPort != nil && r.relayPort != nil }, "both listeners ready")
    return r
}

func nonLoopbackIPv4() -> String? {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
    defer { freeifaddrs(addrs) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let s = String(cString: host)
        if !s.hasPrefix("127.") && !s.isEmpty { return s }
    }
    return nil
}

final class Box<T> { var value: T; init(_ v: T) { value = v } }
func runAsync<T>(_ f: @escaping @Sendable () async -> T) -> T? {
    let s = DispatchSemaphore(value: 0); let box = Box<T?>(nil)
    Task.detached { box.value = await f(); s.signal() }
    return s.wait(timeout: .now() + 20) == .timedOut ? nil : box.value
}

print("=== iOS cable relay host tests ===")

test("the handshake matches the Mac's: AC1, 16-byte nonce, 32-byte HMAC-SHA256 keyed by the token") {
    check(CableHandshake.magic == Data("AC1".utf8) && CableHandshake.nonceLength == 16 && CableHandshake.answerLength == 32, "constants")
    let n = CableHandshake.newNonce()
    check(n.count == 16 && n != CableHandshake.newNonce(), "fresh 16-byte nonces")
    let a = CableHandshake.answer(nonce: n, token: token)
    check(a == hmac(n, token) && a.count == 32, "answer is HMAC-SHA256(token, nonce)")
    check(CableHandshake.verify(answer: a, nonce: n, token: token), "verifies")
    check(!CableHandshake.verify(answer: hmac(n, "other"), nonce: n, token: token), "wrong key refused")
    check(!CableHandshake.verify(answer: a.prefix(31), nonce: n, token: token), "short answer refused")
}

test("the defaults are the plan's: 48628 tunnels, 48629 relay, 10 s wait, 5 s handshake") {
    let c = USBRelay.Config()
    check(c.tunnelPort == 48628 && c.relayPort == 48629, "ports")
    check(c.waitLimit == 10 && c.handshakeTimeout == 5, "limits")
    check(c.maxIdleAge < 20, "a tunnel is taken before the Mac's 20 s idle expiry")
    check(MacClient.cableSession.configuration.httpMaximumConnectionsPerHost == 4, "Cable session: 4 per host")
}

test("both listeners accept on 127.0.0.1 only") {
    let r = try makeRelay(); defer { r.stop() }
    let loop = Peer(port: try unwrap(r.tunnelPort)); defer { loop.close() }
    check(loop.waitReady(), "loopback reaches the tunnel port")
    if let ip = nonLoopbackIPv4() {
        for port in [try unwrap(r.tunnelPort), try unwrap(r.relayPort)] {
            let lan = Peer(port: port, host: NWEndpoint.Host(ip)); defer { lan.close() }
            check(!lan.waitReady(1), "\(ip):\(port) refused")
        }
    } else {
        print("  (no non-loopback IPv4 on this Mac: the LAN half was not exercised)")
    }
}

test("a verified tunnel carries a request, and a reply written then closed at once arrives whole") {
    let r = try makeRelay(); defer { r.stop() }
    r.setToken(token)
    let mac = try macTunnel(r); defer { mac.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "verified")
    let client = Peer(port: try unwrap(r.relayPort)); defer { client.close() }
    check(client.waitReady(), "client connects")
    let request = Data("POST /photo HTTP/1.1\r\n\r\n".utf8)
    client.send(request)
    check(mac.read(request.count) == request, "the request reaches the Mac, byte for byte")
    var reply = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
    reply.append(Data((0..<1_500_000).map { UInt8($0 % 251) }))
    mac.send(reply, final: true); mac.close()   // CaptureServer writes and closes at once
    let (got, eof) = client.readToEOF()
    check(got == reply, "the whole reply (\(got.count) of \(reply.count) bytes)")
    check(eof, "then end of stream")
    check(r.status.verifiedTunnels == 0, "the tunnel was used up")
}

test("the client's end of stream reaches the Mac, and the Mac's reply still comes back") {
    let r = try makeRelay(); defer { r.stop() }
    r.setToken(token)
    let mac = try macTunnel(r); defer { mac.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "verified")
    let client = Peer(port: try unwrap(r.relayPort)); defer { client.close() }
    client.send(Data("GET".utf8), final: true)
    let (up, upEOF) = mac.readToEOF()
    check(up == Data("GET".utf8) && upEOF, "request then end of stream at the Mac")
    mac.send(Data("OK".utf8), final: true)
    let (down, downEOF) = client.readToEOF()
    check(down == Data("OK".utf8) && downEOF, "reply after a half-close")
    check(eventually { r.tunnelCount == 0 }, "both directions done: the pair is released")
}

test("a tunnel with a wrong HMAC, or a reply longer than 32 bytes, is closed and never used") {
    let r = try makeRelay { $0.waitLimit = 1 }; defer { r.stop() }
    r.setToken(token)
    let wrong = try macTunnel(r) { hmac($0, "not-the-token") }; defer { wrong.close() }
    check(wrong.closedByPeer(), "wrong HMAC: closed by the phone")
    check(eventually { r.status.rejectedAnswers == 1 }, "counted as a Mac with another token")
    let long = try macTunnel(r) { hmac($0, token) + Data([0]) }; defer { long.close() }
    check(long.closedByPeer(), "33 bytes: closed by the phone")
    check(r.status.verifiedTunnels == 0, "none verified")
    let client = Peer(port: try unwrap(r.relayPort)); defer { client.close() }
    client.send(Data("secret".utf8))
    let (got, _) = client.readToEOF(timeout: 3)
    check(got.isEmpty, "the request went nowhere, and the wait limit closed it")
}

test("a tunnel that does not answer within the handshake limit is closed") {
    let r = try makeRelay { $0.handshakeTimeout = 0.5 }; defer { r.stop() }
    r.setToken(token)
    let silent = try macTunnel(r) { _ in nil }; defer { silent.close() }
    check(silent.closedByPeer(timeout: 3), "closed after the limit")
    check(r.status.verifiedTunnels == 0, "never verified")
}

test("anything a tunnel says unasked closes it") {
    let r = try makeRelay(); defer { r.stop() }
    let held = Peer(port: try unwrap(r.tunnelPort)); defer { held.close() }
    check(held.waitReady() && eventually { r.status.tunnelOpen }, "held")
    held.send(Data("HTTP/1.1 200 OK\r\n".utf8))
    check(held.closedByPeer(), "a held tunnel that speaks first is not the Mac")
    r.setToken(token)
    let idle = try macTunnel(r); defer { idle.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "verified")
    idle.send(Data("x".utf8))
    check(idle.closedByPeer() && eventually { r.status.verifiedTunnels == 0 }, "an idle tunnel that speaks is dropped")
}

test("a full tunnel table drops its oldest unverified tunnel for a newcomer") {
    let r = try makeRelay { $0.maxTunnels = 3 }; defer { r.stop() }
    let squatters = try (0..<3).map { _ -> Peer in let p = Peer(port: try unwrap(r.tunnelPort)); check(p.waitReady(), "squatter"); return p }
    check(eventually { r.tunnelCount == 3 }, "the table is full of unverified tunnels")
    r.setToken(token)
    check(squatters.allSatisfy { $0.read(19) != nil }, "all challenged")   // they never answer
    let mac = try macTunnel(r); defer { mac.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "the Mac's tunnel still gets in and verifies")
    check(squatters[0].closedByPeer(), "the oldest squatter made room")
    squatters.forEach { $0.close() }
}

test("before pairing a tunnel is held unverified, opens the cable status, and is challenged once the token is set") {
    let r = try makeRelay(); defer { r.stop() }
    let p = Peer(port: try unwrap(r.tunnelPort)); defer { p.close() }
    check(p.waitReady(), "connects")
    check(eventually { r.status.tunnelOpen }, "tunnelOpen before pairing")
    check(p.read(1, timeout: 0.4) == nil, "no hello without a token")
    check(r.status.verifiedTunnels == 0, "not verified")
    r.setToken(token)
    let hello = try unwrap(p.read(19))
    check(hello.prefix(3) == Data("AC1".utf8), "challenged once paired")
    p.send(hmac(Data(hello.dropFirst(3)), token))
    check(eventually { r.status.verifiedTunnels == 1 }, "verified")
    r.setToken("another-mac")
    check(p.closedByPeer() && eventually { r.status.verifiedTunnels == 0 }, "a new token drops tunnels verified by the old")
}

test("queued requests drain in order as tunnels arrive, and one past the wait limit is closed") {
    let r = try makeRelay { $0.waitLimit = 1.5 }; defer { r.stop() }
    r.setToken(token)
    var clients: [Peer] = []
    for i in 0..<3 {
        let c = Peer(port: try unwrap(r.relayPort)); check(c.waitReady(), "client \(i)")
        c.send(Data("req\(i)".utf8)); clients.append(c)
        check(eventually { r.waitingCount == i + 1 }, "\(i + 1) waiting")
    }
    for i in 0..<2 {
        let mac = try macTunnel(r)
        check(mac.read(4) == Data("req\(i)".utf8), "tunnel \(i) carries request \(i): first in, first out")
        mac.send(Data("ok\(i)".utf8), final: true); mac.close()
        check(clients[i].readToEOF().0 == Data("ok\(i)".utf8), "client \(i) answered")
    }
    let (late, _) = clients[2].readToEOF(timeout: 3)
    check(late.isEmpty && r.waitingCount == 0, "the third waited past the limit and was closed")
    clients.forEach { $0.close() }
}

test("the youngest verified tunnel is taken, and one past its idle age is dropped instead") {
    let r = try makeRelay { $0.maxIdleAge = 0.6 }; defer { r.stop() }
    r.setToken(token)
    let old = try macTunnel(r); defer { old.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "first verified")
    Thread.sleep(forTimeInterval: 0.8)
    let young = try macTunnel(r); defer { young.close() }
    check(eventually { r.status.verifiedTunnels == 2 }, "second verified")
    let c = Peer(port: try unwrap(r.relayPort)); defer { c.close() }
    c.send(Data("ping".utf8))
    check(young.read(4) == Data("ping".utf8), "the young tunnel carries it")
    check(old.closedByPeer(), "the stale one was closed")
}

/// A port nothing is listening on now: bound once by the system, then released.
func freePort() throws -> UInt16 {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let l = try NWListener(using: params)
    l.newConnectionHandler = { $0.cancel() }
    l.start(queue: DispatchQueue(label: "free-port"))
    defer { l.cancel() }
    check(eventually { (l.port?.rawValue ?? 0) != 0 }, "a system port")
    return try unwrap(l.port?.rawValue)
}

test("restart drops every tunnel and listens again on the same ports") {
    let tPort = try freePort(), rPort = try freePort()
    Thread.sleep(forTimeInterval: 0.2)
    let r = try makeRelay { $0.tunnelPort = tPort; $0.relayPort = rPort }; defer { r.stop() }
    check(r.tunnelPort == tPort && r.relayPort == rPort, "the configured ports")
    r.setToken(token)
    let mac = try macTunnel(r); defer { mac.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "verified")
    let waiting = Peer(port: rPort); defer { waiting.close() }
    check(eventually { waiting.isReady && r.status.verifiedTunnels == 0 }, "a client spliced to the one tunnel")
    r.restart()
    check(waiting.readToEOF(timeout: 3).1, "its splice is cut by the restart")
    check(mac.closedByPeer(), "the tunnel is closed")
    check(eventually { r.tunnelPort == tPort && r.relayPort == rPort }, "same ports again")
    let again = try macTunnel(r); defer { again.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "a new tunnel verifies with the kept token")
}

test("a busy relay port falls back to a system port, and a Cable endpoint follows it") {
    let blockerParams = NWParameters.tcp
    blockerParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let blocker = try NWListener(using: blockerParams)
    blocker.newConnectionHandler = { $0.cancel() }
    blocker.start(queue: DispatchQueue(label: "blocker"))
    check(eventually { blocker.port != nil && blocker.port!.rawValue != 0 }, "blocker listening")
    let busy = blocker.port!.rawValue
    defer { blocker.cancel() }
    let r = try makeRelay { $0.relayPort = busy }; defer { r.stop() }
    let port = try unwrap(r.relayPort)
    check(port != busy, "relay on \(port), not the busy \(busy)")
    let ep = try unwrap(MacEndpoint.fromQRPayload(#"{"host":"10.0.0.5","port":48627,"token":"\#(token)","name":"Studio"}"#)).asCable()
    check(ep.requestBaseURL(cableRelayPort: port) == "http://127.0.0.1:\(port)", "the endpoint asks the relay")
    check(ep.requestBaseURL(cableRelayPort: nil) == nil, "no relay, no request")

    // The real MacClient through the relay: a /ping answered by the fake Mac.
    r.setToken(token)
    let mac = try macTunnel(r); defer { mac.close() }
    check(eventually { r.status.verifiedTunnels == 1 }, "verified")
    let client = MacClient(endpoint: ep, relay: r)
    let macSide = DispatchQueue(label: "fake-mac")
    let seen = Box<String>("")
    macSide.async {
        var req = Data()
        while !req.contains(Data("\r\n\r\n".utf8)), let b = mac.read(1) { req.append(b) }
        seen.value = String(decoding: req, as: UTF8.self)
        mac.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8), final: true)
    }
    let ok = runAsync { await client.ping() }
    check(ok == true, "ping through the relay")
    check(seen.value.hasPrefix("GET /ping HTTP/1.1") && seen.value.contains("Bearer \(token)"), "the Mac saw the request with its token")
}

test("a pairing saved before the Cable flag existed still loads, as Wi-Fi") {
    let old = Data(#"{"host":"10.0.0.5","port":48627,"token":"T","name":"Studio","isCloud":false}"#.utf8)
    let ep = try JSONDecoder().decode(MacEndpoint.self, from: old)
    check(!ep.isCable && !ep.isCloud && ep.host == "10.0.0.5" && ep.relay == nil && ep.account == nil, "Wi-Fi, as saved")
    let cloud = MacEndpoint.cloud(relayToken: "RT", name: "Studio", account: "me@example.org")
    check(try JSONDecoder().decode(MacEndpoint.self, from: JSONEncoder().encode(cloud)) == cloud, "Cloud round trip")
}

test("a tunnel that closes straight after answering returns nothing, and a splice ends with its tunnel") {
    let r = try makeRelay { $0.waitLimit = 1.5 }; defer { r.stop() }
    r.setToken(token)
    let c = Peer(port: try unwrap(r.relayPort)); defer { c.close() }
    check(c.waitReady() && eventually { r.waitingCount == 1 }, "a request waiting")
    let mac = try macTunnel(r) { hmac($0, token) + Data() }
    mac.send(nil, final: true)   // answer, then end of stream at once
    let (got, _) = c.readToEOF(timeout: 3)
    check(got.isEmpty, "nothing came back from a closing tunnel, and the request was ended, not left to time out")
    c.close(); mac.close()
    check(eventually { r.tunnelCount == 0 }, "released")
    let mac2 = try macTunnel(r); defer { mac2.close() }
    let c2 = Peer(port: try unwrap(r.relayPort)); defer { c2.close() }
    c2.send(Data("x".utf8))
    check(mac2.read(1) == Data("x".utf8), "spliced")
    mac2.close()   // the Mac drops the tunnel mid-request
    check(c2.readToEOF(timeout: 3).1, "the Mac's end of stream reaches the local side, not left to time out")
    c2.close()
    check(eventually { r.tunnelCount == 0 }, "both directions over: released")
}

test("Cable endpoints store the mode, survive a save, and take the no-address QR") {
    let ep = try unwrap(MacEndpoint.fromQRPayload(#"{"host":"","port":48627,"token":"T","name":"Studio","relay":"R"}"#))
    check(!ep.hasHost && !ep.isCable && !ep.isCloud, "an empty host parses, and has no host for Wi-Fi")
    check(ep.relayToken == "R", "still offers Cloud")
    let cable = ep.asCable()
    check(cable.isCable && cable.token == "T" && cable.name == "Studio" && cable.relay == "R", "Cable keeps token, name, relay")
    let back = try JSONDecoder().decode(MacEndpoint.self, from: JSONEncoder().encode(cable))
    check(back == cable && back.isCable, "round trip")
    check(MacEndpoint.fromQRPayload(#"{"host":"10.0.0.5","port":48627,"token":"T"}"#)?.hasHost == true, "a LAN QR has a host")
    check(MacEndpoint.fromQRPayload(#"{"host":"10.0.0.5","port":48627,"token":"T"}"#)?.requestBaseURL(cableRelayPort: 1) == "http://10.0.0.5:48627",
          "Wi-Fi ignores the relay")
}

print("")
print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
