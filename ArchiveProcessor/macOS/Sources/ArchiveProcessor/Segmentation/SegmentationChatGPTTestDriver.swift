import Foundation
import CryptoKit
import Security

/// Headless, $0 self-test of ChatGPT by Sign in with ChatGPT (W36.seg-opt-siwc), gated by
/// `SEGMENTATION_CHATGPT_TEST=1` (does nothing in normal use). No OpenAI server is reached: every request goes to an
/// in-process fake of the auth server and the Responses API, the ID tokens are signed by a key made for the run, and
/// the credentials are kept in memory (the Keychain is never touched). The one real socket is the loopback callback
/// listener, driven by a GET from this process. Run by `scripts/test-segmentation-chatgpt.sh`.
///
/// What has to be true:
///   1. The authorize URL carries OpenAI's parameters exactly (scope, resource, loopback `/callback`, S256 PKCE,
///      `dynamic_agent_client` + `agent_name_hint` first; the issued client id + hints on a re-sign-in), fresh
///      secrets per attempt, and one host id per installation.
///   2. The ID token is refused unless its RS256 signature, issuer, audience, nonce and expiry all hold.
///   3. The whole sign-in, through the real loopback listener: a stray request is ignored, the issued client id is
///      kept, and a forged state or an `error=` never reaches the token endpoint and saves nothing.
///   4. Refresh: one at a time however many callers, rotation keeps the newest token, a refused refresh clears the
///      tokens but keeps the registration, a server error keeps them.
///   5. The window request and the stream: `store: false`, `stream: true`, the images inline, the bench's reasoning
///      level; only a completed response is an answer; OpenAI's error codes map to stop, fail or retry.
///   6. A 401 refreshes once and resends; a second, or a revoked grant, asks for sign-in again.
///   7. Routes and the chooser: the plan route is used without a key or when chosen; the row says "Using ChatGPT
///      plan" with the token figure and its approximate price, and adds no dollars to the run.
///   8. Sign-out revokes the refresh token and forgets the account even when revocation fails.
@MainActor
enum SegmentationChatGPTTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENTATION_CHATGPT_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    private static var outPath: String {
        ProcessInfo.processInfo.environment["SEGMENTATION_CHATGPT_TEST_OUT"] ?? "/tmp/segmentation-chatgpt-test.txt"
    }

    private static func section(_ name: String) {
        lines.append("-- \(name)")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: outPath + ".partial", atomically: true, encoding: .utf8)
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    nonisolated static let day = Date(timeIntervalSince1970: 1_791_720_000)   // 11 Oct 2026, midday UTC

    static func run() async {
        defer { finish() }
        guard let signer = TestSigner() else { check("an RSA test key could be made", false); return }
        section("1 authorize URL"); await authorizeURL()
        section("2 ID token"); idToken(signer)
        section("3 sign-in"); await signIn(signer)
        section("4 refresh"); await refresh()
        section("5 request and stream"); await stream()
        section("6 401"); await unauthorized()
        section("7 routes and chooser"); routesAndChooser()
        section("8 sign-out"); await signOut()
    }

    // MARK: Fixtures

    /// A fresh scratch defaults suite, never the app's own.
    private static func defaults() -> String {
        let name = "ap-chatgpt-test-\(UUID().uuidString)"
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        return name
    }

    private static func creds(access: String = "a1", refresh: String = "r1", expires: Date = day.addingTimeInterval(3600))
        -> ChatGPTCredentials {
        ChatGPTCredentials(email: "user@example.com", subject: "sub-1", clientID: "oaiapp_test", hostID: "urn:uuid:h1",
                           idToken: "id.old.token", accessToken: access, refreshToken: refresh, accessExpires: expires,
                           scopes: ["chatgpt.tokens.use.direct"])
    }

    nonisolated private static func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { a, _ in a })
    }

    private static func form(_ r: URLRequest) -> [String: String] {
        var c = URLComponents()
        c.percentEncodedQuery = String(data: r.httpBody ?? Data(), encoding: .utf8)
        return Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: 1

    private static func authorizeURL() async {
        let d = defaults()
        let store = MemoryChatGPTCredentialStore()
        let auth = ChatGPTAuth(store: store, defaultsSuite: d, http: FakeOpenAI(signer: nil).http)
        let a = await auth.makeAttempt(port: 54321)
        let q = query(await auth.authorizeURL(a))
        eq("1 client_id is dynamic on a first sign-in", q["client_id"], "dynamic_agent_client")
        eq("1 response_type", q["response_type"], "code")
        eq("1 redirect is loopback /callback", q["redirect_uri"], "http://127.0.0.1:54321/callback")
        eq("1 scope exactly", q["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        eq("1 resource", q["resource"], "https://api.openai.com/v1")
        eq("1 S256", q["code_challenge_method"], "S256")
        eq("1 challenge is SHA-256 of the verifier", q["code_challenge"],
           ChatGPTAuth.b64url(Data(SHA256.hash(data: Data(a.verifier.utf8)))))
        eq("1 state and nonce sent", [q["state"], q["nonce"]], [a.state, a.nonce])
        eq("1 agent_name_hint on a first registration", q["agent_name_hint"], "Archive Processor")
        check("1 host id is a urn:uuid", q["ext_agent_host_id"]?.hasPrefix("urn:uuid:") == true, "\(q)")
        check("1 no hints on a first sign-in", q["login_hint"] == nil && q["id_token_hint"] == nil)
        let b = await auth.makeAttempt(port: 54321)
        let q2 = query(await auth.authorizeURL(b))
        eq("1 the host id is kept", q2["ext_agent_host_id"], q["ext_agent_host_id"])
        check("1 fresh secrets each attempt", a.state != b.state && a.nonce != b.nonce && a.verifier != b.verifier)
        check("1 the verifier is 43-128 characters", (43...128).contains(a.verifier.count), "\(a.verifier.count)")

        // A registration whose tokens went bad signs in again with its issued client id.
        var stale = creds(); stale.accessToken = ""; stale.refreshToken = ""
        store.save(stale)
        let c = await auth.makeAttempt(port: 1)
        let q3 = query(await auth.authorizeURL(c))
        eq("1 re-sign-in uses the issued client id", q3["client_id"], "oaiapp_test")
        eq("1 re-sign-in keeps its host id", q3["ext_agent_host_id"], "urn:uuid:h1")
        eq("1 re-sign-in hints", [q3["login_hint"], q3["id_token_hint"]], ["user@example.com", "id.old.token"])
        eq("1 no agent_name_hint on re-sign-in", q3["agent_name_hint"], nil)
        check("1 the email's @ is encoded", (await auth.authorizeURL(c)).absoluteString.contains("user%40example.com"))
    }

    // MARK: 2

    private static func idToken(_ s: TestSigner) {
        let iss = "https://auth.openai.com"
        let good: [String: Any] = ["iss": iss, "aud": "oaiapp_test", "nonce": "n1", "sub": "sub-1",
                                   "email": "user@example.com", "exp": day.timeIntervalSince1970 + 600]
        func verify(_ jwt: String, keys: [[String: Any]]? = nil) -> Result<IDToken.Claims, Error> {
            Result { try IDToken.verify(jwt, keys: keys ?? [s.jwk], issuer: iss, clientID: "oaiapp_test", nonce: "n1", now: day) }
        }
        eq("2 a good token verifies", try? verify(s.sign(good)).get(), IDToken.Claims(subject: "sub-1", email: "user@example.com"))
        var arr = good; arr["aud"] = ["other", "oaiapp_test"]
        check("2 an audience list containing the client verifies", (try? verify(s.sign(arr)).get()) != nil)
        func refused(_ name: String, _ jwt: String, keys: [[String: Any]]? = nil) {
            if case .failure(let e) = verify(jwt, keys: keys), case ChatGPTAuthError.idTokenInvalid = e {
                check("2 refused: \(name)", true)
            } else { check("2 refused: \(name)", false, "it verified") }
        }
        var bad = good; bad["nonce"] = "n2"; refused("wrong nonce", s.sign(bad))
        bad = good; bad["aud"] = "oaiapp_other"; refused("wrong audience", s.sign(bad))
        bad = good; bad["iss"] = "https://evil.example"; refused("wrong issuer", s.sign(bad))
        bad = good; bad["exp"] = day.timeIntervalSince1970 - 3600; refused("expired", s.sign(bad))
        bad = good; bad.removeValue(forKey: "sub"); refused("no subject", s.sign(bad))
        refused("alg none", s.sign(good, header: ["alg": "none", "kid": s.kid]))
        refused("unknown kid", s.sign(good, header: ["alg": "RS256", "kid": "other"]),
                keys: [s.jwk, { var k = s.jwk; k["kid"] = "k2"; return k }()])
        let parts = s.sign(good).split(separator: ".").map(String.init)
        var tampered = good; tampered["sub"] = "sub-2"
        let forged = parts[0] + "." + ChatGPTAuth.b64url(try! JSONSerialization.data(withJSONObject: tampered)) + "." + parts[2]
        refused("a payload changed after signing", forged)
        if let other = TestSigner() { refused("signed by another key", other.sign(good)) }
        refused("malformed", "abc.def")
        eq("2 the JWK's DER is the Security framework's own", IDToken.pkcs1DER(modulus: s.n, exponent: s.e), s.der)
        eq("2 a leading zero byte is not doubled", IDToken.pkcs1DER(modulus: Data([0, 0x7f]), exponent: Data([1, 0, 1])),
           Data([0x30, 0x08, 0x02, 0x01, 0x7f, 0x02, 0x03, 1, 0, 1]))
    }

    // MARK: 3

    private static func signIn(_ s: TestSigner) async {
        let fake = FakeOpenAI(signer: s)
        let store = MemoryChatGPTCredentialStore()
        let auth = ChatGPTAuth(store: store, defaultsSuite: defaults(), http: fake.http, now: { day })
        do {
            let c = try await auth.signIn(open: { url in
                let q = query(url)
                fake.nonce = q["nonce"] ?? ""
                Task.detached {
                    // A stray request first (a browser asks for a favicon): it must not end the wait.
                    _ = try? await URLSession.shared.data(from: URL(string: q["redirect_uri"]!.replacingOccurrences(of: "/callback", with: "/favicon.ico"))!)
                    // And a callback with another state (a stray local request): ignored, not the end of the attempt.
                    var stray = URLComponents(string: q["redirect_uri"]!)!
                    stray.queryItems = [.init(name: "code", value: "evil"), .init(name: "state", value: "forged")]
                    _ = try? await URLSession.shared.data(from: stray.url!)
                    var cb = URLComponents(string: q["redirect_uri"]!)!
                    cb.queryItems = [.init(name: "code", value: "code-1"), .init(name: "state", value: q["state"]),
                                     .init(name: "scope", value: "chatgpt.tokens.use.direct openid"),
                                     .init(name: "client_id", value: "oaiapp_issued")]
                    _ = try? await URLSession.shared.data(from: cb.url!)
                }
            }, timeout: .seconds(20))
            check("3 a stray callback did not end the wait", fake.requests(path: "/api/accounts/oauth/token")
                .allSatisfy { form($0)["code"] == "code-1" })
            eq("3 signed in as the token's subject", [c.subject, c.email], ["sub-1", "user@example.com"])
            eq("3 the issued client id is kept", c.clientID, "oaiapp_issued")
            eq("3 the tokens are saved", [store.load()?.accessToken, store.load()?.refreshToken], ["at-1", "rt-1"])
            eq("3 the account reads as signed in", auth.signedInAccount(), "user@example.com")
            let ex = fake.requests(path: "/api/accounts/oauth/token").first.map(form) ?? [:]
            eq("3 code exchange form", [ex["grant_type"], ex["code"], ex["client_id"], ex["resource"]],
               ["authorization_code", "code-1", "oaiapp_issued", "https://api.openai.com/v1"])
            check("3 the exchange sends the verifier and the same redirect",
                  (ex["code_verifier"]?.count ?? 0) >= 43 && ex["redirect_uri"]?.hasSuffix("/callback") == true, "\(ex)")
            check("3 the exchange sends no client secret", ex["client_secret"] == nil)
        } catch {
            check("3 sign-in through the loopback listener", false, "\(error)")
        }

        // The callback half alone: a forged state, an error, and a token that fails its check.
        let fake2 = FakeOpenAI(signer: s)
        let store2 = MemoryChatGPTCredentialStore()
        let auth2 = ChatGPTAuth(store: store2, defaultsSuite: defaults(), http: fake2.http, now: { day })
        let a = await auth2.makeAttempt(port: 9)
        fake2.nonce = a.nonce
        func rejected(_ name: String, _ q: [String: String]) async {
            do { _ = try await auth2.complete(a, query: q); check("3 \(name)", false, "accepted") } catch {
                check("3 \(name)", store2.load() == nil, "saved \(String(describing: store2.load()))")
            }
        }
        await rejected("forged state saves nothing", ["state": "forged", "code": "c", "client_id": "oaiapp_x"])
        await rejected("error= saves nothing", ["state": a.state, "error": "access_denied"])
        eq("3 neither reached the token endpoint", fake2.requests(path: "/api/accounts/oauth/token").count, 0)
        fake2.nonce = "someone-else's"
        await rejected("a token with another nonce saves nothing", ["state": a.state, "code": "c", "client_id": "oaiapp_x"])

        // A stale registration re-signed-in by another account: that grant is revoked and the registration
        // forgotten, so the next sign-in starts a new one.
        let fake3 = FakeOpenAI(signer: s)
        var stale = creds(); stale.accessToken = ""; stale.refreshToken = ""; stale.subject = "sub-OLD"
        let store3 = MemoryChatGPTCredentialStore(stale)
        let auth3 = ChatGPTAuth(store: store3, defaultsSuite: defaults(), http: fake3.http, now: { day })
        check("3 a stale registration is offered to forget", auth3.hasStaleRegistration && auth3.signedInAccount() == nil)
        let b = await auth3.makeAttempt(port: 9)
        fake3.nonce = b.nonce
        do { _ = try await auth3.complete(b, query: ["state": b.state, "code": "c"]); check("3 another account refused", false) } catch {
            check("3 another account refused", store3.load() == nil, "\(error)")
        }
        eq("3 its new grant is revoked", fake3.requests(path: "/api/accounts/oauth/revoke").map { form($0)["token"] ?? "" }, ["rt-1"])
        eq("3 the next attempt registers afresh", query(await auth3.authorizeURL(await auth3.makeAttempt(port: 9)))["client_id"],
           "dynamic_agent_client")
    }

    // MARK: 4

    private static func refresh() async {
        let fake = FakeOpenAI(signer: nil)
        fake.refreshDelay = 0.2
        let store = MemoryChatGPTCredentialStore(creds(expires: day.addingTimeInterval(-10)))
        let auth = ChatGPTAuth(store: store, defaultsSuite: defaults(), http: fake.http, now: { day })
        let tokens = await withTaskGroup(of: String?.self) { g in
            for _ in 0..<5 { g.addTask { try? await auth.accessToken() } }
            var out: [String?] = []
            for await t in g { out.append(t) }
            return out
        }
        eq("4 five callers get the new token", Set(tokens), Set(["at-2"]))
        eq("4 one refresh for all of them", fake.requests(path: "/api/accounts/oauth/token").count, 1)
        let f = fake.requests(path: "/api/accounts/oauth/token").first.map(form) ?? [:]
        eq("4 refresh form", [f["grant_type"], f["client_id"], f["refresh_token"], f["resource"]],
           ["refresh_token", "oaiapp_test", "r1", "https://api.openai.com/v1"])
        check("4 refresh sends no scope", f["scope"] == nil)
        eq("4 the rotated refresh token is kept", store.load()?.refreshToken, "rt-2")
        eq("4 a fresh token is not refreshed again", try? await auth.accessToken(), "at-2")
        eq("4 still one refresh", fake.requests(path: "/api/accounts/oauth/token").count, 1)

        fake.refreshReply = (400, ["error": "invalid_grant"])
        do { _ = try await auth.accessToken(afterRejecting: "at-2"); check("4 invalid_grant asks for sign-in", false) } catch {
            check("4 invalid_grant asks for sign-in", (error as? ChatGPTAuthError) == .signInRequired, "\(error)")
        }
        eq("4 the tokens are cleared", [store.load()?.accessToken, store.load()?.refreshToken], ["", ""])
        eq("4 the registration is kept", store.load()?.clientID, "oaiapp_test")
        eq("4 not signed in", auth.signedInAccount(), nil)

        let fake2 = FakeOpenAI(signer: nil)
        fake2.refreshReply = (500, ["error": "server_error"])
        let store2 = MemoryChatGPTCredentialStore(creds(expires: day.addingTimeInterval(-10)))
        let auth2 = ChatGPTAuth(store: store2, defaultsSuite: defaults(), http: fake2.http, now: { day })
        do { _ = try await auth2.accessToken(); check("4 a server error is reported", false) } catch {
            check("4 a server error is reported", { if case .server = error as? ChatGPTAuthError { return true }; return false }(), "\(error)")
        }
        eq("4 a server error keeps the tokens", store2.load()?.refreshToken, "r1")

        let slow = FakeOpenAI(signer: nil)
        slow.refreshDelay = 0.5
        let store3 = MemoryChatGPTCredentialStore(creds(expires: day.addingTimeInterval(-10)))
        let auth3 = ChatGPTAuth(store: store3, defaultsSuite: defaults(), http: slow.http, now: { day })
        async let pending = try? auth3.accessToken()
        try? await Task.sleep(for: .seconds(0.1))
        await auth3.signOut()
        let late = await pending
        check("4 a refresh that lands after sign-out does not sign back in", late == nil && store3.load() == nil,
              "\(String(describing: late)) \(String(describing: store3.load()))")

        let refused = FakeOpenAI(signer: nil)
        refused.refreshReply = (401, ["error": "invalid_client"])
        let store4 = MemoryChatGPTCredentialStore(creds(expires: day.addingTimeInterval(-10)))
        let auth4 = ChatGPTAuth(store: store4, defaultsSuite: defaults(), http: refused.http, now: { day })
        _ = try? await auth4.accessToken()
        eq("4 a refused client drops the registration", [store4.load()?.clientID, store4.load()?.refreshToken], ["", ""])
        eq("4 so the next sign-in registers afresh", query(await auth4.authorizeURL(await auth4.makeAttempt(port: 9)))["client_id"],
           "dynamic_agent_client")
    }

    // MARK: 5

    private static let voter = WindowVoter.catalog.first { $0.provider == .openai }!
    private static let window = WindowRequest(voter: voter, prompt: "PROMPT", images: [Data([1, 2]), Data([3])],
                                              pageNumbers: [4, 5])

    static func sse(_ events: [[String: Any]]) -> Data {
        Data(events.map { ev in
            "event: \(ev["type"] as? String ?? "")\ndata: \(String(data: try! JSONSerialization.data(withJSONObject: ev), encoding: .utf8)!)\n\n"
        }.joined().utf8)
    }

    static func completed(_ text: String?) -> [String: Any] {
        var resp: [String: Any] = ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 5]]
        resp["output"] = text.map { [["type": "reasoning"], ["type": "message", "content": [["type": "output_text", "text": $0]]]] } ?? []
        return ["type": "response.completed", "response": resp]
    }

    private static func send(_ fake: FakeOpenAI, store: MemoryChatGPTCredentialStore? = nil)
        async -> Result<String, Error> {
        let auth = ChatGPTAuth(store: store ?? MemoryChatGPTCredentialStore(creds()), defaultsSuite: defaults(),
                               http: fake.http, now: { day })
        let t = ChatGPTPlanWindowTransport(auth: auth, http: fake.http)
        do { return .success(try await t.send(window)) } catch { return .failure(error) }
    }

    private static func kind(_ r: Result<String, Error>) -> String {
        switch r {
        case .success(let s): return "ok:\(s)"
        case .failure(WindowTransportError.usageLimit): return "usageLimit"
        case .failure(WindowTransportError.fatal): return "fatal"
        case .failure(WindowTransportError.failed): return "failed"
        case .failure(let e): return "other:\(e)"
        }
    }

    private static func stream() async {
        let fake = FakeOpenAI(signer: nil)
        fake.responses = [(200, sse([["type": "response.created"],
                                     ["type": "response.output_text.delta", "delta": "AN"],
                                     ["type": "response.output_text.delta", "delta": "SWER"],
                                     completed("ANSWER")]), [:])]
        eq("5 a completed stream answers", kind(await send(fake)), "ok:ANSWER")
        guard let req = fake.requests(path: "/v1/responses").first,
              let body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] else {
            check("5 the request was sent", false); return
        }
        eq("5 bearer token", req.value(forHTTPHeaderField: "Authorization"), "Bearer a1")
        eq("5 store false, stream true", [body["store"] as? Bool, body["stream"] as? Bool], [false, true])
        eq("5 the voter's model", body["model"] as? String, "gpt-6.1-sol")
        eq("5 the bench's reasoning level", (body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let content = ((body["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        eq("5 labels, images, then the prompt", content.map { $0["type"] as? String ?? "" },
           ["input_text", "input_image", "input_text", "input_image", "input_text"])
        eq("5 page labels", [content.first?["text"] as? String, content[safe: 2]?["text"] as? String], ["Page 4:", "Page 5:"])
        eq("5 the image inline", content[safe: 1]?["image_url"] as? String, "data:image/jpeg;base64,AQI=")
        eq("5 the prompt last", content.last?["text"] as? String, "PROMPT")
        check("5 no output-token cap sent", body["max_output_tokens"] == nil)

        func one(_ status: Int, _ data: Data, _ headers: [String: String] = [:]) async -> String {
            let f = FakeOpenAI(signer: nil); f.responses = [(status, data, headers)]
            return kind(await send(f))
        }
        func errorBody(_ code: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": "m"]])
        }
        eq("5 deltas when the completed event carries no text",
           await one(200, sse([["type": "response.output_text.delta", "delta": "D"], completed(nil)])), "ok:D")
        eq("5 no completed event is no answer",
           await one(200, sse([["type": "response.output_text.delta", "delta": "D"]])), "failed")
        eq("5 an empty answer fails", await one(200, sse([completed("  ")])), "failed")
        eq("5 a usage limit in the stream stops the run", await one(200, sse([["type": "response.failed", "response":
            ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "m"]]]])), "usageLimit")
        eq("5 a usage limit before the stream stops the run",
           await one(429, errorBody("subscription_sharing_usage_limit_exceeded"), ["Retry-After": "120"]), "usageLimit")
        do {
            let f = FakeOpenAI(signer: nil)
            f.responses = [(429, errorBody("subscription_sharing_usage_limit_exceeded"), ["Retry-After": "120"])]
            if case .failure(WindowTransportError.usageLimit(let reset, let message)) = await send(f) {
                check("5 the usage limit says when and links Manage usage",
                      reset.map { abs($0.timeIntervalSinceNow - 120) < 30 } == true
                      && message.contains("https://chatgpt.com/settings/usage"), "\(String(describing: reset)) \(message)")
            } else { check("5 the usage limit says when and links Manage usage", false) }
        }
        eq("5 another 429 is left to the engine's retry", await one(429, errorBody("rate_limit_exceeded")), "failed")
        eq("5 temporarily unavailable stops resumably", await one(503, errorBody("subscription_sharing_usage_unavailable")), "usageLimit")
        eq("5 not eligible stops", await one(403, errorBody("subscription_sharing_user_not_eligible")), "fatal")
        eq("5 an unsupported input stops", await one(400, errorBody("subscription_sharing_unsupported_capability")), "fatal")
        eq("5 a 500 is retried", await one(500, Data("oops".utf8)), "failed")
        let none = FakeOpenAI(signer: nil)
        eq("5 not signed in stops and asks for sign-in",
           kind(await send(none, store: MemoryChatGPTCredentialStore())), "fatal")
        eq("5 not signed in sends nothing", none.requests(path: "/v1/responses").count, 0)
    }

    // MARK: 6

    private static func unauthorized() async {
        let unauthorizedBody = try! JSONSerialization.data(withJSONObject: ["error": ["code": "invalid_token", "message": "m"]])
        let fake = FakeOpenAI(signer: nil)
        fake.responses = [(401, unauthorizedBody, [:]), (200, sse([completed("OK")]), [:])]
        let store = MemoryChatGPTCredentialStore(creds())
        eq("6 a 401 refreshes and resends", kind(await send(fake, store: store)), "ok:OK")
        eq("6 one refresh", fake.requests(path: "/api/accounts/oauth/token").count, 1)
        eq("6 the resend carries the new token",
           fake.requests(path: "/v1/responses").map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
           ["Bearer a1", "Bearer at-2"])

        let twice = FakeOpenAI(signer: nil)
        twice.responses = [(401, unauthorizedBody, [:]), (401, unauthorizedBody, [:])]
        let store2 = MemoryChatGPTCredentialStore(creds())
        eq("6 a second 401 stops", kind(await send(twice, store: store2)), "fatal")
        eq("6 but keeps the freshly refreshed tokens", store2.load()?.refreshToken, "rt-2")

        let revoked = FakeOpenAI(signer: nil)
        revoked.responses = [(401, try! JSONSerialization.data(withJSONObject:
            ["error": ["code": "subscription_sharing_invalid_user", "message": "m"]]), [:])]
        let store3 = MemoryChatGPTCredentialStore(creds())
        eq("6 a revoked grant asks for sign-in", kind(await send(revoked, store: store3)), "fatal")
        eq("6 without trying a refresh", revoked.requests(path: "/api/accounts/oauth/token").count, 0)
        eq("6 and clears the tokens", store3.load()?.refreshToken, "")
    }

    // MARK: 7

    private static func routesAndChooser() {
        guard let options = SegmentationOptionsStore.shared, let spec = try? options.spec(for: .openai),
              let mixSpec = try? options.spec(for: .mix) else {
            check("7 the bundled figures load", false); return
        }
        let auth = ChatGPTAuth(store: MemoryChatGPTCredentialStore(creds()), defaultsSuite: defaults())
        func route(_ s: ApproachSpec, _ keys: [WindowProvider: String], _ chatGPT: ChatGPTAuth?, _ r: ChatGPTRoute,
                   claude: String? = nil) -> String {
            switch WindowStageTransport.make(s, keys: keys, claudeBinary: claude, chatGPT: chatGPT, chatGPTRoute: r) {
            case .failure(let m): return "missing:\(m.description)"
            case .success(let t):
                let rt = (t as? RoutingWindowTransport)?.routes[.openai]
                return rt is ChatGPTPlanWindowTransport ? "plan" : rt is APIWindowTransport ? "key" : "?"
            }
        }
        eq("7 signed in, no key → plan", route(spec, [:], auth, .apiKey), "plan")
        eq("7 key and plan, key chosen → key", route(spec, [.openai: "k"], auth, .apiKey), "key")
        eq("7 key and plan, plan chosen → plan", route(spec, [.openai: "k"], auth, .plan), "plan")
        eq("7 key only → key", route(spec, [.openai: "k"], nil, .apiKey), "key")
        eq("7 plan chosen but signed out → refused, never the key", route(spec, [.openai: "k"], nil, .plan),
           "missing:ChatGPT is set to go by your ChatGPT plan, but ChatGPT is not signed in. Sign in with ChatGPT, or choose By API key.")
        eq("7 neither → missing", route(spec, [:], nil, .plan),
           "missing:ChatGPT needs an OpenAI API key or Sign in with ChatGPT.")
        eq("7 the mix: Claude by its plan, ChatGPT by its plan", route(mixSpec, [:], auth, .apiKey, claude: "/bin/echo"), "plan")
        if case .success(let t) = WindowStageTransport.make(mixSpec, keys: [:], claudeBinary: "/bin/echo", chatGPT: auth) {
            check("7 the run says Using ChatGPT plan", OCRProcessor.usesChatGPTPlan(t) && OCRProcessor.usesPlan(t))
        } else { check("7 the run says Using ChatGPT plan", false) }
        if case .success(let t) = WindowStageTransport.make(spec, keys: [.openai: "k"], claudeBinary: nil) {
            check("7 a key run does not say Using ChatGPT plan", !OCRProcessor.usesChatGPTPlan(t))
        }

        let signedIn = SegmentationRoutes(chatGPTAccount: "user@example.com")
        let row = SegmentationRow.make(.openai, options: options, pageCount: 1000, routes: signedIn, today: day)
        check("7 ChatGPT runs on the plan alone", row.canRun, "\(row.unavailableReason ?? "")")
        eq("7 the plan line", row.costLines,
           ["ChatGPT plan: about 6.9M tokens, roughly $14.51 of API calls at list price (approximate). Using ChatGPT plan"])
        eq("7 the plan adds no dollars", row.apiDollars, nil)
        eq("7 the cost pane", row.costSummary, "your plan")
        eq("7 no key needed", row.missingKeys, [])
        let keyChosen = SegmentationRoutes(hasOpenAIKey: true, chatGPTAccount: "u", chatGPTRoute: .apiKey)
        check("7 key chosen → dollars", SegmentationRow.make(.openai, options: options, pageCount: 1000, routes: keyChosen,
                                                             today: day).costLines == ["about $14.51 by API key at list price"])
        let planChosen = SegmentationRoutes(hasOpenAIKey: true, chatGPTAccount: "u", chatGPTRoute: .plan)
        eq("7 plan chosen → the plan line", SegmentationRow.make(.openai, options: options, pageCount: 1000,
                                                                 routes: planChosen, today: day).costLines, row.costLines)
        check("7 the route is asked only with both", keyChosen.offersChatGPTRouteChoice && !signedIn.offersChatGPTRouteChoice)
        let both = SegmentationRow.make(.mix, options: options, pageCount: 1000,
                                        routes: SegmentationRoutes(hasClaudeCLI: true, chatGPTAccount: "u"), today: day)
        check("7 the mix on both plans: two plan lines, no dollars",
              both.canRun && both.apiDollars == nil && both.costLines.count == 2
              && both.costLines[0].hasPrefix("Claude plan:") && both.costLines[1].hasPrefix("ChatGPT plan:"), "\(both.costLines)")
        eq("7 a small folder's token figure", SegmentationRow.make(.openai, options: options, pageCount: 40,
                                                                   routes: signedIn, today: day).costLines,
           ["ChatGPT plan: about 280K tokens, roughly $0.58 of API calls at list price (approximate). Using ChatGPT plan"])
        eq("7 Gemini has no ChatGPT controls", SegmentationRow.providers(.gemini, options: options), [.gemini])
        eq("7 the mix shows them", SegmentationRow.providers(.mix, options: options), [.anthropic, .openai])
    }

    // MARK: 8

    private static func signOut() async {
        let fake = FakeOpenAI(signer: nil)
        let store = MemoryChatGPTCredentialStore(creds())
        let auth = ChatGPTAuth(store: store, defaultsSuite: defaults(), http: fake.http, now: { day })
        eq("8 revoked", await auth.signOut(), true)
        let f = fake.requests(path: "/api/accounts/oauth/revoke").first.map(form) ?? [:]
        eq("8 revocation form", [f["token"], f["token_type_hint"], f["client_id"]], ["r1", "refresh_token", "oaiapp_test"])
        check("8 forgotten", store.load() == nil && auth.signedInAccount() == nil)

        let failing = FakeOpenAI(signer: nil)
        failing.revokeStatus = 500
        let store2 = MemoryChatGPTCredentialStore(creds())
        let auth2 = ChatGPTAuth(store: store2, defaultsSuite: defaults(), http: failing.http, now: { day })
        eq("8 a failed revocation says so", await auth2.signOut(), false)
        check("8 and still forgets the account", store2.load() == nil)
        let auth3 = ChatGPTAuth(store: MemoryChatGPTCredentialStore(), defaultsSuite: defaults(), http: failing.http)
        eq("8 signed out already: nothing sent", await auth3.signOut(), false)
    }
}

// MARK: - Fakes

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// An RSA key made for the run, which signs the fake server's ID tokens.
private struct TestSigner {
    let privateKey: SecKey
    let der: Data
    let n: Data
    let e: Data
    let kid = "k1"

    init?() {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, nil), let pub = SecKeyCopyPublicKey(key),
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let parts = Self.parse(der) else { return nil }
        privateKey = key; self.der = der; n = parts.0; e = parts.1
    }

    var jwk: [String: Any] {
        ["kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256", "n": ChatGPTAuth.b64url(n), "e": ChatGPTAuth.b64url(e)]
    }

    func sign(_ claims: [String: Any], header: [String: Any]? = nil) -> String {
        let h = ChatGPTAuth.b64url(try! JSONSerialization.data(withJSONObject: header ?? ["alg": "RS256", "kid": kid, "typ": "JWT"]))
        let c = ChatGPTAuth.b64url(try! JSONSerialization.data(withJSONObject: claims))
        let input = Data("\(h).\(c)".utf8)
        let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil) as Data? ?? Data()
        return "\(h).\(c).\(ChatGPTAuth.b64url(sig))"
    }

    /// `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`, read independently of the code under
    /// test so the round trip proves the builder.
    static func parse(_ der: Data) -> (Data, Data)? {
        let b = [UInt8](der)
        var i = 0
        func length() -> Int? {
            guard i < b.count else { return nil }
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            var n = 0
            for _ in 0..<(first & 0x7f) { guard i < b.count else { return nil }; n = n << 8 | Int(b[i]); i += 1 }
            return n
        }
        func integer() -> Data? {
            guard i < b.count, b[i] == 0x02 else { return nil }
            i += 1
            guard let n = length(), i + n <= b.count else { return nil }
            defer { i += n }
            return Data(b[i..<(i + n)])
        }
        guard b.first == 0x30 else { return nil }
        i = 1
        guard length() != nil, let n = integer(), let e = integer() else { return nil }
        return (n, e)
    }
}

