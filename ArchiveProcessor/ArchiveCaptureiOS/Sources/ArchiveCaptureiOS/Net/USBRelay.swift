import Foundation
import Network
import CryptoKit

/// The iPhone end of the cable route (REFERENCE.md §Live Capture, USB local relay §2, §7; W40.i-usb-app). An iPhone cannot
/// open a connection to the Mac over the cable, but the Mac's `USBMuxBridge` can open one into the phone through
/// usbmuxd. So the app listens on two loopback ports and joins them:
///
/// - **48628, the tunnel port.** The Mac keeps idle tunnels open into it. Each new tunnel is challenged first:
///   the phone sends `AC1` + a 16-byte random nonce and the Mac must answer HMAC-SHA256(lanToken, nonce) within
///   5 s. Only a verified tunnel is ever given a request, so another app on the phone that connects here cannot
///   pose as the Mac and receive a photo plus the bearer token. Before pairing there is no token: tunnels are held
///   unverified (they only tell the Connect screen a cable is there) and challenged once the QR is scanned.
/// - **48629, the local relay.** `MacClient`'s host in Cable mode. Each connection is queued, first in first out,
///   until a verified idle tunnel is free, then spliced to it; one that waits 10 s is closed and the queue's own
///   retry takes over. If 48629 is busy the relay takes a system port, and `MacClient` asks for it each request.
///
/// Both listeners are bound explicitly to 127.0.0.1: unbound, `NWListener` takes every interface and a Wi-Fi peer
/// could reach them. A splice forwards each side's end of stream to the other and cancels the pair only once both
/// directions have finished and the last send was processed, because `CaptureServer` writes its reply and closes
/// at once; closing the phone's side on the Mac's close would cut that reply off.
///
/// Suspension leaves the listeners defunct, so the app calls `restart()` on every return to `.active`. Network and
/// CryptoKit only, no UIKit: the macOS host tests (`scripts/test-ios-usb-relay.sh`) compile it standalone. All state
/// lives on `queue`.
final class USBRelay: @unchecked Sendable {
    struct Config {
        var tunnelPort: UInt16 = 48628
        var relayPort: UInt16 = 48629
        /// How long a local connection waits for a verified tunnel; inside `MacClient`'s 30 s request timeout.
        var waitLimit: TimeInterval = 10
        /// How long the Mac has to answer `AC1`.
        var handshakeTimeout: TimeInterval = 5
        /// A tunnel that arrived longer ago than this is not used: the Mac expires an idle tunnel 15 to 20 s after
        /// opening it, and one taken near that age would race the expiry. Age counts from ARRIVAL, the Mac's clock,
        /// not from verification, which at pairing happens to every held tunnel at once. Youngest first, likewise.
        var maxIdleAge: TimeInterval = 12
        /// Tunnels held at once, of any state. The Mac keeps four; the cap only bounds what a local app could open,
        /// and a full table makes room by closing its oldest unverified tunnel.
        var maxTunnels = 16
        /// After one direction of a splice ends, how long the other may stay open before the pair is cancelled.
        var lingerLimit: TimeInterval = 30
        /// Local connections waiting at once; past it a newcomer is refused (only a misbehaving local app gets here).
        var maxWaiting = 32
    }

    /// What the Connect screen and the cable mode read. Delivered on the main queue.
    struct Status: Equatable {
        /// 48628 is listening; false means the cable route is unavailable (the port is taken).
        var tunnelListening = false
        /// At least one tunnel is open into 48628, verified or not. Before pairing it only picks a default.
        var tunnelOpen = false
        var verifiedTunnels = 0
        var relayPort: UInt16?
        /// Tunnels that answered the challenge WRONGLY since the token was last set: a Mac is on the cable but
        /// holds another token, so the pairing is stale ("re-scan"), not unreachable.
        var rejectedAnswers = 0
    }

    static let shared = USBRelay()

    private let config: Config
    private let queue = DispatchQueue(label: "com.archiveprocessor.capture.usbrelay")
    private var tunnelListener: NWListener?
    private var relayListener: NWListener?
    private var tunnels: [Tunnel] = []
    private var waiting: [Waiter] = []
    /// Local connections accepted but not yet ready.
    private var starting: [Int: NWConnection] = [:]
    private var splices: [Splice] = []
    private var token: String?
    private var running = false
    private var generation = 0
    private var nextWaiterID = 0
    private var boundRelayPort: UInt16?
    private var boundTunnelPort: UInt16?
    private var tunnelReady = false
    private var rejectedAnswers = 0
    private var lastStatus = Status()
    private var statusHandler: ((Status) -> Void)?

