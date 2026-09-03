import Foundation
import AppKit
import ArchiveCore

/// Owns a live-capture session: the incoming folder, the pairing token, the received photos
/// (grouped as the phone marked them), and the receiver server lifecycle. The `CaptureServer`
/// calls `ingest(...)` for each photo; the UI observes the published state and hands the
/// grouped result off to the OCR pipeline.
@MainActor
final class CaptureSession: ObservableObject {
    @Published private(set) var photos: [CapturedPhoto] = []      // ordered by seq
    @Published private(set) var serverRunning = false
    @Published private(set) var listenPort: UInt16 = 0
    @Published private(set) var lastActivity: Date?
    @Published var statusMessage = "Idle"
    @Published private(set) var connectedDeviceName: String?

    /// Headless test seam for manifest durability failures. Nil in production; the closure owns no files
    /// unless the test explicitly writes them.
    var manifestWriteOverride: ((Data, URL) -> Bool)?

    /// Headless test seam: fires at the exact point a resolved tag card is handed to live processing
    /// (`notifySegmentResolved`), so a test can prove that point is never reached before the decision is
    /// durable. Nil in production.
    var resolvedNotifyHookForTest: ((String) -> Void)?

    /// How many photos the phone still has un-sent (its last heartbeat), + when we last heard it, so the
    /// Mac can surface "phone still has N to send" and hold Finish until the phone has drained.
    @Published private(set) var phonePendingCount = 0
    private var phonePendingAt: Date?
    /// True only if a FRESH heartbeat (within 20s) says the phone still has photos to send — staleness
    /// guards against blocking Finish forever if the phone disconnects mid-send.
    var phonePendingActive: Bool {
        phonePendingCount > 0 && (phonePendingAt.map { Date().timeIntervalSince($0) < 20 } ?? false)
    }

    /// Phone heartbeat (`POST /phone/status`): record the un-sent count + freshness, and (during a live
    /// session) re-evaluate a pending Finish so it advances once the phone has drained.
    func updatePhonePending(_ count: Int) {
        phonePendingCount = count
        phonePendingAt = Date()
        notePhoneContact()
        if processingMode == .live { liveProcessor.phoneStatusChanged() }
    }

    // MARK: - Headless E2E autopilot (Tier-2 test seam; env-gated, PROD-UNCHANGED when unset)

