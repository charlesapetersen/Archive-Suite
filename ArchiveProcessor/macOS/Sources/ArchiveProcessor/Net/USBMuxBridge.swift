import Foundation
import Network
import CryptoKit

/// The iPhone's cable route, Mac end (W40.i-usb-mac; design: REFERENCE.md §Live Capture, USB local relay §2).
///
/// An iPhone cannot open a connection to the Mac over the cable, but the Mac can open one INTO the phone:
/// macOS's `usbmuxd` (`/var/run/usbmuxd`, the private service Xcode, Finder and libimobiledevice use)
/// connects a Mac socket to a TCP port an app on the phone listens on. This bridge rebuilds what
/// `adb reverse` gives Android out of that one primitive: it keeps a few idle tunnels open into the phone
/// app's tunnel port (48628), answers each tunnel's `AC1` handshake, and on the first request byte splices
/// the tunnel to `CaptureServer`'s loopback-only cable listener. The phone's transport, pipeline and the
/// Mac's HTTP server are unchanged.
///
/// Only the Mac uses anything private. If a macOS update changes the protocol, only this route fails, and
/// it says so (`Status.unavailable`); `scripts/usbmux-probe.sh` checks the protocol without a phone.
///
/// Every mutable field is owned by the serial `queue`; every Network.framework callback runs on it.
final class USBMuxBridge: @unchecked Sendable {
    struct Config: Sendable {
        var socketPath: String
        /// The phone app's tunnel port (REFERENCE.md §Live Capture, USB local relay). Injectable so the test driver's stand-in phone
        /// need not take the real port; production always uses 48628.
        var devicePort: UInt16 = 48628
        var poolSize = 4
        var topUpInterval: Double = 2
        /// An idle tunnel older than this is closed and replaced: a suspended phone leaves defunct sockets
        /// that never report an end of stream, so expiry, not EOF, is what keeps the pool live.
        var idleExpiry: Double = 20
        /// How long to wait before re-opening a lost `Listen` socket (usbmuxd restarted, or not there).
        var reconnectInterval: Double = 5
        /// After the server has finished its reply, how long a splice may wait for the phone's end of
        /// stream before both sides are closed anyway.
        var lingerAfterReply: Double = 10
        /// An answered tunnel counts as live for the pane only once the phone has kept it this long: a
        /// phone holding another Mac's pairing closes it straight after the answer.
        var settleTime: Double = 1

        static var production: Config { Config(socketPath: USBMuxBridge.defaultSocketPath) }
    }

    /// What the Live Capture pane says about the cable (REFERENCE.md §Live Capture, USB local relay "The pane and QR caption").
    enum Status: Equatable, Sendable {
        /// usbmuxd could not be reached, or refused `Listen`.
        case unavailable
        /// No iPhone attached by USB.
        case noDevice
        /// An iPhone is attached but its app refused the tunnel (not running, or suspended).
        case appNotOpen
        /// The app accepted a tunnel but has not proved the pairing yet (no QR scanned).
        case awaitingPairing
        /// A verified tunnel is open, or one carried a request recently.
        case connected
    }

