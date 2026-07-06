# Archive Suite — Merge Plan

Bring **Archive Processor** and **Archive Reader** together into a single offering, **Archive Suite**,
as one monorepo with two separate macOS apps, one combined installer, and one place for maintenance.

> **Status (2026-07-06):** Phases **A–E DONE and PUBLISHED.** `main` pushed to `origin` (== local, 0 diverged);
> **release live** at github.com/charlesapetersen/Archive-Suite/releases/tag/`suite-v1.0.0` with
> `ArchiveSuite-1.0.0.dmg` (4.48 MB) attached. Only **Phase F** (redirect + archive the old
> `archiveprocessor` repo) remains — **awaiting owner confirm** (irreversible-ish; plan gates it on the
> release being live, which it now is). Near-term local backlog is in `SUITE_TODO.md`.
>
> This document is the durable, resumable source of truth. Every step is idempotent and re-runnable.

---

## Decisions (locked — 2026-07-05)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Repo model | **Monorepo.** `Archive-Suite` (the repo Reader already points at) holds both apps as sibling subdirs. |
| D2 | Two apps or one | **Two separate apps** — two `.app` bundles, two bundle IDs (`com.archiveprocessor.app`, `com.archivereader.app`). No merge of executables. |
| D3 | Versioning | **Umbrella Suite version, apps keep their own.** The Suite gets its own release line starting **v1.0.0** (the combined DMG). Each app retains an independent internal version (Reader 1.0, Processor continues its line). |
| D4 | Old repo | **Archive after a redirect release.** Cut one final release + README on `charlesapetersen/archiveprocessor` pointing to Archive-Suite, then set it read-only (archived). Existing download links keep resolving. |
| D5 | History | **Preserve both git histories and Processor's tags** via an unrelated-histories merge after path relocation. |
| D6 | Shared code | **Defer heavy extraction.** Ship a shared **tag-format contract doc** now (the real coupling); an `ArchiveCore` Swift package is a later, optional phase. |
| D7 | Installer | **One combined DMG** — both apps + a single `Applications` symlink + "drag both here" artwork + a first-launch (right-click→Open) note. Both apps are ad-hoc signed, not notarized. |
| D8 | Working directive | **Token-efficient feature-add & maintenance is a first-class goal** of bringing the apps together. Agents are encouraged; speed and quality matter; be efficient with context too. See §Guiding directive. |

---

## Guiding directive — token-efficient feature-add & maintenance

Bringing the apps together is not only about structure; it's an opportunity to make **adding features and
maintaining both apps cheaper in tokens** without sacrificing speed or quality. Treat context/token cost as
a real budget alongside wall-clock and correctness. This directive governs how we build the Suite and how we
work in it afterward — encode it into the umbrella `CLAUDE.md` / `AGENTS.md` (Phase C.7) so it's durable.

**Principles**
- **Agents are encouraged, right-sized.** Delegate broad searches / multi-file sweeps / independent work to
  subagents (or a Workflow) so the main thread keeps the *conclusion*, not the file dumps. Match fan-out to
  the task — a few agents for a small change, a larger pool only for genuinely broad audits. Don't spawn
  agents (or re-run a search you already delegated) for a single known-location lookup.
- **Read narrowly, not wholesale.** Prefer scoped reads (the function/region you need), `grep`/Explore to
  locate, and `git log -- <path>` scoped to a subdir. Avoid loading whole files or the *other* app when a
  change touches only one.
- **Structure the repo so a change needs less context.** Per-app authoritative `CLAUDE.md` with an
  Implementation Map, small single-purpose files (continue the god-file split), clear ownership lanes, and a
  single shared contract (`SPEC/tag-format.md`) mean an agent can load one app + one spec, not everything.
- **DRY docs and tooling.** Umbrella-plus-per-app docs with no duplicated prose, one shared launch/icon/
  bootstrap path — so nobody spends tokens re-deriving or reconciling divergent copies.
- **Isolate work with worktrees + scoped agents** (per [[AGENTS.md]] lanes) so parallel work doesn't force
  one context to hold both apps at once.
