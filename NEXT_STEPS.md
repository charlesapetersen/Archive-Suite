# Next Steps — prioritized roadmap

Durable plan for the next work, as of **2026-07-06**, coming out of the Android Live Capture walkthrough
and the Tier-1/Tier-2 test build-out. Ordered by priority. Each item links to the detailed doc that
already specifies it — this file is the **index + sequencing**, not a duplicate.

**Conventions (apply throughout):** `Capture/` + `Net/` + the phone↔Mac protocol are **Tier-2** — multi-agent
adversarial review before shipping (`CLAUDE.md`). The **"never lose a photo"** invariant is non-negotiable.
Keep the **Android + iPhone companions in sync**. Push commits often; cut DMG/GitHub releases sparingly.
XcodeGen for Mac/iOS (`xcodegen generate`, never hand-edit `.pbxproj`), Gradle for Android.

---

## P0 — DATA SAFETY: per-capture streaming  ⭐ do first
Photos currently stay on the phone until **End segment**; a segment can be hundreds of photos, so a
crash/drop before End segment loses them all. Stream each photo's bytes to the Mac + durable backup folder
**as captured**, preserving the durable queue + idempotent `(group,seq)` re-upload. End segment becomes
grouping-only.
- **Spec:** `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` → *Workstream S*; `KNOWN_ISSUES.md` → the `[HIGH — data safety]` entry.
- **Effort:** M. **Tier-2.** Both companions + Mac `CaptureSession.ingest`.
- **Acceptance:** during a 100+ shot segment the backup folder fills continuously; killing the phone
  mid-segment loses nothing already shot; reconnect re-uploads only un-acked pages, no duplicates.

## P1 — Live Capture connectivity UX (stop the silent Wi-Fi failure)
On networks with client isolation (airport/guest/hotel/CGNAT) Wi-Fi pairing fails silently — the phone
sits on a dead scanner. Make the failure legible + give escape hatches.
- **Spec:** `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` → **P0** (hotspot guidance + Mac "not paired within ~20s"
  hint + list all IPv4s) and **P1** (reachability preflight → typed `ConnectResult`, cause-named messages
  + fallbacks, and **fix Android's QR analyzer latching** so re-scan works). `KNOWN_ISSUES.md` → the
  silent-Wi-Fi entry. Do P1 **alongside P0 (streaming)** — they touch the same connect/queue path.
- **Effort:** P0 = S, P1 = M. **Tier-2** (Net path). Test with the `192.0.2.1`(timeout)/closed-port(RST)/
  wrong-token(401) triad — no blocked network needed.

## Testing still owed
- **Wi-Fi Live Capture walkthrough — DEFERRED (not yet done).** Today's run was USB-only because the
  airport Wi-Fi had client isolation. **Still to do on a trusted network / personal hotspot:** verify
  Wi-Fi pairing (QR scan → connect), then **Run C failure/recovery** (network drop mid-capture, Mac app
  quit + relaunch, phone app kill + relaunch — the "never lose a photo" cases). Script: `LIVE_CAPTURE_ANDROID_TEST.md`
  (Run A §A1 + Run C). Best done **after P0 streaming** so Run C actually exercises the fixed behavior.
- **iPhone Live Capture walkthrough — DEFERRED** (from the original ask; `ArchiveCaptureiOS/`). Same
  script; the protocol/UX are shared so most steps transfer. Needs a physical iPhone.
- **Tier-2 automated pipeline suite** already passes 5/5 headless (`scripts/test-tier2.sh`); **Tier-1
  smoke** passes (`scripts/test-smoke.sh`). Optional: widen Tier-2 coverage (more collections / larger
  `MAXIMAGES`) on an unattended run.

## Smaller UX fixes (from the walkthrough)
- **Re-pair coordination** — Mac doesn't detect a phone-side Re-pair (stale "paired", must click "Show QR"
  manually; `adb reverse` torn down on re-pair). Add a disconnect signal / auto re-show QR; distinguish
  "server listening" from "phone connected"; verify `USBBridge` re-runs `adb reverse` on reconnect.
  `KNOWN_ISSUES.md`.
- **Stale OCR/progress text while the tag card is open** — looks hung; keep it live. `KNOWN_ISSUES.md`,
  `Views/LiveCaptureView.swift`.
- **Live Capture output-folder picker** — finalize wrote to `~/Downloads` with no control; add a
  destination picker to the Live Capture pane (with `?` help + gray-out per the settings convention).
  `POTENTIAL_FEATURES.md`.
- **Decide the phone "Finish" button** — it only posts a "ready to process" status to the Mac; it doesn't
  finalize. Empower it (drive the Mac finalize), relabel it, or remove it. `POTENTIAL_FEATURES.md`.

## Longer-term connectivity (bigger, gated)
- **P2 — iOS peer-to-peer transport** (MultipeerConnectivity) to bypass infrastructure Wi-Fi entirely;
  Android has no matching macOS peer, so its bypass stays hotspot/USB. Behind a `SegmentTransport`
  abstraction. `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` → P2.
- **P3 — cloud relay** (works off-site). **Owner privacy decision required** (archival photos transit
  third-party storage); build behind a local `FileRelayTransport` for auth-free testing; preserve the
  durable-queue + idempotency invariant. `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` → P3.
- Reconcile the Bonjour service-name mismatch (iOS `_archiveproc._tcp` vs Mac `_archivecap._tcp`) before
  any mDNS/MultipeerConnectivity discovery work.

---

## Recommended sequence
1. **P0 streaming + P1 connectivity UX together** (same code path; both Tier-2, one review pass).
2. **Wi-Fi + Run C walkthrough** on a trusted network to validate P0/P1 end-to-end on a real phone.
3. Smaller UX fixes (Re-pair coordination, stale status, output picker, Finish-button decision) — batchable.
4. iPhone walkthrough.
5. P2 / P3 transports when the connectivity seam and owner decisions are ready.

**See also:** `LIVE_CAPTURE_CONNECTIVITY_PLAN.md` (detailed phased plan + tests), `KNOWN_ISSUES.md` (bugs),
`POTENTIAL_FEATURES.md` (features/decisions), `LIVE_CAPTURE_ANDROID_TEST.md` (walkthrough script),
`TESTING.md` (Tier-1/Tier-2 automated tests).