    static var defaultSocketPath: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ARCHIVE_USBMUX_SOCKET"], !override.isEmpty {
            return override
        }
        #endif
        return "/var/run/usbmuxd"
    }

    private let config: Config
    private let targetPort: UInt16
    private let token: String
    private let onStatus: @Sendable (Status) -> Void
    private let queue = DispatchQueue(label: "usbmux.bridge")

    private var running = false
    private var listenConn: NWConnection?
    private var listening = false
    private var listenBuffer = Data()
    private var reconnectWork: DispatchWorkItem?
    private var topUpTimer: DispatchSourceTimer?
    private var devices: [Int: Device] = [:]
    private var lastStatus: Status?
    private var nextTag: UInt32 = 1

    /// Owned by `queue`, like every field of the bridge.
    private final class Tunnel: @unchecked Sendable {
        enum State { case connecting, awaitingHello, idle, spliced }
        let deviceID: Int
        let conn: NWConnection
        let born: Double
        /// When this tunnel is closed if it is still idle: `idleExpiry` less up to a quarter, so a pool
        /// filled in one burst is not all replaced in one tick, leaving a moment with no verified tunnel.
        let expiresAt: Double
        /// The splice's local port as registered in `CablePeers`, kept so it is unregistered even when the
        /// connection's path is gone by then.
        var registeredPort: UInt16?
        var state = State.connecting
        var answeredAt: Double?
        var server: NWConnection?
        var finishedDirections = 0
        var lingerWork: DispatchWorkItem?
        var closed = false
        init(deviceID: Int, conn: NWConnection, born: Double, expiresAt: Double) {
            self.deviceID = deviceID; self.conn = conn; self.born = born; self.expiresAt = expiresAt
        }
    }

    private struct Device {
        var tunnels: [ObjectIdentifier: Tunnel] = [:]
        var lastSpliceAt: Double?
    }

    init(config: Config, targetPort: UInt16, token: String, onStatus: @escaping @Sendable (Status) -> Void) {
        self.config = config
        self.targetPort = targetPort
        self.token = token
        self.onStatus = onStatus
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            openListen()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + config.topUpInterval, repeating: config.topUpInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            topUpTimer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            topUpTimer?.cancel(); topUpTimer = nil
            reconnectWork?.cancel(); reconnectWork = nil
            dropListen(closeSpliced: true)
        }
    }

    // MARK: - The Listen socket

    private func openListen() {
        guard running, listenConn == nil else { return }
        let conn = NWConnection(to: .unix(path: config.socketPath), using: .tcp)
        listenConn = conn
        listenBuffer = Data()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.listenConn else { return }
            switch state {
            case .ready:
                guard let msg = USBMuxCodec.encode(USBMuxCodec.message("Listen"), tag: self.takeTag()) else {
                    self.listenLost(); return
                }
                conn.send(content: msg, completion: .contentProcessed { _ in })
                self.readListen(conn)
            case .waiting, .failed, .cancelled:
                // `.waiting` is how a missing socket file shows up; treat it as lost and retry later.
                self.listenLost()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func readListen(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak conn] data, _, isComplete, error in
            guard let self, let conn, conn === self.listenConn else { return }
            if let data { self.listenBuffer.append(data) }
            while true {
                switch USBMuxCodec.decode(self.listenBuffer) {
                case .need:
                    if isComplete || error != nil { self.listenLost(); return }
                    self.readListen(conn)
                    return
                case .bad:
                    self.listenLost()
                    return
                case let .message(msg, _, consumed):
                    self.listenBuffer.removeFirst(consumed)
                    self.handleListenMessage(msg)
                    guard self.listenConn === conn else { return }   // the message tore the socket down
                }
            }
        }
    }

    private func handleListenMessage(_ msg: [String: Any]) {
        switch msg["MessageType"] as? String {
        case "Result":
            if (msg["Number"] as? Int) == 0 {
                listening = true
                publishStatus()
            } else {
                listenLost()
            }
        case "Attached":
            guard let id = msg["DeviceID"] as? Int else { return }
            let props = msg["Properties"] as? [String: Any]
            // Wi-Fi-synced devices are listed too; only the cable is this route.
            guard (props?["ConnectionType"] as? String) == "USB" else { return }
            if devices[id] == nil { devices[id] = Device() }
            topUp(id)
            publishStatus()
        case "Detached":
            guard let id = msg["DeviceID"] as? Int else { return }
            detach(id)
            publishStatus()
        case "Paired":
            if let id = msg["DeviceID"] as? Int, devices[id] != nil { topUp(id) }
        default:
            break
        }
    }

    private func listenLost() {
        dropListen(closeSpliced: false)
        guard running, reconnectWork == nil else { publishStatus(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            self.openListen()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + config.reconnectInterval, execute: work)
        publishStatus()
    }

    /// A lost Listen socket leaves requests already spliced to finish (they do not depend on it); a stop
    /// closes them too.
    private func dropListen(closeSpliced: Bool) {
        let conn = listenConn
        listenConn = nil
        listening = false
        conn?.cancel()
        for id in Array(devices.keys) { detach(id, closeSpliced: closeSpliced) }
        publishStatus()
    }

    /// `Detached` means the cable is gone, so every tunnel of the device goes, spliced ones included.
    private func detach(_ id: Int, closeSpliced: Bool = true) {
        guard let device = devices.removeValue(forKey: id) else { return }
        for tunnel in device.tunnels.values where closeSpliced || tunnel.state != .spliced { close(tunnel) }
    }

    // MARK: - The pool

    private func tick() {
        guard running, listening else { return }
        let now = Self.now()
        for (id, device) in devices {
            for tunnel in device.tunnels.values where tunnel.state != .spliced && now >= tunnel.expiresAt {
                close(tunnel)
            }
            topUp(id)
        }
        publishStatus()
    }

    /// Open fresh tunnels until the device has `poolSize` that are not carrying a request. Refilling never
    /// waits on an end of stream or on the last `Connect`'s result: a refused one simply leaves room that
    /// the next tick fills again.
    private func topUp(_ id: Int) {
        guard running, listening, let device = devices[id] else { return }
        let open = device.tunnels.values.filter { $0.state != .spliced }.count
        guard open < config.poolSize else { return }
        for _ in open..<config.poolSize { openTunnel(id) }
    }

    private func openTunnel(_ id: Int) {
        let conn = NWConnection(to: .unix(path: config.socketPath), using: .tcp)
        let born = Self.now()
        let tunnel = Tunnel(deviceID: id, conn: conn, born: born,
                            expiresAt: born + config.idleExpiry * Double.random(in: 0.75...1))
        devices[id]?.tunnels[ObjectIdentifier(tunnel)] = tunnel
        let tag = takeTag()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard tunnel.state == .connecting,
                      let msg = USBMuxCodec.connect(deviceID: id, port: self.config.devicePort, tag: tag) else { return }
                conn.send(content: msg, completion: .contentProcessed { _ in })
                self.readConnectResult(tunnel)
            case .waiting, .failed, .cancelled:
                self.close(tunnel)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Read the `Connect` reply EXACTLY (header, then body): after `Result 0` the same socket is the raw
    /// pipe, and the phone may speak at once, so a byte too many here would eat the handshake.
    private func readConnectResult(_ tunnel: Tunnel) {
        tunnel.conn.receive(minimumIncompleteLength: USBMuxCodec.headerSize, maximumLength: USBMuxCodec.headerSize) {
            [weak self] header, _, _, _ in
            guard let self, !tunnel.closed else { return }
            guard let header, header.count == USBMuxCodec.headerSize,
                  let length = USBMuxCodec.declaredLength(header) else { self.close(tunnel); return }
            let bodyLength = length - USBMuxCodec.headerSize
            guard bodyLength > 0 else { self.close(tunnel); return }
            tunnel.conn.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) {
                [weak self] body, _, _, _ in
                guard let self, !tunnel.closed else { return }
                guard let body, body.count == bodyLength,
                      case let .message(msg, _, _) = USBMuxCodec.decode(header + body),
                      msg["MessageType"] as? String == "Result" else { self.close(tunnel); return }
                guard (msg["Number"] as? Int) == 0 else {
                    // 3 = the app is not listening (not running, or suspended). Close; never reuse.
                    self.close(tunnel)
                    return
                }
                tunnel.state = .awaitingHello
                self.publishStatus()
                self.readHello(tunnel)
            }
        }
    }

    /// The phone speaks first: `AC1` + a 16-byte nonce. The Mac answers HMAC-SHA256(lanToken, nonce). A
    /// tunnel that sends anything else is closed; one that stays silent is closed by the idle expiry.
    private func readHello(_ tunnel: Tunnel) {
        let n = CableHandshake.helloLength
        tunnel.conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, _ in
            guard let self, !tunnel.closed else { return }
            guard let data, let nonce = CableHandshake.nonce(fromHello: data) else { self.close(tunnel); return }
            tunnel.conn.send(content: CableHandshake.answer(nonce: nonce, token: self.token),
                             completion: .contentProcessed { _ in })
            tunnel.state = .idle
            tunnel.answeredAt = Self.now()
            self.publishStatus()
            self.awaitFirstByte(tunnel)
        }
    }

    private func awaitFirstByte(_ tunnel: Tunnel) {
        tunnel.conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
            guard let self, !tunnel.closed else { return }
            guard let data, !data.isEmpty else { self.close(tunnel); return }
            self.splice(tunnel, first: data, firstIsLast: isComplete)
        }
    }

    // MARK: - The splice

    private func splice(_ tunnel: Tunnel, first: Data, firstIsLast: Bool) {
        tunnel.state = .spliced
        devices[tunnel.deviceID]?.lastSpliceAt = Self.now()
        topUp(tunnel.deviceID)   // replace the tunnel now taken
        publishStatus()

        guard let port = NWEndpoint.Port(rawValue: targetPort) else { close(tunnel); return }
        let server = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        tunnel.server = server
        server.stateUpdateHandler = { [weak self] state in
            guard let self, !tunnel.closed else { return }
            switch state {
            case .ready:
                // Tell CaptureServer which device this loopback peer carries, so its failed-auth throttle
                // keys it `cable:<device>` and not 127.0.0.1 (shared with adb reverse and local processes).
                if case let .hostPort(_, local)? = server.currentPath?.localEndpoint {
                    CablePeers.register(localPort: local.rawValue, deviceID: tunnel.deviceID)
                    tunnel.registeredPort = local.rawValue
                }
                server.send(content: first, completion: .contentProcessed { [weak self] error in
                    guard let self, !tunnel.closed else { return }
                    if error != nil { self.close(tunnel); return }
                    if firstIsLast { self.finishDirection(tunnel, to: server) }
                    else { self.pump(tunnel, from: tunnel.conn, to: server) }
                })
                self.pump(tunnel, from: server, to: tunnel.conn, serverToPhone: true)
            case .waiting:
                self.close(tunnel)   // the server is not there; nothing was exchanged
            case .failed:
                // CaptureServer can answer 401/413/429 before reading the body and close with unread data,
                // which resets the loopback leg. The pumps still hold whatever arrived before the reset and
                // forward it; give them a moment before closing, so the phone sees the refusal and not a drop.
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close(tunnel) }
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    /// Copy one direction, one chunk at a time (the next read waits for the previous send to be taken, so a
    /// slow side applies back-pressure). On end of stream, forward it as an end of stream rather than a
    /// close: `CaptureServer` writes its reply and closes at once, and closing the phone's side then would
    /// cut the reply off.
    ///
    /// The server's side may end in a reset rather than an end of stream: `CaptureServer` answers 401/413/429
    /// before reading a body and closes with that body unread. So a failed read from the server, or a failed
    /// send to it, ends only that direction; the reply already read still reaches the phone, followed by an
    /// end of stream. A failure on the phone's side closes everything: there is no one left to answer.
    private func pump(_ tunnel: Tunnel, from: NWConnection, to: NWConnection, serverToPhone: Bool = false) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !tunnel.closed else { return }
            let next: @Sendable () -> Void = { [weak self] in
                guard let self, !tunnel.closed else { return }
                if isComplete || (error != nil && serverToPhone) {
                    self.finishDirection(tunnel, to: to, serverToPhone: serverToPhone)
                } else if error != nil {
                    self.close(tunnel)
                } else {
                    self.pump(tunnel, from: from, to: to, serverToPhone: serverToPhone)
                }
            }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !tunnel.closed else { return }
                    if sendError == nil { next() }
                    else if serverToPhone { self.close(tunnel) }
                    else { self.abandonDirection(tunnel) }   // the server stopped reading; await its reply
                })
            } else {
                next()
            }
        }
    }

    /// The phone-to-server direction cannot go on (the server closed its read side); count it as done
    /// without an end of stream, so the reply direction decides when the splice closes.
    private func abandonDirection(_ tunnel: Tunnel) {
        tunnel.finishedDirections += 1
        if tunnel.finishedDirections >= 2 { close(tunnel) }
    }

    private func finishDirection(_ tunnel: Tunnel, to: NWConnection, serverToPhone: Bool = false) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self] _ in
            guard let self, !tunnel.closed else { return }
            tunnel.finishedDirections += 1
            if tunnel.finishedDirections >= 2 { self.close(tunnel); return }
            if serverToPhone {
                // The reply is out. Give the phone a bounded time to finish its side.
                let work = DispatchWorkItem { [weak self] in self?.close(tunnel) }
                tunnel.lingerWork = work
                self.queue.asyncAfter(deadline: .now() + self.config.lingerAfterReply, execute: work)
            }
        })
    }

    /// Idempotent. `cancel()` (not `forceCancel()`) closes gracefully, so bytes already handed to the
    /// kernel are still delivered.
    private func close(_ tunnel: Tunnel) {
        guard !tunnel.closed else { return }
        tunnel.closed = true
        tunnel.lingerWork?.cancel()
        if let port = tunnel.registeredPort { CablePeers.unregister(localPort: port) }
        if let server = tunnel.server {
            server.stateUpdateHandler = nil   // the handlers capture the tunnel: break the cycle
            server.cancel()
        }
        tunnel.conn.stateUpdateHandler = nil
        tunnel.conn.cancel()
        devices[tunnel.deviceID]?.tunnels[ObjectIdentifier(tunnel)] = nil
        publishStatus()
    }

    // MARK: - Status

    private func currentStatus() -> Status {
        guard listening else { return .unavailable }
        guard !devices.isEmpty else { return .noDevice }
        let now = Self.now()
        var status = Status.appNotOpen
        for device in devices.values {
            if device.tunnels.values.contains(where: {
                $0.state == .spliced || ($0.state == .idle && $0.answeredAt.map { now - $0 >= config.settleTime } == true)
            })
                || device.lastSpliceAt.map({ now - $0 <= config.idleExpiry }) == true {
                return .connected
            }
            if device.tunnels.values.contains(where: { $0.state == .awaitingHello || $0.state == .idle }) {
                status = .awaitingPairing
            }
        }
        return status
    }

    private func publishStatus() {
        guard running else { return }
        let status = currentStatus()
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus(status)
    }

    private func takeTag() -> UInt32 {
        defer { nextTag &+= 1 }
        return nextTag
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

/// usbmuxd's socket framing: a 16-byte little-endian header (total length, version 1, message type 8 =
/// plist, tag) followed by an XML plist. Pure, so the test driver pins it.
enum USBMuxCodec {
    static let headerSize = 16
    static let version: UInt32 = 1
    static let plistType: UInt32 = 8
    /// A plist reply is a few hundred bytes; anything past this is not usbmuxd.
    static let maxMessageBytes = 1 << 20

    /// usbmuxd takes `PortNumber` in NETWORK byte order inside an ordinary integer: 48628 goes out as
    /// 0xF4BD (62653). Sent without the swap, the phone would be asked for port 62653.
    static func wirePort(_ port: UInt16) -> Int { Int(port.byteSwapped) }
    static func port(fromWire value: Int) -> UInt16 { UInt16(truncatingIfNeeded: value).byteSwapped }

    static func message(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var m: [String: Any] = ["MessageType": type, "ClientVersionString": "ArchiveProcessor",
                                "ProgName": "ArchiveProcessor", "kLibUSBMuxVersion": 3]
        for (key, value) in fields { m[key] = value }
        return m
    }

    static func connect(deviceID: Int, port: UInt16, tag: UInt32) -> Data? {
        encode(message("Connect", ["DeviceID": deviceID, "PortNumber": wirePort(port)]), tag: tag)
    }

    static func encode(_ message: [String: Any], tag: UInt32) -> Data? {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        else { return nil }
        var out = Data(capacity: headerSize + body.count)
        for field in [UInt32(headerSize + body.count), version, plistType, tag] {
            withUnsafeBytes(of: field.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(body)
        return out
    }

    enum Decoded {
        case need
        case bad
        case message([String: Any], tag: UInt32, consumed: Int)
    }

    /// The total length a header declares, if the header is well formed.
    static func declaredLength(_ data: Data) -> Int? {
        guard data.count >= headerSize else { return nil }
        let length = Int(readLE(data, 0))
        guard length >= headerSize, length <= maxMessageBytes,
              readLE(data, 4) == version, readLE(data, 8) == plistType else { return nil }
        return length
    }

    static func decode(_ data: Data) -> Decoded {
        guard data.count >= headerSize else { return .need }
        guard let length = declaredLength(data) else { return .bad }
        guard data.count >= length else { return .need }
        let start = data.startIndex
        let body = data.subdata(in: (start + headerSize)..<(start + length))
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
        else { return .bad }
        return .message(plist, tag: readLE(data, 12), consumed: length)
    }

    private static func readLE(_ data: Data, _ offset: Int) -> UInt32 {
        let s = data.startIndex + offset
        return UInt32(data[s]) | UInt32(data[s + 1]) << 8 | UInt32(data[s + 2]) << 16 | UInt32(data[s + 3]) << 24
    }
}

/// The tunnel handshake (REFERENCE.md §Live Capture, USB local relay): the phone sends `AC1` and a 16-byte random nonce; the Mac
/// replies HMAC-SHA256(key: lanToken, message: nonce), 32 bytes. It proves to the phone that the far end
/// of a tunnel is its own Mac before a photo goes in, so another app on the phone cannot pose as one.
enum CableHandshake {
    static let magic = Data("AC1".utf8)
    static let nonceLength = 16
    static let helloLength = 3 + nonceLength
    static let answerLength = 32

    static func nonce(fromHello hello: Data) -> Data? {
        guard hello.count == helloLength, hello.prefix(3) == magic else { return nil }
        return Data(hello.dropFirst(3))
    }

    static func answer(nonce: Data, token: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: Data(token.utf8))))
    }
}

/// Which device each spliced loopback connection carries, by the bridge's local port, so `CaptureServer`
/// can key its failed-auth throttle `cable:<device>`. Written on the bridge's queue, read on the server's.
enum CablePeers {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byPort: [UInt16: Int] = [:]

    static func register(localPort: UInt16, deviceID: Int) { lock.withLock { byPort[localPort] = deviceID } }
    static func unregister(localPort: UInt16) { lock.withLock { _ = byPort.removeValue(forKey: localPort) } }
    static func deviceID(forLocalPort port: UInt16) -> Int? { lock.withLock { byPort[port] } }

    /// The throttle key `CaptureServer` last derived for a cable peer (read by the test driver).
    nonisolated(unsafe) private static var _lastResolvedKey: String?
    static var lastResolvedKey: String? {
        get { lock.withLock { _lastResolvedKey } }
        set { lock.withLock { _lastResolvedKey = newValue } }
    }
}
