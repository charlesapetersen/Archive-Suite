#if DEBUG // a test driver, compiled out of Release
import Foundation
import Network

/// Headless, $0 test of the iPhone cable route's Mac end (W40.i-usb-mac; REFERENCE.md §Live Capture, USB local relay
/// §5). Gated by `USBMUX_TEST=1`; `scripts/test-usbmux-bridge.sh` starts `scripts/fake-usbmuxd.py`, points
/// `ARCHIVE_USBMUX_SOCKET` at it and reads the plain-text report from `USBMUX_TEST_OUT`.
///
/// The driver plays the phone: a listener on 127.0.0.1 that the fake usbmuxd connects each `Connect` into
/// (on the port it decodes WITH the byte swap), speaking the `AC1` handshake. Behind the bridge stands
/// either a stand-in server that writes a large reply and closes at once, or a real `CaptureServer`
/// (for the separate throttle key). Nothing leaves loopback; nothing touches a corpus.
@MainActor
enum USBMuxBridgeTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["USBMUX_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    // MARK: - Helpers

    /// Resumes a continuation exactly once, whichever callback or timeout gets there first.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Never>?
        init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
        func resume(_ value: T) {
            let c: CheckedContinuation<T, Never>? = lock.withLock { defer { cont = nil }; return cont }
            c?.resume(returning: value)
        }
    }

    private final class StatusLog: @unchecked Sendable {
        private let lock = NSLock()
        private var value: USBMuxBridge.Status?
        private var seen: [USBMuxBridge.Status] = []
        func set(_ s: USBMuxBridge.Status) { lock.withLock { value = s; seen.append(s) } }
        var current: USBMuxBridge.Status? { lock.withLock { value } }
        func everSince(_ mark: Int, _ s: USBMuxBridge.Status) -> Bool { lock.withLock { seen.dropFirst(mark).contains(s) } }
        var mark: Int { lock.withLock { seen.count } }
    }

    private static func waitUntil(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// One request/reply to the (fake) usbmuxd on a fresh socket.
    private static func mux(_ path: String, _ msg: [String: Any]) async -> [String: Any]? {
        guard let frame = USBMuxCodec.encode(msg, tag: 99), let reply = await muxFrame(path, frame),
              case let .message(m, _, _) = USBMuxCodec.decode(reply) else { return nil }
        return m
    }

    /// The raw reply frame (Data is Sendable; the decoded plist is not).
    nonisolated private static func muxFrame(_ path: String, _ frame: Data) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let once = Once(cont)
            let conn = NWConnection(to: .unix(path: path), using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: frame, completion: .contentProcessed { _ in })
                    conn.receive(minimumIncompleteLength: 16, maximumLength: 16) { head, _, _, _ in
                        guard let head, let length = USBMuxCodec.declaredLength(head) else {
                            once.resume(nil); conn.cancel(); return
                        }
                        conn.receive(minimumIncompleteLength: length - 16, maximumLength: length - 16) { body, _, _, _ in
                            once.resume(body.map { head + $0 })
                            conn.cancel()
                        }
                    }
                case .waiting, .failed:
                    once.resume(nil); conn.cancel()
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil); conn.cancel() }
        }
    }

    /// Send `request` over a fresh TCP connection to 127.0.0.1:`port` and read until end of stream.
    nonisolated private static func httpExchange(host: NWEndpoint.Host = .ipv4(.loopback), port: UInt16,
                                                 _ request: Data, timeout: Double = 5) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let once = Once(cont)
            let conn = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let inbox = Inbox()
            @Sendable func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                    if let data { inbox.append(data) }
                    if complete { once.resume(inbox.data); conn.cancel() }
                    else if error != nil { once.resume(nil); conn.cancel() }
                    else { read() }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: request, completion: .contentProcessed { _ in })
                    read()
                case .waiting, .failed:
                    once.resume(nil); conn.cancel()
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(nil); conn.cancel() }
        }
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = Data()
        func append(_ d: Data) { lock.withLock { buf.append(d) } }
        var data: Data { lock.withLock { buf } }
    }

    nonisolated private static func statusCode(_ reply: Data?) -> Int? {
        guard let reply, let line = String(decoding: reply.prefix(64), as: UTF8.self).split(separator: "\r\n").first
        else { return nil }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }

    nonisolated private static func request(_ path: String, token: String) -> Data {
        Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nConnection: close\r\n\r\n".utf8)
    }

    // MARK: - The stand-in phone

    /// The phone app's tunnel listener on 127.0.0.1, with the phone's half of the handshake.
    private final class FakePhone: @unchecked Sendable {
        enum Mode { case honest, silent, badMagic }
        final class Tunnel: @unchecked Sendable {
            let conn: NWConnection
            let acceptedAt = Date()
            var verified = false
            var closed = false
            var taken = false
            var inbox = Data()
            init(_ conn: NWConnection) { self.conn = conn }
        }
        let q = DispatchQueue(label: "usbmux.test.phone")
        private var listener: NWListener?
        private var tunnels: [Tunnel] = []
        private var _mode = Mode.honest
        private var _port: UInt16 = 0
        private var _token: String
        init(token: String) { _token = token }
        /// The key the phone checks the Mac's answer against (the pairing it holds).
        var token: String { get { q.sync { _token } } set { q.sync { _token = newValue } } }

        var port: UInt16 { q.sync { _port } }
        var mode: Mode { get { q.sync { _mode } } set { q.sync { _mode = newValue } } }
        func snapshot() -> [Tunnel] { q.sync { tunnels } }
        func openVerifiedIdle() -> Int { q.sync { tunnels.filter { $0.verified && !$0.closed && !$0.taken }.count } }
        func openCount() -> Int { q.sync { tunnels.filter { !$0.closed && !$0.taken }.count } }
        func take() -> Tunnel? {
            q.sync {
                // The youngest: the one furthest from the Mac's idle expiry.
                guard let t = tunnels.filter({ $0.verified && !$0.closed && !$0.taken })
                    .max(by: { $0.acceptedAt < $1.acceptedAt }) else { return nil }
                t.taken = true
                return t
            }
        }
        func isClosed(_ t: Tunnel) -> Bool { q.sync { t.closed } }
        func inbox(_ t: Tunnel) -> Data { q.sync { t.inbox } }

        func start(port: UInt16) {
            q.sync {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
                guard let l = try? NWListener(using: params) else { return }
                l.stateUpdateHandler = { [weak self, weak l] state in
                    if case .ready = state, let self, let l { self._port = l.port?.rawValue ?? 0 }
                }
                l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                l.start(queue: q)
                listener = l
            }
        }

        /// Close the listener and every tunnel: the app quit.
        func stop() {
            q.sync {
                listener?.cancel(); listener = nil
                for t in tunnels where !t.closed { t.closed = true; t.conn.cancel() }
            }
        }

        private func accept(_ conn: NWConnection) {
            let t = Tunnel(conn)
            tunnels.append(t)
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.q.async { t.closed = true }
                default: break
                }
            }
            conn.start(queue: q)
            var nonce = Data(count: CableHandshake.nonceLength)
            for i in 0..<nonce.count { nonce[i] = UInt8.random(in: 0...255) }
            switch _mode {
            case .honest:
                conn.send(content: CableHandshake.magic + nonce, completion: .contentProcessed { _ in })
                let expected = CableHandshake.answer(nonce: nonce, token: _token)
                conn.receive(minimumIncompleteLength: 32, maximumLength: 32) { [weak self] data, _, complete, _ in
                    guard let self else { return }
                    if let data, data == expected {
                        t.verified = true
                        if complete { t.closed = true } else { self.readLoop(t) }
                    } else {
                        t.inbox.append(data ?? Data())
                        t.closed = true
                        conn.cancel()
                    }
                }
            case .silent:
                readLoop(t)
            case .badMagic:
                conn.send(content: Data("XX1".utf8) + nonce, completion: .contentProcessed { _ in })
                readLoop(t)
            }
        }

        private func readLoop(_ t: Tunnel) {
            t.conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
                if let data { t.inbox.append(data) }
                if complete || error != nil { t.closed = true } else { self?.readLoop(t) }
            }
        }

        func send(_ t: Tunnel, _ data: Data) { t.conn.send(content: data, completion: .contentProcessed { _ in }) }
        func cancel(_ t: Tunnel) { q.sync { t.closed = true; t.conn.cancel() } }
    }

    /// Send a request down one verified tunnel and read the reply until the Mac's end of stream, then
    /// close the phone's side (which the bridge forwards to the server). A request that races the Mac's
    /// idle expiry fails; like the phone's own retry, it is sent once more on a fresh tunnel.
    private static func throughCable(_ phone: FakePhone, _ request: Data) async -> Data? {
        if let reply = await throughCableOnce(phone, request), !reply.isEmpty { return reply }
        return await throughCableOnce(phone, request)
    }

    private static func throughCableOnce(_ phone: FakePhone, _ request: Data) async -> Data? {
        guard await waitUntil(3, { phone.openVerifiedIdle() > 0 }), let t = phone.take() else { return nil }
        phone.send(t, request)
        let done = await waitUntil(8) { phone.isClosed(t) }
        let reply = phone.inbox(t)
        phone.cancel(t)
        return done ? reply : nil
    }

    // MARK: - The stand-in server

    /// Reads one request head, writes a large reply, and closes AT ONCE, as `CaptureServer` does: the
    /// bridge must forward the end of stream without cutting the reply off.
    private final class StandInServer: @unchecked Sendable {
        let q = DispatchQueue(label: "usbmux.test.server")
        private var listener: NWListener?
        private var _port: UInt16 = 0
        var port: UInt16 { q.sync { _port } }
        let body: Data
        init(bodyBytes: Int) {
            var b = Data(count: bodyBytes)
            for i in 0..<bodyBytes { b[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
            body = b
        }
        var reply: Data {
            Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        }
        func start() {
            q.sync {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                guard let l = try? NWListener(using: params) else { return }
                l.stateUpdateHandler = { [weak self, weak l] state in
                    if case .ready = state, let self, let l { self._port = l.port?.rawValue ?? 0 }
                }
                l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
                l.start(queue: q)
                listener = l
            }
        }
        func stop() { q.sync { listener?.cancel(); listener = nil } }
        private func serve(_ conn: NWConnection, buffer: Data = Data()) {
            if buffer.isEmpty { conn.start(queue: q) }
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, _ in
                guard let self else { return }
                let buf = buffer + (data ?? Data())
                if buf.range(of: Data("\r\n\r\n".utf8)) != nil {
                    conn.send(content: self.reply, completion: .contentProcessed { _ in conn.cancel() })
                } else if complete {
                    conn.cancel()
                } else {
                    self.serve(conn, buffer: buf)
                }
            }
        }
    }

    // MARK: - The run

    private static func run() async {
        var results: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            NSLog("USBMUX \(ok ? "PASS" : "FAIL"): \(name) \(detail)")
        }
        let env = ProcessInfo.processInfo.environment
        let socketPath = env["ARCHIVE_USBMUX_SOCKET"] ?? ""

        // 1. The codec. 48628 goes out as 0xF4BD; read without the swap that would be port 62653.
        check("codec: 48628 is sent as 0xF4BD (network byte order)",
              USBMuxCodec.wirePort(48628) == 0xF4BD && USBMuxCodec.wirePort(48628) == 62653)
        check("codec: 0xF4BD decodes back to 48628", USBMuxCodec.port(fromWire: 0xF4BD) == 48628)
        if let frame = USBMuxCodec.connect(deviceID: 7, port: 48628, tag: 5),
           case let .message(m, tag, consumed) = USBMuxCodec.decode(frame) {
            let head = [UInt8](frame.prefix(16))
            check("codec: Connect carries DeviceID and the swapped PortNumber",
                  m["MessageType"] as? String == "Connect" && m["DeviceID"] as? Int == 7
                    && m["PortNumber"] as? Int == 0xF4BD && tag == 5 && consumed == frame.count)
            check("codec: header is length, version 1, type 8, tag (little-endian)",
                  Int(head[0]) | Int(head[1]) << 8 | Int(head[2]) << 16 == frame.count && head[3] == 0
                    && head[4] == 1 && head[8] == 8 && head[12] == 5)
            if case .need = USBMuxCodec.decode(frame.prefix(10)) { check("codec: a short header waits for more", true) }
            else { check("codec: a short header waits for more", false) }
            if case .need = USBMuxCodec.decode(frame.prefix(frame.count - 1)) { check("codec: a short body waits for more", true) }
            else { check("codec: a short body waits for more", false) }
            var bad = frame; bad[4] = 2
            if case .bad = USBMuxCodec.decode(bad) { check("codec: a wrong version is refused", true) }
            else { check("codec: a wrong version is refused", false) }
        } else {
            check("codec: Connect round-trips", false)
        }

        // 2. The handshake: HMAC-SHA256 against the published test vector.
        let vector = CableHandshake.answer(nonce: Data("The quick brown fox jumps over the lazy dog".utf8), token: "key")
        check("handshake: HMAC-SHA256 matches the RFC test vector",
              vector.map { String(format: "%02x", $0) }.joined()
                == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        let nonce = Data(repeating: 0xAB, count: 16)
        check("handshake: AC1 + 16 bytes is a hello; anything else is not",
              CableHandshake.nonce(fromHello: CableHandshake.magic + nonce) == nonce
                && CableHandshake.nonce(fromHello: Data("XX1".utf8) + nonce) == nil
                && CableHandshake.nonce(fromHello: CableHandshake.magic + nonce.prefix(15)) == nil)

        // 3. S-037 and the pane line (pure).
        check("S-037: the QR host is en0/en1 first, then any other address, then empty",
              LiveCaptureView.pairingHost(primary: "192.168.1.5", candidates: ["10.0.0.1"]) == "192.168.1.5"
                && LiveCaptureView.pairingHost(primary: nil, candidates: ["172.20.10.2"]) == "172.20.10.2"
                && LiveCaptureView.pairingHost(primary: nil, candidates: []) == "")
        check("S-037: a VPN, AirDrop or self-assigned address never stands in for Wi-Fi",
              LiveCaptureView.isPairableFallback(interface: "bridge100", ip: "172.20.10.2")
                && LiveCaptureView.isPairableFallback(interface: "en5", ip: "169.254.12.1") == false
                && LiveCaptureView.isPairableFallback(interface: "utun3", ip: "10.8.0.2") == false
                && LiveCaptureView.isPairableFallback(interface: "awdl0", ip: "10.0.0.9") == false)
        check("pane: a cable line for each state but no device",
              LiveCaptureView.cableLine(.noDevice) == nil && LiveCaptureView.cableLine(.connected) != nil
                && LiveCaptureView.cableLine(.appNotOpen) != nil && LiveCaptureView.cableLine(.unavailable) != nil
                && LiveCaptureView.cableLine(.awaitingPairing) != nil)

        // 4. No usbmuxd at all says so.
        let deadLog = StatusLog()
        let dead = USBMuxBridge(config: USBMuxBridge.Config(socketPath: "/tmp/no-usbmuxd-\(UUID().uuidString)"),
                                targetPort: 1, token: "t") { deadLog.set($0) }
        dead.start()
        check("no usbmuxd: status is unavailable", await waitUntil(3) { deadLog.current == .unavailable })
        dead.stop()

        guard !socketPath.isEmpty, await mux(socketPath, ["MessageType": "FakeStats"]) != nil else {
            check("the fake usbmuxd is reachable at ARCHIVE_USBMUX_SOCKET", false, socketPath)
            return finish(results)
        }

        // 5. Live, against the fake.
        let token = "TEST-LAN-TOKEN-0123456789abcdefXYZ"
        let phone = FakePhone(token: token)
        phone.start(port: 0)
        let server = StandInServer(bodyBytes: 512 * 1024)
        server.start()
        guard await waitUntil(3, { phone.port != 0 && server.port != 0 }) else {
            check("stand-ins listen", false); return finish(results)
        }
        let phonePort = phone.port
        var cfg = USBMuxBridge.Config(socketPath: socketPath)
        cfg.devicePort = phonePort
        cfg.topUpInterval = 0.25
        cfg.idleExpiry = 2
        cfg.reconnectInterval = 0.5
        cfg.lingerAfterReply = 2
        let log = StatusLog()
        let bridge = USBMuxBridge(config: cfg, targetPort: server.port, token: token) { log.set($0) }
        bridge.start()
        check("listen: no device attached reads noDevice", await waitUntil(3) { log.current == .noDevice })

        _ = await mux(socketPath, ["MessageType": "FakeAttach", "DeviceID": 9, "ConnectionType": "Network"])
        _ = await mux(socketPath, ["MessageType": "FakeAttach", "DeviceID": 7, "ConnectionType": "USB"])
        check("attach: the pool fills to four verified tunnels",
              await waitUntil(3) { phone.openVerifiedIdle() >= 4 }, "verified=\(phone.openVerifiedIdle())")
        check("attach: status is connected", await waitUntil(2) { log.current == .connected })
        await sleep(1)
        check("pool: never more than four idle tunnels", phone.openCount() == 4, "open=\(phone.openCount())")
        let stats1 = await mux(socketPath, ["MessageType": "FakeStats"])
        let byDevice1 = stats1?["ConnectsByDevice"] as? [String: Int] ?? [:]
        check("attach: a Wi-Fi-synced device is ignored", byDevice1["9"] == nil, "\(byDevice1)")

        // The splice: a reply written and closed at once arrives whole.
        let reply = await throughCable(phone, request("/x", token: token))
        check("splice: a reply the server closes at once arrives whole",
              reply == server.reply, "got \(reply?.count ?? -1) of \(server.reply.count) bytes")
        check("splice: the taken tunnel is replaced", await waitUntil(2) { phone.openVerifiedIdle() >= 4 })

        let replies = await withTaskGroup(of: Data?.self) { group -> [Data?] in
            for i in 0..<4 { group.addTask { await throughCable(phone, request("/c\(i)", token: token)) } }
            var out: [Data?] = []
            for await r in group { out.append(r) }
            return out
        }
        check("splice: four concurrent requests each arrive whole",
              replies.count == 4 && replies.allSatisfy { $0 == server.reply },
              replies.map { "\($0?.count ?? -1)" }.joined(separator: ","))

        // Idle expiry with no end of stream: the phone never closes; the Mac must.
        if let idle = phone.snapshot().first(where: { $0.verified && !$0.closed && !$0.taken }) {
            let closed = await waitUntil(cfg.idleExpiry + 2) { phone.isClosed(idle) }
            let age = Date().timeIntervalSince(idle.acceptedAt)
            check("expiry: an idle tunnel with no EOF is closed by the Mac", closed && age <= cfg.idleExpiry + 2,
                  String(format: "after %.1fs", age))
        } else {
            check("expiry: an idle tunnel with no EOF is closed by the Mac", false, "no idle tunnel")
        }

        // A silent tunnel is never answered and is expired; with only silent ones, the pane asks for pairing.
        phone.mode = .silent
        let silentSince = Date()
        if await waitUntil(cfg.idleExpiry + 2, { phone.snapshot().contains { $0.acceptedAt > silentSince } }),
           let first = phone.snapshot().first(where: { $0.acceptedAt > silentSince }) {
            let closed = await waitUntil(cfg.idleExpiry + 2) { phone.isClosed(first) }
            check("handshake: a silent tunnel gets no answer and is closed by the expiry",
                  closed && phone.inbox(first).isEmpty, "inbox \(phone.inbox(first).count)")
        } else {
            check("handshake: a silent tunnel gets no answer and is closed by the expiry", false, "none accepted")
        }
        check("handshake: with only silent tunnels the status reads awaitingPairing",
              await waitUntil(cfg.idleExpiry * 2 + 3) {
                  log.current == .awaitingPairing && phone.openVerifiedIdle() == 0
              })

        phone.mode = .badMagic
        let badSince = Date()
        if await waitUntil(cfg.idleExpiry + 2, { phone.snapshot().contains { $0.acceptedAt > badSince } }),
           let bad = phone.snapshot().first(where: { $0.acceptedAt > badSince }) {
            let closed = await waitUntil(1) { phone.isClosed(bad) }
            check("handshake: a wrong hello is closed at once, unanswered",
                  closed && phone.inbox(bad).isEmpty && Date().timeIntervalSince(bad.acceptedAt) < 1.5,
                  String(format: "closed=%@ after %.2fs, inbox %d", closed ? "yes" : "no",
                         Date().timeIntervalSince(bad.acceptedAt), phone.inbox(bad).count))
        } else {
            check("handshake: a wrong hello is closed at once, unanswered", false, "none accepted")
        }

        phone.mode = .honest
        check("handshake: honest tunnels bring the status back to connected",
              await waitUntil(cfg.idleExpiry + 3) { log.current == .connected })

        // Refused Connect: the app is closed. Top-up keeps trying, whatever Connect returned.
        phone.stop()
        check("refused: an attached phone whose app is closed reads appNotOpen",
              await waitUntil(cfg.idleExpiry + 3) { log.current == .appNotOpen })
        let refused1 = (await mux(socketPath, ["MessageType": "FakeStats"]))?["Refused"] as? Int ?? 0
        await sleep(1)
        let refused2 = (await mux(socketPath, ["MessageType": "FakeStats"]))?["Refused"] as? Int ?? 0
        check("refused: the pool keeps retrying", refused2 > refused1, "\(refused1) → \(refused2)")
        phone.start(port: phonePort)
        check("refused: the app back on its port is connected again",
              await waitUntil(4) { log.current == .connected && phone.openVerifiedIdle() >= 1 })

        // Detach closes the device's tunnels and stops connecting.
        _ = await mux(socketPath, ["MessageType": "FakeDetach", "DeviceID": 7])
        check("detach: every tunnel closes", await waitUntil(2) { phone.openCount() == 0 })
        check("detach: status is noDevice", await waitUntil(2) { log.current == .noDevice })
        let c1 = ((await mux(socketPath, ["MessageType": "FakeStats"]))?["ConnectsByDevice"] as? [String: Int])?["7"] ?? 0
        await sleep(1)
        let c2 = ((await mux(socketPath, ["MessageType": "FakeStats"]))?["ConnectsByDevice"] as? [String: Int])?["7"] ?? 0
        check("detach: no Connect after the device left", c1 == c2, "\(c1) → \(c2)")
        bridge.stop()
        server.stop()

        // 6. Into a real CaptureServer: the cable has its own failed-auth throttle key.
        CablePeers.register(localPort: 5555, deviceID: 7)
        check("throttle: a registered cable peer is keyed by its device",
              CaptureServer.cableSourceKey(remotePort: 5555) == "cable:7"
                && CaptureServer.cableSourceKey(remotePort: 5556) == "cable:unregistered")
        CablePeers.unregister(localPort: 5555)

        let session = CaptureSession()
        session.cableBridgeEnabled = false
        let capture = CaptureServer(session: session)
        capture.start()
        guard await waitUntil(5, { session.listenPort != 0 && session.cableListenPort != 0 }) else {
            check("CaptureServer listens on both ports", false); phone.stop(); return finish(results)
        }
        let lanPort = session.listenPort, cablePort = session.cableListenPort
        let realLog = StatusLog()
        let realBridge = USBMuxBridge(config: cfg, targetPort: cablePort, token: session.lanToken) { realLog.set($0) }
        realBridge.start()
        // A phone holding a different pairing refuses every tunnel: the HMAC does not match its key.
        let otherMacMark = realLog.mark
        _ = await mux(socketPath, ["MessageType": "FakeAttach", "DeviceID": 7, "ConnectionType": "USB"])
        await sleep(2)
        check("handshake: a phone paired to another Mac verifies no tunnel and never reads connected",
              phone.openVerifiedIdle() == 0 && (realLog.current == .awaitingPairing || realLog.current == .appNotOpen)
                && !realLog.everSince(otherMacMark, .connected),
              "verified=\(phone.openVerifiedIdle()) status=\(String(describing: realLog.current))")
        _ = await mux(socketPath, ["MessageType": "FakeDetach", "DeviceID": 7])
        phone.token = session.lanToken
        _ = await mux(socketPath, ["MessageType": "FakeAttach", "DeviceID": 7, "ConnectionType": "USB"])
        check("real server: the cable connects", await waitUntil(4) { realLog.current == .connected })
        let good = session.lanToken

        // A refusal sent before the body is read (CaptureServer then closes with it unread, a reset on the
        // loopback leg) must still reach the phone as a 401, not as a dropped connection.
        let bigBody = Data(repeating: 0x5A, count: 2 * 1024 * 1024)
        let bigPost = Data(("POST /photo HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer wrong\r\n"
            + "X-Group: g1\r\nX-Seq: 0\r\nContent-Length: \(bigBody.count)\r\nConnection: close\r\n\r\n").utf8) + bigBody
        let early = statusCode(await throughCable(phone, bigPost))
        check("splice: a 401 sent before the body is read reaches the phone", early == 401, "got \(early ?? -1)")

        // (A) Bad tokens from loopback do not back off the cable.
        var last: Int?
        for _ in 0..<7 { last = statusCode(await httpExchange(port: lanPort, request("/ping", token: "wrong"))) }
        check("throttle: seven bad tokens from loopback are throttled", last == 429, "last \(last ?? -1)")
        CablePeers.lastResolvedKey = nil
        let viaCable = await throughCable(phone, request("/ping", token: good))
        check("throttle: the real splice is keyed by its device, as the bridge registered it",
              CablePeers.lastResolvedKey == "cable:7", CablePeers.lastResolvedKey ?? "nil")
        check("throttle: the cable is not backed off by loopback's failures",
              statusCode(viaCable) == 200, "got \(statusCode(viaCable) ?? -1)")
        check("real server: the cable's /ping reply arrives whole",
              viaCable.map { String(decoding: $0, as: UTF8.self).contains("\"ok\":true") } == true)
        await sleep(Double(CaptureServer.AuthThrottle.baseBackoff) + 0.3)

        // (B) Bad tokens through the cable do not back off loopback.
        last = nil
        for _ in 0..<7 { last = statusCode(await throughCable(phone, request("/ping", token: "wrong"))) }
        check("throttle: seven bad tokens through the cable are throttled", last == 429, "last \(last ?? -1)")
        let viaLoopback = statusCode(await httpExchange(port: lanPort, request("/ping", token: good)))
        check("throttle: loopback is not backed off by the cable's failures", viaLoopback == 200,
              "got \(viaLoopback ?? -1)")

        // (C) The cable listener is loopback only.
        if let ip = LiveCaptureView.primaryIPv4() ?? LiveCaptureView.allIPv4Candidates().first,
           let v4 = IPv4Address(ip) {
            let lan = await httpExchange(host: .ipv4(v4), port: cablePort, request("/ping", token: good), timeout: 3)
            check("cable listener: unreachable on the LAN address", lan == nil || lan?.isEmpty == true, ip)
        } else {
            check("cable listener: unreachable on the LAN address (no LAN address here, not tested)", true)
        }

        realBridge.stop()
        capture.stop()
        phone.stop()
        finish(results)
    }

    private static func finish(_ results: [String]) {
        let passed = !results.isEmpty && results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["USBMUX_TEST_OUT"]
            ?? NSTemporaryDirectory() + "usbmux-test.txt"
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        NSLog("USBMUX DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
#endif
