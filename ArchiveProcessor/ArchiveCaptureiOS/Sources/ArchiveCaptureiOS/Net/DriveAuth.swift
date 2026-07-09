import AuthenticationServices
import CryptoKit
import Foundation

/// Thread-safe token storage so `DriveClient`'s synchronous token provider (called off the main thread)
/// can read the current access/refresh tokens without actor-isolation conflicts.
private final class TokenStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _accessToken: String?
    private var _refreshToken: String?
    private var _expiry: Date?

    var accessToken: String? { lock.withLock { _accessToken } }
    var refreshToken: String? { lock.withLock { _refreshToken } }
    var expiry: Date? { lock.withLock { _expiry } }

    func update(accessToken: String?, refreshToken: String?, expiry: Date?) {
        lock.withLock {
            if let at = accessToken { _accessToken = at }
            if let rt = refreshToken { _refreshToken = rt }
            _expiry = expiry
        }
    }

    func clear() {
        lock.withLock { _accessToken = nil; _refreshToken = nil; _expiry = nil }
    }

    func load() {
        let ud = UserDefaults.standard
        lock.withLock {
            _accessToken = ud.string(forKey: "driveAccessToken")
            _refreshToken = ud.string(forKey: "driveRefreshToken")
            if let t = ud.object(forKey: "driveTokenExpiry") as? Double {
                _expiry = Date(timeIntervalSince1970: t)
            }
        }
    }

    func persist() {
        let ud = UserDefaults.standard
        lock.withLock {
            ud.set(_accessToken, forKey: "driveAccessToken")
            ud.set(_refreshToken, forKey: "driveRefreshToken")
            if let e = _expiry { ud.set(e.timeIntervalSince1970, forKey: "driveTokenExpiry") }
            else { ud.removeObject(forKey: "driveTokenExpiry") }
        }
    }
}

/// On-device Google sign-in for the Drive cloud relay, mirroring the Android `DriveAuth.kt`
/// (PKCE, `drive.file` scope, autonomous token refresh) but using `ASWebAuthenticationSession` —
/// the RFC 8252 native-app flow for iOS.
///
/// The iOS OAuth client uses **no client secret** (PKCE only; the redirect is the reversed-client-ID
/// custom scheme, verified by bundle ID in the Google Cloud console). The persisted tokens (access +
/// refresh) live in UserDefaults; `accessTokenBlocking()` feeds `DriveClient`'s `() -> String` token
/// provider and refreshes transparently.
///
/// The phone must sign in to the **same Google account** as the Mac — `drive.file` is per-project, so
/// an OAuth client in the same GCP project can see/write the folder the Mac created.
///
/// **Setup (one-time, GCP console):** create an **iOS** OAuth client in project `YOUR_GCP_PROJECT` with
/// bundle ID `com.archiveprocessor.capture.ios`. Copy the client ID here. Enable **"Custom URI scheme"**
/// in the client's Advanced Settings (off by default; Google blocks it otherwise — same gotcha as Android).
@MainActor
final class DriveAuth: ObservableObject {

    // MARK: - GCP iOS OAuth client

    /// iOS OAuth client in GCP project YOUR_GCP_PROJECT (bundle ID com.archiveprocessor.capture.ios).
    /// **Replace this** with the real client ID after creating the iOS client in the Google Cloud console.
    static let clientID = "YOUR_GCP_PROJECT-REPLACE_WITH_IOS_CLIENT_ID.apps.googleusercontent.com"

    /// Reversed-client-ID custom scheme — the redirect URI for iOS installed-app clients (no secret needed).
    static var redirectURI: String {
        let prefix = clientID.components(separatedBy: ".apps.googleusercontent.com").first!
        return "com.googleusercontent.apps.\(prefix):/oauth2redirect"
    }

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let scope = "https://www.googleapis.com/auth/drive.file"

    // MARK: - Token state

    @Published private(set) var isSignedIn: Bool = false

    /// Thread-safe store so `accessTokenBlocking` (called off the main thread by `DriveClient`) can
    /// read tokens without crossing the `@MainActor` boundary.
    private let tokens = TokenStore()

    init() {
        tokens.load()
        isSignedIn = tokens.refreshToken != nil
    }

    // MARK: - Sign in (ASWebAuthenticationSession + PKCE)

    func signIn() async -> (success: Bool, error: String?) {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.sha256Base64URL(verifier)

        var comps = URLComponents(string: Self.authEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = comps.url else { return (false, "Failed to build auth URL") }

        let scheme = Self.redirectURI.components(separatedBy: ":").first!

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                    if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: error ?? DriveAuthError.cancelled) }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.start()
            }

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                return (false, "No authorization code in the redirect")
            }

            return await exchangeCode(code, verifier: verifier)
        } catch {
            if (error as? DriveAuthError) == .cancelled || (error as NSError).code == 1 {
                return (false, "Sign-in was cancelled")
            }
            return (false, error.localizedDescription)
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async -> (success: Bool, error: String?) {
        let body = [
            "code": code,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        return await tokenRequest(body)
    }

    func refreshAccessToken() async -> Bool {
        guard let rt = tokens.refreshToken else { return false }
        let body = [
            "client_id": Self.clientID,
            "refresh_token": rt,
            "grant_type": "refresh_token",
        ]
        return (await tokenRequest(body)).success
    }

    private func tokenRequest(_ params: [String: String]) async -> (success: Bool, error: String?) {
        var req = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\(Self.percentEncode($0.value))" }
            .joined(separator: "&").data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
                return (false, msg)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = json["access_token"] as? String else {
                return (false, "Missing access_token in response")
            }
            let rt = json["refresh_token"] as? String
            let expiresIn = (json["expires_in"] as? Int) ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
            tokens.update(accessToken: at, refreshToken: rt, expiry: expiry)
            tokens.persist()
            isSignedIn = true
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Token accessor (for DriveClient)

    /// Returns a valid access token, refreshing if expired. Blocking (semaphore bridge) for use from
    /// `DriveClient`'s synchronous token provider — MUST be called off the main thread.
    /// `nonisolated` so it can be captured in a `@Sendable` closure without crossing `@MainActor`.
    nonisolated func accessTokenBlocking() throws -> String {
        dispatchPrecondition(condition: .notOnQueue(.main))

        if let at = tokens.accessToken, let exp = tokens.expiry, Date() < exp { return at }
        guard tokens.refreshToken != nil else { throw DriveError.notSignedIn }

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        var err: Error?
        Task { @MainActor in
            let ok = await self.refreshAccessToken()
            if ok, let at = self.tokens.accessToken { result = at }
            else { err = DriveError.notSignedIn }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 65) == .timedOut {
            throw DriveError.tokenRefreshTimedOut
        }
        if let r = result { return r }
        throw err ?? DriveError.notSignedIn
    }

    // MARK: - Sign out

    func signOut() {
        tokens.clear()
        tokens.persist()
        isSignedIn = false
    }

    // MARK: - PKCE helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    /// S256 code challenge: SHA-256 hash of the verifier, base64url-encoded (via CryptoKit).
    private static func sha256Base64URL(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64URLEncoded()
    }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "-._~")
        return s
    }()
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private enum DriveAuthError: Error {
    case cancelled
}
