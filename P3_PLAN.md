# Archive Suite — P3 (structural) plan

Durable, resumable plan for the three P3 items in `SUITE_TODO.md`: give Processor a tight Implementation
Map, de-nest the `App/App` folders, and extract a shared `ArchiveCore` package. **Planning only — not
executed.** Paths are repo-root-relative (`/Users/<user>/Desktop/Claude/Archive Suite`); Reader source =
`ArchiveReader/ArchiveReader/Sources/ArchiveReader/`, Processor source =
`ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/`.

## Recommended order & rationale
1. **P3.1 Processor Implementation Map** — trivial, doc-only, zero risk, immediate token-efficiency payoff. Do first.
2. **P3.3a ArchiveCore — read-only model** — the real DRY win; moderate risk; safe because it moves read/parse code only.
3. **P3.2 De-nesting** — cosmetic, broad path churn; do it as its own build-verified pass, and **after** ArchiveCore if that's happening (so paths churn once). Lowest value.
4. **P3.3b ArchiveCore — unified write path** — highest risk (safety-critical); deferred until there's capacity for a full adversarial + scratch-corpus review. Optional.

Do 1 anytime. Decide 2 vs 3 based on appetite; they're independent but both touch `project.yml` path refs, so sequence them (don't run in parallel worktrees on the same files).

---

## P3.1 — Processor Implementation Map (doc-only)  `[ ]`
**Why:** the token-efficiency directive (umbrella `CLAUDE.md` §Working directive, C.7) wants each per-app
`CLAUDE.md` to carry a tight per-file map so an agent loads *one app + one spec*, not the whole tree.
Reader's `CLAUDE.md` has one ("Implementation map"); **Processor's does not** (it has a Project-Structure
tree + god-file-split notes, but no per-file one-liner map).
- [ ] Survey `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/{Models,OCR,Tagging,Capture,Net,Views}` and add an **"Implementation map"** section to `ArchiveProcessor/CLAUDE.md`, mirroring Reader's format (path → one-line purpose), grouped by folder. Include the companions' key files (`ArchiveCaptureiOS/Sources/…`, `ArchiveCapture/…`) briefly.
- [ ] Cross-check against the god-file split notes already in `CLAUDE.md` (`OCRProcessor+*`, `OCRView+*`) so they agree.
- **Risk:** none (doc). **Effort:** M (survey). **Verify:** doc review; no build impact. **Delegable:** yes (a reader agent surveys + drafts).

---

