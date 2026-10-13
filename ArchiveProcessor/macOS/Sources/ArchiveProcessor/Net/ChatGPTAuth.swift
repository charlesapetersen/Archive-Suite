import Foundation
import Network
import CryptoKit
import Security

// MARK: - Sign in with ChatGPT (W36.seg-opt-siwc)
//
// OpenAI's sanctioned route for an open-source app that runs locally to use the user's own ChatGPT plan
// (`segbench-results/usage.md`; https://developers.openai.com/siwc/token-sharing-open-source). The app never
// touches the user's `codex` login. OpenAI's devkit is JavaScript, so this is the same protocol written natively:
//
//   1. Authorization code + PKCE (S256) in the user's browser, redirected to `http://127.0.0.1:<port>/callback`.
//      The first sign-in sends `client_id=dynamic_agent_client`; OpenAI issues a client id in the callback, kept
//      for every later refresh and re-sign-in. No client secret exists.
//   2. The ID token is checked before the account counts as signed in: RS256 against the discovery document's
//      JWKS, the issuer, the audience (the issued client id) and the nonce sent.
//   3. Access tokens are refreshed one at a time (refresh tokens rotate, and a reused one is refused).
//   4. Sign-out revokes the refresh token, then forgets the tokens.
//
// Tokens are secrets: they live in the Keychain only and are never logged. The host id is not a secret; it is
// generated once per installation and kept in defaults, so signing in again on this Mac reuses it.

/// A signed-in account. Empty `refreshToken` means the tokens became unusable (a refused refresh or a revoked
/// grant) and the user must sign in again; the issued client id and the identity are kept for that re-sign-in.
struct ChatGPTCredentials: Codable, Equatable, Sendable {
    var email: String?
    var subject: String
    var clientID: String
    var hostID: String
    var idToken: String
    var accessToken: String
    var refreshToken: String
    var accessExpires: Date
    var scopes: [String]

    var isUsable: Bool { !refreshToken.isEmpty }
}

/// Where the credentials live: the Keychain in the app, memory in the headless test (which never touches the
/// Keychain, see `KeychainHelper.isHeadlessTestMode`).
protocol ChatGPTCredentialStore: Sendable {
    func load() -> ChatGPTCredentials?
    @discardableResult func save(_ c: ChatGPTCredentials) -> Bool
    func delete()
}

struct KeychainChatGPTCredentialStore: ChatGPTCredentialStore {
    static let account = "ChatGPTPlanCredentials"

    func load() -> ChatGPTCredentials? {
        KeychainHelper.load(account: Self.account).flatMap { try? JSONDecoder().decode(ChatGPTCredentials.self, from: Data($0.utf8)) }
    }

    func save(_ c: ChatGPTCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(c), let s = String(data: data, encoding: .utf8) else { return false }
        return KeychainHelper.save(account: Self.account, password: s)
    }

    func delete() { KeychainHelper.delete(account: Self.account) }
}

final class MemoryChatGPTCredentialStore: ChatGPTCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ChatGPTCredentials?

    init(_ value: ChatGPTCredentials? = nil) { self.value = value }

    func load() -> ChatGPTCredentials? { lock.withLock { value } }
    @discardableResult func save(_ c: ChatGPTCredentials) -> Bool { lock.withLock { value = c }; return true }
    func delete() { lock.withLock { value = nil } }
}

enum ChatGPTAuthError: Error, Equatable, CustomStringConvertible {
    /// No usable tokens: the user has to sign in (again).
    case signInRequired
    /// The browser came back with something other than our code: a mismatched state, an `error=`, no code.
    case callbackRejected(String)
    /// The ID token failed a check; the account is not signed in.
    case idTokenInvalid(String)
    /// The auth server answered with an error that keeps the tokens (a transient failure, retry later).
    case server(status: Int, message: String)
    case timedOut

    var description: String {
        switch self {
        case .signInRequired: return "Sign in with ChatGPT again."
        case .callbackRejected(let m): return "ChatGPT sign-in was not completed: \(m)"
        case .idTokenInvalid(let m): return "ChatGPT sign-in could not be verified: \(m)"
        case .server(let s, let m): return "ChatGPT sign-in server error \(s): \(m)"
        case .timedOut: return "ChatGPT sign-in timed out; try again."
        }
    }
}

