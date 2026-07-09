import Foundation
import AppKit
import Network
import CryptoKit

/// Google OAuth for the Drive relay (Desktop / installed-app **loopback** flow, `drive.file` scope).
/// Persists the refresh token in the Keychain and mints/refreshes short-lived access tokens.
///
/// - `accessToken()` is AUTONOMOUS (refreshes via the stored refresh token) once signed in — this is what
///   `DriveClient`'s token provider calls. Unit-testable via a mock `HTTPExecuting`.
/// - `signIn(...)` is INTERACTIVE and OWNER-GATED: it opens the browser and runs a localhost redirect
///   server, so it can't run headless. Compile-verified only; the owner runs it once (the drive.file
///   cross-client spike already proved the account/scope work).
final class DriveAuth: @unchecked Sendable {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let keychainAccount = "DriveRefreshToken"

    private let clientId: String
    private let clientSecret: String
    private let http: HTTPExecuting
    private let lock = NSLock()
    private var cached: (token: String, expiry: Date)?

    init(clientId: String, clientSecret: String, http: HTTPExecuting = URLSessionHTTP()) {
        // Trim whitespace/newlines: a pasted client id/secret very often carries a trailing space or
        // newline, which Google rejects as `invalid_client` ("client secret is invalid"). Trimming here
        // covers BOTH the interactive sign-in exchange and the autonomous relay-refresh path.
        self.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
    }

    var isSignedIn: Bool { KeychainHelper.load(account: Self.keychainAccount) != nil }
    func signOut() { KeychainHelper.delete(account: Self.keychainAccount); lock.lock(); cached = nil; lock.unlock() }

    /// A valid access token, refreshed as needed. Throws `.notSignedIn` if there's no stored refresh token.
    func accessToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.expiry > Date().addingTimeInterval(60) { return c.token }
        guard let stored = KeychainHelper.load(account: Self.keychainAccount) else { throw DriveError.notSignedIn }
        let (token, expiry) = try refreshedToken(using: stored)
        cached = (token, expiry)
        return token
    }

    /// Exchange a refresh token for a fresh access token (autonomous).
    private func refreshedToken(using refreshToken: String) throws -> (String, Date) {
        let form = ["client_id": clientId, "client_secret": clientSecret,
                    "refresh_token": refreshToken, "grant_type": "refresh_token"]
        let (status, data, _) = try http.execute(method: "POST", url: Self.tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(Self.formEncode(form).utf8))
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["access_token"] as? String else {
            throw DriveError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        return (at, Date().addingTimeInterval(ttl))
    }

    // MARK: - Interactive sign-in (OWNER-GATED — opens a browser; not for headless runs)

    /// Runs the installed-app loopback OAuth flow: starts a localhost listener, opens the consent URL, and
    /// on the redirect exchanges the code (PKCE) for tokens, persisting the refresh token in the Keychain.
    func signIn(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let verifier = Self.b64url(Self.randomBytes(48))
        let challenge = Self.b64url(Data(SHA256.hash(data: Data(verifier.utf8))))   // PKCE S256
        let state = Self.b64url(Self.randomBytes(24))   // CSRF guard: echoed back on the redirect, verified below
        let listener = LoopbackRedirectServer()
        do {
            let port = try listener.start { [weak self] code, returnedState in
                guard let self else { return }
                // Reject a redirect whose `state` doesn't match the one we sent — a foreign/forged callback
                // must never drive a token exchange. Verified BEFORE exchanging the code.
                guard returnedState == state else {
                    completion(.failure(DriveError.oauthStateMismatch)); listener.stop(); return
                }
                do {
                    let tokens = try self.exchange(code: code, verifier: verifier, redirect: "http://127.0.0.1:\(listener.port)")
                    if let refresh = tokens["refresh_token"] as? String {
                        _ = KeychainHelper.save(account: Self.keychainAccount, password: refresh)
                    }
                    completion(.success(()))
                } catch { completion(.failure(error)) }
                listener.stop()
            }
            var comps = URLComponents(string: Self.authURL)!
            comps.queryItems = [
                .init(name: "client_id", value: clientId),
                .init(name: "redirect_uri", value: "http://127.0.0.1:\(port)"),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scope),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
                .init(name: "state", value: state),
            ]
            if let url = comps.url { NSWorkspace.shared.open(url) }
        } catch { completion(.failure(error)) }
    }

    private func exchange(code: String, verifier: String, redirect: String) throws -> [String: Any] {
        let form = ["client_id": clientId, "client_secret": clientSecret, "code": code,
                    "code_verifier": verifier, "grant_type": "authorization_code", "redirect_uri": redirect]
        let (status, data, _) = try http.execute(method: "POST", url: Self.tokenURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(Self.formEncode(form).utf8))
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return obj
    }

    // MARK: - helpers
    private static func formEncode(_ d: [String: String]) -> String {
        d.map { "\($0.key)=\(($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value))" }
         .joined(separator: "&")
    }
    private static func randomBytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal localhost HTTP listener that captures the single `GET /?code=...` OAuth redirect. Owner-gated
/// (only used by `DriveAuth.signIn`); binds an ephemeral port on 127.0.0.1.
private final class LoopbackRedirectServer: @unchecked Sendable {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    func start(onCode: @escaping @Sendable (String, String?) -> Void) throws -> UInt16 {
        // Bind the listen socket to the loopback interface ONLY (not 0.0.0.0/all interfaces), so no other
        // host on the network can reach the transient OAuth redirect server. `port: .any` still lets the
        // OS pick an ephemeral port, reported via `listener.port`.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data, let req = String(data: data, encoding: .utf8),
                   let line = req.split(separator: "\r\n").first,
                   let pathPart = line.split(separator: " ").dropFirst().first,
                   let comps = URLComponents(string: "http://x\(pathPart)"),
                   let code = comps.queryItems?.first(where: { $0.name == "code" })?.value {
                    let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value
                    let body = "Signed in — you can close this tab and return to Archive Processor."
                    let resp = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    onCode(code, returnedState)
                } else { conn.cancel() }
            }
        }
        let sem = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = l.port?.rawValue ?? 0; sem.signal() }
        }
        l.start(queue: .global())
        _ = sem.wait(timeout: .now() + 5)
        return port
    }
    func stop() { listener?.cancel(); listener = nil }
}