## P3.2 — De-nest the `App/App` folders  `[ ]`
**Why:** the merge left `ArchiveReader/ArchiveReader/` and `ArchiveProcessor/ArchiveProcessor/` (outer =
relocated app dir, inner = that app's XcodeGen project dir). Purely cosmetic; **lowest-value P3 item** —
broad, error-prone path churn for aesthetics. Do only if the nesting genuinely bothers; otherwise leave it.

**Approach (per app, one at a time, build-verified, its own commit):** rename the inner project dir to
`macOS`, keeping the Xcode **scheme / target / product name = `ArchiveReader` / `ArchiveProcessor`** (only
the folder changes → bundle IDs & schemes untouched).
```bash
git mv ArchiveReader/ArchiveReader ArchiveReader/macOS      # (then the same for ArchiveProcessor)
```
- [ ] Update EVERY path reference (grep each app subtree for the old `ArchiveReader/ArchiveReader` / `ArchiveProcessor/ArchiveProcessor` segment):
  - the app's `launch.sh` (`APPDIR="ArchiveReader"` → `APPDIR="macOS"`) and `bootstrap.sh` (it `find`s `project.yml`, so likely fine — verify),
  - the app's `.gitignore` path refs, `scripts/test-*.sh` (Processor), and any doc/path refs incl. the CLAUDE Implementation Map,
  - **`release/build-suite-dmg.sh`** — the `APPS` project-dir entries (`ArchiveReader/ArchiveReader` → `ArchiveReader/macOS`, same for Processor),
  - root `CLAUDE.md`/`AGENTS.md`/`README.md` repo-map lines and `SPEC`/per-app CLAUDE relative links (`../../SPEC/...` depth is unchanged since it's still two levels — verify).
- [ ] Regenerate + build BOTH apps (`xcodegen generate && xcodebuild … build`) and run Reader's tests; then rebuild the combined DMG (`release/build-suite-dmg.sh <ver> --no-build` won't help — rebuild) to confirm the release path still resolves.
- **Risk:** med (a missed path ref silently breaks a script/the DMG). **Effort:** M. **Verify:** both apps build + Reader tests + a DMG build. **Delegable:** cautiously, with a "grep proves zero stale refs" gate.
- **Backup/revert:** tag before starting; it's pure rename so `git revert`/reset is clean.

---

## P3.3 — Extract a shared `ArchiveCore` Swift package  `[ ]`
**Why:** the two apps are coupled by the tag/PDF contract (`SPEC/tag-format.md`). The SPEC keeps the
*documentation* in sync; `ArchiveCore` would keep the *code* in sync — one definition of the tag model and
(eventually) one audited writer, so Reader's `TagWriter` and Processor's `MacOSTagger` can't drift. Reader
already keeps `Core/` UI-free specifically for this.

### P3.3a — read-only shared model (the safe, high-value half)  `[ ]`
Move the UI-free, **read/parse** domain into a package both apps depend on:
- [ ] Create `ArchiveCore/` (SPM package, no UI imports) with `Package.swift`.
- [ ] Move Reader's read-side `Core/` types in: `DocumentTags` (+ facet parsing), `PDFFormatStatus`, `TagSimilarity`, `DuplicateNames`, `FileLink`, `CopyTextCleaner`, `DocumentRuns`, `LibraryFilter`/`LibrarySort` (the pure bits). Keep `TagWriter`/`TagReading`/`TagEditing` in the app for now (write path — see P3.3b).
- [ ] Point Processor at the **same** `DocumentTags`/facet + PDF/classification model so its *emit* side and Reader's *read* side share one source (Processor's tagger keeps writing; it just references the shared vocabulary/types).
- [ ] Both apps' `project.yml` add `ArchiveCore` as a local package dependency (`packages:` + `dependencies:`); `xcodegen generate`.
- [ ] Move the relevant tests into the package (or keep app-level tests exercising the package).
- **Risk:** med (module boundaries, access levels — `internal` → `public`; XcodeGen local-package wiring). **No behavior change.** **Effort:** L. **Verify:** both apps build; Reader tests green; write-surface lint green (write path unchanged).

### P3.3b — unified audited write path (deferred, high-risk)  `[ ]`
- [ ] Reconcile Reader's `TagWriter` (delta-based, trustworthy-read guard, verify-after-write, inverse-delta undo) with Processor's `MacOSTagger` (`stampUnread`, color labels, batch) into ONE audited writer in `ArchiveCore`, preserving BOTH apps' guarantees (Reader Prime Directive: only tag edits, never bytes/location; Processor Tier-2).
- **Risk:** HIGH — this is the irreplaceable-data write surface for both apps. **Gate:** full multi-agent adversarial review + property/integration tests on **scratch copies only** (never the corpus), on both apps, before shipping. **Defer** until P3.3a is stable and there's capacity for that review. The `SPEC` contract + P3.3a already capture most of the value.

---

## Also outstanding (not P3 — recorded so it's not lost)
**P2 — Processor Live-Capture cluster (device/GUI-verification-gated).** Implementable now but, like the
document-viewer bugs, these are runtime/behavior fixes that need a live session (several need a **paired
phone** or a real OCR run) to confirm — so they're best done in a session where Live Capture can be driven,
not landed blind. Items: connectivity UX (legible Wi-Fi failure + preflight + Android QR-latch), keep OCR
status live while the tag card is open, re-pair coordination, output-folder picker (Tier-2: output path),
streaming residuals, `KNOWN_ISSUES #2` (merged-doc loose originals; Tier-2 file-move), behavior-preserving
de-dups, and no-API local features (profiles/presets, global shortcuts). Non-device-gated subset that could
still be done heads-down: the de-dups, the output-folder picker (careful — Tier-2), and no-API local
features. **Blocked entirely:** Android `targetSdk 34→36` (needs an installed Android SDK + AGP upgrade).

## State
| Field | Value |
|-------|-------|
| Overall | PLANNED — not started. |
| Do-first | P3.1 (Processor Implementation Map) — zero-risk doc win. |
| Biggest win | P3.3a (ArchiveCore read-only model). |
| Lowest value | P3.2 (de-nesting) — cosmetic, broad path churn. |
| Deferred | P3.3b (unified write path) — safety-critical, needs adversarial + scratch-corpus review. |
