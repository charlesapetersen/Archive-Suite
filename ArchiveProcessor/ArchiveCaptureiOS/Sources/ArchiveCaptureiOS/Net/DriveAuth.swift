import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// On-device Google sign-in for the Drive cloud relay, mirroring the Android `DriveAuth.kt`
/// (PKCE, `drive.file` scope, autonomous token refresh) but using `ASWebAuthenticationSession` —
/// the RFC 8252 native-app flow for iOS.
///
/// The iOS OAuth client uses **no client secret** (PKCE only; the redirect is the reversed-client-ID
/// custom scheme, verified by bundle ID in the Google Cloud console). The persisted tokens (access +
/// refresh) live in the Keychain, this device only (`TokenStore`, `Net/DriveTokenStore.swift`); `accessTokenBlocking()` feeds `DriveClient`'s `() -> String` token
/// provider and refreshes transparently.
///
/// The phone must sign in to the **same Google account** as the Mac — `drive.file` is per-project, so
/// an OAuth client in the same GCP project can see/write the folder the Mac created.
///
/// **Setup (one-time, GCP console):** create an **iOS** OAuth client in your own project with
/// bundle ID `com.archiveprocessor.capture.ios`, enable **"Custom URI scheme"** in its Advanced Settings
/// (off by default; Google blocks it otherwise — same gotcha as Android), and put its id in the gitignored
/// `Config/DriveLocal.xcconfig` (`DriveOAuthConfig`). A build without one hides sign-in.
@MainActor
final class DriveAuth: ObservableObject {

    // MARK: - GCP iOS OAuth client

    /// The iOS OAuth client this build carries, or nil when none was configured (`DriveOAuthConfig`).
    nonisolated static let config: DriveOAuthConfig? = .current
    nonisolated static var isConfigured: Bool { config != nil }

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let scope = "https://www.googleapis.com/auth/drive.file"

    // MARK: - Token state

    @Published private(set) var isSignedIn: Bool = false

    /// Thread-safe store so `accessTokenBlocking` (called off the main thread by `DriveClient`) can
    /// read tokens without crossing the `@MainActor` boundary.
    private let tokens = TokenStore()

    /// Held for the life of the sign-in sheet: `ASWebAuthenticationSession` must be retained, and since iOS 13
    /// `start()` fails at once (`presentationContextNotProvided`) without a presentation context.
    private var authSession: ASWebAuthenticationSession?
    private let presentationAnchor = KeyWindowAnchor()

    init() {
        tokens.load()
        isSignedIn = Self.isConfigured && tokens.refreshToken != nil
    }

    // MARK: - Sign in (ASWebAuthenticationSession + PKCE)

    func signIn() async -> (success: Bool, error: String?) {
        guard let config = Self.config else { return (false, DriveOAuthConfig.unconfiguredMessage) }
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.sha256Base64URL(verifier)

        var comps = URLComponents(string: Self.authEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = comps.url else { return (false, "Failed to build auth URL") }

        let scheme = config.redirectScheme

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                // start() returning false may or may not also call the handler; resume exactly once.
                let once = ResumeOnce()
                let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                    guard once.claim() else { return }
                    if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: error ?? DriveAuthError.cancelled) }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = presentationAnchor
                authSession = session
                if !session.start(), once.claim() { cont.resume(throwing: DriveAuthError.couldNotStart) }
            }
            authSession = nil

            guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                return (false, "No authorization code in the redirect")
            }

            return await exchangeCode(code, verifier: verifier, config: config)
        } catch {
            authSession = nil
            if (error as? DriveAuthError) == .couldNotStart { return (false, "Could not open the Google sign-in sheet") }
            if (error as? DriveAuthError) == .cancelled || (error as NSError).code == 1 {
                return (false, "Sign-in was cancelled")
            }
            return (false, error.localizedDescription)
        }
    }

    private func exchangeCode(_ code: String, verifier: String,
                              config: DriveOAuthConfig) async -> (success: Bool, error: String?) {
        let body = [
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        return await tokenRequest(body)
    }

    func refreshAccessToken() async -> Bool {
        guard let config = Self.config, let rt = tokens.refreshToken else { return false }
        let body = [
            "client_id": config.clientID,
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
            if !tokens.persist() { NSLog("DriveAuth: could not save the Drive tokens to the Keychain") }
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
        if !tokens.persist() { NSLog("DriveAuth: could not delete the Drive tokens from the Keychain") }
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
    case couldNotStart
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Presents the sign-in sheet over the app's key window.
private final class KeyWindowAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
            ?? ASPresentationAnchor()
    }
}