/// The auth server and the Responses API, in process. Records every request.
private final class FakeOpenAI: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let signer: TestSigner?
    private var refreshCount = 0

    var nonce = ""
    var refreshDelay: Double = 0
    var refreshReply: (Int, [String: Any])?
    var revokeStatus = 200
    /// The Responses API's replies, in order; the last repeats.
    var responses: [(Int, Data, [String: String])] = []

    init(signer: TestSigner?) { self.signer = signer }

    func requests(path: String) -> [URLRequest] { lock.withLock { recorded.filter { $0.url?.path == path } } }

    var http: ChatGPTAuth.HTTP {
        { [self] r in try await self.handle(r) }
    }

    private func reply(_ r: URLRequest, _ status: Int, _ data: Data, _ headers: [String: String] = [:]) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    private func json(_ r: URLRequest, _ status: Int, _ obj: [String: Any]) -> (Data, URLResponse) {
        reply(r, status, try! JSONSerialization.data(withJSONObject: obj), ["Content-Type": "application/json"])
    }

    private func handle(_ r: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(r) }
        let path = r.url?.path ?? ""
        switch path {
        case "/.well-known/openid-configuration":
            return json(r, 200, ["issuer": "https://auth.openai.com",
                                 "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
                                 "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke"])
        case "/.well-known/jwks.json":
            return json(r, 200, ["keys": signer.map { [$0.jwk] } ?? []])
        case "/api/accounts/oauth/revoke":
            return reply(r, revokeStatus, Data())
        case "/api/accounts/oauth/token":
            var c = URLComponents(); c.percentEncodedQuery = String(data: r.httpBody ?? Data(), encoding: .utf8)
            let grant = c.queryItems?.first { $0.name == "grant_type" }?.value
            let client = c.queryItems?.first { $0.name == "client_id" }?.value ?? ""
            if grant == "refresh_token" {
                if refreshDelay > 0 { try await Task.sleep(for: .seconds(refreshDelay)) }
                if let rr = refreshReply { return json(r, rr.0, rr.1) }
                let n = lock.withLock { refreshCount += 1; return refreshCount + 1 }
                return json(r, 200, ["access_token": "at-\(n)", "refresh_token": "rt-\(n)", "expires_in": 3600,
                                     "token_type": "Bearer"])
            }
            let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": client, "nonce": nonce,
                                         "sub": "sub-1", "email": "user@example.com",
                                         "exp": SegmentationChatGPTTestDriver.day.timeIntervalSince1970 + 600]
            return json(r, 200, ["access_token": "at-1", "refresh_token": "rt-1", "id_token": signer?.sign(claims) ?? "",
                                 "expires_in": 3600, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"])
        case "/v1/responses":
            let next: (Int, Data, [String: String])? = lock.withLock {
                guard !responses.isEmpty else { return nil }
                return responses.count > 1 ? responses.removeFirst() : responses[0]
            }
            guard let next else { return reply(r, 500, Data("no scripted reply".utf8)) }
            return reply(r, next.0, next.1, next.2)
        default:
            return reply(r, 404, Data())
        }
    }
}