- **Batch & cache.** Issue independent tool calls together; keep edits surgical (Edit over full rewrites) so
  the harness's file-state tracking and prompt cache stay warm.
- **Guardrail:** efficiency never overrides correctness or the Reader Prime Directive (file safety). When in
  tension, quality wins — but reach for the *cheapest path that fully meets the bar*, not the most exhaustive
  one by default.

---

## Current state  (Reader re-verified 2026-07-06)

> Both sides re-verified **2026-07-06** and confirmed merge-ready (Phase 0 satisfied on both). See each entry.

**Archive Processor** — `~/Desktop/Claude/Archive Processor`
- Remote: `git@github.com:charlesapetersen/archiveprocessor.git` (own repo). Mature: **v3.8.2**, tags v3.3.0→v3.8.2.
- macOS SwiftUI app (Swift 6, XcodeGen `project.yml` authoritative, `.xcodeproj` gitignored) + **iOS** companion (`ArchiveCaptureiOS/`) + **Android** companion (`ArchiveCapture/`).
- Release flow (in memory `release-process`): xcodegen → xcodebuild Release → stage `.app` + `ln -s /Applications` → `hdiutil` DMG → `gh release`. Ad-hoc signed (`CODE_SIGN_IDENTITY "-"`), not notarized.
- Multi-agent ready (worktrees, `AGENTS.md`). Bundle prefix `com.archiveprocessor`. `launch.sh` + `bootstrap.sh`
  verified relocation-safe (each `cd`s to its own dir; `launch.sh` uses relative `APPDIR="ArchiveProcessor"`;
  `bootstrap.sh` runs `xcodegen` for every `project.yml` it `find`s — so macOS + iOS regenerate after the move).
- ✅ **Ready 2026-07-06:** working tree CLEAN + fully pushed; `pre-suite-merge` tagged + pushed (`c7ecc00`).
  Build-verified this session on **macOS + Android + iOS**. 34 commits since the `v3.8.2` tag — automated test
  suites (`scripts/test-smoke.sh`, `test-tier2.sh` + `tier2_assert.py`), Live Capture **per-capture streaming**
  + connectivity diagnostics, and walkthrough/plan docs — all committed. (Streaming is build-verified +
  Tier-2-reviewed with the one critical data-loss race already guarded; its on-device Wi-Fi/Run C behavior is
  verified next session — **non-blocking** for this structural merge, and can happen in the monorepo.)

**Archive Reader** — `~/Desktop/Claude/Archive Reader`  *(re-verified 2026-07-06)*
- Remote: **already** `https://github.com/charlesapetersen/Archive-Suite.git` (the intended monorepo), Reader at repo root. DMG tooling not yet (Phase D). Now tagged **`pre-suite-merge`** → `1d21190` (revert point, pushed).
- macOS SwiftUI app (same stack). Sandboxed. Safety-first: never mutates the corpus; only Finder tags via one audited `Core/TagWriter.swift`. Bundle prefix `com.archivereader`.
- Feature state: v1 **+ UI Batch-2 shipped** — navigable folder-tree sidebar, smart folders (create/apply/rename/delete), corpus-wide tag rename, and an **inline NSTokenField tag editor** with autocomplete. **109 tests + write-surface lint green.** `Core/` stays UI-free — a good `ArchiveCore` foundation (D6/G).
- `launch.sh` and `bootstrap.sh` verified relocation-safe (cd to own dir + relative `APPDIR="ArchiveReader"` / relative `find project.yml`), so they keep working after Phase A's move into `ArchiveReader/ArchiveReader/`.
- README already frames Processor as its sibling and anticipates "Archive Suite."
- ✅ **Working tree CLEAN and fully pushed** (`main` = `origin/main`). Phase 0.1–0.4 satisfied on the Reader side.
- Open (non-blocking, carries into the monorepo): GUI-verify the inline editor's blur-vs-Return fragment behavior; remove the scratch test-tag `InlineTest` left on `Batch-A/00001` during testing.