actor ChatGPTAuth {
    typealias HTTP = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let resource = "https://api.openai.com/v1"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let dynamicClientID = "dynamic_agent_client"
    /// Sent as `agent_name_hint` on a first registration; the same on every install.
    static let appName = "Archive Processor"
    /// The "Manage usage" link OpenAI requires beside "Using ChatGPT plan".
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    /// The app's account; nil-safe to read from anywhere (the store is Sendable).
    static let shared = ChatGPTAuth(store: KeychainChatGPTCredentialStore())

    nonisolated let store: any ChatGPTCredentialStore
    /// The defaults suite holding the host id: nil is the app's own (UserDefaults is not Sendable, so the name is
    /// kept rather than the object).
    private let defaultsSuite: String?
    private let http: HTTP
    private let now: @Sendable () -> Date
    /// The one refresh in flight; every caller that needs a fresh token waits on it.
    private var refreshing: Task<ChatGPTCredentials, Error>?
    /// Bumped by sign-out and by "sign in again", so a refresh that was already on the wire cannot write the
    /// account back afterwards.
    private var generation = 0

    init(store: any ChatGPTCredentialStore, defaultsSuite: String? = nil,
         http: @escaping HTTP = { try await NetworkSession.data(for: $0, policy: .nonIdempotent, maxRetries: 0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.defaultsSuite = defaultsSuite
        self.http = http
        self.now = now
    }

    // MARK: State

    /// The signed-in account's email (or "ChatGPT account"), or nil. Reads the Keychain: never from a view body.
    nonisolated func signedInAccount() -> String? {
        guard let c = store.load(), c.isUsable else { return nil }
        return c.email ?? "ChatGPT account"
    }

    nonisolated var isSignedIn: Bool { signedInAccount() != nil }

    /// A registration is saved whose tokens went bad: the next sign-in reuses it, so the user must be able to
    /// forget it to sign in as someone else.
    nonisolated var hasStaleRegistration: Bool { store.load().map { !$0.isUsable } ?? false }

    /// This installation's host id, made once.
    func hostID() -> String {
        let defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let h = defaults.string(forKey: DefaultsKeys.chatGPTHostID), !h.isEmpty { return h }
        let h = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(h, forKey: DefaultsKeys.chatGPTHostID)
        return h
    }

    // MARK: Access tokens

    /// A current access token, refreshed when it is within a minute of expiring.
    func accessToken() async throws -> String {
        guard let c = store.load(), c.isUsable else { throw ChatGPTAuthError.signInRequired }
        if c.accessExpires > now().addingTimeInterval(60), !c.accessToken.isEmpty { return c.accessToken }
        return try await refresh().accessToken
    }

    /// After the API refused `rejected` with a 401: refresh once, unless another caller already has.
    func accessToken(afterRejecting rejected: String) async throws -> String {
        guard let c = store.load(), c.isUsable else { throw ChatGPTAuthError.signInRequired }
        if c.accessToken != rejected, !c.accessToken.isEmpty { return c.accessToken }
        return try await refresh().accessToken
    }

    /// The API said the grant itself is gone (`subscription_sharing_invalid_user`): forget the tokens, keep the
    /// registration for the re-sign-in.
    /// `dropRegistration` also forgets the issued client id, so the next sign-in registers afresh (the auth server
    /// refused the client itself).
    func markSignInRequired(dropRegistration: Bool = false) {
        generation += 1
        guard var c = store.load() else { return }
        c.accessToken = ""; c.refreshToken = ""
        if dropRegistration { c.clientID = "" }
        store.save(c)
    }

    private func refresh() async throws -> ChatGPTCredentials {
        if let t = refreshing { return try await t.value }
        let t = Task { try await performRefresh() }
        refreshing = t
        defer { if refreshing == t { refreshing = nil } }
        return try await t.value
    }

    private func performRefresh() async throws -> ChatGPTCredentials {
        guard var c = store.load(), c.isUsable else { throw ChatGPTAuthError.signInRequired }
        let started = (generation, c.refreshToken)
        let (status, obj) = try await postForm(Self.tokenURL, [
            "grant_type": "refresh_token", "client_id": c.clientID, "refresh_token": c.refreshToken,
            "resource": Self.resource,
        ])
        // Signed out, or told to sign in again, while the request was out: the reply must not revive the account.
        guard !Task.isCancelled, generation == started.0, store.load()?.refreshToken == started.1 else {
            throw ChatGPTAuthError.signInRequired
        }
        guard status == 200, let access = obj["access_token"] as? String, !access.isEmpty else {
            let code = (obj["error"] as? String) ?? ""
            // The four codes OpenAI lists as "clear unusable tokens and repeat OAuth with the saved client id".
            if ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_reused"].contains(code) {
                markSignInRequired()
                throw ChatGPTAuthError.signInRequired
            }
            // A refused client cannot be refreshed or re-signed-in with; start a new registration.
            if ["invalid_client", "unauthorized_client"].contains(code) {
                markSignInRequired(dropRegistration: true)
                throw ChatGPTAuthError.signInRequired
            }
            throw ChatGPTAuthError.server(status: status, message: Self.errorText(obj, status: status))
        }
        c.accessToken = access
        // Rotation: keep only the newest refresh token; a reply without one leaves the old one valid.
        if let r = obj["refresh_token"] as? String, !r.isEmpty { c.refreshToken = r }
        if let id = obj["id_token"] as? String, !id.isEmpty { c.idToken = id }
        c.accessExpires = now().addingTimeInterval(Self.expiresIn(obj))
        store.save(c)
        return c
    }

    // MARK: Sign-in

    /// One attempt's secrets, fresh every time.
    struct Attempt: Sendable {
        let verifier: String
        let state: String
        let nonce: String
        let redirectURI: String
        /// The saved registration being re-signed-in, or nil for a first registration.
        let prior: ChatGPTCredentials?

        var challenge: String { ChatGPTAuth.b64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    }

    func makeAttempt(port: UInt16) -> Attempt {
        // Re-sign-in reuses the issued client id only for a registration whose tokens went bad; after a sign-out
        // the registration is gone and the next sign-in is a new one (it may be a different account).
        let prior = store.load().flatMap { $0.clientID.isEmpty ? nil : $0 }
        return Attempt(verifier: Self.b64url(Self.randomBytes(48)), state: Self.b64url(Self.randomBytes(24)),
                       nonce: Self.b64url(Self.randomBytes(24)), redirectURI: "http://127.0.0.1:\(port)/callback",
                       prior: prior)
    }

    /// The browser URL for an attempt.
    func authorizeURL(_ a: Attempt) -> URL {
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: a.prior?.clientID ?? Self.dynamicClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: a.redirectURI),
            .init(name: "scope", value: Self.scope),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: a.state),
            .init(name: "nonce", value: a.nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: a.challenge),
            .init(name: "ext_agent_host_id", value: a.prior?.hostID ?? hostID()),
        ]
        if let p = a.prior {
            if !p.idToken.isEmpty { items.append(.init(name: "id_token_hint", value: p.idToken)) }
            if let e = p.email { items.append(.init(name: "login_hint", value: e)) }
        } else {
            items.append(.init(name: "agent_name_hint", value: Self.appName))
        }
        var comps = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        // URLComponents leaves `+` and `@` bare in a query; encode them so a scope or an email reads as sent.
        comps.percentEncodedQuery = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").replacingOccurrences(of: "@", with: "%40")
        return comps.url!
    }

    /// The interactive sign-in: listens on loopback, hands the authorize URL to `open` (the browser in the app),
    /// and completes on the callback. Gives up after `timeout`.
    func signIn(open: @escaping @Sendable (URL) -> Void, timeout: Duration = .seconds(600)) async throws -> ChatGPTCredentials {
        let listener = LoopbackCallbackListener()
        let port = try await listener.start()
        defer { listener.stop() }
        let attempt = makeAttempt(port: port)
        listener.expectedState = attempt.state
        open(authorizeURL(attempt))
        let query = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await listener.callback() }
            group.addTask { try await Task.sleep(for: timeout); throw ChatGPTAuthError.timedOut }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return try await complete(attempt, query: query)
    }

    /// The callback's half, separate so the test can drive it with any query.
    func complete(_ a: Attempt, query: [String: String]) async throws -> ChatGPTCredentials {
        // The state is checked before anything else: a forged callback never reaches the token endpoint.
        guard query["state"] == a.state else { throw ChatGPTAuthError.callbackRejected("state mismatch") }
        if let e = query["error"] {
            throw ChatGPTAuthError.callbackRejected(query["error_description"].map { "\(e): \($0)" } ?? e)
        }
        guard let code = query["code"], !code.isEmpty else { throw ChatGPTAuthError.callbackRejected("no code") }
        guard let clientID = query["client_id"].flatMap({ $0.isEmpty ? nil : $0 }) ?? a.prior?.clientID else {
            throw ChatGPTAuthError.callbackRejected("no client id issued")
        }

        let (status, obj) = try await postForm(Self.tokenURL, [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "code_verifier": a.verifier, "redirect_uri": a.redirectURI, "resource": Self.resource,
        ])
        guard status == 200, let access = obj["access_token"] as? String, !access.isEmpty,
              let refresh = obj["refresh_token"] as? String, !refresh.isEmpty,
              let idToken = obj["id_token"] as? String else {
            throw ChatGPTAuthError.server(status: status, message: Self.errorText(obj, status: status))
        }
        let discovery = try await getJSON(Self.discoveryURL)
        guard let issuer = discovery["issuer"] as? String,
              let jwksURL = (discovery["jwks_uri"] as? String).flatMap(URL.init(string:)) else {
            throw ChatGPTAuthError.idTokenInvalid("the discovery document has no issuer or jwks_uri")
        }
        let jwks = try await getJSON(jwksURL)
        let claims = try IDToken.verify(idToken, keys: jwks["keys"] as? [[String: Any]] ?? [], issuer: issuer,
                                        clientID: clientID, nonce: a.nonce, now: now())
        if let p = a.prior, p.subject != claims.subject, !p.subject.isEmpty {
            // Another account answered a re-sign-in of this registration. Its grant is revoked and the old
            // registration forgotten, so the next attempt registers that account afresh.
            await revoke(refresh, clientID: clientID)
            generation += 1
            store.delete()
            throw ChatGPTAuthError.idTokenInvalid("a different ChatGPT account signed in; sign in again to use it")
        }
        let scopes = ((obj["scope"] as? String) ?? query["scope"] ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
        let c = ChatGPTCredentials(email: claims.email, subject: claims.subject, clientID: clientID,
                                   hostID: a.prior?.hostID ?? hostID(), idToken: idToken, accessToken: access,
                                   refreshToken: refresh, accessExpires: now().addingTimeInterval(Self.expiresIn(obj)),
                                   scopes: scopes)
        guard store.save(c) else {
            throw ChatGPTAuthError.server(status: 0, message: "the Keychain refused to save the sign-in")
        }
        return c
    }

    // MARK: Sign-out

    /// Revokes the refresh token, then forgets the account whatever the server said (the user asked to sign out).
    /// Returns whether the server confirmed the revocation.
    @discardableResult
    func signOut() async -> Bool {
        refreshing?.cancel()
        refreshing = nil
        generation += 1
        defer { store.delete() }
        guard let c = store.load(), c.isUsable else { return false }
        return await revoke(c.refreshToken, clientID: c.clientID)
    }

    @discardableResult
    private func revoke(_ refreshToken: String, clientID: String) async -> Bool {
        do {
            let discovery = try await getJSON(Self.discoveryURL)
            guard let url = (discovery["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else { return false }
            let (status, _) = try await postForm(url, ["token": refreshToken, "token_type_hint": "refresh_token",
                                                       "client_id": clientID])
            return status == 200
        } catch {
            return false
        }
    }

    // MARK: HTTP

    private func postForm(_ url: URL, _ form: [String: String]) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(Self.formEncode(form).utf8)
        let (data, response) = try await http(r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http(r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ChatGPTAuthError.server(status: status, message: "GET \(url.path) failed")
        }
        return obj
    }

    private static func expiresIn(_ obj: [String: Any]) -> TimeInterval {
        (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
    }

    private static func errorText(_ obj: [String: Any], status: Int) -> String {
        let code = (obj["error"] as? String) ?? ((obj["error"] as? [String: Any])?["code"] as? String) ?? "HTTP \(status)"
        let detail = (obj["error_description"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String)
        return detail.map { "\(code): \($0)" } ?? code
    }

    static func formEncode(_ d: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return d.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let ok = SecRandomCopyBytes(kSecRandomDefault, n, &bytes) == errSecSuccess
        precondition(ok, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func b64urlDecode(_ s: Substring) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

// MARK: - The ID token

enum IDToken {
    struct Claims: Equatable, Sendable {
        let subject: String
        let email: String?
    }

    /// Checks an RS256 ID token against the JWKS keys, then its issuer, audience, nonce and expiry.
    static func verify(_ jwt: String, keys: [[String: Any]], issuer: String, clientID: String, nonce: String,
                       now: Date) throws -> Claims {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = ChatGPTAuth.b64urlDecode(parts[0]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claimData = ChatGPTAuth.b64urlDecode(parts[1]),
              let claims = (try? JSONSerialization.jsonObject(with: claimData)) as? [String: Any],
              let signature = ChatGPTAuth.b64urlDecode(parts[2]) else {
            throw ChatGPTAuthError.idTokenInvalid("malformed token")
        }
        guard header["alg"] as? String == "RS256" else {
            throw ChatGPTAuthError.idTokenInvalid("unsupported alg \(header["alg"] ?? "none")")
        }
        let kid = header["kid"] as? String
        let rsa = keys.filter { $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" }
        guard let jwk = kid.flatMap({ k in rsa.first { $0["kid"] as? String == k } }) ?? (rsa.count == 1 ? rsa.first : nil),
              let n = (jwk["n"] as? String).flatMap({ ChatGPTAuth.b64urlDecode(Substring($0)) }),
              let e = (jwk["e"] as? String).flatMap({ ChatGPTAuth.b64urlDecode(Substring($0)) }),
              let key = publicKey(modulus: n, exponent: e) else {
            throw ChatGPTAuthError.idTokenInvalid("no signing key matches the token")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signingInput as CFData,
                                    signature as CFData, nil) else {
            throw ChatGPTAuthError.idTokenInvalid("bad signature")
        }
        guard claims["iss"] as? String == issuer else { throw ChatGPTAuthError.idTokenInvalid("wrong issuer") }
        let aud = (claims["aud"] as? [String]) ?? [(claims["aud"] as? String)].compactMap { $0 }
        guard aud.contains(clientID) else { throw ChatGPTAuthError.idTokenInvalid("wrong audience") }
        guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthError.idTokenInvalid("wrong nonce") }
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue,
              Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60) else {
            throw ChatGPTAuthError.idTokenInvalid("expired")
        }
        guard let sub = claims["sub"] as? String, !sub.isEmpty else { throw ChatGPTAuthError.idTokenInvalid("no subject") }
        return Claims(subject: sub, email: claims["email"] as? String)
    }

    /// An RSA public key from a JWK's modulus and exponent, as the PKCS#1 `RSAPublicKey` DER the Security
    /// framework takes.
    static func publicKey(modulus: Data, exponent: Data) -> SecKey? {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(pkcs1DER(modulus: modulus, exponent: exponent) as CFData, attrs as CFDictionary, nil)
    }

    static func pkcs1DER(modulus: Data, exponent: Data) -> Data {
        func integer(_ d: Data) -> Data {
            var bytes = [UInt8](d.drop { $0 == 0 })
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }   // stay positive
            return Data([0x02]) + length(bytes.count) + Data(bytes)
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }

    private static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

// MARK: - The loopback callback

/// Listens on 127.0.0.1 only (never all interfaces) for the one `GET /callback?…` the browser is redirected to.
/// Any other path gets a 404 and is ignored; the first callback ends the wait.
final class LoopbackCallbackListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var _expectedState: String?

    /// When set, a callback carrying any other state is answered and ignored, so a stray local request cannot end
    /// the attempt before the real redirect arrives.
    var expectedState: String? {
        get { lock.withLock { _expectedState } }
        set { lock.withLock { _expectedState = newValue } }
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        lock.withLock { listener = l }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        let port = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if once.take() { c.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.take() { c.resume(throwing: e) }
                    self?.deliver(.failure(e))   // a listener that dies while waiting ends the wait
                case .cancelled: if once.take() { c.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: .global())
        }
        guard port != 0 else { stop(); throw ChatGPTAuthError.callbackRejected("no loopback port") }
        return port
    }

    /// The callback's query, once it arrives.
    func callback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                let ready: Result<[String: String], Error>? = lock.withLock {
                    if let result { return result }
                    waiter = c
                    return nil
                }
                if let ready { c.resume(with: ready) }
            }
        } onCancel: {
            deliver(.failure(CancellationError()))
        }
    }

    func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
        deliver(.failure(CancellationError()))
    }

    private func deliver(_ r: Result<[String: String], Error>) {
        let w: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard result == nil else { return nil }
            result = r
            defer { waiter = nil }
            return waiter
        }
        w?.resume(with: r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first
            let target = line?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let comps = URLComponents(string: "http://127.0.0.1\(target)")
            guard line?.hasPrefix("GET ") == true, comps?.path == "/callback" else {
                Self.reply(conn, status: "404 Not Found", body: "Not found.")
                return
            }
            var query: [String: String] = [:]
            for item in comps?.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
            if let expected = self.expectedState, query["state"] != expected {
                Self.reply(conn, status: "400 Bad Request", body: "This sign-in link is not the one Archive Processor is waiting for.")
                return
            }
            let ok = query["code"] != nil && query["error"] == nil
            Self.reply(conn, status: "200 OK", body: ok
                ? "Signed in with ChatGPT. You can close this tab and return to Archive Processor."
                : "ChatGPT sign-in did not complete. You can close this tab and try again in Archive Processor.")
            self.deliver(.success(query))
        }
    }

    private static func reply(_ conn: NWConnection, status: String, body: String) {
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
}