    init(config: Config = Config()) { self.config = config }

    // MARK: - Public surface

    /// Start both listeners (idempotent).
    func start() { queue.async { if !self.running { self.running = true; self.openListeners() } } }

    /// Tear down both listeners and every tunnel and local connection, then listen again. For each return to the
    /// foreground: a suspended app's sockets are defunct and never report it.
    func restart() {
        queue.async {
            self.closeAll()
            self.running = true
            self.openListeners()
        }
    }

    func stop() { queue.async { self.closeAll(); self.running = false; self.publishStatus() } }

    /// The paired Mac's `lanToken`, or nil when no Cable pairing holds one. A change drops every tunnel verified
    /// against the old token and challenges the held ones with the new.
    func setToken(_ newToken: String?) {
        queue.async {
            let t = newToken.flatMap { $0.isEmpty ? nil : $0 }
            guard t != self.token else { return }
            self.token = t
            self.rejectedAnswers = 0
            for tunnel in self.tunnels where tunnel.state == .verifying || tunnel.state == .idle {
                self.close(tunnel)
            }
            if t != nil { self.tunnels.filter { $0.state == .held }.forEach(self.challenge) }
            self.publishStatus()
        }
    }

    func onStatus(_ handler: @escaping (Status) -> Void) {
        queue.async {
            self.statusHandler = handler
            let s = self.lastStatus
            DispatchQueue.main.async { handler(s) }
        }
    }

    /// The relay's bound port, or nil while it is not listening. `MacClient` asks for it each request.
    var relayPort: UInt16? { queue.sync { boundRelayPort } }
    var status: Status { queue.sync { currentStatus() } }
    /// For the host tests, which bind port 0.
    var tunnelPort: UInt16? { queue.sync { tunnelReady ? boundTunnelPort : nil } }
    var waitingCount: Int { queue.sync { waiting.count } }
    var tunnelCount: Int { queue.sync { tunnels.count } }

    // MARK: - Listeners

    private func openListeners() {
        generation += 1
        tunnelListener = makeListener(port: config.tunnelPort, isRelay: false)
        relayListener = makeListener(port: config.relayPort, isRelay: true)
    }

    private func makeListener(port: UInt16, isRelay: Bool) -> NWListener? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        // Lets a re-created listener bind past the TIME_WAIT the torn-down tunnels leave; a second LIVE listener on
        // the port is still refused (measured), so a busy port is still seen as busy.
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else {
            if isRelay, port != 0 { return makeListener(port: 0, isRelay: true) }
            publishStatus()
            return nil
        }
        let gen = generation
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, gen == self.generation else { conn.cancel(); return }
            if isRelay { self.acceptLocal(conn) } else { self.acceptTunnel(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, gen == self.generation else { return }
            switch state {
            case .ready:
                if isRelay { self.boundRelayPort = listener.port?.rawValue }
                else { self.tunnelReady = true; self.boundTunnelPort = listener.port?.rawValue }
                self.publishStatus()
            case .failed:
                listener.cancel()
                if isRelay {
                    self.boundRelayPort = nil
                    // 48629 taken: a system port instead. The endpoint stores the mode, not the port, so it follows.
                    if port != 0 { self.relayListener = self.makeListener(port: 0, isRelay: true) }
                } else {
                    self.tunnelReady = false
                    self.tunnelListener = nil
                }
                self.publishStatus()
            default:
                break
            }
        }
        listener.start(queue: queue)
        return listener
    }

    private func closeAll() {
        generation += 1
        tunnelListener?.cancel(); tunnelListener = nil
        relayListener?.cancel(); relayListener = nil
        boundRelayPort = nil
        tunnelReady = false
        splices.forEach { abort($0) }
        tunnels.forEach { close($0) }
        waiting.forEach { $0.conn.cancel() }
        waiting.removeAll()
        let unready = starting.values
        starting.removeAll()
        unready.forEach { $0.cancel() }
    }

    // MARK: - Tunnels