**No bundle-ID or path collisions.** Both gitignore `build/`, `*.xcodeproj/`, `.maintenance/`, `Test files/`. `launch.sh` in each is a near-mirror; `scripts/makeicon.swift` is near-duplicated.

---

## Target structure

```
Archive-Suite/                       # the repo Reader already points at
├── README.md                        # SUITE umbrella — presents both apps as one offering
├── CLAUDE.md                        # SUITE umbrella — repo map, conventions, release; links per-app CLAUDE.md
├── AGENTS.md                        # SUITE umbrella — multi-agent lanes across both apps
├── SUITE_MERGE_PLAN.md              # this doc (stays at root)
├── SPEC/
│   └── tag-format.md                # shared contract: the Finder-tag vocabulary Processor writes & Reader reads
├── release/
│   ├── build-suite-dmg.sh           # builds BOTH apps Release + one combined DMG + gh release
│   └── dmg-background.png           # "drag both → Applications" artwork (+ first-launch note)
├── ArchiveReader/                   # ← entire current Reader repo root, relocated here
│   ├── ArchiveReader/               #   the XcodeGen project dir (project.yml, Sources/, Tests/)
│   ├── CLAUDE.md README.md AGENTS.md PLAN.md STATUS.md launch.sh bootstrap.sh scripts/ ...
│   └── (build/, .xcodeproj, .maintenance/ — gitignored, regenerated locally)
├── ArchiveProcessor/                # ← entire Processor repo root, merged in WITH history
│   ├── ArchiveProcessor/            #   the XcodeGen project dir
│   ├── ArchiveCapture/              #   Android companion
│   ├── ArchiveCaptureiOS/           #   iOS companion
│   ├── CLAUDE.md README.md AGENTS.md launch.sh bootstrap.sh scripts/ ...
│   └── (build/, .xcodeproj — gitignored)
└── ArchiveCore/                     # OPTIONAL / deferred (D6) — shared UI-free package
```

**On the double-naming** — `ArchiveReader/ArchiveReader/` and `ArchiveProcessor/ArchiveProcessor/` (outer =
the relocated repo root; inner = that app's XcodeGen **project dir**, which each standalone repo already
names after the app). It's a harmless byproduct of nesting an app-named project dir under an app-named
product dir — builds/tooling are unaffected (each `launch.sh` uses a relative `APPDIR`, so the move doesn't
change it). This merge **keeps it as-is (zero-risk)** — the Reader side is already verified against these
paths, and re-touching it just to de-nest would add risk to the migration for a purely cosmetic gain.

It is *cosmetic, not useful.* If the nesting bothers you, flatten it as a **separate, per-app,
build-verified cleanup — ideally AFTER the merge** (so it never entangles the migration): in each app,
`git mv <App>/<App> <App>/macOS`, then update only that app's `launch.sh` `APPDIR`, its `.gitignore`/doc
path refs, and (Processor) the `scripts/test-*.sh` paths. The Xcode **scheme / target / `.app` name stay
`ArchiveProcessor` / `ArchiveReader`** — only the folder is renamed, so schemes and bundle IDs are untouched.
Deferred by default.

---

## Phases

Legend: `[ ]` todo · `[x]` done · `[~]` in progress. Update the checkbox **and** the State table as you go.

### Phase 0 — Safety net & prerequisites  `[x]`
Do NOT start the merge with dirty trees or without a backup.

> **BOTH sides DONE (2026-07-06):** Reader — tree clean + pushed, `pre-suite-merge` @ `1d21190`. Processor —
> tree clean + pushed, `pre-suite-merge` @ `c7ecc00` (its `ContentView.swift` + `ProcessFilesTestDriver.swift`
> and the 34 commits since `v3.8.2` are all committed). 0.5 tooling confirmed. Phase 0 satisfied on both
> sides — safe to start Phase A on owner go-ahead.

- [x] 0.1 Land or stash in-flight work: Reader sidebar work **committed**; Processor's `ContentView.swift` +
  `ProcessFilesTestDriver.swift` (and all this-session work) **committed + pushed**.
