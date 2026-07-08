# Live Capture — Google Drive cloud relay, on-device E2E (owner-gated)

**Goal:** finish + verify the phone→Google-Drive→Mac cloud transport end-to-end with a paired phone.
**Lane/worktree:** `wt/cloud-e2e-…`. Build: per-worktree `-derivedDataPath ./build/DD`. **Commit early + often**
(this plan + the DriveClient instrumentation were once lost to a parallel `git worktree remove --force`).

## State (what's built)
- **Mac Drive backend** — `Net/{DriveClient,DriveObjectStore,DriveAuth,FileRelayReceiver,RelayObjectFormat}.swift`.
  Mock-tested + **LIVE-validated 10/10** against real Drive earlier. Object format → `SPEC/relay-object-format.md`.
- **Control plane (shipped, on main):** Mac cloud Settings (transport picker + client-ID/secret + owner-gated
  "Sign in to Google Drive" loopback OAuth) in `Views/SettingsView.swift`; cloud pairing QR + relay status in
  `Views/LiveCaptureView.swift`; `CaptureSession.isCloudTransport`.
- **Phone uploaders** — iOS + Android `DriveRelayTransport` + `DriveClient` (mock-tested). Android on-device
  Google OAuth via **AppAuth** (Custom Tabs + PKCE, reversed-client-ID redirect) in `net/DriveAuth.kt`; cloud
  pairing in `ui/ConnectScreen.kt`; transport branch in `capture/CaptureViewModel.kt` (`transportFor`/`connectCloud`).

## OAuth facts
- Project `YOUR_GCP_PROJECT`, scope `drive.file` (per-project → same Google account on Mac + phone can share the folder).
- **Mac** = Desktop client `YOUR_GCP_PROJECT-YOUR_DESKTOP_OAUTH_CLIENT_ID` (+ secret `GOCSPX-<REDACTED-ROTATE-THIS>`), loopback PKCE.
- **Phone (Android)** = Android client `YOUR_ANDROID_OAUTH_CLIENT_ID`, package `com.archiveprocessor.capture`,
  debug SHA-1 `3C:0C:63:1D:0B:59:14:4E:06:13:F7:D0:D7:23:FF:DA:6A:D4:56:B9` (registered), redirect scheme
  `com.googleusercontent.apps.YOUR_ANDROID_OAUTH_CLIENT_ID`.
- Relay token = `CaptureSession.token` (the 6-char code); phone gets it via the cloud QR `{mode:"cloud", token, name}`
  and `DriveRelayTransport` self-discovers the Drive folder from `appProperties.relayToken`.

## 🔴 CURRENT BLOCKER — Mac "Sign in to Google Drive" fails
- Symptom (first attempt): browser shows the loopback success page (redirect caught, `onCode` ran) but the app
  showed *"Sign-in failed: … DriveError error 1"* (= `.noResponse` — the code→token POST got no `HTTPURLResponse`).
- Ruled OUT: bad creds (curl → `invalid_grant`, not `invalid_client`), unreachable endpoint, missing
  `network.client` (present); the working loopback server proves the sandbox grants networking at runtime.
- **Instrumented (this session):** `DriveError: LocalizedError` (shows the real message) + `URLSessionHTTP`
  captures the nil/nil triple → the next failure reads `transport error: no HTTPURLResponse — resp=… dataBytes=…`.
- **Resume:** launch the worktree build, retry sign-in, read the descriptive message.
  - `resp=nil … err=nil` → outbound URLSession silently dropped → dig into sandbox/entitlements of the local build,
    or move the token exchange off the `NWListener` connection thread (`DriveAuth.signIn` runs `exchange` inline in
    the loopback `onCode` callback) onto a plain `DispatchQueue.global().async` and re-test.
  - `HTTP 4xx: …` → creds/redirect_uri issue (re-copy Desktop creds; check loopback port match).
  - Signed in → proceed.

## Then (happy path)
Mac: Settings → Transport = Cloud → signed in → Live Capture → **Start** → "Watching Drive" + cloud QR (folder +
`_epoch.json` created in Drive). Phone: Cloud → scan QR → Google sign-in (**same account**) → shoot 1 photo → End
segment. **Verify:** photo appears in the Mac session + `~/Pictures/Archive Processor Live Capture/<session>/`.

Delete this plan once the E2E test passes (git keeps history).
