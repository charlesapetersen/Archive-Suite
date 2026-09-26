# Tier-2 review: W3.cap-r3-fu12-fu2 committed Clear journal

Baseline: `31afea2` (`fix(processor): W3.cap-r3-fu12-fu2 — coordinate Clear recovery`).

## Confirmed P2 finding

`CaptureSession.commitPreparedClear` wrote a committed capture manifest with an empty photo roster before `finishPreparedClear` moved the source JPEGs to Trash. If the process stopped in that interval and there were no filed groups, `CaptureSession.latestUnprocessedSession` did not select the session: it accepted photos, a nonempty filed-group ledger, or a `prepared` marker, but not a `committed` marker. The originals remained in the visible backup folder, but no Captured-pane recovery path remained. When filed groups existed, the committed manifest was selected, but the empty roster left `finishPreparedClear` with no source URLs to clean up.

## Reproduction

1. Create a scratch session with one received photo and no filed groups.
2. Persist a matching, empty staging manifest for Clear.
3. Persist the capture manifest's `committed` phase, then stop before `finishPreparedClear`.
4. Reopen the session. The old implementation did not select the committed session when its photo roster was empty; with the photo entry present, it also had no filename journal to finish trashing sources.

## Review scope and result

Reviewed the W3.cap-r3-fu12-fu2 Clear transaction, `CaptureSession.commitPreparedClear`, `CaptureSession.finishPreparedClear`, `CaptureSession.latestUnprocessedSession`, and `LiveCaptureProcessor.loadStagingManifest`. The staging-token match, rollback path, failed/unverified-manifest preservation, retry refusal, and `_processed` retention were sound. No permanent data loss was found; the gap left originals Finder-visible but stranded. The regression test should cover launch-time selection and cleanup with no filed groups.

## Resolution

The fix retains the original photo entries in the committed capture manifest until recoverable cleanup is
complete, includes committed journals in `latestUnprocessedSession`, and calls `finishPreparedClear` on launch
before Live/Stage-for-later mode selection. The scratch regression verifies a committed journal with no filed
groups is selected and that launch retires its source and clears the manifest. Processor Debug build,
`test-recovery.sh`, and the three-fixture phone↔Mac E2E all passed after the fix. An independent re-review found
no remaining blocker under the successful atomic staging-manifest write ordering; power-loss rollback across
the separate manifests was not simulated.