- [x] 0.2 Confirm clean trees: `git status` clean in **both** repos.
- [x] 0.3 Push both repos to their remotes (backup off-machine).
- [x] 0.4 Tag a revert point in **each** repo: Reader `pre-suite-merge` @ `1d21190`, Processor @ `c7ecc00` (both pushed).
- [x] 0.5 Confirm tooling: `xcodegen` present (builds pass); `gh` = `/opt/homebrew/bin/gh` (bare `gh` is a shadowing Python tool — see memory `release-process`).

### Phase A — Relocate Reader into `ArchiveReader/`  `[x]`
> **DONE 2026-07-06** (commit `59e57e9` on `main`). Tracked files under `ArchiveReader/`; history preserved (`--follow`); Reader Release build green in new location. Gitignored `.maintenance/` + `Test files/` left at root (now covered by the new root `.gitignore`).
Run in the Suite repo root (`~/Desktop/Claude/Archive Reader`). Everything moves **except** `.git` and this plan.
```bash
cd ~/Desktop/Claude/"Archive Reader"
git switch -c suite-merge                 # do the merge on a branch; merge to main at the end
mkdir -p .suite-stage
# null-delimited so any tracked top-level name with spaces is handled safely (Reader's current names
# have none, but this keeps the step robust). `.suite-stage` is untracked, so ls-tree won't list it.
while IFS= read -r -d '' p; do
  [ "$p" = "SUITE_MERGE_PLAN.md" ] && continue
  git mv "$p" .suite-stage/
done < <(git ls-tree -z --name-only HEAD)
git mv .suite-stage ArchiveReader
git commit -m "Suite: relocate Archive Reader into ArchiveReader/ subdir"
```
- [ ] A.1 Tracked files relocated under `ArchiveReader/` (root now: `.git`, `ArchiveReader/`, `SUITE_MERGE_PLAN.md`).
- [ ] A.2 Regenerate build state in the new location: `cd ArchiveReader && ./bootstrap.sh` (or `xcodegen generate`), then `./launch.sh` builds & runs. (Gitignored `build/`, `.xcodeproj`, `.maintenance/` don't move with `git mv` — regenerate; delete any stale copies left at the old root.)

### Phase B — Merge Processor in WITH full history  `[x]`
> **DONE 2026-07-06** (relocate `6cf7be3` on the ex-Processor `suite-relocate` branch; merge `8e3a6fc` on `main`). `--allow-unrelated-histories` merge; companions (Android `ArchiveCapture/` + iOS `ArchiveCaptureiOS/`) present; Processor history + all tags `v1.0.0`–`v3.8.2` carried in; **both apps Release-build green in the monorepo** (B.3). ⚠️ The carried-in bare `v1.0.0` tag means the Suite release tag is namespaced **`suite-v1.0.0`** (see Phase E / D3).
First relocate Processor's files inside its OWN repo (on a branch), then merge that branch into the Suite repo. Because Reader is under `ArchiveReader/` and Processor under `ArchiveProcessor/`, there are **no path conflicts**.
```bash
# 1) In the Processor repo — relocate onto a branch
cd ~/Desktop/Claude/"Archive Processor"
git switch -c suite-relocate
mkdir -p .suite-stage
# null-delimited (matches Phase A) so any tracked top-level name is handled safely; `.suite-stage` is
# untracked, so ls-tree won't list it.
while IFS= read -r -d '' p; do git mv "$p" .suite-stage/; done < <(git ls-tree -z --name-only HEAD)
git mv .suite-stage ArchiveProcessor
git commit -m "Suite: relocate Archive Processor into ArchiveProcessor/ subdir"

# 2) In the Suite repo — pull it in preserving history + tags
cd ~/Desktop/Claude/"Archive Reader"
git remote add processor ~/Desktop/Claude/"Archive Processor"
git fetch processor --tags
git merge --allow-unrelated-histories processor/suite-relocate \
  -m "Suite: bring in Archive Processor with full history under ArchiveProcessor/"
git remote remove processor
```
- [ ] B.1 `ArchiveProcessor/` present in the Suite repo with its subtree (incl. Android + iOS companions).
- [ ] B.2 History preserved: `git log --oneline -- ArchiveProcessor/` shows the v3.x commits; `git tag` lists v3.3.0→v3.8.2. (These are Processor's history; the new umbrella line is separate — D3.)
- [ ] B.3 Both apps build from the monorepo: `cd ArchiveProcessor && ./bootstrap.sh && ./launch.sh`; likewise Reader.
- Alternative if preferred: `git subtree add --prefix=ArchiveProcessor <remote> main`. The relocate-then-merge path above is chosen for cleaner full-history + tags.

### Phase C — Suite scaffolding (umbrella docs + shared tooling)  `[x]`
> **DONE 2026-07-06** (commit `5366aee` on `main`). All of C.1–C.7 landed: root `README.md`, `CLAUDE.md`, `AGENTS.md`, `.gitignore`, `SPEC/tag-format.md`, and the `./launch.sh reader|processor` dispatcher. The token-efficiency directive is encoded into the umbrella `CLAUDE.md`/`AGENTS.md`. **`SPEC/tag-format.md` surfaced real (pre-existing) contract-drift to fix later** — see §Follow-ups.
- [ ] C.1 Root `README.md` — the offering: what the Suite is; the **workflow** (Processor *captures/OCRs/tags* → Reader *reads/triages* the tagged PDFs); install both; per-app links.
- [ ] C.2 Root `CLAUDE.md` — umbrella: repo map, monorepo conventions, release process, links to each app's `CLAUDE.md` (which stay authoritative for their app). Fold in the `release-process` memory (gh path gotcha, DMG steps).
- [ ] C.3 Root `AGENTS.md` — multi-agent lanes now span two apps + companions; per-worktree `-derivedDataPath ./build/DD`; shared hotspots (`SPEC/tag-format.md`, `project.yml` files, release script).
- [ ] C.4 Root `.gitignore` — suite-level artifacts (`release/*.dmg`, `/build/`). Per-app `.gitignore` files remain in each subdir (they already cover build/xcodeproj/.maintenance/Test files/Android/etc.).
- [ ] C.5 `SPEC/tag-format.md` — the shared contract (D6): the exact Finder-tag vocabulary both apps depend on — subject / date facets / priority (P7–P10) / color / read-state, and the chronological convention (`Year` / `MM Month` / `Day N`, medieval-safe, Date-Uncertain italic year). Cite it from both apps' CLAUDE.md as the single source of truth so the writer (Processor) and reader (Reader) never drift.
- [ ] C.6 (Opportunistic, low-risk) Shared tooling dedup: a root `launch.sh` dispatcher (`./launch.sh reader|processor` → delegates to each app's `launch.sh`); note the near-duplicate `scripts/makeicon.swift` as a future single-source. Keep per-app `launch.sh` working. (Also serves §Guiding directive — one shared path, no divergent copies.)
- [ ] C.7 Encode the §Guiding directive (token-efficient feature-add & maintenance) into the umbrella `CLAUDE.md` and `AGENTS.md`: agents right-sized, scoped reads, per-app context isolation via ownership lanes + worktrees, DRY docs/tooling, batch/cache, correctness-and-safety-first guardrail. Make each per-app `CLAUDE.md` carry a tight Implementation Map so an agent loads one app + one spec, not the whole repo.

### Phase D — Combined installer (one DMG)  `[x]`
> **DONE 2026-07-06** (in commit `5366aee`). `release/build-suite-dmg.sh` (+ `make-dmg-background.swift` → committed `dmg-background.png`) builds both Release apps, stages both `.app`s + one `Applications` symlink + the background, styles the Finder window (best-effort, plain-DMG fallback), and produces `/tmp/ArchiveSuite-<ver>.dmg`. **Built + smoke-tested `/tmp/ArchiveSuite-1.0.0.dmg` (4.3M):** both apps present + executable, `Applications`→`/Applications`, ad-hoc signed, layout persisted (D.3, verified without launching GUIs).
- [ ] D.1 `release/build-suite-dmg.sh`: for each app — `xcodegen generate` then `xcodebuild -scheme <App> -configuration Release -derivedDataPath ./build/rel build`; stage **both** `ArchiveProcessor.app` + `ArchiveReader.app` into one temp dir; add `ln -s /Applications`; add `release/dmg-background.png`; set window layout + icon positions (AppleScript/`.DS_Store`); `hdiutil create -volname "Archive Suite <ver>" -srcfolder <stage> -ov -format UDZO /tmp/ArchiveSuite-<ver>.dmg`.
- [ ] D.2 `release/dmg-background.png`: two app icons → arrow → **Applications**, "drag **both** apps here," plus a first-launch note (right-click → Open; ad-hoc signed / not notarized).
- [ ] D.3 Smoke-test the DMG: mount, drag both to a scratch `/Applications`-like dir, launch each once.
- Guidance goal met: the DMG guides users to drop **both** apps directly into Applications in one motion.

### Phase E — First Suite release (suite-v1.0.0)  `[x]  PUBLISHED 2026-07-06`
- [x] E.1 Merge `suite-merge` → `main` (fast-forward) and **pushed** — `origin/main` @ `59f2b5b`, 0 diverged.
- [x] E.2 Combined DMG built + smoke-tested (`/tmp/ArchiveSuite-1.0.0.dmg`, 4.48 MB).
- [x] E.3 Tag `suite-v1.0.0` created + **pushed** (`suite-` prefix — bare `v1.0.0` is Processor's historical tag).
- [x] E.4 **Release LIVE:** `gh release create suite-v1.0.0` with the DMG → github.com/charlesapetersen/Archive-Suite/releases/tag/suite-v1.0.0 (published, asset `uploaded`).

### Phase F — Deprecate the old Processor repo (D4)  `[ ]  DEFERRED — do only AFTER the Suite release is live online`
- [ ] F.1 On `charlesapetersen/archiveprocessor`: final commit updating README → "Archive Processor now ships as part of **Archive Suite**: <link>." Optional final release note pointing to the Suite DMG.
- [ ] F.2 Archive the repo (read-only): `/opt/homebrew/bin/gh repo archive charlesapetersen/archiveprocessor`.
- [ ] F.3 Update local remotes/notes: the `~/Desktop/Claude/Archive Processor` clone is now historical — future work happens in the Suite monorepo's `ArchiveProcessor/`. (Consider removing the standalone clone once comfortable, or keep as an archived backup.)

### Phase G — OPTIONAL later: shared `ArchiveCore` package  `[ ]`
- [ ] G.1 Only if a concrete shared Swift type earns it (e.g. the tag read/write model). Reader already keeps `Core/` UI-free — good foundation. Extract a UI-free SPM package `ArchiveCore/` consumed by both apps' `project.yml`. Defer until the `SPEC/tag-format.md` contract shows a type worth centralizing; the doc contract (C.5) captures most of the value at a fraction of the cost.

---

## Maintenance-in-one-place wins (why the monorepo)
- One repo, one issue tracker, one releases page, one CI target.
- Umbrella docs at root + authoritative per-app docs — no cross-repo drift.
- Shared contract (`SPEC/tag-format.md`) keeps the writer/reader tag vocabulary in lockstep.
- Shared tooling (launch dispatcher, icon script, bootstrap) dedupes near-identical scripts over time.
- One combined DMG = one thing to build, sign, and hand to a user.

## Risks & mitigations
- **History loss** → Phase B merges with `--allow-unrelated-histories` after relocation; `pre-suite-merge` tags (0.4) make it revertible; work happens on the `suite-merge` branch.
- **Dirty-tree corruption** → Phase 0 gates on clean trees + pushed backups.
- **Broken builds after move** → each app's `launch.sh`/`bootstrap.sh` regenerates XcodeGen locally; verify both build before merging to main (B.3).
- **Gatekeeper on unnotarized apps** → first-launch note baked into the DMG art (D.2); revisit notarization if store distribution is ever pursued (Processor Phase 4 is owner-deferred).
- **Existing Processor users** → redirect release + archived (not deleted) repo (Phase F) keeps their links alive.

## Resume (durability against interruption)
1. Open this file. Read the **State** table below and the phase checkboxes.
2. Resume at the first unchecked step; each step is idempotent (re-running a completed `git mv`/scaffold step is a no-op or safely re-does).
3. If mid-merge and unsure: `git status`, `git log --oneline -5`, and compare against the phase you were on. To abort cleanly: `git merge --abort` (during Phase B) or reset the `suite-merge` branch to `pre-suite-merge`.
4. Nothing is destructive until Phase E (push to main) and Phase F (archive old repo) — both explicitly owner-gated.

## Resume when back online (the only remaining work — all uploads)

Local `main` already holds the full merge + scaffolding; the DMG + `suite-v1.0.0` tag exist locally.
Run these on good connectivity (in `~/Desktop/Claude/Archive Reader`):

```bash
# 1) Push the merged history + tags (~23 MB first push).
git push origin main
git push origin suite-v1.0.0
git push origin --tags            # optional: also publishes Processor's preserved v1.0.0–v3.8.2 tags

# 2) Publish the release with the combined DMG (rebuild if /tmp was cleared: release/build-suite-dmg.sh 1.0.0).
/opt/homebrew/bin/gh release create suite-v1.0.0 /tmp/ArchiveSuite-1.0.0.dmg \
  --repo charlesapetersen/Archive-Suite --title "Archive Suite 1.0.0" \
  --notes-file /path/to/notes    # draft at scratchpad/suite-release-notes.md

# 3) THEN Phase F — redirect + archive the old repo (only after the Suite release is verified live):
#    edit archiveprocessor README → point to Archive-Suite; then:
/opt/homebrew/bin/gh repo archive charlesapetersen/archiveprocessor
```
If `/tmp/ArchiveSuite-1.0.0.dmg` is gone (reboot), regenerate with `release/build-suite-dmg.sh 1.0.0`.

## Follow-ups surfaced during the merge (not blocking; pre-existing, carry into the monorepo)
`SPEC/tag-format.md` reconciled Processor's actual tag-writing code against Reader's documented "Verified
Facts" and found drift worth fixing in **Archive Reader** (all handled safely today, but should be hardened):
1. **Page-2 filename line:** Reader assumes `<basename>.jpg` and that the line is present; Processor writes the
   *verbatim* original name (`.png/.tiff/.heic` possible) and **omits** the line when the source name is nil.
   Reader must not hard-assume the extension or presence.
2. **Year width:** Reader's doc says "4 digits"; its parser accepts **3–4** (Processor emits 4). Doc-only nit.
3. **`Box`/`Folder`/`OCR Failed` as literal subject tags:** emitted by Processor, not enumerated in Reader's
   facts (Reader classifies them as subjects — harmless, now documented in the spec).
4. **Sort-key "signed for BC":** aspirational — no BC/negative-year token exists in the vocabulary.

## State
| Field | Value |
|-------|-------|
| Overall | **Executed A–E locally; uploads deferred (owner on a plane).** Nothing remote changed; nothing destructive ran. |
| Local `main` | `5366aee` — full merge + scaffolding; **120 commits ahead of `origin/main` (unpushed)**; `suite-v1.0.0` tag local-only |
| Artifacts | `/tmp/ArchiveSuite-1.0.0.dmg` (4.3M, smoke-tested); both apps Release-build green in the monorepo |
| Remaining | Push `main` + tags; `gh release create suite-v1.0.0` w/ DMG; then Phase F (archive old repo). All network — see §Resume when back online. |
| Revert | `git reset --hard pre-suite-merge` (Reader) restores the pre-merge tip; `origin/main` is already the pre-merge state |