    private final class Tunnel {
        enum State { case held, verifying, idle, spliced, closed }
        let conn: NWConnection
        var state: State = .held
        var nonce = Data()
        var answer = Data()
        let arrivedAt = Date()
        var splice: Splice?
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private func acceptTunnel(_ conn: NWConnection) {
        if tunnels.count >= config.maxTunnels {
            // Full: drop the oldest unverified tunnel rather than the newcomer, so a local app that fills the table
            // before pairing cannot keep the Mac's tunnels out. With none unverified, refuse the newcomer.
            guard let oldest = tunnels.first(where: { $0.state == .held || $0.state == .verifying }) else {
                conn.cancel(); return
            }
            close(oldest)
        }
        let tunnel = Tunnel(conn)
        tunnels.append(tunnel)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, tunnel.state != .closed else { return }
            switch state {
            case .ready:
                self.read(tunnel)
                if self.token != nil { self.challenge(tunnel) }
                self.publishStatus()
            case .failed, .cancelled:
                if let s = tunnel.splice { self.abort(s) } else { self.close(tunnel) }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Send `AC1` + a fresh nonce; the answer arrives through `read`.
    private func challenge(_ tunnel: Tunnel) {
        guard tunnel.state == .held, tunnel.conn.state == .ready, token != nil else { return }
        tunnel.state = .verifying
        tunnel.nonce = CableHandshake.newNonce()
        tunnel.answer = Data()
        tunnel.conn.send(content: CableHandshake.magic + tunnel.nonce, contentContext: .defaultMessage, isComplete: true,
                         completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close(tunnel) }
        })
        queue.asyncAfter(deadline: .now() + config.handshakeTimeout) { [weak self] in
            guard let self, tunnel.state == .verifying else { return }
            self.close(tunnel)   // silent past the limit: never used
        }
    }

    /// One receive is outstanding on every tunnel for its whole life, and what it delivers depends on the state.
    /// The Mac never speaks first and says nothing between its answer and the reply, so data on a held or idle
    /// tunnel, or more than the 32-byte answer, is not the Mac and closes the tunnel.
    private func read(_ tunnel: Tunnel) {
        tunnel.conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, tunnel.state != .closed else { return }
            if tunnel.state == .spliced, let splice = tunnel.splice {
                self.forwardDown(splice, data: data, isComplete: isComplete, error: error)
                return
            }
            if isComplete || error != nil { self.close(tunnel); return }   // before any promotion: a closing tunnel is never used
            if let data, !data.isEmpty {
                guard tunnel.state == .verifying else { self.close(tunnel); return }
                tunnel.answer.append(data)
                if tunnel.answer.count >= CableHandshake.answerLength {
                    guard tunnel.answer.count == CableHandshake.answerLength, let token = self.token,
                          CableHandshake.verify(answer: tunnel.answer, nonce: tunnel.nonce, token: token) else {
                        if tunnel.answer.count == CableHandshake.answerLength { self.rejectedAnswers += 1 }
                        self.close(tunnel); return
                    }
                    tunnel.state = .idle
                    self.publishStatus()
                    self.serveWaiting()   // may splice this tunnel at once; the receive re-issued below then feeds it
                }
            }
            self.read(tunnel)
        }
    }

    private func close(_ tunnel: Tunnel) {
        if let splice = tunnel.splice, !splice.finished { finish(splice); return }   // finish closes the tunnel
        guard tunnel.state != .closed else { return }
        tunnel.state = .closed
        tunnel.conn.cancel()
        tunnels.removeAll { $0 === tunnel }
        publishStatus()
    }

    /// The youngest verified idle tunnel; any past `maxIdleAge` is closed instead (the Mac replaces it).
    private func takeTunnel() -> Tunnel? {
        let now = Date()
        for stale in tunnels where stale.state == .idle && now.timeIntervalSince(stale.arrivedAt) > config.maxIdleAge {
            close(stale)
        }
        return tunnels.filter { $0.state == .idle }.max { $0.arrivedAt < $1.arrivedAt }
    }

    // MARK: - Local connections

    private struct Waiter { let id: Int; let conn: NWConnection }