    /// The headless phone↔Mac E2E needs the Mac to resolve tag cards + finalize with no GUI. These three
    /// hooks are ALL gated on the existing headless-launch flag `LIVECAPTURE_AUTOSTART=1` PLUS their own
    /// flag, so with the envs unset (production) they are `false` and nothing below ever runs — behavior is
    /// byte-identical. They reuse the proven `LiveCaptureTestDriver` polling patterns and do NOT alter the
    /// Recovery Core Directive: finalize still deletes a source only after its output is confirmed at the
    /// destination, via the Trash (the `finalize` path is unchanged; we only drive it).
    private var headlessAutostart: Bool { ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" }
    /// (a) Auto-resolve each completed document segment's tag card via the EXISTING `skipMacTags`.
    private var headlessAutoSkipTags: Bool {
        headlessAutostart && ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSKIPTAGS"] == "1"
    }
    /// (b) Auto-drive the EXISTING finish→finalize path when the phone signals session-complete.
    private var headlessAutoFinalize: Bool {
        headlessAutostart && ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOFINALIZE"] == "1"
    }
    private var headlessFinalizeStarted = false

    /// (a) Resolve every currently complete-but-unresolved document segment via the SAME `skipMacTags` the
    /// GUI tag card uses (no card, LLM-only tags). Armed by `LIVECAPTURE_AUTOSKIPTAGS`, and also implied by
    /// `LIVECAPTURE_AUTOFINALIZE` (finalize can't proceed while a card is pending, so it must resolve them
    /// the same way). `pendingTagGroup` returns the first unresolved group and `skipMacTags` adds it to
    /// `resolvedGroupIds`, so the loop terminates. No-op in production.
    private func headlessResolvePendingTags() {
        guard headlessAutoSkipTags || headlessAutoFinalize else { return }
        // W23.m7: a failed manifest write now ROLLS the resolve back, so the same card stays pending —
        // stop instead of spinning forever on a group that cannot be persisted. The caller re-enters this
        // (the finalize autopilot polls), so a transient failure is still retried, just not in a hot loop.
        while let g = pendingTagGroup, skipMacTags(groupId: g.id) {}
    }

    /// (b)+(c) Launch the headless finish→finalize autopilot once (guarded), when armed. Called from
    /// `completeAllOpenDocGroups`, i.e. when the phone's `POST /session/complete` arrives (LAN) or a cloud
    /// session-complete marker is drained. No-op / never scheduled in production.
    private func startHeadlessFinalizeIfRequested() {
        guard headlessAutoFinalize, !headlessFinalizeStarted else { return }
        // DATA SAFETY: refuse to auto-finalize unattended without an isolated output dir. When
        // LIVECAPTURE_TESTOUT is unset, `LiveCaptureProcessor.currentOutputDirectory` falls back to the
        // real Settings output dir, so an autopilot run would file test pages into the operator's real
        // corpus with no confirmation. Require TESTOUT (mirrors the LiveCaptureTestDriver guard; see the
        // "Archive test-run safety" invariant). No-op in production (never armed there).
        guard let out = ProcessInfo.processInfo.environment["LIVECAPTURE_TESTOUT"], !out.isEmpty else { return }
        headlessFinalizeStarted = true
        Task { @MainActor [weak self] in await self?.runHeadlessFinalize() }
    }

    /// Drive the EXISTING Finish path headlessly, honoring the drain gate. `requestFinish` holds until the
    /// phone has drained (`phonePendingActive`), no segment is still OCR'ing/tagging, and no tag card is
    /// pending — its watchdog + per-segment staging + heartbeats re-evaluate readiness, exactly like the GUI
    /// Finish button. When `beginFinalize` surfaces the collection drafts, auto-name any unnamed new
    /// collection and call the unmodified `finalize`, then (c) write the done-signal for the harness.
    private func runHeadlessFinalize() async {
        let lp = liveProcessor
        headlessResolvePendingTags()
        lp.requestFinish()
        // Wait (bounded ~300s) for finishSession → beginFinalize to populate drafts (the point the GUI would
        // show CollectionFinalizeSheet). Keep resolving any late-completing card while we wait.
        for _ in 0..<600 {
            headlessResolvePendingTags()
            // "Review rotation" is read LIVE in finishSession (not the locked config); when on, the finish
            // path parks on the rotation-review sheet instead of populating drafts. Drive it exactly as the
            // GUI "Continue" button would — apply the detected rotations, which always proceeds to
            // beginFinalize. No operator edits exist headlessly, so this is a faithful straight-through.
            if lp.showRotationReview { lp.applyRotationReviewAndFinalize() }
            if let summary = lp.finalizeSummary { writeHeadlessDone(summary: summary); return }
            if lp.showFinalizeSheet && !lp.drafts.isEmpty { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // Auto-name any new collection whose candidate name came back empty; append-to-existing drafts and
        // pre-named ones are left as decided. Then run the EXISTING finalize (same move + data-safety gate).
        if lp.showFinalizeSheet {
            var drafts = lp.drafts
            for i in drafts.indices where drafts[i].chosenExisting == nil
                && drafts[i].finalName.trimmingCharacters(in: .whitespaces).isEmpty {
                drafts[i].finalName = drafts.count > 1 ? "Live Capture \(sessionId) \(i + 1)" : "Live Capture \(sessionId)"
            }
            lp.finalize(drafts)
        }
        // Wait (bounded ~120s) for the move to complete (finalizeSummary is set at the end of `finalize`).
        for _ in 0..<240 {
            if lp.finalizeSummary != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        writeHeadlessDone(summary: lp.finalizeSummary ?? "NO SUMMARY (timeout)")
    }

    /// (c) Signal the harness that the headless run finished so it can stop polling: write `DONE.txt` (the
    /// finalize summary — collections + counts) into `LIVECAPTURE_TESTOUT` and append a `LIVECAPTURE_DONE …`
    /// line to `LIVECAPTURE_READYFILE`, mirroring the `LIVECAPTURE_READY` line the harness already parses.
    /// (Output already files into `LIVECAPTURE_TESTOUT` via `LiveCaptureProcessor.currentOutputDirectory`,
    /// so nothing lands in the real corpus.) Only ever reached from the env-gated autopilot above.
    private func writeHeadlessDone(summary: String) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["LIVECAPTURE_TESTOUT"], !out.isEmpty {
            let donePath = (out as NSString).appendingPathComponent("DONE.txt")
            try? summary.write(toFile: donePath, atomically: true, encoding: .utf8)
        }
        let line = "LIVECAPTURE_DONE \(summary)\n"
        if let path = env["LIVECAPTURE_READYFILE"] {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        FileHandle.standardError.write(Data(line.utf8))
        NSLog("HEADLESS AUTOFINALIZE: \(summary)")
    }

    /// Mac operator's per-segment tags entered during capture (groupId → tags), plus the set of
    /// document groups already tagged or skipped on the Mac (drives the auto-advancing card).
    @Published private(set) var macTags: [String: MacSegmentTags] = [:]
    @Published private(set) var resolvedGroupIds: Set<String> = []
    /// Document groups the phone has signalled complete (via `POST /segment/complete` at End segment).
    /// Photos now stream to the Mac page-by-page as they are shot, so a document group exists mid-segment;
    /// its tag card must appear only once the segment is complete — this gates `pendingTagGroup`.
    @Published private(set) var completedDocGroups: Set<String> = []

    // MARK: - Live processing mode (streaming vs. batch handoff)

    /// How this session's captures are processed. Resolved on first activity from the app-wide
    /// **Settings** choice (`liveProcessingMode`), then fixed for the session.
    enum LiveProcessingMode: String { case undecided, stageForLater, live }
    @Published private(set) var processingMode: LiveProcessingMode = .undecided
    /// The snapshotted processing settings for a `.live` session (nil until activated).
    @Published private(set) var config: SessionProcessingConfig?
    /// Set once the first segment begins processing (the config is already snapshotted).
    @Published private(set) var settingsLocked = false
    /// True once a phone has paired (pinged) or sent a photo — used to hide the QR. Sticky (it survives a
    /// quiet phone), so it drives QR *visibility*; live "is a phone actually there right now" is the
    /// separate `phoneConnected` below. Reset by a phone-side re-pair (`phoneDidDisconnect`).
    @Published private(set) var paired = false

    // MARK: - Phone-connection liveness (B4: "Connected" vs "Listening")

    /// When we last heard from a paired phone — a ping, a `/phone/status` heartbeat, or an ingested photo.
    /// Drives the honest "Connected" vs merely "Listening" status split so a stale green dot never reads as
    /// "still paired." Reset to nil on a phone-side re-pair (`POST /session/disconnect` → `phoneDidDisconnect`).
    @Published private(set) var lastPhoneContactAt: Date?
    /// Published mirror of "a phone is actively paired (seen within the freshness window)". Stored (not a
    /// pure computed) so it flips back to false on its own when heartbeats stop: a repeating timer (armed
    /// while the receiver is up) re-evaluates it, and an explicit re-pair resets it at once.
    @Published private(set) var phoneConnected = false
    /// A phone counts as connected only while its last contact is this recent. The companions heartbeat
    /// every ~8s (their auto-retry loop), so ~25s tolerates a couple of missed beats before going gray.
    private static let phoneContactWindow: TimeInterval = 25
    private var connectionTimer: Timer?

    /// Record any phone contact (ping / heartbeat / ingest): refresh the freshness clock, keep the QR hidden
    /// (`paired`), and mark the phone connected.
    private func notePhoneContact() {
        lastPhoneContactAt = Date()
        paired = true
        if !phoneConnected { phoneConnected = true }
    }

    /// Re-evaluate `phoneConnected` from the freshness window (driven by the connection timer) so the dot
    /// goes gray on its own if a phone leaves WITHOUT a clean re-pair.
    private func refreshPhoneConnected() {
        let fresh = lastPhoneContactAt.map { Date().timeIntervalSince($0) < Self.phoneContactWindow } ?? false
        if phoneConnected != fresh { phoneConnected = fresh }
    }

    private func startConnectionTimer() {
        guard connectionTimer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPhoneConnected() }
        }
        RunLoop.main.add(t, forMode: .common)
        connectionTimer = t
    }
    private func stopConnectionTimer() { connectionTimer?.invalidate(); connectionTimer = nil }

    /// Streaming coordinator (created on first use). Processes each segment during a `.live` session.
    private(set) lazy var liveProcessor = LiveCaptureProcessor(session: self)

    /// The user's app-wide choice (Settings ⌘,): stream each segment live, or stage for a later batch run.
    private var liveModeEnabled: Bool { UserDefaults.standard.string(forKey: DefaultsKeys.liveProcessingMode) == LiveProcessingMode.live.rawValue }

    /// On first activity, fix the session's processing mode from Settings and — for live — snapshot
    /// the config so mid-session Settings changes don't affect the running session.
    func activateProcessingIfNeeded() {
        guard processingMode == .undecided else { return }
        if liveModeEnabled {
            let cfg = SessionProcessingConfig.fromDefaults()
            config = cfg
            processingMode = .live
            liveProcessor.activate(config: cfg)
        } else {
            processingMode = .stageForLater
        }
    }

    func markPaired() { notePhoneContact() }
    /// Re-show the pairing QR (e.g. to pair a different phone); doesn't disconnect the current one, so the
    /// live "connected" indicator is left alone (only the sticky QR-hide flag is cleared).
    func unpairDisplay() { paired = false }

    /// The phone re-paired (`POST /session/disconnect`). Reset the pairing + connection indicators and
    /// re-show the QR automatically, so the operator can immediately re-scan without hunting for "Show QR"
    /// (B4-i). Received photos + all session/processing state are UNTOUCHED — the phone retains its captures
    /// and re-uploads them to the new endpoint (idempotent `ingest`), so nothing is lost. Also nudges the
    /// USB bridge to re-assert `adb reverse` at once so a wired re-pair reconnects without waiting for the
    /// 5s heal tick (B4-iii). The drain-gate counters (`phonePending*`) are deliberately left to expire on
    /// their own (20s staleness window) so a re-pair mid-Finish can't prematurely un-gate finalize.
    func phoneDidDisconnect() {
        paired = false
        phoneConnected = false
        lastPhoneContactAt = nil
        connectedDeviceName = nil
        USBBridge.reassertNow()
    }

    /// Start a live session with an explicit config (used by the headless test driver).
    func beginLiveSession(config: SessionProcessingConfig) {
        self.config = config
        processingMode = .live
        liveProcessor.activate(config: config)
    }

    /// Test-only: force stage-for-later so `ingest` never triggers OCR (no API key, $0). Used by the
    /// FileRelay offline invariant driver.
    func beginStageSessionForTest() { if processingMode == .undecided { processingMode = .stageForLater } }

    /// Test-only ($0, W3.cap-r2): put the session in `.live` and arm its OWN `liveProcessor` against a
    /// scratch staging dir, so a headless driver can drive the REAL `ingest` → `photoIngested` path.
    /// Deliberately NOT `beginLiveSession`: that calls `activate`, whose `pruneLegacyStaging` resolves
    /// orphans against `backupRoot` — which the test has redirected — and would therefore judge the
    /// operator's genuine legacy staging dirs orphaned and delete them. Recovery Core Directive: a test
    /// must not be able to remove real work, so it takes the arming path that touches nothing outside tmp.
    func _recoveryTestBeginLive(config: SessionProcessingConfig, stagingDir: URL) {
        self.config = config
        processingMode = .live
        liveProcessor._recoveryTestArm(stagingDir: stagingDir, config: config, staged: [])
    }

    /// Test-only: when set, the next `ingest` returns nil (simulating a durable-write failure) so the relay
    /// receiver's "no receipt / no delete / no processed-entry on a nil ingest" invariant can be exercised.
    var testForceIngestFailure = false

    /// Called by the streaming coordinator when the first segment begins processing.
    func lockSettings() { if config != nil { settingsLocked = true } }

    /// Stable 6-char bearer for the **Drive (Cloud) relay only** — the value stamped as the shared
    /// folder's `appProperties.relayToken` and carried in the QR's optional `relay` key. Its byte format
    /// is pinned by `SPEC/relay-object-format.md` (committed golden fixtures + the shipped Android
    /// transport ride on it), so it stays a short, stable code. **Not** the LAN credential: the LAN/USB
    /// HTTP receiver authenticates `lanToken` instead. W16.lan2 split the two so LAN could go high-entropy
    /// without touching the relay wire contract. Persisted so a paired phone keeps its Cloud path.
    let token = CaptureSession.loadOrCreateToken()

    /// High-entropy bearer the phone presents to the **LAN/USB HTTP receiver** (`CaptureServer`), carried
    /// in the QR's `token` key. Unlike the relay code, this credential faces a reachability-only online
    /// guess — no sniffing needed — so it must be brute-force-infeasible: `lanTokenLength` chars over a
    /// 31-symbol alphabet (≈ 158 bits at 32), drawn from the cryptographically-secure system RNG, minted
    /// once per Mac and persisted. Rotating it costs only one QR re-scan per phone (companions treat the
    /// token as opaque). (W16.lan2 — replaces the old ~29.7-bit shared 6-char code on the LAN path.)
    let lanToken = CaptureSession.loadOrCreateLANToken()

    /// Unambiguous 31-symbol alphabet shared by both credentials (no 0/O/1/I/L).
    private static let tokenAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Length of the high-entropy LAN token: 32 × log2(31) ≈ 158 bits.
    static let lanTokenLength = 32

    /// 6 chars from an unambiguous alphabet (no 0/O/1/I/L), persisted in UserDefaults. Drive-relay code.
    private static func loadOrCreateToken() -> String {
        let key = "LiveCaptureToken"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count == 6 { return existing }
        let t = String((0..<6).map { _ in tokenAlphabet.randomElement()! })
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    /// Mint a fresh high-entropy LAN token (pure; no persistence). Each character is an independent draw
    /// from `SystemRandomNumberGenerator` (a CSPRNG on Apple platforms) via `randomElement()`.
    static func makeLANToken() -> String {
        String((0..<lanTokenLength).map { _ in tokenAlphabet.randomElement()! })
    }

    /// Persisted high-entropy LAN token. Re-mints when the stored value is missing or shorter than the
    /// current `lanTokenLength` (so a future length bump upgrades in place); an existing full-length token
    /// is kept stable across launches so a paired phone keeps working without re-scanning.
    private static func loadOrCreateLANToken() -> String {
        let key = "LiveCaptureLANToken"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count >= lanTokenLength { return existing }
        let t = makeLANToken()
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    /// Session id + this session's incoming folder (a per-run subfolder of `backupRoot`). Every photo
    /// received from the phone is written here and kept until the run's output is fully finalized — a
    /// user-visible backup so the originals can be recovered even if the app fails catastrophically.
    let sessionId: String
    let incomingFolder: URL

    /// Durable, user-VISIBLE parent for all Live Capture session folders: `~/Pictures/Archive Processor
    /// Live Capture/`. Kept in Pictures (not the hidden Application Support container) so the operator can
    /// find and copy the raw photos in Finder — including if the app won't launch. Falls back to
    /// Application Support only if the Pictures directory is somehow unavailable.
    static var backupRoot: URL {
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"] {
            return URL(fileURLWithPath: testRoot, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Archive Processor Live Capture", isDirectory: true)
    }

    /// Move an item to the macOS Trash instead of hard-deleting it, so anything the app removes after
    /// processing stays recoverable (Finder → Put Back). This is the **Recovery Core Directive** in code:
    /// the app never *permanently* deletes an irreplaceable capture. Falls back to a hard delete ONLY if
    /// trashing genuinely fails (e.g. a volume with no Trash) — leaving a half-deleted file behind would be
    /// worse. Returns true iff the item went to the Trash (false = fell back to remove, or nothing was
    /// there). Safe on a missing path. `nonisolated static` so finalize/cleanup can call it from any context.
    @discardableResult
    nonisolated static func trashOrRemove(_ url: URL, _ fm: FileManager = .default) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        do { try fm.trashItem(at: url, resultingItemURL: nil); return true }
        catch { try? fm.removeItem(at: url); return false }
    }

    /// Pre-visible-backup location (older builds stored sessions here). Any session left here is
    /// migrated into the visible backupRoot on launch (see migrateLegacySessions) so it's never orphaned
    /// and — critically — so its further photos also land in the Finder-discoverable folder.
    private static var legacyRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveProcessor/LiveCapture", isDirectory: true)
    }

    private lazy var server = CaptureServer(session: self)
    /// The file-relay receiver (offline stand-in for the Google Drive relay). Watches a shared directory
    /// instead of an HTTP port; funnels into the same `ingest`. `epoch = sessionId` so a fresh vs recovered
    /// launch is distinguishable (published in `_epoch.json`; the phone adopts it — see the spec's A2).
    private lazy var fileRelay = FileRelayReceiver(
        session: self, token: token, epoch: sessionId,
        store: LocalDirectoryStore(dir: Self.relayDir(token: token)),
        processedURL: incomingFolder.appendingPathComponent("relay-processed.json"))

    /// The Google Drive cloud relay: the SAME receiver loop, backed by a `DriveObjectStore` (behind
    /// `DriveAuth`) instead of a local directory. Constructed lazily + side-effect-free (no network until a
    /// scan runs); the owner configures the OAuth client + signs in before it can actually reach Drive.
    private lazy var cloudRelay: FileRelayReceiver = {
        let auth = DriveAuth(clientId: UserDefaults.standard.string(forKey: DefaultsKeys.driveClientId) ?? "",
                             clientSecret: KeychainHelper.load(account: "DriveClientSecret") ?? "")
        let client = DriveClient(token: { try auth.accessToken() })
        return FileRelayReceiver(session: self, token: token, epoch: sessionId,
                                 store: DriveObjectStore(client: client, token: token),
                                 processedURL: incomingFolder.appendingPathComponent("relay-processed-cloud.json"))
    }()

    /// CI/test-only transport override (`LIVECAPTURE_TRANSPORT`): forces exactly ONE offline receiver for
    /// the headless harness (`fileRelay`) or an isolated LAN/cloud run. **Not user-facing** — the Settings
    /// Transport picker was removed (A5). In production `start()` always runs the LAN `CaptureServer` and
    /// ADDITIONALLY runs the Drive relay watcher whenever the Mac is signed into Google Drive.
    private var forcedTestTransport: CaptureTransport? {
        ProcessInfo.processInfo.environment["LIVECAPTURE_TRANSPORT"].flatMap { CaptureTransport(rawValue: $0) }
    }

    /// Signed into the Google Drive relay: a refresh token is in the Keychain AND a client id is configured.
    /// Sign-in alone ENABLES the Drive watcher (it is gated to an active session in `start()`/`stop()` to
    /// save Drive quota) — the operator never picks a "cloud mode". `LIVECAPTURE_DRIVE=1` forces it on for a
    /// headless cloud test.
    var isDriveSignedIn: Bool {
        if ProcessInfo.processInfo.environment["LIVECAPTURE_DRIVE"] == "1" { return true }
        return KeychainHelper.load(account: "DriveRefreshToken") != nil
            && !(UserDefaults.standard.string(forKey: DefaultsKeys.driveClientId) ?? "").isEmpty
    }
    /// True while THIS session started the Drive watcher, so `stop()` tears down only what it started.
    private var cloudRelayStarted = false

    /// The file-relay shared-directory root (`<root>/<token>/`), from Settings/env; defaults under the
    /// visible backup root. `LIVECAPTURE_RELAYDIR` overrides it for CI.
    static func relayDir(token: String) -> URL {
        let base = ProcessInfo.processInfo.environment["LIVECAPTURE_RELAYDIR"]
            ?? UserDefaults.standard.string(forKey: DefaultsKeys.liveRelayDir)
            ?? backupRoot.appendingPathComponent("_relay").path
        return URL(fileURLWithPath: base).appendingPathComponent(token, isDirectory: true)
    }

    init() {
        let root = Self.backupRoot
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Move any in-flight session left by an older build into the VISIBLE root, so its photos are
        // Finder-discoverable and every further ingest for it lands there too (not the hidden container).
        if ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"] == nil {
            Self.migrateLegacySessions(into: root)
        }
        // Drop leftover empty session folders (their photos were already cleared at a successful finalize)
        // so the visible backup root doesn't accumulate clutter that buries the run that still has photos.
        // Runs before recovery, so it can never touch the active session (which has photos, or is fresh).
        Self.pruneEmptySessions(under: root)

        // Crash recovery: reload the newest session that still has received-but-unprocessed photos (a
        // manifest + files on disk) so a Mac crash never orphans received data; else start fresh.
        if let restored = Self.latestUnprocessedSession(under: root) {
            sessionId = restored.folder.lastPathComponent
            incomingFolder = restored.folder
            photos = restored.photos
            // Restore which document groups the phone had signalled complete (B5-ii). Without this a
            // mid-session Mac restart showed NO tag card until Finish — the phone won't re-send the
            // segment-complete signal for a group it already got acked. A legacy (pre-B5) manifest has no
            // persisted set, so this is empty and behaves exactly as before for those sessions.
            completedDocGroups = restored.completed
            resolvedGroupIds = restored.resolved     // B9: don't re-surface an already-resolved tag card
            macTags = restored.macTags               // B9: keep the Mac-entered tags across the restart
        } else {
            sessionId = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            incomingFolder = root.appendingPathComponent(sessionId, isDirectory: true)
            try? FileManager.default.createDirectory(at: incomingFolder, withIntermediateDirectories: true)
        }
    }

    // MARK: - Server lifecycle

    /// True once the file-relay receiver is watching its directory (the relay analogue of `serverRunning`;
    /// no port/USB tunnel, so it can't reuse `serverDidStart`).
    @Published private(set) var relayRunning = false
    /// Either receiver is up (transport-agnostic gate for the UI).
    var receiverActive: Bool { serverRunning || relayRunning }
    /// The "Watching Drive" half of the dual status: the Drive relay watcher is currently running.
    var driveWatching: Bool { relayRunning }

    /// Start receiving. In production this ALWAYS starts the LAN `CaptureServer`, and — when signed into
    /// Google Drive — ADDITIONALLY starts the Drive relay watcher, so one pairing QR serves a phone that
    /// chooses Wired, Wi-Fi, OR Cloud with no mode to misconfigure. Under `LIVECAPTURE_TRANSPORT` (CI) it
    /// starts exactly the one forced receiver instead.
    func start() {
        if let forced = forcedTestTransport {
            switch forced {
            case .lan: if !serverRunning { server.start() }
            case .fileRelay: fileRelay.start()                       // own idempotency guard
            case .cloud: cloudRelay.start(); cloudRelayStarted = true
            }
            return
        }
        if !serverRunning { server.start() }        // LAN: BYTE-IDENTICAL to the prior default behavior
        if isDriveSignedIn {                        // Drive watcher auto-runs, gated to this active session
            cloudRelay.start()
            cloudRelayStarted = true
        }
        startConnectionTimer()                      // arm the "phone still here?" freshness re-eval (B4-ii)
    }

    func stop() {
        stopConnectionTimer()
        phoneConnected = false
        server.stop()
        if let forced = forcedTestTransport {
            switch forced { case .fileRelay: fileRelay.stop(); case .cloud: cloudRelay.stop(); case .lan: break }
            cloudRelayStarted = false
            return
        }
        if cloudRelayStarted { cloudRelay.stop(); cloudRelayStarted = false }
    }

    /// Relay receiver readiness (portless; called on the main actor). Mirrors the AUTOSTART READY line so
    /// the headless harness can discover the shared dir, but with no port/USBBridge (a watcher has neither).
    func relayReceiverDidStart(relayDir: String) {
        relayRunning = true
        statusMessage = "Live Capture relay watching \(relayDir) — photos arrive as the phone uploads."
        if ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" {
            let line = fileRelayReadyLine(relayDir: relayDir)
            if let path = ProcessInfo.processInfo.environment["LIVECAPTURE_READYFILE"] {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
    func relayReceiverDidStop() { relayRunning = false }
    func relayReceiverDidFail(_ message: String) { relayRunning = false; statusMessage = "Relay error: \(message)" }

    /// Called by the server (already hopped to the main actor) when it binds/unbinds.
    func serverDidStart(port: UInt16) {
        listenPort = port
        serverRunning = true
        statusMessage = "Listening on port \(port). Scan the QR on the phone to connect."
        if ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1" {
            let line = lanReadyLine(port: port)
            if let path = ProcessInfo.processInfo.environment["LIVECAPTURE_READYFILE"] {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
            FileHandle.standardError.write(Data(lanReadyLogLine(port: port).utf8))
        }
        // Keep the USB reverse tunnel asserted (re-asserted on a timer so a replug self-heals).
        USBBridge.startReverse(port: port)
    }

    // These test-only helpers deliberately share the exact production formatters above. The headless E2E
    // consumes the LAN line, while the Drive-file-relay listener must keep its SPEC-pinned short token.
    private func fileRelayReadyLine(relayDir: String) -> String {
        "LIVECAPTURE_READY transport=fileRelay token=\(token) relayDir=\(relayDir) folder=\(incomingFolder.path)\n"
    }
    private func lanReadyLine(port: UInt16) -> String {
        "LIVECAPTURE_READY port=\(port) token=\(lanToken) folder=\(incomingFolder.path)\n"
    }
    private func lanReadyLogLine(port: UInt16) -> String {
        lanReadyLine(port: port).replacingOccurrences(of: "token=\(lanToken)", with: "token=[REDACTED]")
    }
    func _testFileRelayReadyLine(relayDir: String) -> String { fileRelayReadyLine(relayDir: relayDir) }
    func _testLANReadyLine(port: UInt16) -> String { lanReadyLine(port: port) }
    func _testLANReadyLogLine(port: UInt16) -> String { lanReadyLogLine(port: port) }

    func serverDidStop() {
        serverRunning = false
        statusMessage = "Stopped."
        USBBridge.stopReverse()
    }

    func serverDidFail(_ message: String) {
        serverRunning = false
        statusMessage = "Server error: \(message)"
    }

    // MARK: - Ingestion

    /// Persist a received photo into the session folder and record it. Returns the saved URL,
    /// or nil if the write failed. Uses temp→rename so any folder watcher sees a complete file.
    @discardableResult
    func ingest(jpeg: Data, groupId: String, seq: Int, type: CaptureGroupType,
                priority: String?, year: Int?, month: Int?, deviceName: String?) -> URL? {
        if testForceIngestFailure { testForceIngestFailure = false; return nil }   // test-only injection
        let name = String(format: "%05d-%@.jpg", seq, groupId)
        let finalURL = incomingFolder.appendingPathComponent(name)
        let tempURL = incomingFolder.appendingPathComponent("." + name + ".part")
        do {
            try jpeg.write(to: tempURL, options: .atomic)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        let photo = CapturedPhoto(url: finalURL, groupId: groupId, seq: seq, type: type, receivedAt: Date(),
                                  priority: priority, year: year, month: month)
        // Idempotent re-upload (phone resume after a crash): replace an existing same-group+seq
        // photo instead of duplicating it. Otherwise keep the list ordered by seq.
        if let existing = photos.firstIndex(where: { $0.groupId == groupId && $0.seq == seq }) {
            photos[existing] = photo
        } else if let idx = photos.firstIndex(where: { $0.seq > seq }) {
            photos.insert(photo, at: idx)
        } else {
            photos.append(photo)
        }
        lastActivity = Date()
        connectedDeviceName = deviceName ?? connectedDeviceName
        statusMessage = "Received \(photos.count) photo\(photos.count == 1 ? "" : "s")" + (deviceName.map { " from \($0)" } ?? "")
        // New capture began — drop any prior "Finalized …" summary so the Captured pane shows photos.
        liveProcessor.clearFinalizeSummary()
        notePhoneContact()   // an ingested photo is fresh phone contact (drives "Connected" + hides the QR)
        // Durability contract: only acknowledge success (→ phone deletes its only copy of an
        // un-retakeable archival photo) once the grouping/tag metadata is durably persisted. If the
        // manifest write fails, return nil → server responds 500 → phone retries. The JPEG is already
        // on disk and idempotent replace makes the retry safe; live processing waits until durable.
        guard writeManifest() else { return nil }
        activateProcessingIfNeeded()   // fix mode from Settings on first photo
        if processingMode == .live { liveProcessor.photoIngested(photo) }   // start OCR on arrival
        return finalURL
    }

    /// The operator deleted a page in the Captured pane.
    ///
    /// Resolved by `(groupId, seq)` — the page's durable identity, the same key `PageKey`, the manifest and
    /// `SPEC/relay-object-format.md` use — and deliberately NOT by `CapturedPhoto.id`, which is a fresh
    /// `UUID` minted per *value*. An idempotent re-upload (the phone resuming after a dropped ack) replaces
    /// the value in `photos` under the same key with a new `id`, so a SwiftUI row closure rendered before
    /// that replace hands us a photo whose `id` is no longer present. This used to remove by `id` while
    /// cancelling the OCR by key, and in that window the two disagreed: the cancel landed on the LIVE page
    /// and `removeAll` removed nothing, leaving a page in the session with no task and its source in the
    /// Trash — which finalize files as "OCR not started" over a placeholder image, i.e. a silently
    /// text-less archival document. One identity for both halves, so they cannot diverge; a key that isn't
    /// present is a no-op (nothing trashed either — that stale-value trash was the pre-existing half).
    func removePhoto(_ photo: CapturedPhoto) {
        guard let idx = photos.firstIndex(where: { $0.groupId == photo.groupId && $0.seq == photo.seq }) else { return }
        // W3.cap-r3 — stop this page's paid OCR BEFORE its source goes to the Trash: the page is leaving the
        // session, so nobody will ever read the result. (No-op unless live, and while its segment is
        // mid-finalize — see `photoRemoved`.)
        if processingMode == .live { liveProcessor.photoRemoved(photos[idx]) }
        Self.trashOrRemove(photos[idx].url)   // to Trash, not a hard delete — recoverable
        photos.remove(at: idx)
        writeManifest()
    }

    /// Remove a previously-received photo identified by (groupId, seq). Used when the phone reclassifies
    /// an already-uploaded photo into a new group (`X-Replaces`), so the old copy isn't orphaned on the
    /// Mac. Skipped in live mode once that group has been finalized/staged (removing a staged segment's
    /// source would corrupt staging); a no-op if not present.
    func removePhotoIfSafe(groupId: String, seq: Int) {
        if processingMode == .live && liveProcessor.isFinalized(groupId) { return }
        guard let idx = photos.firstIndex(where: { $0.groupId == groupId && $0.seq == seq }) else { return }
        // W3.cap-r3 — the phone moved this page to another group, so the OCR started for the OLD copy is
        // money nobody will read. Cancel it before the source is trashed. (The new group's own copy was
        // ingested under a different `(groupId, seq)`; both callers skip `rg == groupId`.)
        if processingMode == .live { liveProcessor.photoRemoved(photos[idx]) }
        Self.trashOrRemove(photos[idx].url)   // to Trash, not a hard delete — recoverable
        photos.remove(at: idx)
        writeManifest()
    }

    func clear() {
        for p in photos { Self.trashOrRemove(p.url) }   // to Trash, not a hard delete — recoverable
        photos = []
        completedDocGroups.removeAll()
        resolvedGroupIds.removeAll(); macTags.removeAll()   // B9: keep the persisted resolve state in sync
        writeManifest()
        statusMessage = serverRunning ? "Listening on port \(listenPort)." : "Idle"
    }

    /// Finalize cleanup: delete ONLY the source photos that were actually filed into output (their URLs
    /// in `filed`). Any received-but-unfiled page — e.g. a page that streamed in and arrived after its
    /// segment had already been staged (a straggler) — is KEPT: deleting it would permanently lose an
    /// irreplaceable photo. Kept pages stay in the backup folder + the Captured pane so the operator can
    /// re-Process them. (Data-safety guard for per-capture streaming.)
    func clearFiled(_ filed: Set<URL>) {
        let removed = photos.filter { filed.contains($0.url) }
        for p in removed { Self.trashOrRemove(p.url) }   // to Trash, not a hard delete — recoverable
        photos = photos.filter { !filed.contains($0.url) }
        if photos.isEmpty { completedDocGroups.removeAll(); resolvedGroupIds.removeAll(); macTags.removeAll() }
        writeManifest()
        statusMessage = serverRunning ? "Listening on port \(listenPort)." : "Idle"
    }

    /// Reveal this session's backup folder in Finder. Every photo the phone sends is stored there until
    /// the run's output is fully written, so the operator can recover/copy the originals if anything
    /// fails. Selects the current session folder inside its (visible) parent; if it doesn't exist yet,
    /// opens the parent so the backup location is still discoverable.
    func revealBackupFolder() {
        if FileManager.default.fileExists(atPath: incomingFolder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([incomingFolder])
        } else {
            let root = Self.backupRoot
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            NSWorkspace.shared.open(root)
        }
    }

    // MARK: - Grouping / handoff

    /// Photos grouped as the phone marked them, in capture order.
    var groups: [CaptureGroup] {
        var byId: [String: CaptureGroup] = [:]
        for p in photos {
            if var g = byId[p.groupId] {
                g.photos.append(p)
                byId[p.groupId] = g
            } else {
                byId[p.groupId] = CaptureGroup(id: p.groupId, type: p.type, photos: [p])
            }
        }
        return byId.values
            .map { var g = $0; g.photos.sort { $0.seq < $1.seq }; return g }
            .sorted { $0.order < $1.order }
    }

    // MARK: - Mac-side tagging (auto-advancing card)

    /// The next document group ready for the Mac tag card: **complete** (the phone signalled End
    /// segment via `markSegmentComplete`) and not yet resolved. Pages stream in as shot, so a group
    /// exists mid-segment — gating on `completedDocGroups` keeps the card from popping before the
    /// segment is finished. Box/folder markers need no card (finalized on arrival).
    var pendingTagGroup: CaptureGroup? {
        groups.first { $0.type == .document && completedDocGroups.contains($0.id) && !resolvedGroupIds.contains($0.id) }
    }

    /// The phone ended a document segment (`POST /segment/complete`): attach the segment's tags to its
    /// already-streamed pages (so the tag card pre-fills), then mark it complete so the card appears.
    /// A per-page `P10` already on a photo (streamed with it) is never downgraded. Idempotent: re-sending
    /// the same signal (retry) just re-applies the same tags + is a no-op on the completed set.
    @discardableResult
    func markSegmentComplete(groupId: String, priority: String?, year: Int?, month: Int?) -> Bool {
        let previousPhotos = photos.indices.filter { photos[$0].groupId == groupId }.map {
            (index: $0, priority: photos[$0].priority, year: photos[$0].year, month: photos[$0].month)
        }
        let wasCompleted = completedDocGroups.contains(groupId)
        var changed = false
        for i in photos.indices where photos[i].groupId == groupId {
            if year != nil { photos[i].year = year }
            if month != nil { photos[i].month = month }
            if photos[i].priority != "P10", let priority, !priority.isEmpty { photos[i].priority = priority }
            changed = true
        }
        // completedDocGroups is now persisted in the manifest (B5-ii), so a newly-completed group is a
        // durable state change on its own — persist even when no photo field changed (e.g. re-tagging with
        // the same values), or a Mac restart right after would drop this segment's tag card until Finish.
        let newlyCompleted = completedDocGroups.insert(groupId).inserted
        if changed || newlyCompleted, !writeManifest() {
            // No ack without durable state. Restore memory too, so a retry is guaranteed to attempt the
            // manifest write again and the UI cannot surface a completion the phone still owns.
            for previous in previousPhotos {
                photos[previous.index].priority = previous.priority
                photos[previous.index].year = previous.year
                photos[previous.index].month = previous.month
            }
            if !wasCompleted { completedDocGroups.remove(groupId) }
            return false
        }
        headlessResolvePendingTags()   // headless E2E only (env-gated); no-op in production
        return true
    }

    /// Finish (`POST /session/complete`): surface the tag card for any document segment still open — e.g.
    /// the last segment if the operator finished without tapping End segment — so nothing is stranded.
    @discardableResult
    func completeAllOpenDocGroups() -> Bool {
        var newlyCompleted: [String] = []
        for g in groups where g.type == .document && !resolvedGroupIds.contains(g.id) {
            if completedDocGroups.insert(g.id).inserted { newlyCompleted.append(g.id) }
        }
        if !newlyCompleted.isEmpty, !writeManifest() {
            // Session-complete is a sender-owned control just like segment-complete. Keep memory aligned
            // with disk so LAN/relay can refuse the ack and a retry will attempt persistence again.
            for groupId in newlyCompleted { completedDocGroups.remove(groupId) }
            return false
        }
        // Headless E2E only (env-gated): resolve the just-completed cards, then drive the finish→finalize
        // path (this is called on the phone's POST /session/complete). Both are no-ops in production.
        headlessResolvePendingTags()
        startHeadlessFinalizeIfRequested()
        return true
    }

    /// Operator-visible reason a tag card refused to resolve. One string so the status line and the card's
    /// own inline message can't drift apart.
    static let tagDecisionNotDurableMessage =
        "Could not save this segment's tag decision — check the backup folder and try Save/Skip again."

    /// The ONE point where a resolved tag card is handed to live processing, reached only once the
    /// decision is durably on disk (W23.m7). Ordering matters: `segmentResolved` bakes and stages output
    /// from `macTags`, so telling it first would let a failed manifest write leave produced output that
    /// no recovered state agrees with (relaunch would resurface the group as unresolved, or re-prompt).
    /// `resolvedNotifyHookForTest` observes this point in a headless test; nil in production.
    private func notifySegmentResolved(_ groupId: String) {
        if processingMode == .live { liveProcessor.segmentResolved(groupId: groupId) }
        resolvedNotifyHookForTest?(groupId)
    }

    /// Apply the Mac tag card's tags to a completed segment. **Durability contract (W23.m7):** the
    /// decision is persisted BEFORE anything acts on it, and a failed manifest write rolls memory back —
    /// so the card (derived from the in-memory resolved set) stays up with the operator's entries intact
    /// instead of vanishing into a decision the next launch will not remember. Returns whether the
    /// decision is durable, so the caller can surface the failure. Mirrors the roll-back pattern the
    /// sender-owned controls (`markSegmentComplete` / `completeAllOpenDocGroups`) already use.
    @discardableResult
    func applyMacTags(groupId: String, subjects: [String], quality: Int, year: Int?, month: Int?) -> Bool {
        let previousTags = macTags[groupId]
        macTags[groupId] = MacSegmentTags(subjects: subjects, quality: (0...3).contains(quality) ? quality : 0,
                                          year: year, month: month)
        let newlyResolved = resolvedGroupIds.insert(groupId).inserted
        // B9: persist resolve state + Mac tags so a mid-session restart doesn't re-ask.
        guard writeManifest() else {
            macTags[groupId] = previousTags   // nil restores "never tagged" (removes the key)
            if newlyResolved { resolvedGroupIds.remove(groupId) }
            statusMessage = Self.tagDecisionNotDurableMessage
            return false
        }
        notifySegmentResolved(groupId)
        return true
    }

    /// Resolve a tag card without Mac tags. Same durability contract as `applyMacTags`: persist first,
    /// roll back and report failure rather than silently dropping the decision.
    @discardableResult
    func skipMacTags(groupId: String) -> Bool {
        let newlyResolved = resolvedGroupIds.insert(groupId).inserted
        guard writeManifest() else {   // B9: persist that this card was resolved (skipped)
            if newlyResolved { resolvedGroupIds.remove(groupId) }
            statusMessage = Self.tagDecisionNotDurableMessage
            return false
        }
        notifySegmentResolved(groupId)
        return true
    }

    /// Ordered file URLs + per-group boundary/type/tag info for the OCR pre-grouped handoff.
    func orderedFilesAndGroups() -> (files: [URL], boundaries: [Bool], types: [CaptureGroupType],
                                     priorities: [String?], years: [Int?], months: [Int?], subjects: [[String]]) {
        var files: [URL] = []
        var boundaries: [Bool] = []
        var types: [CaptureGroupType] = []
        var priorities: [String?] = []
        var years: [Int?] = []
        var months: [Int?] = []
        var subjects: [[String]] = []
        for group in groups {
            let mac = macTags[group.id]
            for (i, photo) in group.photos.enumerated() {
                files.append(photo.url)
                boundaries.append(i == 0)          // first photo of a group starts a segment
                types.append(group.type)
                // A saved Mac card is an explicit rating decision, including 0/unrated. Encode its
                // absence as the current wire's P7 clear until W19.q7 renames that phone field.
                // Without a Mac decision, preserve the phone's current rating input unchanged.
                if let mac {
                    priorities.append(DocumentTags.qualityTag(for: mac.quality) ?? "P7")
                } else {
                    priorities.append(photo.priority)
                }
                years.append(mac?.year ?? group.year)     // Mac date override wins over the phone's
                months.append(mac?.month ?? group.month)
                subjects.append(mac?.subjects ?? [])       // Mac-entered subjects (empty if untagged)
            }
        }
        return (files, boundaries, types, priorities, years, months, subjects)
    }

    // MARK: - Durable manifest (crash recovery)

    struct ManifestEntry: Codable {
        let name: String
        let groupId: String
        let seq: Int
        let type: String
        let priority: String?
        let year: Int?
        let month: Int?
    }

    /// The on-disk manifest: the per-photo entries PLUS the set of document groups the phone signalled
    /// complete (B5-ii). Persisting `completedDocGroups` lets a mid-session Mac restart re-surface each
    /// completed segment's tag card. Older builds wrote a bare `[ManifestEntry]` array — `decodeManifest`
    /// still accepts that legacy shape (treating the completion set as empty), so recovery is unbroken.
    struct SessionManifest: Codable {
        let photos: [ManifestEntry]
        let completedDocGroups: [String]
        // B9: also persist which completed segments were RESOLVED (tagged/skipped) + the Mac-entered tags,
        // so a mid-session Mac restart doesn't re-surface an already-resolved card (and drop a re-tag on
        // already-staged output). Optional so pre-B9 manifests ({photos, completedDocGroups}) still decode.
        var resolvedGroupIds: [String]? = nil
        var macTags: [String: MacSegmentTags]? = nil
    }

    private var manifestURL: URL { incomingFolder.appendingPathComponent("manifest.json") }

    /// Persist per-photo metadata + the completed-group set so a Mac crash doesn't lose grouping/tags/
    /// completion (the JPEGs don't carry it). Returns whether the write succeeded, so `ingest` can withhold
    /// the success ack until the grouping metadata is durably on disk (the ingest durability contract).
    @discardableResult
    private func writeManifest() -> Bool {
        let entries = photos.map {
            ManifestEntry(name: $0.url.lastPathComponent, groupId: $0.groupId, seq: $0.seq,
                          type: $0.type.rawValue, priority: $0.priority, year: $0.year, month: $0.month)
        }
        let manifest = SessionManifest(photos: entries, completedDocGroups: Array(completedDocGroups),
                                       resolvedGroupIds: Array(resolvedGroupIds), macTags: macTags)
        guard let data = try? JSONEncoder().encode(manifest) else { return false }
        if let manifestWriteOverride { return manifestWriteOverride(data, manifestURL) }
        do { try data.write(to: manifestURL, options: .atomic); return true }
        catch { return false }
    }

    /// Decode a session manifest, accepting BOTH the current object form ({photos, completedDocGroups})
    /// and the legacy bare-array form (pre-B5 builds wrote just `[ManifestEntry]`). A legacy manifest has
    /// no persisted completion set → empty (its tag cards still surface at Finish, exactly as before).
    static func decodeManifest(_ data: Data) -> (entries: [ManifestEntry], completed: Set<String>,
                                                 resolved: Set<String>, macTags: [String: MacSegmentTags])? {
        let d = JSONDecoder()
        if let m = try? d.decode(SessionManifest.self, from: data) {
            return (m.photos, Set(m.completedDocGroups), Set(m.resolvedGroupIds ?? []), m.macTags ?? [:])
        }
        if let legacy = try? d.decode([ManifestEntry].self, from: data) { return (legacy, [], [], [:]) }
        return nil
    }

    /// Newest session folder that still has photos + a manifest (received but not yet cleared).
    private static func latestUnprocessedSession(under root: URL) -> (folder: URL, photos: [CapturedPhoto], completed: Set<String>, resolved: Set<String>, macTags: [String: MacSegmentTags])? {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        // ISO-8601 folder names sort lexically = chronologically; check newest first.
        for folder in subdirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let decoded = decodeManifest(data),
                  !decoded.entries.isEmpty else { continue }
            var restored: [CapturedPhoto] = []
            for e in decoded.entries {
                // Defense-in-depth: never resolve a manifest name that could escape the folder
                // (a tampered/legacy manifest must not become a path-traversal on restore).
                guard !e.name.contains("/"), !e.name.contains("..") else { continue }
                let url = folder.appendingPathComponent(e.name)
                guard fm.fileExists(atPath: url.path) else { continue }
                restored.append(CapturedPhoto(
                    url: url, groupId: e.groupId, seq: e.seq,
                    type: CaptureGroupType(rawValue: e.type) ?? .document,
                    receivedAt: Date(), priority: e.priority, year: e.year, month: e.month))
            }
            if !restored.isEmpty {
                restored.sort { $0.seq < $1.seq }
                return (folder, restored, decoded.completed, decoded.resolved, decoded.macTags)
            }
        }
        return nil
    }

    /// Move any Live Capture session folders left in the legacy Application Support location into the
    /// visible backup root, so recovery and all further writes use the Finder-discoverable folder.
    /// Best-effort: a name collision (already migrated) is skipped, and any folder that can't be moved
    /// is simply left in place. Moving the whole folder keeps each photo with its manifest, and the
    /// manifest stores bare names, so reloading from the new location rebuilds correct URLs.
    private static func migrateLegacySessions(into root: URL) {
        let fm = FileManager.default
        guard root.standardizedFileURL != legacyRoot.standardizedFileURL,
              let subdirs = try? fm.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil) else { return }
        for folder in subdirs {
            let dest = root.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: folder, to: dest) }
        }
    }

    /// Reclaim stale, spent session folders under the backup root — those whose sources were filed and whose
    /// processed outputs were moved into collections at a successful finalize, so the folder holds nothing
    /// worth recovering — WITHOUT ever destroying data that isn't demonstrably disposable. Runs at launch,
    /// before recovery, so it never touches the active session (which has photos, or is fresh).
    ///
    /// The bar is deliberately CONSERVATIVE (W23.h1): the old version treated *every* child directory of the
    /// visible root as a spent session and `removeItem`-hard-deleted any that lacked a top-level `.jpg` or a
    /// recognized `_processed` output — which recursively purged the `_relay` directory's pending relay
    /// objects on the next launch (the exact crash-recovery case the relay exists to survive), lost
    /// HEIC-/`.jpeg`-only sessions, and bypassed the Recovery Core Directive's Trash guarantee. So a folder is
    /// reclaimed ONLY when `isReclaimableEmptySession` positively identifies it as a spent Archive Processor
    /// session, and every reclaim goes through `trashOrRemove` (Finder → Put Back). Returns what it reclaimed.
    @discardableResult
    static func pruneEmptySessions(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        // Never a candidate: the relay object store (default `<root>/_relay`, or a Settings/CI override). It
        // holds pending phone uploads as nested `<token>/` dirs — no top-level image → it would read "empty".
        var relayBases: Set<String> = [root.appendingPathComponent("_relay", isDirectory: true).standardizedFileURL.path]
        if let env = ProcessInfo.processInfo.environment["LIVECAPTURE_RELAYDIR"] {
            relayBases.insert(URL(fileURLWithPath: env, isDirectory: true).standardizedFileURL.path)
        }
        if let configured = UserDefaults.standard.string(forKey: DefaultsKeys.liveRelayDir) {
            relayBases.insert(URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL.path)
        }
        var reclaimed: [URL] = []
        for folder in subdirs {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard isReclaimableEmptySession(folder, relayBases: relayBases, fm: fm) else { continue }
            // Recovery Core Directive: to the Trash (Put Back), NEVER a hard `removeItem`.
            Self.trashOrRemove(folder)
            reclaimed.append(folder)
        }
        return reclaimed
    }

    /// True iff `folder` is a spent Live Capture session safe to move to the Trash. CONSERVATIVE by
    /// construction — anything we cannot positively account for is KEPT, so this only ever deletes *less*
    /// than the naive "no recognized output" test, never more (W23.h1). All four guards must hold:
    ///   (a) POSITIVE session identification — the launch-created ISO-8601 session-id name shape only
    ///       (`isSessionIdName`); a relay/`_`/hidden/operator-named folder is never a candidate.
    ///   (b) NOT a relay object store (`relayBases`) — belt-and-suspenders over (a).
    ///   (c) NO recoverable capture data — no top-level source image (jpg/jpeg/png/tif/tiff/heic/heif — the
    ///       accepted archive-photo formats, so a HEIC-only or `.jpeg`-only session is kept) and no output
    ///       staged under `_processed/`.
    ///   (d) NO unrecognized content — every remaining entry is spent session metadata (`manifest.json`,
    ///       `_epoch.json`, the relay bookkeeping JSONs, an empty `_processed/`, `.DS_Store`, a `.*.part`
    ///       upload temp). Any other file (notes, an unknown journal, nested recovery material) → KEEP.
    nonisolated static func isReclaimableEmptySession(_ folder: URL, relayBases: Set<String>,
                                                      fm: FileManager = .default) -> Bool {
        let name = folder.lastPathComponent
        if name.hasPrefix("_") || name.hasPrefix(".") { return false }        // (a) reserved / hidden sibling
        if relayBases.contains(folder.standardizedFileURL.path) { return false } // (b)
        guard isSessionIdName(name) else { return false }                     // (a) positive identification

        let sourceImageExts: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"]
        let knownMetadata: Set<String> = ["manifest.json", "_epoch.json",
                                          "relay-processed.json", "relay-processed-cloud.json"]
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let entryName = entry.lastPathComponent
            if entryName == "_processed" {                                    // (c) any staged output → keep
                let hasOutput = ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                    .contains { !$0.lastPathComponent.hasPrefix(".") }
                if hasOutput { return false }
                continue                                                      // an empty _processed is spent
            }
            if sourceImageExts.contains(entry.pathExtension.lowercased()) { return false }  // (c) recoverable
            if knownMetadata.contains(entryName) { continue }                 // (d) spent metadata → disposable
            if entryName == ".DS_Store" || (entryName.hasPrefix(".") && entryName.hasSuffix(".part")) { continue }
            return false                                                      // (d) UNKNOWN content → keep
        }
        return true
    }

    /// The launch-created Live Capture session-id name shape: an ISO-8601 timestamp with `:` → `-`
    /// (e.g. `2026-07-29T19-20-11Z`; see `init()`). Distinctive enough that the relay dir, per-token relay
    /// subfolders, and any operator-created folder never match — so prune only ever considers real sessions.
    nonisolated static func isSessionIdName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }
}
