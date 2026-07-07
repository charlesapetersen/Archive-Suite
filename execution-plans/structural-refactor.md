# Execution plan — structural refactor (de-nest + ArchiveCore)

Short-term execution plan (see root `CLAUDE.md` §Docs & backlog convention). Tracked from `SUITE_TODO.md`
§P3. **Delete this file once both items ship.** Paths are repo-root-relative
(`~/Desktop/Claude/Archive Suite`); Reader source = `ArchiveReader/ArchiveReader/Sources/ArchiveReader/`,
Processor source = `ArchiveProcessor/ArchiveProcessor/Sources/ArchiveProcessor/`.

> **P3.1 (Processor Implementation Map) — DONE** in the 2026-07-07 doc-harmony pass (both apps' `CLAUDE.md`
> now carry an Implementation Map). Remaining structural work is the two items below.

## Recommended order
1. **ArchiveCore — read-only model** (the DRY win; moderate risk; moves read/parse code only).
2. **De-nesting** — cosmetic, broad path churn; do it as its own build-verified pass, and **after**
   ArchiveCore if that's happening (so `project.yml` paths churn once). Lowest value.
3. **ArchiveCore — unified write path** — highest risk; deferred behind a full adversarial + scratch-corpus review.

They're independent but both touch `project.yml` path refs, so sequence them (no parallel worktrees on the same files).

---

## De-nest the `App/App` folders  `[ ]`
The merge left `ArchiveReader/ArchiveReader/` and `ArchiveProcessor/ArchiveProcessor/` (outer = relocated
app dir, inner = that app's XcodeGen project dir). Purely cosmetic; **lowest value** — broad, error-prone
path churn. Do only if the nesting bothers; otherwise leave it.

**Approach (per app, one at a time, build-verified, its own commit):** rename the inner project dir to
`macOS`, keeping the Xcode **scheme / target / product name = `ArchiveReader` / `ArchiveProcessor`** (only
the folder changes → bundle IDs & schemes untouched).
```bash
git mv ArchiveReader/ArchiveReader ArchiveReader/macOS      # then the same for ArchiveProcessor
```
- [ ] Update EVERY path ref (grep each app subtree for the old `ArchiveReader/ArchiveReader` / `ArchiveProcessor/ArchiveProcessor` segment): the app's `launch.sh` (`APPDIR=`), `bootstrap.sh`, `.gitignore` path refs, `scripts/test-*.sh` (Processor), CLAUDE Implementation Map paths, **`release/build-suite-dmg.sh`** `APPS` entries, and root `CLAUDE.md`/`AGENTS.md`/`README.md` repo-map lines.
- [ ] Regenerate + build BOTH apps and run Reader's tests; rebuild the combined DMG to confirm the release path resolves.
- **Risk:** med (a missed ref silently breaks a script/the DMG). **Verify:** both build + Reader tests + a DMG build. **Backup:** tag before starting; pure rename, so reset is clean.

## Extract a shared `ArchiveCore` Swift package  `[ ]`
The apps are coupled by the tag/PDF + relay contracts (`SPEC/tag-format.md`, `SPEC/relay-object-format.md`).
The SPECs keep the docs in sync; `ArchiveCore` would keep the *code* in sync — one tag model and (eventually)
one audited writer, so Reader's `TagWriter` + Processor's `MacOSTagger` can't drift. Reader keeps `Core/`
UI-free specifically for this.

### 3a — read-only shared model (safe, high-value)  `[ ]`
- [ ] Create `ArchiveCore/` (SPM package, no UI imports) + `Package.swift`.
- [ ] Move Reader's read-side `Core/` types in: `DocumentTags` (+ facet parsing), `PDFFormatStatus`, `TagSimilarity`, `DuplicateNames`, `FileLink`, `CopyTextCleaner`, `DocumentRuns`, `LibraryFilter`/`LibrarySort` (pure bits). Keep `TagWriter`/`TagReading`/`TagEditing` in the app for now.
- [ ] Point Processor at the same `DocumentTags`/facet + PDF/classification model (its tagger keeps writing; it just references the shared vocabulary/types).
- [ ] Both `project.yml` add `ArchiveCore` as a local package dependency; `xcodegen generate`.
- [ ] Move relevant tests into the package (or keep app-level tests exercising it).
- **Risk:** med (module boundaries, `internal`→`public`, XcodeGen local-package wiring). **No behavior change.** **Verify:** both build; Reader tests green; write-surface lint green.

### 3b — unified audited write path (deferred, high-risk)  `[ ]`
- [ ] Reconcile Reader's `TagWriter` (delta-based, trustworthy-read guard, verify-after-write, inverse-delta undo) with Processor's `MacOSTagger` (`stampUnread`, color labels, batch) into ONE audited writer in `ArchiveCore`, preserving both apps' guarantees (Reader Prime Directive; Processor Tier-2).
- **Risk:** HIGH — the irreplaceable-data write surface for both apps. **Gate:** full multi-agent adversarial review + property/integration tests on **scratch copies only**, on both apps, before shipping. **Defer** until 3a is stable. The SPEC contracts + 3a already capture most of the value.

## State
| Field | Value |
|-------|-------|
| Overall | PLANNED — not started (P3.1 Impl Maps shipped 2026-07-07). |
| Biggest win | ArchiveCore read-only model (3a). |
| Lowest value | De-nesting (cosmetic). |
| Deferred | Unified write path (3b) — safety-critical. |