    private func acceptLocal(_ conn: NWConnection) {
        guard waiting.count + starting.count < config.maxWaiting else { conn.cancel(); return }
        nextWaiterID += 1
        let id = nextWaiterID
        let gen = generation
        starting[id] = conn   // tracked from accept, so a restart before it is ready still cancels it
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.starting.removeValue(forKey: id) != nil, gen == self.generation else { conn.cancel(); return }
                self.waiting.append(Waiter(id: id, conn: conn))
                self.queue.asyncAfter(deadline: .now() + self.config.waitLimit) { [weak self] in
                    guard let self, let i = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                    self.waiting.remove(at: i)
                    conn.cancel()   // no verified tunnel in time: the caller's retry takes over
                }
                self.serveWaiting()
            case .failed, .cancelled:
                self.starting[id] = nil
                self.waiting.removeAll { $0.id == id }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func serveWaiting() {
        while !waiting.isEmpty, let tunnel = takeTunnel() {
            let waiter = waiting.removeFirst()
            guard waiter.conn.state == .ready else { waiter.conn.cancel(); continue }
            startSplice(local: waiter.conn, tunnel: tunnel)
        }
    }

    // MARK: - The splice

    private final class Splice {
        let local: NWConnection
        let tunnel: Tunnel
        var upDone = false     // local → tunnel finished, end of stream forwarded and processed
        var downDone = false   // tunnel → local
        var finished = false
        init(local: NWConnection, tunnel: Tunnel) { self.local = local; self.tunnel = tunnel }
    }

    private func startSplice(local: NWConnection, tunnel: Tunnel) {
        let splice = Splice(local: local, tunnel: tunnel)
        splices.append(splice)
        tunnel.state = .spliced
        tunnel.splice = splice
        local.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.abort(splice)
            default: break
            }
        }
        publishStatus()
        pumpUp(splice)
        // Down: the tunnel's outstanding receive in `read` now delivers into `forwardDown`.
    }

    private func pumpUp(_ splice: Splice) {
        splice.local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !splice.finished else { return }
            if error != nil { self.abort(splice); return }
            self.send(data, isComplete: isComplete, to: splice.tunnel.conn, in: splice) { [weak self] in
                guard let self else { return }
                if isComplete { splice.upDone = true; self.directionEnded(splice) } else { self.pumpUp(splice) }
            }
        }
    }

    private func forwardDown(_ splice: Splice, data: Data?, isComplete: Bool, error: NWError?) {
        guard !splice.finished else { return }
        if error != nil { abort(splice); return }
        send(data, isComplete: isComplete, to: splice.local, in: splice) { [weak self] in
            guard let self else { return }
            if isComplete { splice.downDone = true; self.directionEnded(splice) } else { self.read(splice.tunnel) }
        }
    }

    /// Forward `data`, then the end of stream when `isComplete`, then `next` once the bytes are processed. A failed
    /// send aborts the pair. Data goes as complete default messages and the end of stream as an EMPTY final
    /// message, as the Mac's bridge does: an incomplete default message followed by a final one carrying data
    /// stalls the second send (measured 2026-10-31), so a reply would never reach the phone's caller.
    private func send(_ data: Data?, isComplete: Bool, to conn: NWConnection, in splice: Splice,
                      next: @escaping () -> Void) {
        let sent: NWConnection.SendCompletion = .contentProcessed { [weak self] err in
            guard let self, !splice.finished else { return }
            if err != nil { self.abort(splice) } else { next() }
        }
        if let data, !data.isEmpty {
            conn.send(content: data, contentContext: .defaultMessage, isComplete: true,
                      completion: isComplete ? .contentProcessed { [weak self] err in
                guard let self, !splice.finished else { return }
                if err != nil { self.abort(splice); return }
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: sent)
            } : sent)
        } else if isComplete {
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: sent)
        } else {
            next()
        }
    }

    private func directionEnded(_ splice: Splice) {
        if splice.upDone && splice.downDone { finish(splice); return }
        queue.asyncAfter(deadline: .now() + config.lingerLimit) { [weak self] in
            guard let self, !splice.finished else { return }
            self.finish(splice)
        }
    }

    private func finish(_ splice: Splice) {
        guard !splice.finished else { return }
        splice.finished = true
        splices.removeAll { $0 === splice }
        splice.local.cancel()
        close(splice.tunnel)
    }

    private func abort(_ splice: Splice) { finish(splice) }

    // MARK: - Status

    private func currentStatus() -> Status {
        Status(tunnelListening: tunnelReady,
               tunnelOpen: tunnels.contains { $0.state != .closed && $0.conn.state == .ready },
               verifiedTunnels: tunnels.filter { $0.state == .idle }.count,
               relayPort: boundRelayPort,
               rejectedAnswers: rejectedAnswers)
    }

    private func publishStatus() {
        let s = currentStatus()
        guard s != lastStatus else { return }
        lastStatus = s
        if let handler = statusHandler { DispatchQueue.main.async { handler(s) } }
    }
}

/// The tunnel handshake, the one wire contract the cable adds (REFERENCE.md §Live Capture, USB local relay). Must match the Mac's
/// `CableHandshake` in `USBMuxBridge.swift` byte for byte: `AC1` + 16-byte nonce → HMAC-SHA256(key: lanToken,
/// message: nonce), 32 bytes.
enum CableHandshake {
    static let magic = Data("AC1".utf8)
    static let nonceLength = 16
    static let answerLength = 32

    static func newNonce() -> Data { SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) } }

    static func answer(nonce: Data, token: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: Data(token.utf8))))
    }

    /// Constant-time (CryptoKit's own comparison).
    static func verify(answer: Data, nonce: Data, token: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(answer, authenticating: nonce, using: SymmetricKey(data: Data(token.utf8)))
    }
}
