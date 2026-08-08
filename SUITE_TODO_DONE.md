# Archive Suite — completed items

Shipped work, moved out of [`SUITE_TODO.md`](SUITE_TODO.md) on 2026-08-01 so the live queue is readable
(`execution-plans/tracker-consolidation.md`, finding F3: 47 open items were buried among 160 done ones in a
single 3,580-line file).

**This is a record, not a to-do list. Nothing here is actionable.** It is kept rather than deleted for two
reasons: the completion notes cite the commits that shipped each item, and several carry the *reasoning* for
why a later change may or may not revisit that code.

⚠️ **`ops/autonomous/next-queue-item.sh` reads this file for dependency state.** A tag it cannot find reads as
NOT done, so an item archived here would otherwise permanently block anything declaring
`(blocked-on: <that tag>)` — the dead end `W3.cap-r4` once created for `W17.stg1`. Scanned for state only;
never a source of queue candidates. **Do not rename or move this file without updating that script.**

Grouped under the `SUITE_TODO.md` section each item was completed in.


## Signing + TCC consent (owner, 2026-08-07)

- [x] **W28.cert-fu1 — the GUI-VM lane builds in a guest with no keychain, so certificate signing RED'd it.
  ✅ DONE** — this commit. **A regression `W28.cert` shipped and this session missed**, because host builds
  were verified and the VM lane was not considered: the guest runs its own `xcodebuild`, and the
  `"Archive Suite Dev"` cert lives only in the HOST login keychain. Every target failed with
  *"No certificate matching 'Archive Suite Dev' found"* — for `reader` **and** `notes`, both attempts. Worse
  than a plain break: `gui-vm-gate.sh` classifies that as a **reproducible UITest failure → RED → park**, so
  a *build-configuration* error was being reported as a product test failure. It was invisible from the host
  (host `reader`/`notes`/`processor-build` steps all pass), which is exactly why it slipped.
  **Fix:** the three guest `xcodebuild` invocations (one in `ops/autonomous/gui-vm-gate.sh`, two in
  `ops/gui/vm-gui-runner.sh`) now pass `CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`, so **the guest stays
  ad-hoc while the host keeps the cert** — restoring precisely the configuration this lane was green on.
  That is the right split, not a workaround: the cert exists *only* to make a TCC grant survive a rebuild,
  and a disposable off-screen VM has no durable grants to keep. ⛔ **Do NOT "fix" this by installing the
  cert into the VM** — that couples a throwaway image to host keychain secrets and breaks again on every VM
  rebuild.
  ⚠️ **Two diagnosis traps hit on the way, both already filed:** `W27.gatetail` — the gate's
  *"failing output (tail)"* showed `status-proof`'s 36-passed output, not `gui-vm`'s, so the RED looked
  self-contradictory; and the per-step output goes to a `mktemp` that is gone by the time you read the
  summary, so the real error only appears by re-running the step directly. Evidence for a VM failure is kept
  at `~/.tart-mirror/vm-artifacts/gui-vm-<app>-attempt{1,2}.log`.

- [x] **W28.trackerbudget — the shipped-rollup prose moved OUT of the open tracker, because DONE was not a
  superset of it. ✅ DONE** — this commit. `SUITE_TODO.md` had reached **98 % of its 200 KB budget (3.2 KB of
  headroom)**, so the next entry of any size would have turned `context-budget.sh` RED and parked the daemon —
  a gate failure caused by *writing a tracker entry*. There were **zero `[x]` items** to drain (63 genuinely
  open, convention already followed), so the usual remedy did not apply. The drainable material was the six
  `✅ **W26.x — SHIPPED …; full entry in SUITE_TODO_DONE.md**` rollups.
  ⚠️ **They could NOT simply be deleted, and checking that was the whole job:** five of six distinctive
  phrases in them appeared **zero** times in `SUITE_TODO_DONE.md` — "full entry in DONE" was **false**, and
  the durable engineering corrections (`W26.symroot`'s *"the item's own prescription was measured WRONG, and
  that correction is the durable part"*, `W26.symroot-fu1`'s *"Not touched, deliberately"*, `W26.walk2`'s
  0/11-Spotlight VM measurement) existed **only** in the open tracker. So they were **moved verbatim**, not
  compressed — `SUITE_TODO_DONE.md` is not in the budget list, which is exactly where shipped prose belongs.
  Result **196,741 → 183,699 bytes (98 % → 91 %)**, headroom 3.2 KB → 16.3 KB, nothing reworded or dropped.
  Verified: every phrase still present, `check-tracker-sync.sh` ✓ *"agree on all 64 shared items"*, and
  `next-queue-item.sh` still resolves all seven affected tags as DONE (one `[x]` line each in DONE, zero
  conflicting `[ ]` lines) — the resolver reads **checkbox** lines, and the `✅` rollups were never checkbox
  lines, so pointer text was never load-bearing for dependency gating.
  ⚠️ **Note for whoever repeats this:** the `✅` blocks are **consecutive with no blank line between them**,
  so "block ends at the next blank line" silently merges five of them into one. That is how this pass moved
  `W26.idx`/`fsev-fu2`/`symroot`/`symroot-fu1` along with `walk2` and left them without a pointer line. Their
  prose is intact in DONE and all four still resolve as DONE, so nothing broke — but split on the `✅` marker,
  not on blank lines.

- [x] **W28.fsevhang-bound — the untimed harness semaphore behind the gate hang is now bounded. ✅ DONE** —
  this commit. Defence-in-depth for **`W26.fixturehang`** (still open, still HIGH — see its UPDATE block for
  the confirmed leaked-`ARUITestRootPath` trigger, the 3/3-hang vs 12/12-pass measurement, and the ruled-out
  suspects). `BlockingCorpusWatcher.start()`'s `gate.wait()` was **unbounded**, which is what turned the
  fixture lane's main-thread `open(2)` into an *unrecoverable* stall: no failure, no test name, `xcodebuild
  test` never returns, `step()` never reports, and the daemon burns `GATE_MAXRUN` then parks blaming build
  time. It is now bounded (30 s, injectable) and records `timedOutWaitingForGate`; `BlockingWatcherLog`
  additionally releases a watcher appended **after** `releaseAll()` snapshotted, closing the late-arrival
  race. Both are proved by `BlockingWatcherHarnessTests` in ~0.26 s using the injectable bound — a guard
  nothing exercises being the failure mode this repo already learned from the write-surface lint.
  ⚠️ **This does not fix the root cause** and must not be read as closing `W26.fixturehang`: the main-thread
  `FSEventStreamCreate` and the process-wide `isFixtureRoot` default are untouched. It only guarantees the
  pathology can no longer hang the gate silently. Reader suite 376 tests / 0 failures.

- [x] **W28.cert — the suite signs with a real certificate, so a TCC grant survives a rebuild. ✅ DONE** —
  this commit. **The symptom the owner reported:** "Archivereader.app would like to access files in your
  Desktop folder" over and over. **The cause was not the Desktop** — it was `CODE_SIGN_IDENTITY "-"`. An
  ad-hoc signature's designated requirement is pinned to the **cdhash**, which changes on every rebuild, so
  macOS saw each build as a different program and discarded every TCC grant. With the daemon rebuilding all
  day that is a consent dialog per build, forever; clicking Allow could never stick. Measured on the three
  stale copies then on disk: three different cdhashes, hence three separate TCC clients.
  **Fix:** a local **self-signed** code-signing cert (`"Archive Suite Dev"`, `ops/setup-signing-cert.sh`,
  10-year, user trust store only, key at `~/.local/share/archive-suite-signing/`). The requirement becomes
  `identifier "com.archivereader.app" and certificate leaf = H"e34232a4…"` — **proven byte-identical across
  two builds with different cdhashes**, which is the whole point and the acceptance test to re-run if this is
  ever touched (`codesign -d -r-`, twice, diff).
  Applied at `settings.base` in all three macOS `project.yml` files so the app **and both test bundles** share
  one identity — `com.archivereader.uitests.xctrunner` is its own TCC client and would otherwise keep
  prompting on its own account. `CODE_SIGNING_REQUIRED: NO` removed (a signing failure should be loud).
  **The iOS companion deliberately stays ad-hoc** — a macOS self-signed cert is not valid for iOS, and it is
  PARKED.
  ⚠️ **The trap, which cost a full debugging round: a self-signed cert has NO Team ID.**
  `ENABLE_HARDENED_RUNTIME: YES` enables **library validation**, which loads only code sharing the main
  binary's Team ID — and *no team does not satisfy same team*. Xcode 16 puts a Debug build's code in
  `<App>.debug.dylib` inside the bundle, so the app died at launch with `SIGABRT`
  (`DYLD … Library not loaded: @rpath/ArchiveReader.debug.dylib … (code signature…)`) and took **every
  app-hosted test** with it. This is the **W7.1 UITest finding generalised**: ad-hoc sidestepped library
  validation; a cert without a team walks into it. Hence the **Debug-only** entitlements now carry
  `com.apple.security.cs.disable-library-validation` + `com.apple.security.get-task-allow` (XCTest
  injection). **Release keeps hardened runtime AND strict validation** — never add either key to a Release
  entitlements file. Processor gets neither: its entitlements are xcodegen-generated from
  `entitlements.properties`, which is **not** config-scoped, so adding them would ship debugger-attach in
  Release; it has no test target that needs them. The UITest targets keep `ENABLE_HARDENED_RUNTIME: NO`
  (W7.1) — plausibly now unnecessary, but not re-tested, so the known-good setting stays.
  **Two process lessons worth keeping, both learned by getting them wrong first:**
  (i) `security import` of an **empty-password** PKCS#12 fails with "The user name or passphrase you entered
  is not correct" — PKCS#12 MACs "no password" and "empty string" differently. Worse, it imports the key and
  cert *anyway* before erroring, so a failed run leaves a usable-looking untrusted identity behind; two such
  orphans accumulated and made `codesign -s` fail with `ambiguous (matches … and …)`. The script now
  **refuses to create a second cert with the same CN** and prints delete-by-hash instructions.
  (ii) The p12's **filename becomes the imported key's label** when the key bag has no friendlyName, so
  `id.p12` produced a key called `id` whose cert was called `Archive Suite Dev`; scoping
  `set-key-partition-list -l "Archive Suite Dev"` then silently configured the *wrong* key and `codesign`
  kept raising "wants to use key" on every invocation. It is now unscoped (`-s -t private`) so it cannot
  miss, and the p12 is named after the CN. **Verify non-interactivity by TIMING, never by exit status** — a
  keychain dialog needs a human, so three signs at ~70 ms each prove no prompt; `rc=0` cannot distinguish
  "never prompted" from "the operator clicked Allow", which is exactly the false pass that hid this bug.

## Autonomous compactor + park diagnosis (from the 2026-08-06 health-gate RED)

- [x] **`arm.sh` → `daemon.sh`, and the verb `arm` → `start` (owner, 2026-08-06). ✅ DONE** — this commit.
  "Arm"/"re-arm" was jargon that had to be explained every time it surfaced in a park note or a status hint.
  The owner chose the conventional shape, so it is now `daemon.sh start | stop | status | nohup` (`keepalive`
  stays an explicit alias for `start`). A **bare `./ops/autonomous/daemon.sh` still means `start`**, so every
  "Start it: …" hint and the owner's habit keep working; the retired `arm` verb is **rejected**, not silently
  aliased — `daemon.sh arm` exits nonzero with `unknown command 'arm'. Use: start | stop | status | nohup |
  keepalive`. Two spellings for one command is how docs drift, so there is deliberately no back-compat alias
  (and nothing to migrate — nothing installs or invokes `arm.sh`; `~/.local/bin` holds only the daemon and the
  compactor, and the launchd plist's `ProgramArguments` points at `archive-suite-autonomous.sh`, never at this
  script, so the rename cannot break a loaded job).
  - **Scope:** 76 path references across 15 files, plus `tests/prove-arm-dispatch.sh` →
    `tests/prove-daemon-dispatch.sh` and the `ARM=` variables (`status-digest.sh` → `DAEMON_CMD`, the harness →
    `DAEMON`). Daemon-sense "re-arm" became "restart" in 18 places across the daemon, README, `AGENTS.md` and
    `SUITE_TODO.md`. **Two `re-arm`s were deliberately LEFT** because they are a different sense entirely —
    `SUITE_TODO.md` "re-arm safety-net lint/smoke tooling" and "re-arming a started-once guard" — and app-code
    `arm`/`armed` (Capture timers in the Processor, iOS and Android companions) was never in scope.
  - **Proof:** `prove-daemon-dispatch.sh` 10/10, with two NEW assertions pinning the rename (`start` resolves to
    keepalive; the retired `arm` verb exits nonzero and is named as unknown). `prove-status` 36/0,
    `prove-compact` 72/0, `prove-daemon` unchanged. All dispatch checks run through `--dry-run`, so the proof
    never installs or launches anything.

- [x] **`prove-status.sh` was reading the owner's REAL `~/Desktop` — its verdict depended on state outside the
  sandbox. ✅ FIXED 2026-08-06** — this commit. `status-digest.sh` checks
  `$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt` to decide whether to print a "it parked and left you a note"
  ask, and this harness never isolated `$HOME` (unlike `prove-daemon.sh`, whose header promises to "never touch
  the owner's Desktop"). Measured, and reproduced deterministically by creating and removing that one file:
  **34 passed / 2 FAILED with a real park note present, 36 / 0 without.** So the two failures reported earlier
  in this session as "pre-existing on main" were an **environment leak, not a defect** — the earlier reading
  that they were latent `status-digest.sh` bugs was wrong. Now `export HOME="$T/home"` in the sandbox, and the
  count is identical either way.
  - Both this harness and `prove-daemon-dispatch.sh` are now **health-gate steps** (`status-proof`,
    `dispatch-proof`), for the same reason `compact-proof` was added: each is seconds long, hermetic and
    deterministic, and an unwatched proof decays into decoration. `prove-daemon.sh` is deliberately excluded —
    ~10 min of real daemon loops does not belong in a gate already running ~22 min against `GATE_MAXRUN=50min`.

- [x] **The plan compactor had been ABORTING Pass 1 on every cycle for weeks, and three separate layers of
  "nothing was watching" let it. ✅ FIXED 2026-08-06** — this commit. The daemon parked on `health gate RED
  (x2)`; the park note said *"a reproducible build/test regression … a broken tree"*, but the tree was green
  and the **only** failing step was `context-budget` (`execution-plans/despotlight.md` at 105,726 B against its
  96,000 budget). The interesting defect was the one nobody was looking at:
  - **The bug.** Every pass bounded its region with "the next **blank-preceded** `## ` header". The live plan's
    `## Daemon Report` had **no** blank line before it (Session Log entries are blank-SEPARATED and
    newest-PREPENDED, so the separator that ends up against the next header is exactly the one that goes
    missing), so Pass 1's region ran to EOF, swept that whole section into the drop set, and hit the anchor
    guard. The guard did its job — the plan was never corrupted — but the pass never ran either. Measured on
    the live plan: the region read as **55,779 B / 26 entries** (the 26 = 11 real entries + 15 Daemon Report
    `- **[` bullets, which match Pass 1's blank-agnostic `^- ` rule) instead of **39,057 B / 11**. Against
    `SL_MAX_BYTES=30000` it should have been reclaiming ~11 KB *every cycle*; instead the plan reached
    **174,152 B = 96%** of its own context budget. It was a deadlock: the pass had to run once to restore the
    blank line that was stopping it from running.
  - **Two sibling data-LOSS paths, found by adversarial review and now proven by tests.** With `## HOLD QUEUE`
    not blank-preceded, **Pass 3 archived an owner-gated `[x]` HOLD QUEUE item out of the plan** (its safety
    check counts only `[ ]`, so a `[x]` left silently). With a section following `## Daemon Report` without a
    blank, **Pass 2 swept that entire section into the DR archive** (`E2E findings` is not in Pass 2's anchor
    list). Both were latent only because of where those headers happen to sit today.
  - **The fix.** A region now ends at the next real section header recognised **by name** (`SEC_HEADER_RE`)
    *or* by the blank line — applied at all **nine** region-end sites. The blank rule is kept because it is
    load-bearing (`prove-compact.sh` Case I: a `## ` pasted inside an entry body must not truncate a region),
    and the name test cannot fire on body text: across **713 KB** of real archived entry bodies there is not
    one column-0 `## ` line. An empty/unbound `sec` falls back to the blank rule rather than matching
    everything. A section that is neither named nor blank-preceded degrades to exactly today's behaviour.
  - **Why it stayed invisible, and what catches it now.** (1) `compact-plan.sh` always exited 0, so an abort
    and a healthy no-op were indistinguishable — it now exits **1 only when a pass truly aborted**. (2) The
    daemon's call site was `… || true`, which its own comment admitted *"swallows any error anyway"* — it now
    logs a loud `⚠⚠ compact-plan ABORTED a pass` line (still never breaking the loop). (3) `prove-compact.sh`,
    the mechanism proof for exactly this code, was **RED on main and wired into nothing** — three Case A
    ordering assertions had been failing since `ce49ead` made Pass 1 newest-first without updating the fixture,
    whose comment still claimed "oldest first … (matches real plan)". Fixture fixed, and it is a health-gate
    step now (`compact-proof`). Harness: **49 → 72 assertions**, and the three new cases (J/K/L) each fail
    against the pre-fix script.
  - **Measured effect.** Session Log region 39,057 → **27,782 B**; plan 174,152 → **162,877 B** (−11,275,
    verified on a copy: idempotent on a second run, every other section byte-identical, all five archived
    entries recoverable). `despotlight.md` 105,726 → **85,685 B** (−20,041) by tombstoning seven sections whose
    work has shipped, each tombstone keeping the facts other sections and live code still cite by number.
    Together the orientation read drops **~31 KB/session (~8k tokens)** and — the real point — is **bounded
    again**.
  - **The park note no longer misdiagnoses.** It now parses the gate's own `HEALTH GATE: RED —<steps>` verdict
    (the embedded `tail -25` *structurally* cannot contain it — the gate prints up to 40 more lines after it),
    classifies document steps against code steps, and for a document failure says so plainly instead of
    asserting a code regression. A real code RED keeps the original wording; a mixed RED is treated as code.
    Step names now also ride in the park *reason*, which upgrades `daemon.log`, the ntfy title, the macOS
    banner and `STATUS.md` for free. The split is IFS-independent: under an inherited `IFS=$'\n'` the loop saw
    one word `" context-budget"` and would have misclassified every document failure as a code regression.
  - ⚠️ **Not fixed here, deliberately** (each is a separate, smaller change): `health-gate.sh`'s
    `--- failing output (tail) ---` is `tail -40` of the **shared** step accumulator, so it shows the last
    step's output rather than the failing step's — it only looked right because `context-budget` runs last. And
    nothing ever deletes `~/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt`, so the "Needs you" bullet stays after the
    cause is fixed.


## Wave 26 — de-Spotlight the suite (owner directive 2026-08-04) — plan `execution-plans/despotlight.md`

### Shipped-rollup detail moved out of `SUITE_TODO.md` (2026-08-07, W28.trackerbudget)

Verbatim from the open tracker, where it was the ONLY copy — `SUITE_TODO_DONE.md` was not a
superset, so these were moved rather than compressed. Nothing was reworded or dropped.

✅ **W26.deny — SHIPPED 2026-08-05 (`2956f3c` → `ad86cce`); full entry in `SUITE_TODO_DONE.md`.** Three things
later items in this wave need from it. **(1)** `TagXattr.inspect` (ArchiveCore) is now the shared primitive
for *"no tags"* vs *"couldn't read the tags"* — call it, don't re-derive it. **(2) Two of this plan's written
prescriptions were measured WRONG while shipping it** — `XATTR_NOFOLLOW` (must FOLLOW: `resourceValues`
reports the *target's* tags through a symlink) and *"a returned size of 0"* (a removed-tags file keeps a
42-byte empty-array plist; 51 of the owner's files are in that state) — both now corrected in plan §4a.1 and
§7a.3. **(3)** The corpus census is refreshed: 123,302 regular files · 21,311 ENOATTR · 101,940 tagged · 51
empty-array residue · **0 denied** · 0 undecodable.

✅ **W26.notsup — SHIPPED 2026-08-05 (this commit); full entry in `SUITE_TODO_DONE.md`.** An xattr-less
SMB/NFS volume remains safely unreadable—never coerced to untagged—but Reader now says *"Finder tags
unavailable for N files"* and explains that it cannot list or edit them, with APFS-copy + rescan guidance.
Mixed-mount permission/file/folder counts remain visible. The mapper recognizes only ArchiveCore's exact
ENOTSUP suffix; an ordinary error path containing `(ENOTSUP)` cannot be misdiagnosed as a volume capability.
Exposure remains zero on the owner's APFS corpus.
✅ **W26.lint — SHIPPED 2026-08-05 (`1460125` → this commit); full entry in `SUITE_TODO_DONE.md`.** Two things
later items in this wave need from it. **(1)** `ArchiveReader/scripts/lint-write-surface.sh` now lints
`packages/ArchiveCore/Sources/ArchiveCore` as well as the Reader app target, and allowances are
**`(file, exact source line)` pairs — never whole files**, so a new ArchiveCore file that calls
`setResourceValue`/`setxattr`/a `FileManager` mutator/`.write(to:)` fails the lint. **Run it before committing
any ArchiveCore work** (`./ArchiveReader/scripts/lint-write-surface.sh`; self-test:
`./ArchiveReader/scripts/test-lint-write-surface.sh`) — and since `W26.lint-fu` (2026-08-07) the daemon's
health gate runs both, so a violation you forget to check is caught within `AUTONOMOUS_GATE_EVERY` commits
instead of never.
**(2)** It was not merely scoped too narrowly, it was passing **vacuously**: the Reader app target has **zero**
tag-write hits of its own (its `TagWriter` is a delta adapter over `ArchiveCore.CoordinatedTagWriter`), so
rule 1 had nothing left to catch. Verified by running the OLD script against planted ArchiveCore violations —
exit 0, "✓ clean".

✅ **W26.lint-fu — SHIPPED 2026-08-07 (`5210c12` → this commit); full entry in `SUITE_TODO_DONE.md`.** All
five of Wave 26's un-run harnesses are steps in `ops/autonomous/health-gate.sh` now — `write-surface-lint`,
`write-surface-lint-proof`, `tag-vocabulary`, `finder-tags` and the skippable `fixture-scripts` (~105 s
together, ahead of the VM lane). Two things later items need from it. **(1) The lint's source lists are
PER-RULE**: rules 1 (tag write) and 3 (errorHandler-less enumerator) now cover
`ArchiveNotes/macOS/Sources/ArchiveNotes`, rule 2 (destructive / content write) deliberately does not — that
tree has 11 pre-existing content writes, six in `NoteStore`, and adding it without auditing them first would
simply turn the lint RED. A new guard (a2) fails if any rule names a tree the union `SRCS` omits. **(2) A
missing PREREQUISITE is exit 3, not exit 1**: `test-fixture-scripts.sh` needs `/opt/homebrew/bin/tag` and the
**gitignored** `Test files/Brown Gemini` corpus, so on any other clone — and in every worktree — the lane
reports `⊘ … NOT VERIFIED: fixture-scripts` instead of parking the run. ⚠️ **`daemon.sh` installs from the
PRIMARY checkout's working tree, so the new gate steps are not live until the primary is fast-forwarded and
the owner restarts the daemon** (Daemon Report).

✅ **W26.walk2 — SHIPPED 2026-08-05 (`f1c0d2f` → `b88d20a` → `6f5d6ad` → this commit); full entry in
`SUITE_TODO_DONE.md`.** Reader Release discovery now uses `ArchiveCore.CorpusWalker`; every
`NSMetadataQuery`/`NSMetadataItem` path and the Spotlight-lag `PendingWrite` subsystem are gone.
`LibraryPhase` is the single health/absence/pruning gate, incomplete passes keep every unseen prior row,
and verified writes use a monotonic ordering guard instead of a timer. The incident's old claim is
unrepresentable: only a settled scan may say no files carry Read/Unread, and it quotes the examined-file
denominator. Manual File ▸ Rescan Archive Folder (⌘⌥R) covers the interval before `W26.fsev` ships.
Adversarial completion added progress for wholly untagged trees, protected deep links from treating degraded
passes as misses, and proved unreadable subtrees cannot erase prior rows. VM verification was deliberately
hostile: Spotlight indexed **0/11** fixture files while Reader still rendered all 11; the full pre-existing
16-test GUI suite and the new denominator check passed. The accepted one-time content-index re-extraction
from switching mtime sources remains deliberate; the database version is unchanged.
✅ **W26.idx — SHIPPED 2026-08-05 (this commit); full entry in `SUITE_TODO_DONE.md`.** Reader now owns a
separate system-SQLite `LibraryIndex`: byte-exact `(root path, marker GUID, file path)` identity, raw tags,
fresh `(mtime, ctime, size, inode, dataless)` fingerprints, every regular file, and honest scan provenance.
Warm rows render immediately as cache/revalidating, while a dedicated-thread fingerprint pass re-reads tags
only for changed/new/unverified paths and makes absence authoritative only after a clean pass. Cache rows are
re-read before any write target/delta is chosen; corpus-wide renames are conditional. Dataless rows never
reach PDF extraction. Canceled 150k-row SQLite work yields every 500 rows, and NFC/NFD spellings remain
distinct through persistence, FSEvents coalescing, containment and exact live reads. The store is a new v1
cache with no migration or legacy-state fallback, as directed. Fixture roots answer NO to the persisted
index through a single `usesPersistedIndex` predicate — on ⌘⌥R as well as launch, which is where they had
been escaping onto the real Application Support database from unit tests. **Scale and VM verification were
not run for this item and are carried into `W26.verify`.**
✅ **W26.fsev-fu2 — SHIPPED 2026-08-06 (this commit); full entry in `SUITE_TODO_DONE.md`.** The walk now has
the deadline the stream got in `W26.fsev-fu1`. A pass that has examined **zero** files after
`scanStallTimeout` (5 s) publishes `.degraded(.scanStalled)` — *"Archive folder has not answered"* — instead
of leaving the list in `.firstScan(done: 0, seen: 0)` behind a spinner for ever. Reported, never cancelled: a
thread blocked in `opendir` cannot be interrupted. It grants nothing (`.degraded` is not settled, so no
pruning and no authoritative absence, and it is set directly rather than through `DiscoveryHealth`, whose
contract is about FINISHED passes); a late pass supersedes it through the existing generation token, and so
does the first file seen. `requestRootRescan` had to learn about it too — ⌘⌥R while stalled would otherwise
have reset the phase to "Scanning…" while `drainWatchWork` refused to start anything.
✅ **W26.symroot — SHIPPED 2026-08-06 (`1e7044d` → this commit); full entry in `SUITE_TODO_DONE.md`.** A root
that is itself a symbolic link is walked **through its target**: the probe `rootIsOpenable` became
`CorpusWalker.canonicalRoot`, which answers *"what must I enumerate for this root?"* and is used by `scan` and
`scanFingerprints` alike, so the warm-start revalidation walk cannot disagree with the full walk about what the
root is. **The item's own prescription was measured WRONG, and that correction is the durable part:** it asked
for the target to be walked but every discovered path rewritten back under the caller's link prefix, to protect
`LibraryIndex`'s byte-exact `(root, path)` contract. Measured, the enumerator **already** hands back fully
ancestor-resolved paths — a root spelled `/var/folders/…` yields `/private/var/folders/…` entries — so the
caller's spelling was never what the walk emitted, and a rewrite would invent a *third* spelling that neither
FileManager nor FSEvents ever produces, leaving `CorpusWatcher`'s realpath'd live events matching no row. So
identity follows enumeration. Only a symlinked FINAL component is canonicalised — every other root reaches the
enumerator byte-for-byte as spelled, so no existing root and no cached row can shift.
✅ **W26.symroot-fu1 — SHIPPED 2026-08-06 (`bd01025` → `bcfaa18` → `766f59c` → this commit); full
entry in `SUITE_TODO_DONE.md`.** A symlinked archive folder can now be **chosen** — `bookmarkData(options:
.withSecurityScope)` cannot `open()` a link, so `setRoot` used to land in a `catch` that only `NSLog`ed: no
root, no scan, nothing said. It adopts `CorpusWalker.canonicalRoot(url)` instead, and both refusal cases now
return a message the window shows. **And the larger half — the spelling.** Every place that compared a
DISCOVERED path against the caller's spelling of the root now uses `RootFolderStore.discoveredPathPrefix`
(or, in discovery's own objects, one derived from the root they were handed): warm-start containment, cache
re-verification before a write, FSEvents containment and subtree eligibility, the sidebar folder tree,
exclusions, the restored folder scope, deep-link reveal, durable-link relative paths, content-index prune.
Two of these were **paired on purpose** — `publishWarmSnapshot` filtering out every warm row was masking
`reverifyCacheRows` rejecting every cache row, so fixing the warm start alone would have unmasked a
write-path failure. Not touched, deliberately: `CorpusRootFingerprint.capture` and `LibraryIndexRoot.path`.

✅ **W26.notesabsence — SHIPPED 2026-08-07 (`5c46d2a` → this commit); full entry in `SUITE_TODO_DONE.md`.**
Notes' basename fallback no longer establishes absence from a walk it was never allowed to make. The root is
probed with `CorpusWalker.canonicalRoot` (`opendir(3)`, plus `realpath(3)` for a symlinked final component so
the *target* is walked) and the enumerator finally has an `errorHandler:`, so one skipped subdirectory demotes
`.exhausted` to `.unreadableRoot`. The one branch that still establishes absence — the root is GONE, the
shipped W8-S9 computer-move contract — is kept and **narrowed**: `lstat(2)`/`ENOENT|ENOTDIR` rather than
`fileExists`, which cannot tell "never there" from "denied by an ancestor" and read a permission error as an
empty archive. 8 new tests (suite 10 → 18); 5 fail against the pre-fix source and 5 mutants are each caught by
a named test. **Two findings came out of it:** the popover sentence for an unfinished search said *"stopped
after N items"*, which this change makes false for a walk that ran to the end and was denied part of the tree
(reworded here, in the same commit that made it wrong); and `ReaderRootStore.grantRoot` cannot adopt a
symlinked root at all — filed as `W26.notesabsence-fu1` below.

✅ **W26.notesabsence-fu2 — SHIPPED 2026-08-07 (this commit); full entry in `SUITE_TODO_DONE.md`.** New
`ReaderRootChooser` is the panel Notes was missing — `grantRoot`'s only caller used to be a test, and
`NSOpenPanel` appeared nowhere in Notes' sources, so `knownRoots` started and stayed empty on every real
machine. Two entry points (File ▸ Choose Archive Folder…, and an in-popover variant that grants and
re-resolves the waiting link in one step), plus two refusal cases the missing chooser had made unreachable
in practice: `ReaderRootGrantRefusal.wrongRootKind` (picking Notes' own `.notes`-marked folder) and
`LinkResolution.wrongArchive` (granting a real, different archive — no longer conflated with "nothing chosen
yet"). All three popover messages now carry a working "choose a folder" button. My own adversarial pass
caught a cancel-leaves-a-permanent-spinner bug in that button before it shipped. The sandbox-symlink question
`fu1` left open is still open — needs a real `NSOpenPanel` pick, VM lane, Reader-only until `W21.vmgui`.
✅ **W26.oracle — SHIPPED 2026-08-06 (`50ea4a1` → this commit); full entry in `SUITE_TODO_DONE.md`.** The
item's premise was **too kind to the old oracle** and the correction is the durable part: it said the `mdls`
read *"would have"* failed during the 2026-08-04 incident. Measured on this machine at the harness's own
output location (`/tmp/ap-e2e-$$/out`, `e2e-phone-mac.sh:34-35`), `mdls -name kMDItemUserTags` answers
`(null)` — **exit 0** — for a file whose tags are provably on disk, because `/tmp` and `/var/folders` are
never indexed. So the tag half of the E2E year check was not fragile, it was **dead in every run that has
ever happened**; `year` has only ever been satisfiable from the output filename or the extracted text. The
risk was never a false FAIL, it was silent loss of assertion coverage. New shared reader
`ArchiveProcessor/scripts/finder_tags.py` (`read_tags` → `ok`/`absent`/`unreadable`, W26.deny's distinction
in Python); `tier2_assert.py`'s `disk_tags` moved into it with **byte-identical** old-vs-new output proven on
a synthetic run dir; new gate `./ArchiveProcessor/scripts/test-finder-tags.sh` (26 checks, 6/6 mutants
caught). **Nothing under `ArchiveProcessor/scripts/` reads Spotlight any more** — `grep -rn
"mdls\|mdfind\|mdimport\|kMDItem\|NSMetadataQuery"` over that tree returns only the two docstring lines that
explain why not.

- [x] **W26.lint-fu — nothing actually RUNS the write-surface lint [S · low · Tier-2 · ops].
  ✅ SHIPPED 2026-08-07** — `5210c12` -> this commit. Filed 2026-08-05 by `W26.lint`, then extended four
  times as later items shipped harnesses with the same defect.

  **The gap.** Wave 26 shipped a mechanism proof for each of its guarantees and wired **none** of them to a
  caller. `lint-write-surface.sh`'s own header claimed it was *"also invoked by the autonomous build"* —
  measured false on 2026-08-05: no caller in `ops/`, in `.claude/hooks/`, or in any script. So the Core
  Directive's automated half ran only when a human remembered it, which is the same failure as a lint that
  passes vacuously, one level further up: the guarantee reads as enforced and is not.

  **All five are health-gate steps now** (`ops/autonomous/health-gate.sh`): `write-surface-lint`,
  `write-surface-lint-proof`, `tag-vocabulary`, `finder-tags`, and the skippable `fixture-scripts`. Measured
  here before wiring, on a clean tree: **0 s / 16 s / 65 s / 3 s / 20 s ≈ 105 s**, against `GATE_MAXRUN` of
  50 min. Placed **before** the ~15–20 min VM lane so a RED lands in the gate's first minutes, and every one
  of them was run green first — the item's "the gate must not start RED".

  **The `fixture-scripts` question the item left open, answered: SKIP, not RED.** It needs
  `/opt/homebrew/bin/tag` and the `Test files/Brown Gemini` corpus, and it PREFLIGHTS both. 🔺 The deciding
  fact is one the item did not have: **`Test files/` is GITIGNORED**, so that corpus exists only in whichever
  checkout the owner put it in — absent from every other clone and from **every git worktree**, i.e. from the
  isolation each session is required to work in. RED there would be a lie about the source. The script now
  exits **3 with a `SKIPPED:` line** for exactly (and only) its two preflight cases — a failed *check* is
  still exit 1 — and the gate runs it through `step_skippable`, the same contract as `gui-vm`, so the lane
  appears as `⊘ … NOT VERIFIED: fixture-scripts` rather than as a silent ✓ or a false park.

  **The SRCS question, resolved by measurement.** Re-measured against
  `ArchiveNotes/macOS/Sources/ArchiveNotes` on 2026-08-07: rule 1 (tag write) **0 hits**; rule 3
  (`errorHandler:`-less enumerator) **0 hits** — the item recorded 1, and `W26.notesabsence` has since fixed
  it; rule 2 (destructive / content write) **11 hits**, six of them in `NoteStore`. Auditing those eleven is
  writing "NoteStore writes notes" eleven times, so the item's own preferred shape wins: **the rules get
  their own source lists.** Rules 1 and 3 cover Notes, rule 2 does not, and the Processor tree is in none —
  its `MacOSTagger` is the suite's *fresh-write* tag adapter and needs its own audit first. Each exclusion is
  a stated decision in the script rather than an omission, and the rule-2 one is pinned by a self-test case
  that fails if someone quietly adds the tree.

  🔺 **What splitting the list cost, which is the part worth keeping.** Guard (a) existence-checks the source
  roots so a rename cannot silently narrow a rule to nothing — but it only ever saw one list. A tree named by
  a rule and omitted from the union would have slipped straight past it: the same vacuous pass, one
  indirection further away. New **guard (a2)** catches exactly that, and the self-test proves it by
  **mutating the lint itself** (dropping Notes from the union while two rules still read it), because a
  configuration bug is not reachable from a source fixture. The mutant carries the usual `cmp -s` vacuity
  check. `✓ clean` also stopped over-claiming: the scopes are no longer uniform, so the line names the
  destructive rule's narrower one instead of implying the union.

  **Verification.** Self-test **14 → 18 checks**, green under both bash 5 and bash 3.2 (the script is
  bash-3.2-safe by design and `/usr/bin/env bash` does not always find 5). Both preflight branches proven to
  exit 3 with `SKIPPED:` — the corpus one directly, the `tag`-CLI one via a mutant, since the CLI is
  installed here. `prove-vm-lane.sh` 48/48 corroborates the exit-3 → `⊘` rendering by extracting and driving
  the gate's real `step_skippable`. The full gate was then run end-to-end, twice: **GREEN** on a clean tree
  with all five new lanes ✓, and **RED naming `write-surface-lint`** with a violation planted in ArchiveCore
  — the mechanism proof the autonomous-setup discipline asks for, rather than an argument that the wiring
  looks right.

  **Also:** `__pycache__/` is gitignored and the `finder-tags` step sets `PYTHONDONTWRITEBYTECODE=1` — that
  script imports `finder_tags.py` from the source tree, so CPython was leaving bytecode in
  `ArchiveProcessor/scripts` on every run, and a gate should not dirty the checkout it is judging.

  🔺 **The full-gate proof could not run as a full gate, and finding out why is the bigger result.** The
  `reader` step **hangs** — 0 % CPU, test host alive, indefinitely. `sample` put the main thread in
  `FSEventStreamCreate → watch_all_parents → open(2)`, reached through the DEBUG fixture lane's *inline*
  watcher start: the exact bug `W26.fsev-fu1` fixed, resurfacing through the carve-out it deliberately left,
  whose stated premise ("a scratch dir's `open(2)` cannot block") is false because FSEvents opens every
  ANCESTOR, not the root. A second hang earlier in the bundle came from a leaked `ARUITestRootPath` in the
  owner's real defaults. Both are filed as **`W26.fixturehang`** (HIGH) with the full stacks; it hangs rather
  than REDs, so the daemon would burn `GATE_MAXRUN` and park blaming build time. The two proof runs above
  therefore used a `sed` copy of the gate with **only** the three app build/test steps removed — verified
  non-vacuous (exactly 3 lines, 12 steps → 9) and with the five new lanes byte-identical — so `step()`,
  `step_skippable()` and the real RED/GREEN tail were all exercised for the lanes this item adds.

  **One thing observed and deliberately not fixed:** with `AUTONOMOUS_GUI_VM=0` the final line still says
  "+ GUI-VM UITests". It is the gate's own over-claiming failure mode, but it fires only when an operator
  has explicitly disabled that lane and therefore knows; folding it in here would have widened a `[S]` ops
  item into the summary-line rewrite it is not.

  ⚠️ **Not live yet, and this is inherent, not an oversight:** `daemon.sh` installs from the PRIMARY
  checkout's working tree, so the new gate steps do nothing until the primary is fast-forwarded and the owner
  restarts the daemon. Flagged in Daemon Report.

- [x] **W26.scripts — fixture scripts drop `mdimport`/`mdfind` polling [S · low · Tier-1 · needs: none].
  ✅ SHIPPED 2026-08-07** — `18824bb` -> this commit. `ArchiveReader/scripts/make-gui-fixture.sh` and
  `smoke-setup.sh` force-indexed their output and then polled `mdfind` for up to 60 s / 40 s.

  **The item called the poll "unnecessary and a source of flake". Measured, it is worse than that: it is
  UNSATISFIABLE wherever these fixtures are actually built.** A `mktemp` dir is never indexed (the same
  fact `W26.oracle` measured about `/tmp`, which had made the E2E tag oracle blind in every run), and the
  Tart guest boots with a cold index. Both scripts only **warned** on timeout, so the shape of the bug was
  a fixture that shipped looking fine and made its UITests fail later for a reason the log never named.

  **What replaced the wait.** `tag -s` and `ditto` are synchronous — the xattr is on disk when they
  return — so there is nothing to wait for and the tags are simply read back:
  - make-gui-fixture: 12 files, exactly **11** carrying Read or Unread, and file 9 carrying **NEITHER**.
    File 9 *is* the tri-state bucket a UITest asserts on, so its absence of a read state is an invariant
    worth pinning, not an omission — a later edit that "helpfully" tags it would silently retire that
    test. Exact-token comparison, because **"Read" is a substring of "Unread"** and a grep would
    over-match. **Fail-closed** now, where the poll only ever warned. (This does not preempt
    `W21.vmgui-a`, which is about the *runner* noticing a failed fixture build; it is what gives that
    item a non-zero exit to notice.)
  - smoke-setup: the raw `com.apple.metadata:_kMDItemUserTags` must be **byte-identical on both sides of
    the copy** — the ditto-preserves-tags claim its own comment makes, which the old poll never checked.
    Raw `xattr` (base macOS) rather than the `tag` CLI, so the smoke setup gains no brew dependency.

  **New `AR_FIXTURE_DST` / `AR_SMOKE_DST`** make the item's own gate runnable on a genuinely unindexed
  volume without clobbering the real fixture. They also feed a `rm -rf`, so they arrive with a guard
  (absolute, ≥2 components, not `$HOME`, not inside the source corpus). 🔺 **My adversarial pass caught
  that guard letting through the one path it exists for:** `$HOME/` is the same directory as `$HOME` but
  a different string, so the equality check missed it while the depth check was happy. Trailing slashes
  are stripped first now (`/` collapses to empty and is refused by the depth check), and a named test
  pins it.

  **New `ArchiveReader/scripts/test-fixture-scripts.sh` — 26 checks, three layers**, because any one
  alone passes vacuously: *static* (no `mdimport`/`mdfind`/`kMDItem… ==` survives in either script — the
  xattr NAME is not a query and must survive); *dynamic* (both run with `mdimport`/`mdfind` shimmed to a
  tripwire that **records** the call, since a non-zero exit alone proves nothing against code that piped
  both to `/dev/null` and `|| true`-ed the poll); *mutation* (4 mutants, each caught by name, and a
  mutant whose `sed` matches nothing is itself a failure so a stale case cannot go quiet). The gate is
  asserted directly rather than argued: the fixture is complete and correct while the **real** `mdfind`
  sees **0 of its 12 files**.

  End-to-end: the fixture built by the changed script **inside the Tart guest** (cold index, the
  environment the poll could never satisfy) drove **ArchiveReaderUITests 17/17 green**. Host default-DST
  build green, both scripts `bash -n` clean. No Swift source touched. Filed nothing new; extended
  `W26.lint-fu` with the new self-test, which — like the other four — nothing yet runs.

- [x] **W26.notesabsence-fu2 — Notes can never grant a Reader root, so the Reader-link preview is
  unreachable on every machine, and the popover's advice ("choose the folder in Reader") cannot help a
  sandboxed app [S–M · MED · behaviour]. ✅ SHIPPED 2026-08-07** — this commit. Filed 2026-08-07 by
  `W26.notesabsence-fu1`; pre-existing, older than Wave 26.

  **The gap, measured by construction.** `ReaderRootStore.grantRoot`'s only caller was
  `ReaderLinkResolver.grantAndResolve`, whose only callers were tests (`grep -rn grantAndResolve
  ArchiveNotes/macOS/Sources` → one hit, its own declaration), and `grep -rn NSOpenPanel
  ArchiveNotes/macOS/Sources` returned nothing — Notes had no archive-folder chooser at all. `knownRoots`
  started and stayed empty on every real machine, and every source-block preview ended at
  `.needsRootGrant`, whose popover said *"Use File ▸ Choose Archive Folder… in Reader first"* — which cannot
  work, because Notes is sandboxed (`app-sandbox` + `files.user-selected.read-write` +
  `bookmarks.app-scope`): a grant the user makes in *Reader* conveys no access to *Notes*.

  **The fix.** New `ReaderRootChooser` (`Links/ReaderRootChooser.swift`) is the panel Notes was missing,
  behind two seams (`pickFolder`, `report`) so a unit-test host never opens a real `NSOpenPanel`/`NSAlert` —
  either would block the whole bundle with nobody there to dismiss it. Two entry points: `chooseRoot()` for
  File ▸ Choose Archive Folder… (new `ReaderRootCommands`, wired into `ArchiveNotesApp`'s `.commands`, passed
  `previewState` directly rather than via `@FocusedValue` — `.commands` does not inherit a window's
  `@EnvironmentObject`s), and `chooseRootAndResolve` for the in-popover variant, which grants *and*
  re-resolves the waiting link in one step. `SourceBlockPreviewState` owns one `ReaderRootChooser` alongside
  its resolver and exposes `chooseArchiveFolder()` to the menu.

  **Two refusal cases that were reachable in principle but had never been reachable in practice, because
  nothing could grant anything before this:**
  - `ReaderRootGrantRefusal.wrongRootKind` — a genuine, decodable Archive root whose marker says `.notes`,
    not `.reader`. The plausible mis-pick is Notes' own store root, which `RootFolderStore` marks the same
    way; without this guard it would sail past `notAnArchiveRoot` and be adopted under a GUID no Reader link
    can ever name.
  - `LinkResolution.wrongArchive(picked:granted:wanted:)` — `grantAndResolve` picking up a real, grantable
    root whose GUID is not the one the link wants. Previously answered `.needsRootGrant(guid: wanted)`, the
    same case as "nothing chosen yet" — telling a user who had just picked a folder to go pick one. The grant
    now **stands** (that archive is usable in Notes from here on); only the specific link is unresolved.
    Updated two pre-existing tests whose expectations this changes (`ReaderLinkResolverTests
    .grantAndResolveWrongGUID`, `DurableLinkE2ETests.regrantWrongFolderRejected`) to assert both the new case
    and that the grant survives.

  **Popover wording**, all three now carry a "choose a folder" button that drives the chooser without
  leaving the popover: `.needsRootGrant`'s message no longer sends the user to Reader; `.grantRefused`
  offers "Choose Another Folder…"; `.wrongArchive` says which archive was picked and that it is a different
  one, not "not found" and not "choose a folder" (repeating the instruction to someone who just followed it).

  🔺 **Caught in my own adversarial pass, not by a test:** the button's action showed an "Opening the
  archive…" spinner before the modal panel ran (so the panel looks like it opens something rather than
  freezing the popover), but on a **cancelled** panel nothing ever replaced that spinner — a cancel would
  have left it spinning forever, since the panel's dismissal leaves no popover to fall back to except the
  one code has to rebuild. Fixed by threading the resolution that was on screen *before* the button was
  pressed through as a fallback (`grantAction(fallbackTo:relativeTo:)`); a cancelled panel now restores
  exactly what the user was looking at. Not unit-tested: it lives in `ReaderPreviewPopover`, which needs a
  real `NSPopover`/window to exercise (the resolver-level bookkeeping is deliberately factored out so *that*
  half stays testable without one — see `fu3`'s note on `releaseRootScope`) — the VM GUI lane is Reader-only
  until `W21.vmgui`. Verified by reading the control flow instead.

  **What is proven and what is not.** Every assertion is at the store/resolver/chooser level in the Notes
  test host — the real `NSOpenPanel` pick is not covered, and cannot be from a unit-test host. That leaves
  one question `fu1` raised open: whether the sandbox honours a security-scoped bookmark minted for a
  symlink's **target** when the panel granted the **link**. Needs a real pick — VM lane, Reader-only until
  `W21.vmgui`.

  **Verification.** Notes **771** swift-testing (763 → 771; 8 new: 1 `wrongRootKind` refusal test in
  `ReaderRootStoreTests`, 7 in the new `ReaderRootChooserTests`) **+ 189** XCTest green; Release BUILD
  SUCCEEDED with **0 source warnings**; build-for-testing (UITest bundle) succeeds. No ArchiveCore, Reader or
  Processor source touched, so those lanes were not re-run.

- [x] **W26.notesabsence-fu3 — `ReaderRootStore` DELETES bookmarks it merely failed to re-mint, so one root
  that has moved takes every other granted root with it [S · MED · Tier-2]. ✅ SHIPPED 2026-08-07** —
  `af01cb7` (the three fixes) → this commit (the tests, the mutation pass, the trackers). Filed 2026-08-07 by
  `W26.notesabsence-fu1`'s adversarial pass; **pre-existing**.

  **One mechanism, three defects.** The store conflated *"I have a URL for this root"* with *"I hold a scope
  for it"*, and settled the confusion in persisted state.

  1. **`root(for:)` — a READ — wrote `UserDefaults`.** A scope that would not start was treated as proof the
     bookmark was dead, so the GUID was dropped and `persistAll()` rebuilt the **whole**
     `readerRootBookmarks` dictionary by re-minting every surviving root — **with no scope started**, which
     is the one condition under which minting reliably fails (it is exactly why `refreshBookmark` starts one).
     `loadSaved` deliberately starts no scopes, so with roots A and B restored at launch, one click into A
     after A's volume went away dropped A *and silently dropped B's persisted bookmark as collateral*.
     `persistAll()` is **deleted outright rather than narrowed**: the shape of the bug is a lookup that
     rewrites the store, and a narrowed version leaves that shape for the next edit to widen again.

     🔺 **The item's own prescription was improved on, and that is the durable part.** It asked only that the
     *other* roots be spared — "remove the one failed GUID's entry and leave the rest byte-untouched". The
     failed root's bookmark now **stays too**. A refused `startAccessingSecurityScopedResource()` is not
     proof of staleness (an unmounted volume refuses one and remounts later), and Notes has **no folder
     chooser at all** (`fu2`), so forgetting a grant here is unrecoverable *by the user*. The Reader, facing
     the identical question, documented the same answer: *"The bookmark remains persisted so a later window
     activation can retry after the volume is mounted again"* (`RootFolderStore.reResolveSavedRoot`) — the
     very comparison the item cited while prescribing the opposite. Mutant **M2 IS the item's literal fix**,
     and a named test kills it, so the deviation is asserted rather than merely argued. The GUID is still
     dropped from `knownRoots` **in memory** — this session cannot open that root — and the next launch
     retries; a test builds a third store on the same defaults to prove the grant survived.

  2. **`grantRoot` recorded a scope whose start returned `false`.** It always does return false there: a
     panel URL is already accessible, so there is no scope to start — and Apple is explicit that such a start
     must not be balanced by a stop. `activeScopes` now holds a `Scope { url, started }`, and
     `stopAccessing(guid:)` stops only what this store started. It also **keeps** the never-started entry
     rather than dropping it: dropping it sent the next lookup down the `knownRoots` path, where the start
     refused again — and that refusal is branch (1), which wiped the whole store. **Losing a session's roots
     by closing a popover was two lines apart.**

     A third imbalance was found in the same lines and closed there rather than filed: re-granting a GUID at
     the **same** path started a second scope that nothing could ever stop, because `activeScopes` holds one
     entry per GUID and the first start lost its only reference.

  3. **`ReaderLinkResolver.stopAccessing(guid:)` had no caller anywhere in the app**, so every root a session
     previewed stayed scoped until quit. Replaced by **`releaseRootScope()`**, which takes no GUID — the
     caller that knows a preview is over does not know which root it was for, and asking it to remember is
     how the old API came to be dead. The resolver remembers instead (`scopedRootGUID`, set by `resolveExact`
     only when a root was really opened, and released when a *different* root is resolved), which is also
     what makes "which root, and when" testable **without a window**. `ReaderPreviewPopover.dismiss()` is the
     one production call site.

  **New `startScope`/`stopScope` seams**, for the same reason `mintBookmark` became one in `fu1`: the branch
  that matters — a bookmark that resolves at launch but whose scope will not start — cannot be provoked from
  a test, because every fixture lives in the app container where a start is *always* refused for the opposite
  reason (the URL needs no scope). Without the seam the failure branch would only ever run in the wrong sense
  and a mutation restoring the whole-dictionary rewrite would pass. `stopScope` is separate so a test can
  prove a stop that must **not** happen did not happen — the absence is the assertion.

  **Verification.** Notes **763** swift-testing (754 → 763; 9 new tests, one of them from the adversarial
  pass) **+ 189** XCTest green; Release BUILD SUCCEEDED with **0 source warnings** (the 22 `NotesGUITests`
  actor-isolation warnings are pre-existing — `W23.notes-uitest-warn`); write-surface lint clean and its
  self-test 14/14. **10 mutants, each caught by a NAMED test** (M1 `persistAll` restored, M2 the item's
  literal prescription, M3/M4 the two halves of the `started` guard, M5 double-start on re-grant, M6 the
  guard dropped from the *replacement* path alone, M7 `releaseRootScope` emptied, M8 the outgoing root
  leaked, M9 an unknown root claiming the scope slot, M10 `stopAccessing` forgetting the bookmark). No
  ArchiveCore, Reader or Processor source is touched, so those lanes were not re-run.

  **My own adversarial pass added the ninth test**: nothing yet proved that a *second* preview works after
  the release — the actual regression the wiring risks (click one source chip, close it, click another).
  M10 is that test's mutant.

  **The one thing verified by READING, not by a test:** that `ReaderPreviewPopover.dismiss()` calls
  `releaseRootScope()`. Showing an `NSPopover` needs a real window, an unattended run may not draw on the
  owner's screen, and the VM GUI lane is Reader-only until `W21.vmgui`. Everything the line *does* is under
  test at the resolver level; only the call itself is not. Say so if it is ever re-examined.

- [x] **W26.notesabsence-fu1 — a symlinked Reader root cannot be GRANTED in Notes, and the failure is
  silent [S · MED · Tier-2]. ✅ SHIPPED 2026-08-07** — `6226e7d` (the fix + its tests) → this commit (the
  mutation pass, the follow-up, the trackers). Filed 2026-08-07 by `W26.notesabsence`; **pre-existing**, and
  `W26.symroot-fu1`'s adoption half surviving one app over.

  **The defect.** `ReaderRootStore.grantRoot` read the `RootMarker` *before* it attempted the bookmark, and
  returned that marker on the way out of a `catch` that only `NSLog`ed. So a failed grant came back **non-nil**
  while `knownRoots[guid]` was never set: the caller believed it had succeeded, `root(for: guid)` answered
  `nil`, and `resolve` reported `.needsRootGrant` — the user is asked to choose the archive folder, chooses it,
  and is asked again, with nothing said. A root that IS a symlink took that path **every** time, because
  `bookmarkData(options: .withSecurityScope)` cannot `open()` a link. That premise is now asserted rather than
  trusted (`securityScopedBookmarkRefusesASymlink`): minting for the link throws while the same directory
  succeeds, so if a future macOS lifts the restriction the suite says the canonicalisation stopped being
  load-bearing instead of passing while guarding nothing.

  **The fix.** The folder is adopted as `CorpusWalker.canonicalRoot(url)`, so the bookmark is minted for — and
  `knownRoots` holds — the openable target. Only a symlinked FINAL component differs from the pick
  (`canonicalRoot` returns every other root byte-unchanged), which `grantAndRetrieve` now asserts directly, so
  no root that works today shifts and no saved bookmark is invalidated. `grantRoot` returns
  `ReaderRootGrant` — `.granted(marker)` or `.refused(_)` — and the refusals are four distinct things, each
  with the `message` the popover shows: `.unreadable` (missing, denied, dangling link, `ELOOP`, not a
  directory, or a link to a regular file — `realpath` succeeds for that one, the `opendir` probe is what
  refuses it), `.notAnArchiveRoot`, `.markerUnreadable` and `.couldNotBookmark`. The last two used to be the
  same bare `nil`: `RootMarker.read` already distinguishes an unreadable identity from an absent one for
  W23.m6's reason — the repair for absence is a fresh GUID, which orphans every link already written from that
  root — and the store was throwing that away with `try?`. `LinkResolution.grantRefused` carries the refusal
  through `grantAndResolve` into `ReaderPreviewPopover`; a marker-less pick used to be reported as
  `.notFound`, a claim the archive had been searched about a folder that was never opened.

  **`ReaderRootStore` now takes an injected `UserDefaults`** (the Reader's precedent from `W26.symroot-fu1`).
  `grantRoot` WRITES `readerRootBookmarks`, and in `.standard` that key is the app's real set of granted Reader
  roots — the `ReaderRootStoreTests` suite that exercised it had **no snapshot at all**, unlike its three
  sibling suites. `grantRootNeverTouchesStandardDefaults` asserts `.standard` is byte-unchanged across a grant.

  **The adversarial pass changed four things, and the first is the one worth remembering.** 🔺 *The branch this
  item is NAMED for had no test, and a mutation putting the original bug back stayed green.* With the
  canonicalisation in place, nothing reachable from a test can make minting fail — every fixture is in the app
  container, where `bookmarkData` always succeeds, and the symlink that used to fail is precisely what the fix
  removes. So `mintBookmark` is now an injectable seam and `couldNotBookmarkIsRefused` drives it; mutant M7
  (`catch` → `return .granted(marker)`, i.e. the exact pre-fix bug) is caught by that test and by nothing else.
  🔺 Re-granting the same GUID at a new path overwrote `activeScopes[guid]` without stopping the scope it
  replaced — `RootFolderStore.setRoot`'s release-the-previous step, in the same order (new access live first).
  🔺 Refusals named the *canonicalised target*, so for a symlinked pick the message named a folder the user had
  never seen; every case now carries the pick. 🔺 The eight tests in `@Suite("ReaderLinkResolver")` granted
  roots against `.standard` with **no snapshot at all** (its three sibling suites at least restore the key),
  leaving a junk entry per run keyed by a random GUID; they take injected scratch domains now. That also made
  the new hermeticity guard assert on **this grant's GUID key** rather than on the whole dictionary — a
  whole-dictionary comparison would have flaked against those sibling suites' restore window while proving
  nothing extra.

  8 new tests (Notes 746 → **754** swift-testing, 189 XCTest, `TEST SUCCEEDED`), Release build clean, 0 source
  warnings; write-surface lint + self-test 14/14. No ArchiveCore change, so no cross-app rebuild was owed.
  **7 mutants, each caught by a named test** (bookmark the pick not the target; store the pick not the target;
  collapse `.markerUnreadable` into `.notAnArchiveRoot`; drop the canonicalisation entirely; ignore the
  injected defaults; report a refusal as `.notFound`; return `.granted` from the bookmark `catch`).

  Two findings went to the queue rather than into this change: **`W26.notesabsence-fu3`** (`persistAll`
  re-mints without a scope, so one moved root deletes every other root's bookmark — pre-existing, and the
  Reader refuses to do it) and **`W26.notesabsence-fu2`**. No GUI check was run or is possible: the popover
  branch this adds is unreachable in the shipping app (fu2), Notes has no VM GUI lane until `W21.vmgui`, and an
  unattended session may not drive the host screen. The refusal string is asserted in a unit test instead.

  ⚠️ **What is NOT proven, and it is the reason `W26.notesabsence-fu2` exists.** Every assertion is at the
  store/resolver level in the Notes test host. In the real app the URL would come from an `NSOpenPanel` grant,
  and whether the sandbox honours a bookmark minted for a symlink's **target** when the panel granted the
  **link** cannot be seen from a unit test. It is also not reachable today: Notes has no folder chooser, so
  nothing in the shipping app calls `grantRoot` at all (see `fu2`). The Reader carries the same residual
  question and shipped on the same footing.

- [x] **W26.notesabsence — Notes' `ReaderLinkResolver` established ABSENCE from a walk that read
  nothing [S · MED · Tier-2]. ✅ SHIPPED 2026-08-07** — `5c46d2a` (the fix + its tests) → this commit (the
  popover wording, the follow-up, the trackers). Filed 2026-08-06 by `W26.symroot`'s adversarial pass;
  pre-existing, and this wave's core defect surviving one app over.

  **The defect.** `scanForBasename` prechecked its root with `fileExists(atPath:isDirectory:)`, which
  **follows** symlinks and reports "yes, a directory" for roots the enumerator then reads nothing from — and
  `FileManager.enumerator(at:)` is **non-nil** for all of them: it reports the root once to `errorHandler:`
  (which this call did not pass) and immediately ends. So the `guard let enumerator … else` floor never fired,
  control fell through to `stop: .exhausted` — *absence established* — and `resolve` turned that into
  `.notFound` for a source file that was sitting right there. Re-measured 2026-08-07 with this call site's own
  enumeration options, each root holding a matching `doc.pdf`:

  | root | `fileExists` / `isDirectory` | entries yielded | dir errors | old verdict |
  | --- | --- | --- | --- | --- |
  | a symlink to the archive folder | true / true | 0 | 1 | `.exhausted` ⇒ **`.notFound`** |
  | a `0o000` directory | true / true | 0 | 1 | `.exhausted` ⇒ **`.notFound`** |
  | one `0o000` SUBdirectory | true / true | the rest | 1 | `.exhausted` ⇒ **`.notFound`** |
  | a root behind a denied ANCESTOR | false / — | — | — | `.exhausted` ⇒ **`.notFound`** |

  **What shipped.**
  - The root is probed with `CorpusWalker.canonicalRoot` — `opendir(3)` rather than a stat, plus `realpath(3)`
    for a symlinked final component so the **target** is enumerated. That is what `W26.symroot` made the
    function public for, and this is its first cross-app use.
  - The enumerator gets the `errorHandler:` whose absence `lint-write-surface.sh` rule 3 bans outright, and
    any recorded directory error demotes `.exhausted` to `.unreadableRoot`. One skipped directory is enough:
    the file may be in it. Same rule `CorpusScanResult.isClean` encodes for the Reader's discovery walk.
  - Containment is derived from the **walked** root rather than the caller's spelling. Measured: this is
    drift-proofing, not a live fix — a mutant reverting it to the caller's spelling passes every test, because
    `ReaderRootContainment.canonical` resolves symlinks on both sides today. It is `W26.symroot-fu1`'s lesson
    applied before it can bite, and it is documented in the source as exactly that rather than as a fix.

  **The absence branch was kept and narrowed, not removed.** A root that is GONE still reports absence — the
  shipped W8-S9 computer-move contract, *a stale root reports the file missing, never a wrong file*. But the
  test for "gone" is now `lstat(2)` failing with `ENOENT`/`ENOTDIR`, not `fileExists`: `fileExists` answers
  `false` for a root denied by a `0o000` **ancestor** exactly as readily as for one that was never there, so
  the old code read a permission error as an empty archive — this wave's defect in miniature, inside the
  branch meant to be the safe one. Two deliberate behaviour changes fall out, both toward "I could not look":
  a **dangling symlink** root (the target may be an unmounted volume) and a root behind a **denied ancestor**
  now report `.searchIncomplete` where they previously reported the file missing.

  **The popover sentence was reworded in the same commit that made it wrong.** `.searchIncomplete` used to
  mean only *cancelled* or *hit the entry bound*, so "The search of the archive stopped after N items" was
  accurate. It is now also reached by a walk that ran all the way to the end and was denied part of the tree,
  where that sentence is precisely the confident-sounding falsehood this wave exists to stop — it reads as
  "we gave up early" when what happened is "we finished and still could not see everything". Now: "The search
  of the archive did not finish (N items examined), so the file may still be there." No enum change, so no
  reason payload and no churn in the tests that compare `.searchIncomplete(scanned:)` by value.

  **Verification.** 8 new tests, suite 10 → 18, whole Notes bundle 189 XCTest + 745 Swift Testing green,
  Debug build clean with 0 new warnings, write-surface lint + its 14/14 self-test green. Anti-vacuity, because
  a green new test proves nothing on its own: **5 of the 8 fail against the pre-fix source** (the other 3 are
  regression guards on behaviour that must NOT change — a clean walk still exhausts, a missing root still
  establishes absence), and **5 mutants are each caught by a named test** — demote unconditionally →
  *clean walk still establishes absence*; drop the absence branch → *a root that is GONE*; `stat` instead of
  `lstat` → *a dangling symlink root*; revert the probe to `fileExists` → *denied ANCESTOR* **and** *dangling
  symlink*; containment from the caller's spelling → **uncaught**, which is why that one is described above as
  drift-proofing rather than claimed as a fix. Scratch temp trees only; no corpus path was read.

  **Filed:** `W26.notesabsence-fu1` — `ReaderRootStore.grantRoot` cannot adopt a symlinked root at all
  (`bookmarkData(.withSecurityScope)` throws `NSCocoaErrorDomain 256`, the `catch` only `NSLog`s, and it
  returns a non-nil marker anyway), so the symlink half of this fix is currently unreachable from the UI. Also
  extended `W26.lint-fu` with the measured cost of adding the Notes tree to the lint's `SRCS`: rule 1 → 0 hits,
  rule 3 → 1 hit (the call fixed here), rule 2 → **11** hits needing individual audited allowances.

- [x] **W26.symroot-fu1 — a symlinked archive folder can be CHOSEN, and every root-relative
  comparison is spelled the way the walker reports [M · Tier-2]. ✅ SHIPPED 2026-08-06** — `bd01025` (the
  ArchiveCore primitive) → `bcfaa18` (adoption) → `766f59c` (the warm start, the write path behind it, and
  the watcher) → this commit (the rest of the sweep + the trackers).

  **What it was, in two halves.**

  *Adoption.* `url.bookmarkData(options: .withSecurityScope, …)` **throws for a symbolic link** —
  `NSCocoaErrorDomain 256` "Could not open() the item" — while the identical call on the same real directory
  succeeds. `RootFolderStore.setRoot` bookmarks FIRST, so a symlinked pick landed in a `catch` that only
  `NSLog`ed: `root` never set, no marker, no scan, and a window that looked exactly as it had before the
  panel opened. `chooseRoot` compounded it by starting the library on the **panel** URL rather than on
  whatever was adopted, and by tearing down the previous root's scope/filters even when nothing was adopted.

  *Spelling.* The enumerator hands back fully `realpath`-resolved paths, so under any root whose spelling
  differs from its resolved one — a symlinked component, or merely an aliased ancestor like `/var/folders` →
  `/private/var/folders` — a comparison against `root.path` rejects every path the walk just produced. That
  is not a corner case: every fixture root is that shape, which is why the sidebar folder tree had never
  placed a file under one.

  **What shipped.**
  - `CorpusWalker.discoveredPathPrefix(for:)` (ArchiveCore, `bd01025`) — *the prefix every path a pass
    reports under this root is spelled with*. Deliberately NOT `canonicalRoot`, which resolves only a
    symlinked FINAL component: a root spelled `…/link/sub` comes back byte-unchanged from `canonicalRoot`
    while its entries arrive under `…/real/sub`. A `String`, not a `URL`, because it carries no security
    scope and must never be opened or persisted.
  - `setRoot` adopts `CorpusWalker.canonicalRoot(url)` and returns a `RootPickRefusal` — `.unreadable` or
    `.couldNotBookmark` — which `chooseRoot` shows and announces. It differs from the pick only for a
    symlinked final component, so no root that works today can shift, and the bookmark is minted for the
    same URL that is adopted, so the scope belongs to the root we keep.
  - `RootFolderStore.discoveredPathPrefix`, set through one private `adopt(_:)` shared by all three adoption
    sites (panel pick, bookmark re-resolve, DEBUG fixture) so a fourth cannot forget it. In-memory only.
  - The sweep: `ArchiveLibrary.publishWarmSnapshot`, `NavigationModel.reverifyCacheRows`,
    `CorpusWatchRequest.reduce` + `CorpusWatchEligibility.includes` (via a new `watchedPathPrefix`, applied
    to the root only and never to an already-resolved event path), `buildFolderTree`, the three
    `sanitizedPathPrefix` callers, `revealAndSelect`, `isExcludedAbsolute`/`absolutePrefixes` callers,
    `pruneIfSettled`, `ArchiveLinkTarget.rootPath` (was `root: URL`) + `ArchiveLinkWriter`, and
    `OptionsView.addExcludedFolder`, which resolves **both** sides because the panel and the root need not
    agree on spelling.

  🔺 **The two that had to move together, and why one was invisible.** `publishWarmSnapshot` emptied `warm`
  on every launch under such a root — and `asOf` being non-nil meant the "truly cold root" guard let the
  publish through anyway, so a fully warm root showed **zero files** until the entire revalidation walk
  finished, which is the whole delay `W26.idx` exists to remove. `reverifyCacheRows` rejected every cache row
  the same way, dropping all of them from a bulk tag write — and that could not be observed while the first
  bullet guaranteed no `.cache` row ever reached `files`. Fixing the warm start alone would have **unmasked a
  write-path failure**.

  🔺 **Discovery's objects derive their own prefix rather than reading the store's.** During a root switch
  `ArchiveLibrary` is still finishing the previous root's pass; borrowing `RootFolderStore`'s current answer
  would judge one root's rows against another's.

  🔺 **`RootFolderStore` now takes an injected `UserDefaults`, and that is what made the adoption path
  testable at all.** `setRoot` WRITES `archiveRootBookmark`, so before this no test could touch it without
  risking the owner's real root (the 2026-07-11 incident) — which is why the store's only two existing tests
  both stopped at `adoptTestRoot`. Production passes `.standard`;
  `testSetRootNeverTouchesTheStandardBookmarkKey` is the guard that the injection holds.

  🔺 **My own adversarial pass caught a regression I had just written.** The reveal target was rebuilt with
  `URL(fileURLWithPath: rootPath).appendingPathComponent(…)`, and that initialiser **normalises composed
  Unicode** — on a volume storing a decomposed name it would emit a spelling the walk never produced, trading
  this item's bug for `W26.idx`'s. Joined as strings now, the same way `ExcludedFoldersStore` does it.

  **Deliberately NOT touched.** `CorpusRootFingerprint.capture` (the item protects it: `stat`/`statfs`/
  `access` all follow the link, so it already fingerprints the enumerated directory) and `LibraryIndexRoot
  .path` — an opaque cache identity that is never compared against file paths, so re-spelling it would orphan
  rows for no gain.

  **Tests.** 12 new (Reader 354 → 366), every fixture built on a **mid-path** symlink so nothing upstream can
  hide the divergence, and the write test asserts the tag actually landed on disk. **7 mutants, each caught
  by a named test:** adopting the pick rather than the target; `discoveredPathPrefix = url.path`; an
  unopenable pick failing silently; and each of the warm-start, re-verify, watcher and display-filter
  comparisons reverted to the old spelling. One test was rewritten after it proved vacuous — the prefix
  assertion passes against `url.path` unless there is a link in the path, because the unit bundle's
  `NSTemporaryDirectory()` is the app container's tmp and not `/var/folders` (memory
  `app-hosted-tests-sandboxed-tmp`).

  **Gate.** Reader 366/366 executed unit tests TEST SUCCEEDED (known `DeepLinkTests` env artifact excluded),
  Release BUILD SUCCEEDED, 0 source warnings; ArchiveCore 204 XCTest + 105 swift-testing; write-surface lint
  clean on both trees + self-test 14/14; **VM XCUITests 17/17** (`ops/gui/vm-gui-runner.sh xcuitest`). Scratch
  `mktemp` fixtures and a throwaway defaults suite only; no corpus access and no host-screen UI automation.

  **Not asserted, on purpose.** The sidebar's own exclusion branch is reachable only through an async sink,
  and with an exclusion live that sink queues a content-index prune that took ~12 s to yield the main actor —
  a slower whole suite in exchange for re-testing the one shared value the display-filter assertion pins. The
  real `NSOpenPanel` route cannot be driven headlessly either; the refusal *values* are tested, its wiring in
  `chooseRoot` is by inspection. **One visible consequence worth knowing:** a symlinked pick is adopted as its
  target, so the toolbar shows the TARGET's folder name rather than the link's.

- [x] **W26.symroot — an archive root that is ITSELF a symlink is now walked through its target
  [S · low · Tier-2]. ✅ SHIPPED 2026-08-06** — `1e7044d` (the walker + its tests) → this commit (the
  trackers, the plan's §4.6 correction, and the follow-up).

  **What it was.** `FileManager.enumerator(at:)` refuses a root that is a symbolic link: it reports the link
  to `errorHandler:` and yields zero objects, even when the target is a readable directory full of tagged
  files (re-measured 2026-08-06, including through a trailing-slash spelling — that changes nothing). So such
  a root discovered **nothing at all** — first as a completed-looking empty pass, then, once `W26.vocab-fu1`
  taught the probe to `lstat`, as an honest `rootUnreadable` ("Archive folder unreadable"). Pre-existing and
  predating Wave 26; nothing in the repo produces a symlinked root, so this was about a setup a user could
  reasonably choose, not a regression.

  **The fix.** `rootIsOpenable(_:) -> Bool` became `public CorpusWalker.canonicalRoot(_:) -> URL?` — *"what
  must I enumerate for this root, or nil if I cannot open it at all"* — consumed by **both** `scan` and
  `scanFingerprints`. A symlinked final component resolves through `realpath(3)`; everything else is returned
  unchanged. `realpath` rather than a hand-rolled `readlink` chase because it settles a link-to-a-link, a
  relative destination and an `ELOOP` cycle in one call and fails outright on a dangling one. The resolved
  path is then still `opendir`-probed: `realpath` **succeeds** for a link to a regular file, so that second
  probe is the only thing rejecting it — and it is the mutant that a "this is redundant" simplification trips.

  🔺 **THE ITEM'S OWN PRESCRIPTION WAS MEASURED WRONG — this is the durable part of the entry.** As filed
  (and as echoed in the plan's §4.6), the fix was to walk the target but **rewrite every discovered path back
  under the caller's link prefix**, on the grounds that returning resolved paths *"breaks the byte-exact path
  contract `LibraryIndex` keys on … `/var` → `/private/var` means that is not a corner case."* Measured
  2026-08-06: the enumerator **already** hands back fully ancestor-resolved paths — hand it a root spelled
  `/var/folders/…` and every entry comes back `/private/var/folders/…` — so the caller's spelling was never
  what the walk emitted, and the contract in question is that the walk's OWN output is stable, which it is.
  The rewrite would have been actively harmful: it would invent a *third* spelling that neither FileManager
  nor FSEvents ever produces, so `CorpusWatcher`'s realpath'd live events would match **no row**, and every
  tag write under such a root would read as a brand-new file. **Identity therefore follows enumeration**, and
  `testARootThatIsItselfASymlinkIsWalkedThroughItsTarget` asserts that in BYTES against a direct scan of the
  target — it is the test that fails if someone re-implements the filed design.

  **Why only the FINAL component.** `realpath`-ing every root would re-spell every root in the suite
  (`/var/folders/…` → `/private/var/…`, and a case-mismatched pick on a case-insensitive volume) and orphan
  cached rows wholesale — the cost the filed item was right to worry about, just about the wrong mechanism. A
  non-symlink root is therefore handed to the enumerator byte-for-byte as the caller spelled it, so nothing
  that exists today can shift; `testANonSymlinkedRootIsUsedEXACTLYAsTheCallerSpelledIt` pins both halves of
  that asymmetry (root keeps the spelling, entries come back resolved) from a single pass.

  **Gate.** ArchiveCore 201 XCTest (199 before) + 105 swift-testing; Reader unit bundle, Processor Debug
  build, Notes unit bundle all green; write-surface lint + self-test clean on both trees. Four mutants — the
  symlink branch removed, the `opendir(resolved)` probe dropped, `realpath` applied to every root, and
  `scanFingerprints` left on the unresolved root — each caught by a named test. Scratch `mktemp` fixtures
  only; no corpus access, no host-screen automation.

  **Filed:** `W26.symroot-fu1` — the Reader's own root-relative logic (folder tree, exclusions, link writing,
  and `CorpusWatcher` containment) still compares against its granted **link** spelling, so live updates stop
  entirely under such a root; the naive fix there loses the sandbox security scope. Open in `SUITE_TODO.md`.

- [x] **W26.reinfect — the approved JPEGS-index item can no longer re-introduce `NSMetadataQuery`
  [S · low · Tier-1]. ✅ SHIPPED 2026-08-06** — `39d1567` (the rewrite + the tag + the edge) → this commit
  (the tracker move + the plan's Site 7).

  **What it was.** `SUITE_TODO.md` §"PDF + JPEG dual image reference" §2 read *"Detection: index the JPEGS
  tree (**a second `NSMetadataQuery`**). This is **REQUIRED, not an optimisation** — 80.1% of partners need
  relocation resolution no path rule can do."* Open, owner-approved, and therefore the one place in the
  backlog that could have put Spotlight back into the codebase Wave 26 exists to clear. `despotlight.md`
  §"Site 7" called it the highest-value find in the doc lane, and it was right to.

  **What shipped.** The requirement is untouched — the relocation problem is real and no path rule solves
  it. Only the mechanism changed: `ArchiveCore.CorpusWalker` over the JPEGS subtree, `scanFingerprints`
  (one following `stat(2)` per file, **no** per-file tag read, since a partner lookup needs no tags),
  building `stem → [path]` plus collection context. The resolution order (exact mirrored subpath → indexed
  stem in collection context → refuse when ambiguous) is unchanged.

  **Three things the rewrite could say that the original could not**, each from measuring rather than
  reading:
  - **It is a second SUBTREE, not a second root** — and this is what changed the blocking edge. `Archival
    Photos JPEGS` is a **sibling of** `Archival Photos` under `~/Desktop/Google Drive/` (measured
    read-only today), so design decision #1's root raise *already contains it*: no second bookmark, and it
    is already inside what `CorpusWatcher` watches and `LibraryIndex` keys on. The same measurement says
    the JPEGS tree is **163,106 files** (4.8 s to enumerate) against the main tree's 123,302 — so the root
    raise roughly **doubles every cold walk** (~286k files). The item therefore got
    `(blocked-on: W26.walk2, W26.verify)`, **not** the `(blocked-on: W26.walk1)` `W26.reinfect` specified:
    `walk2` because raising the root while discovery was still Spotlight-only would have put 286k files at
    the mercy of the index that failed on 2026-08-04, and `verify` because its 100k+ scale lane — never yet
    run — is the measurement that says whether doubling the walk is affordable at all.
  - **Absence must stay distinguishable from failure.** "No partner" **hides the switch**, so it may only
    be concluded from a clean pass; an incomplete or denied JPEGS walk means *partner unknown*.
    `CorpusScanResult` already separates the two. This is `W26.deny`'s defect written down for a second
    consumer **before that consumer exists**, which is the only cheap moment to do it.
  - **Storage is an open sub-decision**, now named instead of left implicit: a stem table inside the
    existing `LibraryIndex` SQLite DB (which already carries untracked rows — `entry.tracked` +
    `entry_root_tracked` — and the warm-start/revalidation machinery a separate index would duplicate)
    inherits its byte-exact path contract and therefore `W26.symroot`'s open question.

  **The item had no tag, and that was the actual reason it kept going stale.** Both `W26.reinfect` and
  `despotlight.md` §Site 7 cite it as `SUITE_TODO.md:1048`; it was at line 1384 by the time this ran — 336
  lines out. It is now **`W24.jpeg1`** (the `W24.*` namespace already holds owner-decided items that are
  not for the daemon queue, e.g. `W24.cal1`).

  **The `(blocked-on:)` clause is documentation and deliberately cannot be more than that.**
  `next-queue-item.sh` draws its *candidates* from the plan's `## WORK QUEUE` region only — it reads
  `SUITE_TODO` just to resolve tag state — and `W24.jpeg1` is kept out of that region on purpose, because
  §3 changes `DurableLink`, a cross-app contract, making it owner-gated. Mirroring the line into the plan
  to "make the edge live" would make the item **daemon-pickable**, i.e. the exact opposite of the intent.
  What keeps the daemon off it is its absence from the plan queue; the tag and edge are for the human who
  eventually picks it up.

  **Gate, and the one honest deviation from it.** The item's test was *"`grep -n "NSMetadataQuery"
  SUITE_TODO.md` returns nothing outside Wave 26's historical notes"*. It now returns **one** hit outside
  §Wave 26: the superseded clause, quoted inside the annotation that replaces it. That is deliberate —
  deleting it would erase the record that the mechanism was *changed by decision* rather than lost in an
  edit, and it is the same "passage explicitly annotated as history" carve-out `despotlight.md` §7a.7
  already had to add to `W26.verify`'s own grep for the same reason. `W26.verify`'s grep is unaffected
  either way: it covers `ArchiveReader/`, `ArchiveProcessor/`, `packages/` and `scripts/`, not root
  markdown. The second half of the test (*"`next-queue-item.sh` reports the JPEGS item as
  `blocked:W26.walk1`"*) was already flagged stale on 2026-08-05; it is worse than stale — the script never
  prints that item at all, for the structural reason above.

  **Nothing filed.** No code was touched; this is a Tier-1 tracker change.

- [x] **W26.oracle — the E2E test oracle reads Finder tags from the xattr, not `mdls` [S · low · Tier-1].
  ✅ SHIPPED 2026-08-06** — `50ea4a1` (the shared reader + the byte-identical predecessor proof) → this
  commit (the swap, the gate, the trackers).

  **The defect, and the correction to how the item described it.** `assert_mac.py:43` built its Finder-tag
  blob with `sh("mdls", "-name", "kMDItemUserTags", p)`, consumed at `:44`/`:55` by the assertion *"every
  expected year appears in an output filename OR a Finder tag."* The item said this *"would have"* reported
  empty tags during the 2026-08-04 incident. **Measured on this machine, that is too kind.** The harness puts
  TESTOUT at `/tmp/ap-e2e-$$/out` (`e2e-phone-mac.sh:34-35`), and neither `/tmp` nor `/var/folders` is
  Spotlight-indexed — so on a file whose tags `xattr -px` returns in full, `mdls` answers
  `kMDItemUserTags = (null)` and **exits 0**. The tag branch of that year check has therefore been **dead in
  every E2E run there has ever been**; `year` could only ever be satisfied by the output filename or the
  extracted text. The real cost was never a false FAIL — it was a silently missing assertion: a regression
  that stopped writing the year into filenames but kept tagging it correctly would have been reported as
  *"date extraction or tagging broke"*, and a regression that broke only tagging could not be caught at all.

  **What shipped.** `ArchiveProcessor/scripts/finder_tags.py` is now the one Spotlight-free Finder-tag reader
  for the Processor's oracles. `read_tags(path) -> (names, label, status)` reports **why** an empty answer is
  empty — `absent` (verified) vs `unreadable` (denied, vanished, malformed, timed out) — which is W26.deny's
  distinction (`2956f3c`, `ArchiveCore.TagXattr.inspect`) carried into the Python lane. Only the exact
  `No such xattr` stderr signature confirms absence, so a future macOS wording change degrades to *"I could
  not look"* and never to a false *"there is nothing here"*. A **zero-length** attribute is `absent`, not an
  error, because W26.deny measured that calling size 0 a failure mis-flagged 51 real corpus files.
  `assert_mac.py` now folds the xattr-read tag names into its blob, **prints the tags it read** (the E2E
  report showed nothing about tags before), and when a year is missing while any tag read failed it says the
  check *"may be a blind check rather than a real failure"* instead of blaming tagging.

  **`tier2_assert.py` was touched, so the gate was equivalence, not a bare import.** It owns the assertions
  for `test-tier2.sh` — the one driver that really tags files — so its local `disk_tags` was moved into the
  shared module verbatim, and the **predecessor** (`git show HEAD:`) and the new version were run against the
  same synthetic run dir in all three tagging modes from a foreign cwd: byte-identical stdout and exit codes,
  including the tag-derived assertion text (`tags=['Red','Box','Unread']`, `labelNumber=6`), so the
  comparison is not vacuous. That also proves the sibling import resolves as actually invoked — `python3
  "$REPO/scripts/tier2_assert.py"` puts the scripts dir on `sys.path[0]`.

  **The gate: `./ArchiveProcessor/scripts/test-finder-tags.sh`** (~2 s, no key, no network, no app build,
  `mktemp` only). Lane 1 is `finder_tags.py --self-test`: every status branch against a real fixture —
  tagged, no-xattr-at-all, zero-length xattr, vanished, `0o000`, non-plist value, bare colour name with no
  `\nINDEX` suffix — plus a no-write assertion. Lane 2 builds the incident inside the test lane: a `/tmp`
  fixture Spotlight has never indexed, whose expected year exists **only** as a Finder tag, with the ground
  truth held **outside** TESTOUT (inside it, the oracle would find the year in its own ground-truth file and
  the lane would pass without reading a tag). Four linked assertions: `mdls` finds no year there; the oracle
  PASSES anyway; stripping the tag makes it FAIL (so the pass was *caused* by the tag); making the tag
  unreadable makes it FAIL *while naming the blind read*. 26 checks green.

  **Mutation-tested rather than assumed green, and it found a real hole.** Six mutants, and the first pass
  killed only five: reverting to `mdls`, calling a denied read `absent`, dropping the blind-read diagnostic,
  losing the bare-colour label index, and dropping tags from the year blob were all caught by a named check —
  but **making a zero-length xattr `unreadable` SURVIVED**, because every "no tags" fixture had no attribute
  at all and so never reached that branch. A present-but-empty attribute (`xattr -w … "" file`, which does
  appear in the attribute listing) was added; that mutant is now caught by name. This is the branch W26.deny
  measured against the real corpus, so it was the one that most needed a fixture.

  **Filed:** `W26.oracle-fu1` — `tier2_assert.py` still calls the compatibility `disk_tags`, so an unreadable
  tag xattr **passes** its `mode == 'none'` assertion that no tags were written; that is the W26.deny defect
  surviving in the money lane's oracle, and it needs no key to fix or test. `W26.lint-fu` extended to wire
  `test-finder-tags.sh` into the health gate — a test nothing runs is the `W26.lint` failure mode, and this
  wave has now shipped three such scripts.

  **Not done, deliberately:** `test-tier2.sh` was not run. It needs a Gemini key, costs money, and **cannot
  pass on this machine at all** — `pypdf` is not installed, and `tier2_assert.py` makes that a hard failure
  (`"pypdf not available — cannot verify PDF structure"`). Raised in the Daemon Report rather than fixed
  inside this item. The equivalence proof above is what stands in for it, and it is stronger than a single
  live run: it compares every assertion's text against the predecessor instead of just checking a verdict.

- [x] **W26.fsev-fu2 — a first scan against a root that will not open no longer spins "Scanning…" for ever
  [S · low · Tier-1]. ✅ SHIPPED 2026-08-06** — `5b4a8c8` (the deadline) → this commit (5 tests, 4 mutants,
  the lanes, trackers).

  **The defect.** `W26.fsev-fu1` bounded the FSEvents stream's `open(2)`, so an unopenable root drew a window
  and the status bar said *"Archive folder is not responding"*. `CorpusWalker`'s own `opendir(3)` probe
  blocks on the **same** root, on its dedicated `Thread`, with no bound at all — the pass never reaches
  `finish`, `LibraryPhase` stays `.firstScan(done: 0, seen: 0)`, and `LibraryEmptyState` reads that as
  `.scanning`. An honest status bar above a list-blanking spinner that lies for ever, which is precisely the
  "I could not look" / "there is nothing here" split this wave exists to close.

  **Reported, not cancelled — forced, not chosen.** A thread blocked in `opendir`/`readdir` cannot be
  interrupted, and `ScanCancellation` is only consulted between directory entries, which a stalled probe
  never reaches. So `scanStallTimeout` (5 s) changes what the app *says*, not what it is doing: a pass that
  has examined **zero** files by then publishes `.degraded(.scanStalled)` — a new `DiscoveryFailure` case,
  *"Archive folder has not answered"*, distinct from `liveUpdatesStalled` (which is about the refresh
  channel, with a real list underneath) and from `rootUnreadable` (which is a finished answer).

  **Five seconds, not the stream's two, and keyed on files rather than time alone.** A healthy walk emits its
  first 500-file batch in ~40 ms (measured: 123,028 files in 10.15 s), so five seconds with nothing seen
  means the root probe itself has not returned. One examined file proves the pass is past that probe, so
  `filesSeenInCurrentPass` — tracked for revalidations too, which record no visible progress but hang just as
  readily — is the discriminator. ⚠️ Known and accepted: a root of **fewer than 500 files** emits no progress
  until the walk ends, so a genuinely slow small folder can draw the sentence for the second or two before
  its pass lands. Self-correcting, and never authoritative.

  **It grants nothing.** `.degraded` is not settled, so no content-index pruning and no authoritative
  absence — and the phase is set **directly** rather than through `DiscoveryHealth`, deliberately: that type
  judges a *finished* pass, and every caller of `isSettled` is entitled to assume a phase it produced
  describes one. The empty state says `couldNotLook`, never `.nothingTagged` / `.folderIsEmpty`.

  **Two supersedings, not one.** A late pass withdraws the verdict through the generation token that already
  existed — and so does the first progress callback, because a walk that is producing rows must not keep a
  phase the empty state reads as "could not look". Without that, the wrong sentence would stand for the whole
  remaining duration of a walk that had merely been slow to start.

  **The non-obvious edit.** `requestRootRescan` optimistically resets the phase to a scanning one whenever it
  is asked for a re-walk. ⌘⌥R is the likeliest thing an owner staring at "has not answered" will press — and
  the failure's own tooltip says it will not force the stalled read to return — while `drainWatchWork`
  refuses to start anything with the stalled walk still in flight. Unguarded, the press would have put back
  the exact silent spinner this item removes.

  **Mutation-tested, four mutants, each caught by a named test:** removing the report entirely (the pre-fix
  behaviour — kills 4 of the 5 tests, the survivor being the one that asserts a stall must *not* happen);
  dropping the zero-files discriminator; dropping the `requestRootRescan` guard; dropping the
  progress-withdrawal. Honest limit: `finish`'s `cancelScanStallDeadline()` is defence-in-depth whose only
  real window — a deadline firing during a slow SQLite commit after an empty-folder pass — I could not make
  deterministic; the `inFlight != nil` guard is what closes the general case.

  **Verification.** Reader Debug **354/354** executed unit tests (349 before; known `DeepLinkTests` env
  artifact excluded), 0 source warnings; Reader Release clean; write-surface lint clean + self-test 14/14;
  **Reader XCUITests 17/17 in the headless Tart VM** (its fixture again indexed 0/11 by Spotlight while the
  app listed everything). No ArchiveCore change, so no cross-app rebuild was owed. No host-screen automation,
  no real-corpus access; scratch corpora and scratch SQLite files only.

- [x] **W26.fsev-fu1 — `FSEventStreamCreate` no longer opens the root on the MAIN THREAD at launch
  [S · med · Tier-2]. ✅ SHIPPED 2026-08-06** — `a4aced6` (the sequencing + 5 tests) → this commit (the
  identity case, the suite-wide lanes, the VM lane, trackers).

  **The defect.** `NavigationModel.init()` → `ArchiveLibrary.start(scope:)` → `startWatcher` →
  `CorpusWatcher.start()` → `FSEventStreamCreate` → **`open(2)`, on the main thread.** Found by
  stack-sampling a Reader unit run that sat 9+ minutes at 0% CPU against the owner's real corpus root, not
  by reading the code. On local disk the open is microseconds, which is how it survived a whole wave; under
  an unanswerable TCC prompt, a stalled network/cloud mount or a disconnected volume it never returns and
  **the app never draws a window** — no message, nothing to cancel.

  **Why it was not a `DispatchQueue.async` around one line.** `W26.fsev` deliberately starts the stream
  BEFORE the launch walk, because a change in the interval between them is lost for good
  (`kFSEventStreamEventIdSinceNow` cannot replay it). The fix keeps that ordering and inverts *who waits*:
  the **walk** is now deferred behind the start (`passWaitingForWatcher`, gating both `beginScan` and
  `drainWatchWork`) instead of the **main thread** waiting on the open. Same guarantee, different victim.

  **The deferral is bounded.** `watcherStartTimeout` (2 s) turns a silent stall into a drawn window: a root
  that will not open degrades to "list what you can, no live updates" with a new
  `DiscoveryFailure.liveUpdatesStalled` — *"Archive folder is not responding"*, distinct from
  `liveUpdatesUnavailable`, which is a **finished** answer about a journal-less volume rather than "no
  answer yet". The start is not abandoned: if it ever returns, the stream is adopted and pays for the
  interval it missed with **exactly one** catch-up pass. `retryWatcherIfNeeded` therefore no longer reports
  an outcome (it cannot), and `revalidateOnActivation` gets its catch-up from the start's own completion
  instead of from a synchronous return value.

  **Three decisions that are not obvious, each measured or reasoned rather than assumed.** (1) A dedicated
  `Thread`, not a shared queue — a start stuck in `open` must not hold a pool slot that the NEXT root's
  start would queue behind, which would make one bad volume cost every subsequent one its live updates.
  (2) `CorpusWatching` gains `Sendable` but deliberately **no lock**: a lock held by a `start()` that never
  returns would block `stop()` on the main thread and restore the original bug in a new place. Safety comes
  from the call discipline instead (`stop()` only ever on an instance whose `start()` has returned), which
  is now written down on the protocol. (3) `watcherDidStart` checks watcher **identity**, not just root
  generation. Every abandonment path clears `pendingWatcherStart`, and the one sequence where the generation
  cannot help — a RootChanged event with no resolver installed re-walks the *same* root, then ⌘⌥R starts a
  second stream under that same generation — is now a test. Removing the identity clause was **verified** to
  fail it; the first version of that test passed without the clause and was rewritten for that reason.

  **DEBUG fixture roots keep the inline start, on purpose.** `beginScan`'s fixture branch is synchronous
  because two shipped tests read `files` the moment `NavigationModel()` returns and the XCUITest lane's
  `waitForRows` timings were calibrated against that; a fixture root is a scratch directory the test itself
  just made on local disk, where the hazard cannot arise. One `isFixtureRoot` spelling now serves all three
  behaviours that key off it, so they cannot drift.

  **Tests: 6 new cases in `CorpusWatcherLibraryTests`** — the syscall runs off the main thread (the defect
  itself, pinned at its narrowest); the walk waits for the stream while `start(scope:)` returns; a stalled
  start still lists what is readable, says why, and later adopts the stream with one catch-up pass; a
  stalled start that fails late reports the journal answer instead of the stall wording; a root switch
  abandons a still-stuck start; and the identity case above. **Three mutations, all caught by name**:
  dropping the identity check, making a late stream owe no catch-up pass, and removing the walk's hold each
  failed a specific test. `testBurstQueuesAtMostOneMoreRootWalk` now asserts 0 passes mid-burst rather than
  1 — the coalescing invariant it exists for is unchanged, the launch walk simply has not started yet.

  **Lanes.** Reader Debug **349/349** executed unit tests (the known `DeepLinkTests` env artifact excluded)
  with 0 source warnings; Reader Release clean; write-surface lint clean + self-test 14/14; **Reader
  XCUITests 17/17 in the headless Tart VM** (the fixture was indexed 0/11 by Spotlight and the app still
  listed everything — `W26.walk2`'s hostile proof, re-run against the new launch sequencing, which is the
  one lane that could have caught a fixture-synchrony regression). No `ArchiveCore` change, so no cross-app
  rebuild was owed; no host-screen automation and no real-corpus access.

  **Filed:** `W26.fsev-fu2` — the *walk*'s own `opendir` has no deadline, so an unopenable root still spins
  `.firstScan` forever even though the status bar is now honest about it.
  **Not verified, deliberately:** whether this also stops the `DeepLinkTests` bundle **hang** described in
  Reader `KNOWN_ISSUES.md`. Confirming it means provoking a TCC prompt on the owner's physical screen, which
  an unattended session may not do. The main-thread half of that presentation is gone by construction; the
  environment artifact itself remains `W20.deeplink-isolation`.

- [x] **W26.vocab-fu1 — ArchiveCore: a missing or unopenable ROOT is now `rootUnreadable` [S · low ·
  Tier-1]. ✅ SHIPPED 2026-08-06** — `e050ebd` (the probe, the lint fix, ArchiveCore tests) → this commit
  (the app lanes + trackers).
  **The premise, re-measured before fixing it (and it was worse than filed).**
  `FileManager.enumerator(at:)` returns a **live enumerator for a root it cannot open** — confirmed across
  all three ways a root goes bad, not just the filed one: a path that does not exist (`ENOENT`), a `0o000`
  directory (`EACCES`), and a regular file handed in as a root (`ENOTDIR`). In every case the enumerator
  is non-nil, reports the root once to `errorHandler:`, and ends. So `completed == true`,
  `rootUnreadable == false`, `filesSeen == 0`, and a walk that read **nothing** was indistinguishable from
  a walk that **found** nothing to any caller gating on `completed`. The `guard let enumerator … else`
  branches in both walk functions were dead code. `rootUnreadable` now means what its name says, for
  `scan` and `scanFingerprints` alike, via an `opendir(3)` probe ahead of enumeration.
  **Two things the probe deliberately is NOT**, both measured rather than reasoned about:
  1. **Not a comparison against the URL the error handler reported.** For the `0o000` root FileManager
     hands back `/private/var/…` while the caller passed `/var/…` — so a path or byte comparison answers
     "that was not the root" for the exact case it must catch. (The `/private` alias trap again.)
  2. **Not `opendir` alone.** `opendir` FOLLOWS a symlink; `FileManager.enumerator` does not. Measured: a
     root that is itself a symlink is refused outright — reported to `errorHandler:`, zero objects — even
     when its target is a readable directory full of tagged files. My first cut called such a root
     openable, and the test written to prove symlinks were fine is what failed. An `lstat` on the **final
     component only** now precedes the `opendir`, so a symlinked root is the last instance of this defect
     rather than a survivor of it; aliased *ancestors* (`/var` → `/private/var`, where every fixture in
     the suite lives) are untouched, with a test that fails if they ever are not.
  **A latent bug in the code this deleted.** `W26.vocab`'s local `mayStamp` compared
  `directoryErrors` against the root by `standardizedFileURL.path` — which does not resolve the
  `/private` alias, so for the `0o000` case it did **not** match and the harvest would have stamped a
  wholly unreadable root as covered. The walker-level answer has no such hole. Per the item's own
  instruction, `mayStamp` is deleted rather than left as a second opinion: `SystemTagsProvider` now stamps
  on `result.completed`, and the ArchiveCore mirror of the rule was collapsed the same way.
  **The counter-case is tested, because the tightening is dangerous without it.** A denial *below* the
  root still completes the pass. Otherwise every sealed subfolder would re-file as an unreadable archive,
  and the Processor's harvest — which stamps on `completed` — would re-walk a 100k-file corpus once per
  tagging-UI appearance.
  **Reader effect, as the item predicted:** a missing/denied/not-a-directory root now reports
  "Archive folder unreadable" instead of the generic "1 folder could not be read". `DiscoveryHealth`'s
  `.neverIdentified` clause is kept — it is an independent observation (`CorpusRootFingerprint.capture`
  failing) — and both its comment and `LibraryPhase`'s, which asserted the walker could not see a sealed
  root, are corrected.
  **The write-surface lint went RED, on prose.** Rule 3 bans the `errorHandler:`-less overload, and
  documenting *why* means writing `FileManager.enumerator(at:)` in a doc comment — which the balanced-paren
  matcher read as the violation being described, so the honest way to explain the rule was to trip it.
  Rule 3 now skips a match whose starting line opens a comment (`//` or `*` as the first non-space
  characters, checked on the line the rule already reports); a real call sharing a line with a trailing
  comment is still caught, and the only thing it can now miss is commented-out code. Guarded in **both**
  directions by two new self-test cases — prose passes, the identical text as code still fails — because
  an untested lint relaxation is exactly how rule 1 came to pass vacuously (`W26.lint`).
  **Gate.** ArchiveCore 199 XCTest + 105 swift-testing; Reader **343 executed unit tests, TEST SUCCEEDED**,
  Release build clean, zero source warnings; Processor Debug clean (its scheme has no test action — the
  behaviour it lost lives in the ArchiveCore harvest mirror); Notes 189 + 738; write-surface lint clean on
  both trees, self-test **12 → 14**. No VM lane: the only visible change is which sentence the empty state
  shows, and `LibraryDiscoverySwapTests` already asserts that end to end through the real `ArchiveLibrary`
  against a scratch tree (`LibraryEmptyState.forPhase(…) == .couldNotLook(.rootUnreadable)`), which is a
  tighter assertion than a screenshot. Scratch/temp fixtures only; the real corpus was never touched.
  **Filed while shipping:** `W26.symroot` (a symlinked archive root cannot be discovered at all —
  pre-existing, and the obvious fix breaks `LibraryIndex`'s byte-exact path contract) and **`W26.fsev-fu1`
  (`FSEventStreamCreate` blocks the MAIN THREAD at launch)** — the latter found by stack-sampling a Reader
  unit run that hung 9+ minutes at 0% CPU, which is also a **material escalation of the known
  `DeepLinkTests` environment artifact**: it no longer merely fails, it hangs the whole unit bundle, so a
  session must exclude it up front rather than wait it out. See Daemon Report.

- [x] **W26.vocab — Processor `SystemTagsProvider` off Spotlight → persisted `TagVocabulary` [M · low].
  ✅ SHIPPED 2026-08-06** — `a90bbc8` (the store + 28 tests) → `2d7c7c2` (the provider rewrite; the last
  `NSMetadataQuery` in the Processor) → `eaa7987` (the harvest composition, and the two defects its first
  filesystem test found) → `a25ee02` (the write-path Tier-2 proof) → this commit (trackers).
  **What shipped.** `ArchiveCore.TagVocabulary` — a persisted, monotonically-growing set of **subject** tag
  names, replacing an `NSMetadataQuery` scoped to `NSMetadataQueryUserHomeScope` with
  `kMDItemUserTags LIKE "*"`. No per-root walk reproduces a home-wide scope, so the plan's §4.4 answer is
  to change SHAPE rather than mechanism: stop re-deriving the vocabulary on demand and accumulate it, from
  three non-Spotlight sources — a one-per-root `CorpusWalker` harvest of the persisted output directory,
  every tag the operator types (`register`, now flushed synchronously so it survives a relaunch), and every
  Finder-tag write the app performs, taken from `TagWriteResult.after`/`.afterLabel` — the tags that
  VERIFIED on disk, not the ones intended.
  **The `$HOME` prohibition is a function, not a comment.** `isHarvestableRoot` refuses `$HOME`, the nine
  personal-data folders directly inside it, and the whole-filesystem roots, case-insensitively (the boot
  volume is, so `/users/me/desktop` would otherwise bypass a guard that only knew the canonical spelling).
  A *specific* folder inside Desktop — the real corpus is one — stays harvestable.
  **Two defects found by the FIRST filesystem test of the harvest, neither reachable from the unit tests**
  (which hand `add` literal arrays and never walk anything): (1) the harvest ingested through the walker's
  `([String]) -> Bool` predicate, which carries no Finder label, so the marker colour was never dropped —
  and since this app stamps Red or Purple on every real-tagging output, "Red" and "Purple" were on course
  to become permanent entries in a field labelled *Subjects*, while the write path (which has
  `afterLabel`) already avoided exactly that. Fixed with an additive
  `onTagsRead: (@Sendable ([String], Int?) -> Void)?` on `CorpusWalker.scan`/`scanOnDedicatedThread` —
  every successful read, matching or not, before the predicate, never consulted for the result, default
  `nil` so no existing caller changes. It also retires the smell it replaces: the predicate is no longer a
  sink defended by "do not fix this to return true". (2) A **vanished archive root was stamped as
  harvested**, because `FileManager.enumerator(at:)` returns a live enumerator for a missing directory and
  the pass comes back `completed == true` / `rootUnreadable == false` / `filesSeen == 0`. New
  `mayStamp` also requires the root to be absent from `directoryErrors`; a denied *sub*directory
  deliberately still stamps, because an unstamped root is re-walked on every tagging-UI appearance.
  **A third defect, from the adversarial pass:** the store's test-mode redirection checked only
  `ARCHIVEPROC_HEADLESS`, but `scripts/test-tier2.sh` — the one driver that runs the REAL tagging pipeline
  over the Ground Truth fixtures — sets `PROCESSFILES_TESTMODE` instead, so the run that tags the most
  files was the run that would have written fixture subjects into the operator's real vocabulary. It now
  uses `KeychainHelper.isHeadlessTestMode`, the suite's existing enumeration of driver environments.
  **Tier-2 gate.** `ArchiveProcessor/scripts/test-tag-vocabulary.sh` + `scripts/tag-vocabulary-driver.swift`
  — 51 assertions over the REAL `MacOSTagger` / `SystemTagsProvider` / `DefaultsKeys` / `KeychainHelper`,
  compiled standalone against the REAL ArchiveCore (the Processor has no XCTest bundle; this is the
  `test-drive-store.sh` pattern) and driven on scratch files across separate PROCESSES. Tag and label
  expectations are copied verbatim from `MacOSTaggerParityTests`, which predates the hook, so a perturbed
  write shows up as a diff against the old behaviour. It pins: the write is unchanged; the ingest is the
  verified on-disk result, facet-filtered; a **refused** write contributes nothing (the hook is after the
  `try`); relaunch is a real relaunch; a real harvest stamps the root and declines to re-walk; three
  forbidden roots each record nothing and start no walk; and the store resolves outside Application Support
  under a driver environment, with a negative control proving it resolves inside for a normal run. It also
  proves **the harvest WROTE NOTHING** — every file's `(mtime, ctime, size, inode, label, tags)` is
  identical afterwards, and no file appeared. That assertion was adopted from the killed checkpoint-2
  session's uncommitted WIP (archived under `old/w26-vocab-prior-session-wip-20260806/`), which had thought
  of it and this session had not; a mutant that rewrites one fixture file's tags mid-phase is caught by
  **ctime and the tag list with mtime unchanged**, which is exactly the case a naive fingerprint misses.
  **Mutation-tested rather than assumed green** (the `W26.lint` lesson): five mutants, five killed — and one
  **survived the first attempt**, because the phase flushed the store itself right after `register`, so an
  assertion that a typed tag persists would have passed with `register`'s flush deleted. It now reads the
  JSON back before any flush of ours. An assertion downstream of the thing it tests is not an assertion.
  **The narrowing is accepted and documented, as the item required:** suggestions are now scoped to the
  archive rather than to every tagged file in the home folder, and are subjects only. Both are improvements
  for this UI; a tag existing only on an unrelated personal file outside every archive root will no longer
  be suggested. Widening the harvest to `~/Desktop` would recover most of that but needs a new user-visible
  authorisation prompt (`NSDesktopFolderUsageDescription`) — an owner decision, raised in the Daemon Report.
  **Verification.** ArchiveCore 195 XCTest + 105 Swift Testing; Reader unit bundle green; Notes bundle
  green; Processor Debug BUILD SUCCEEDED with no source warnings; write-surface lint + self-test 12/12.
  No real corpus read or written, no persisted default touched, no host-screen automation.
  **Filed:** `W26.vocab-fu1` (whether `rootUnreadable` should cover a missing root — ArchiveCore's call);
  `W26.lint-fu` extended to wire this script into the health gate, which nothing currently runs.

- [x] **W26.walk1 — `CorpusWalker` in ArchiveCore + the first-ever Reader discovery test [M · low · Tier-1].
  ✅ SHIPPED 2026-08-05** — `b3efb16` (walker + 14 tests) → `025d126` (the enumerator lint rule) → this
  commit (the Reader discovery tests + trackers).
  **What shipped.** `packages/ArchiveCore/Sources/ArchiveCore/Corpus/CorpusWalker.swift` — read-only,
  deterministic discovery whose result type is built around the distinction the whole incident turned on:
  `entries` · `unreadable` · `directoryErrors` · `filesSeen` · `vanishedMidScan` · `rootUnreadable` ·
  `cancelled`, plus **`isClean`** as the one gate before an absence may be treated as real. Tags come from
  `TagReading.read`, so discovery and the write path agree by construction — including on "could not read".
  **The four plan defects filed against this item, all closed:** §7a.3 (the promoted body's
  `guard case .success … else { continue }` silently drops an unreadable file — now counted, with its
  reason, and the pass is not clean); §4a.2 (the `errorHandler:`-less enumerator overload silently skips
  directories it cannot descend — now recorded); §7a.12 (`ENOENT` is churn, gets its own counter, is
  excluded from `entries` and must NOT count as a denial, or ordinary Finder activity permanently degrades
  the library); §4a.4 + §7a.10 (cloud placeholders — the walk runs with
  `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` **thread-scoped and restored**, and every entry carries
  `isDataless` so a later indexer can skip rather than download).
  **Two decisions the plan said to make BEFORE writing it, made:** (a) **synchronous** (§5.6) —
  `DocumentPageLinkTests`/`RootMarkerStateTests` assert discovery synchronously and keep working unchanged,
  and the thread-scoped I/O policy is only sound without an `await`; off-main callers get
  `scanOnDedicatedThread`/`scanDetached`, a real `Thread` rather than `Task.detached` (pool reuse leaks the
  policy; a ~10 s blocking walk starves the pool). (b) **everything tagged is returned** (§5.17) —
  user-excluded folders stay a post-discovery filter in `NavigationModel`, since excluded files are
  deliberately visible in the UI but absent from the content index.
  **No `getxattr` size-0 pre-filter.** The plan permitted one; declined, because only `ENOATTR` may ever
  conclude "no tags" and re-deriving that outside `TagXattr.inspect` is how `W26.deny` comes back — persisted.
  **Lint rule 3 (plan §7a.8, reassigned here by `W26.lint`):** no `FileManager.enumerator` without an
  `errorHandler:`, in either linted tree. It **cannot be a grep** — `enumerator(at:` matches ZERO
  occurrences in this repo because every call spans lines — so it balances parentheses with perl to isolate
  the whole call. Verified non-vacuous: it reports exactly the two known multi-line sites and passes
  `CorpusWalker`'s handler-bearing call. Allowances for `ArchiveLibrary.swift:97` (the call `W26.walk2`
  deletes — the STALE guard then forces the allowance out) and `PDFThumbnailer.swift:158` (its own
  disposable cache). Self-test 9 → 13 cases, including a handler-BEARING plant that must PASS, so the rule
  cannot degrade into a ban on walking.
  **Tests.** ArchiveCore 124 → 138: exact membership on a mixed fixture (tagged/untagged/other-tags-only/
  hidden/nested/package-descendant + an em-dash & NBSP filename), a **byte-identity** check comparing mode,
  size, `st_flags`, mtime, **ctime** and the raw tag xattr of every entry before and after two scans (ctime
  is load-bearing: a tag write bumps ctime without touching mtime), denial/directory-denial/unreadable-root,
  churn-is-not-denial, cancellation, batching, symlink-classified-by-target, and the I/O policy set inside
  and restored after. Reader 276 → 279 via the first-ever `LibraryDiscoveryTests` — the walker matches the
  shipped loader exactly on a readable tree, and diverges on exactly one thing: an unreadable file, which
  the loader drops in silence while still reporting a settled library. 278/279 green (the known
  `DeepLinkTests.testRevealAndSelectNoRoot` environment artifact). Notes + Processor test bundles rebuilt
  (shared-ArchiveCore rule). `lint-write-surface.sh` + its self-test clean.
  **Measured cost recorded rather than discovered:** one extra `stat(2)` per entry (~15 µs, ≈+1.9 s at
  123k) buys `S_ISREG` + `SF_DATALESS` + ENOENT-vs-denial from one call and lets the walk skip
  `resourceValues` entirely for directories — folded into `W26.verify`'s baseline.
  **Filed while shipping:** nothing new; `W26.notsup`'s dependency was CORRECTED from `walk1` to `walk2`
  (its `DiscoveryStatus`/`.degraded` surface is walk2's deliverable, so left as filed the resolver would
  have offered it with nowhere to surface — the exact problem its own text warned about).

- [x] **W26.walk2 — Reader discovery → `CorpusWalker`; delete the `PendingWrite` subsystem; honest
  discovery health [L · med · Tier-2]. ✅ SHIPPED 2026-08-05** — `f1c0d2f` (root identity + health model) →
  `b88d20a` (production swap) → `6f5d6ad` (incident regression suite) → this commit (adversarial findings,
  cross-app/VM gate, trackers).
  **The incident is closed.** Reader Release discovery now walks its selected root through
  `ArchiveCore.CorpusWalker`; `NSMetadataQuery`, `NSMetadataItem`, both observers, both `searchScopes`
  branches (including the dead whole-Mac branch), and the DEBUG-only alternate discovery mechanism are
  gone. `-ARUITestRootPath` selects only a root now, so tests and production exercise the same engine.
  The headline regression constructs `ArchiveLibrary` with that key explicitly absent and finds every tagged
  file in a brand-new, never-indexed scratch tree. In the headless Tart VM, the hostile fixture reported
  **0/11 files Spotlight-indexed after 60 seconds while Reader rendered all 11** — direct pixel evidence
  that discovery no longer depends on the failed service that caused the 1,849-file incident.
  **Honest state and absence.** `LibraryPhase` replaced `isGathering` with `.noRoot`,
  `.firstScan(done:seen:)`, `.revalidating`, `.settled(asOf:scanned:)`, and `.degraded`; the pure
  `DiscoveryHealth` mapping consults `CorpusScanResult.isClean` plus a pre/post
  `CorpusRootFingerprint`. Only `.settled` makes absence actionable or permits content-index pruning.
  Rows publish atomically at pass end; progress batches count regular files examined even when none match.
  A degraded pass preserves **every** unseen prior row — including descendants of an unreadable directory,
  for which no per-file failure URL can exist — and a degraded deep-link lookup never counts as a
  document-not-found miss. The empty UI can claim *"none carry a Read or Unread tag"* only after a clean
  scan that saw at least one file, and the rendered sentence quotes that denominator. Empty folder, no root,
  first scan, revalidation, and failure each have distinct wording.
  **The write race, without a Spotlight overlay.** The ~80-line `PendingWrite` TTL/convergence subsystem,
  its timer and its 8-case test file were deleted. A monotonic sequence guard now stamps pass starts and
  verified writes: the five existing write call sites directly replace rows from `TagWriter`'s fresh
  `.after`/`.afterLabel`, and any older in-flight pass must retain that value. There is no TTL, timer, or tag
  comparison. A verified write that removes Read/Unread membership removes its row immediately.
  **Refresh and pruning.** File ▸ Rescan Archive Folder (⌘⌥R; ⌘R remains Mark Read) is the explicit refresh
  path until `W26.fsev` ships. The two-consecutive-absence content-index gate remains, but its eligibility is
  now strictly `phase.isSettled`; revalidating, degraded, cancelled, root-replaced, and partial snapshots
  cannot prune. Excluded folders remain a post-discovery filter exactly as before.
  **Deliberate mtime decision.** Discovery now vends `.contentModificationDateKey` instead of Spotlight's
  `NSMetadataItemFSContentChangeDateKey`. Exact timestamps may differ, so the disposable content index will
  re-extract the corpus once (the measured expectation is ~17 minutes). Accepted as simpler and self-healing;
  no tolerance that might hide a real content edit, and no `content-index-v2` bump that would strand a DB.
  **Adversarial completion.** Three findings were fixed before the checkbox moved: a degraded directory walk
  could drop all previously visible descendants; degraded passes could consume a deep link's three-miss
  give-up budget; and match-sized progress batches left a large wholly-untagged tree at zero until completion.
  Each has a regression test. The empty-state accessibility element is also pinned by an off-screen UI test,
  which creates and removes only its own sandbox scratch folder.
  **Verification.** ArchiveCore: 146 XCTest + 105 Swift Testing tests green. Reader: 303/303 executed unit
  tests green with the one known environment-dependent `DeepLinkTests.testRevealAndSelectNoRoot` case
  skipped (`W20.deeplink-isolation`); Release build green; write-surface lint clean and self-test 12/12.
  Processor Debug build and the complete Notes unit bundle are green (shared-ArchiveCore gate). Reader VM:
  existing GUI suite 16/16 plus the new untagged-denominator test green; sighted capture inspected. No real
  corpus write, move, rename, delete, or content read was used. The walk1 enumerator allowance and obsolete
  fixture-comparison tests were retired in the production-swap checkpoint as required.

- [x] **W26.notsup — a volume that does not support extended attributes reads as UNREADABLE, not untagged
  [S · LOW · latent]. ✅ SHIPPED 2026-08-05** — this commit.
  **The consequence, kept safe.** `TagXattr.inspect` still treats every errno except `ENOATTR` as unreadable,
  including `ENOTSUP`; nothing special-cases an xattr-less volume back to "no tags." On some SMB/NFS mounts
  that means every file is omitted and every tag write refuses, because Finder's Read/Unread tags cannot be
  represented there. FAT/exFAT are not in this category on macOS, which emulates their xattrs. Exposure on the
  owner's APFS corpus remains zero (0 non-ENOATTR results across 123,302 files, measured 2026-08-05).
  **The missing explanation now exists.** `DiscoveryHealth` maps ArchiveCore's exact
  `extended attributes unsupported on this volume (ENOTSUP)` suffix to a distinct
  `DiscoveryFailure.finderTagsUnsupported`. The status line says *"Finder tags unavailable for N files"*;
  its detail explains that Reader cannot tell whether those files carry Read/Unread, will not list or edit
  them, and recommends using an archive copy on a Finder-tag-capable volume such as APFS before rescanning.
  A root may cross mount boundaries, so the case also retains counts for other unreadable files and folders
  rather than letting the specific diagnosis hide simultaneous failures.
  **Adversarial correction before ship.** The first classifier used a broad `(ENOTSUP)` substring. An ordinary
  localized error could contain a filename such as `report-(ENOTSUP)-draft.pdf` and be falsely diagnosed as a
  volume capability. Classification now requires the exact ArchiveCore suffix; a negative regression test
  pins that boundary.
  **Verification.** Two new health-mapping tests plus the existing empty-state wiring: targeted 24/24 green;
  complete Reader unit bundle 305/305 executed green with only the separately tracked
  `DeepLinkTests.testRevealAndSelectNoRoot` environment case skipped (`W20.deeplink-isolation`). Reader
  Release build green; write-surface lint clean and self-test 12/12. No ArchiveCore primitive or write path
  changed, no real corpus was read or written, and no physical xattr-less volume was required.

- [x] **W26.fsev — `CorpusWatcher` (FSEvents) replaces `DidUpdate` [M · med · Tier-2].
  ✅ SHIPPED 2026-08-05** — this commit.
  **The live path.** Reader starts a FileEvents + MarkSelf + WatchRoot stream on a serial dispatch queue
  **before** its launch walk, with a second security-scope access balanced across exactly the stream lifetime.
  Each asynchronous exact/subtree read owns a separate balanced operation scope and cancellation token, so it
  cannot outlive a root switch or borrow access that the stream teardown has released.
  It persists no event ID: launch establishes truth, then watches `SinceNow`. `CorpusWalker.inspect` is the
  shared one-path authority, so launch and live events agree about stat/tag failures, dataless files,
  Read/Unread membership, content mtime, and the stale-NSURL-cache trap. Semantic FSEvents flags are never
  believed: every normal event means re-stat and re-read. Hidden files, package descendants, and directory
  symlink targets remain outside the same universe as a full walk; only the measured
  `.sb-[8 hex]-[6 alnum]` atomic-save sibling is ignored.
  **Recovery and coalescing.** `MustScanSubDirs` performs a clean/degraded subtree merge; dropped/history/
  wrapped sentinels force a root pass; RootChanged/mount/unmount re-resolve the persisted bookmark and restart.
  Exact and subtree work runs off the main actor on a dedicated thread. Root passes are bounded to one active +
  one queued with a one-second minimum interval, and a queued pass keeps discovery revalidating so absence and
  content-index pruning never see a false settled window. Stream start failure is visible as *"Live archive
  updates unavailable"*: activation retries it, re-walks after five stale minutes while it remains down, and
  always performs one catch-up walk if a SinceNow stream recovers. ⌘⌥R remains immediate; there is no timer.
  **Adversarial completion.** Two independent passes found eleven defects, all fixed with regressions: SDK
  drop/history sentinels were filtered by their meaningless/outside path; a recovered SinceNow stream lost its
  outage interval; an older live read could overwrite a newer verified Reader edit; an already-queued old-root
  callback could enter the replacement root; directory→file replacement left phantom descendants; a queued
  root pass briefly published settled; and failed Start called the start-only Stop API. The write-vs-read fix
  initially discarded fresh content metadata; directory symlinks could expand outside the root; background
  subtree work borrowed the stream scope and outlived root switches; and RootChanged unioned with a drop flag
  selected the weaker full scan instead of bookmark re-resolution. The final write-vs-read rule extends the
  full-walk monotonic tag ordering to exact and subtree events, including a verified removal, while using the
  fresh inspection's mtime and type. A newer serialized live read retires converged guards so long-running
  healthy sessions do not retain every Reader edit forever.
  **Verification.** The watcher suite is 26/26, including a real local-APFS stream plus an external
  `/usr/bin/xattr` Finder-tag write and deterministic `FSEventStreamFlushSync`; the rest use disposable scratch
  trees and injected streams. ArchiveCore passed 149 XCTest and 105 Swift Testing cases; Reader passed all 331
  selected unit tests (the separately tracked deep-link isolation case remains excluded) plus its Release build;
  Processor Debug built; and all 738 Notes tests passed. The write-surface lint and its self-test are clean.
  No real corpus write, move, rename, delete, content read, or Spotlight query was used; no host-screen UI
  automation is part of this proof.

- [x] **W26.idx — `LibraryIndex` (SQLite) warm start + background revalidation [L · med · Tier-2].
  ✅ SHIPPED 2026-08-05** — this commit.
  **Durable discovery cache.** `LibraryIndex` is a sibling of `ContentIndex`: a system-SQLite actor at
  `library-index-v1.sqlite3`, outside the corpus, populated only through the SQLite C API. This is a new v1
  format with no migration, dual reader, or legacy selection-state fallback. Root identity is the conjunction
  of its byte-exact resolved path and durable marker GUID; parent/nested roots and a replacement mounted at the
  same pathname remain separate. The entry key is `(root_id, byte-exact path)` and stores every readable
  regular file, raw tag order, label, `tracked`, `verified`, dataless state, and a fresh
  `(mtime, ctime, size, inode)` stat fingerprint. `DocumentTags.parse` remains the only facet authority.
  `started`/`finished` scan provenance, counts, errors and outcome distinguish a clean settled snapshot from
  an interrupted/partial rewrite after relaunch. Only a clean pass verifies rows and applies absence.
  **Warm and revalidate.** A current snapshot publishes tracked rows immediately with explicit
  `.cache(asOf:)` provenance and `.revalidating` phase. A dedicated thread then scans cheap fingerprints for
  all regular paths and reuses raw tags only when a previously verified tuple matches exactly; ctime forces a
  read after Finder tag-only edits. New, changed and unverified paths use the same fresh
  `CorpusWalker.inspect` primitive as full/live discovery. Fingerprint batches report real cold progress;
  tag-phase batches keep the denominator monotonic. The SQLite snapshot, tag encoding and writes poll
  cancellation every 500 rows, leaving a canceled scan unfinished/unverified so a root switch is not queued
  behind 150k stale operations. Rows publish only after the durable commit, while verified Reader writes that
  land during that commit still outrank the older scan.
  **Byte and trust boundaries.** URLs are reconstructed from filesystem representations, never
  `URL(fileURLWithPath:)`. `LibraryIndexPath` hashes UTF-8 bytes and enforces absolute component containment;
  canonically equivalent NFC/NFD names remain independent. Adversarial review extended that guarantee through
  the live path: FSEvent exact/subtree sets now use byte keys, root comparisons and containment are byte-level
  (including `/`), and each live read/eligibility probe reconstructs the exact reported pathname. Corrupt
  out-of-root database rows may be loaded for diagnosis/eviction but never rendered or used as write targets.
  **Writes and cloud placeholders.** Cached rows are useful for display, never authority for a mutation.
  `NavigationModel` freshly re-inspects the cache-provenance subset before mark/group/inline/rename actions;
  missing, unreadable, untracked or out-of-root rows are rejected while valid neighbours proceed. Corpus-wide
  rename uses `TagWriter.renameToken`, which re-reads under coordination and writes only if the old token still
  exists. `ArchiveFile` carries dataless state; `ContentIndexer` deletes stale disposable FTS rows for
  placeholders, filters them before scheduling, and wraps the actual PDF-open boundary in the thread-scoped
  no-materialisation policy to close the discovery→open race.
  **Adversarial completion.** Review findings fixed before ship include old-root publication during the new
  root's async prepare gap; verified writes overwritten while SQLite committed; canceled actor work running to
  completion; cold fingerprint progress stuck at zero; partial SQLite steps presented as EOF; stale cached
  selections becoming write targets; normalized composed filenames missing live updates; corrupt outside-root
  cache rows; and weak dataless tests that observed only an intermediate deletion. Regression coverage includes
  cold→quit→warm→changed-while-closed, partial/crashed provenance, nested and replaced roots, byte-distinct
  canonical names, a forced SQLite step error, deterministic batch cancellation, root-switch and commit/write
  races, mixed cache/disk bulk writes, zero PDF-open calls for dataless rows, and the policy at the race-path
  open boundary. All fixtures and databases are disposable scratch data; no real corpus was read or written.
  🔺 **The gate ran AFTER the implementation session ended, and it was not green on arrival.** That session
  lost its tooling before the suite-wide lanes, so the work sat uncommitted in a preserved worktree with
  only focused Reader tests and ArchiveCore behind it. Completing the gate failed **three** Reader tests,
  and one of them was a real defect in this item:
  **(1) `ArchiveLibrary` — fixture roots escaped onto the persisted index via ⌘⌥R.** `start(scope:)`
  checked `ARUITestRootPath` and stayed synchronous, but `rescan()` → `requestRootRescan` →
  `drainWatchWork` did not, so a rescan on a fixture root took the **async** indexed path and opened the
  **real Application Support database from a unit test** — breaking the synchrony every fixture test is
  calibrated against (`DeepLinkTests.testDegradedDiscoveryNeverCountsAsDocumentNotFound` asserted a
  post-`rescan()` failure state that could no longer exist yet, and took 122 s to fail). Both sites now go
  through one `usesPersistedIndex` predicate, so the fixture answer cannot diverge by call path again.
  **(2) A byte-exactness test that could not fail.**
  `testComposedFilenameEventKeepsItsExactFilesystemSpellingThroughLiveRead` compared spellings with
  `XCTAssertEqual` on `String` — and Swift string equality is **canonical**, so an NFC/NFD mismatch
  compares EQUAL. Under that vacuous precondition the test was wrong in the other direction too: it emitted
  its own composed spelling for a file this volume stores **decomposed** (measured: `readdir`,
  `contentsOfDirectory` and `FileManager.enumerator` all return NFD for a name created as NFC), i.e. an
  event FSEvents can never deliver — and the library correctly answered with a **second row**. It now
  adopts the on-disk spelling, compares UTF-8 bytes, and asserts the row count stays 1, which is the
  invariant its name always claimed.
  **(3) A `/`-rooted eligibility assertion that contradicted `.skipsHiddenFiles`.** It asserted
  `/tmp/archive/file.pdf` is eligible under root `/`; macOS marks `/tmp` **hidden**, so the launch walk
  skips it and the live path must agree. Split into a positive case over an all-visible chain
  (`/Users/Shared/…`, which is what actually pins the first-separator arithmetic) and a negative case
  documenting the hidden first component.
  **Gate (2026-08-05, post-handoff).** ArchiveCore 154 XCTest + 105 Swift Testing; Reader **351/351**
  executed unit tests (the separately tracked `DeepLinkTests.testRevealAndSelectNoRoot` isolation artifact
  excluded, W20.deeplink-isolation) + Release **BUILD SUCCEEDED, 0 source warnings**; Processor Debug
  **BUILD SUCCEEDED**; Notes 189 XCTest + 738 Swift Testing; write-surface lint clean + self-test 12/12.
  **The scale and VM lanes were NOT run and are carried into `W26.verify`** — see the ⚠️ block on that item
  for the three warm-start timings, the SQLite size/RSS ceiling and the VM GUI checks it now owes. No
  host-screen UI automation, and no real corpus read or written at any point.

- [x] **W26.deny — 🔴 the same coercion is in the AUDITED WRITE PATH and it DESTROYS TAGS [S · med · Tier-2].
  ✅ FIXED 2026-08-05** — `2956f3c` (read primitive) → `ad86cce` (write path + trackers).
  **The bug:** `TagWrite.swift:252-261` carried the comment *"a read FAILURE aborts (never treated as
  empty)"* and then did `before = rv.tagNames ?? []` four lines under it. `resourceValues` **does not throw**
  for a file whose extended attributes are unreadable while its directory is traversable — it returns
  `tagNames == nil`, byte-for-byte its answer for an untagged file — so the `catch` never fired, `before`
  became `[]` for a file carrying real tags, and `transform([], nil)` produced a delta that line ~271 wrote.
  Reproduced independently here before fixing: `mode 0o200` and an ACL denying only `readextattr` both took
  `["Unread","Subj","P9"]` → `["Read"]`, write **SUCCEEDED**; `mode 0o000` failed the write (−5000) but still
  reported `before == []`, so its undo inverse was corrupt.
  **The fix:** a new ArchiveCore primitive, `TagXattr.inspect`, resolves the ambiguity at the syscall layer —
  `getxattr` on `com.apple.metadata:_kMDItemUserTags`, where **only `ENOATTR` confirms absence**. Both call
  sites route through it: `TagReading.read` (only on the `tagNames == nil` branch, so a tagged file pays
  nothing) and `CoordinatedTagWriter`, whose §2/§3 fresh read AND §8 post-write re-read now both refuse
  rather than coerce. **Later items in this wave must CALL `TagXattr.inspect`, not re-derive it** (plan
  §7a.3 makes this binding for `W26.walk1`'s pre-filter).
  ⚠️ **Two of the plan's written prescriptions were measured WRONG while shipping this, and both would have
  reintroduced the bug** (corrected in plan §4a.1 / §7a.3): (a) the probe must **FOLLOW symlinks** — NOT
  `XATTR_NOFOLLOW`, which the plan specified — because `resourceValues` reports the *target's* tags through
  a symlink, so a NOFOLLOW probe answers about the link and returns `ENOATTR` for a **denied target**;
  (b) *"`ENOATTR` or a returned size of 0 is the only honest verified-no-tags"* is too strict — removing a
  file's tags leaves a **42-byte empty-array plist**, and **51 of the owner's files** are in exactly that
  state, so the strict rule would have reported all 51 as unreadable.
  **Corpus census, read-only, 2026-08-05** (supersedes the 123,028 figure): **123,302** regular files in
  30.8 s, 0 walk errors — 21,311 `ENOATTR` · 101,940 tagged · 51 empty-array residue · **0 denied** ·
  0 undecodable · 0 non-array. So the fix changes the answer for **no file on disk today**; it guards
  against modes and ACLs arriving from network copies, restores and archive extractions.
  **Tests:** `ArchiveCoreTests/TagDenialTests` — 20 tests, throwaway temp files only. The four denial shapes,
  a corrupt attribute, a non-tag array, a symlink to a denied target, the three write-abort cases (incl. "no
  result, so no corrupt inverse" and "the transform is never even consulted"), and — the guards against
  over-strictness — untagged, empty-array residue, traverse-only parent, a plain directory, an ordinary write,
  a write to a confirmed-untagged file. Skipped as root, where every denial would pass vacuously.
  **Six mutants measured**, each red exactly where it should be: M1 the original `?? []` → 9 red incl. the
  write succeeding and destroying tags; M2 only the writer reverted → exactly the 4 write tests; M3
  `XATTR_NOFOLLOW` → only the symlink test; M4 the plan's size-0 rule → the empty-array residue; M5 drop the
  is-it-a-tag-array check → the corrupt attribute; M6 `ENOATTR` treated as unreadable → the honest cases.
  **The adversarial pass sent the fix back once:** `plist is [Any]` accepted a NON-empty array, so a tag array
  macOS declined to decode would still have been called "no tags" — the same coercion one layer in. It now
  requires the array to be empty, which also makes the read TOCTOU honest.
  Residual **`W26.notsup` shipped 2026-08-05**: an xattr-less volume remains unreadable rather than untagged,
  and now gets specific Finder-tag capability guidance through `W26.walk2`'s health surface. See the completed
  entry above and `ArchiveReader/KNOWN_ISSUES.md`.

- [x] **W26.lint — extend the write-surface lint to cover ArchiveCore [S · low · Tier-1]. ✅ DONE 2026-08-05**
  — `1460125` (lint + self-test) → this commit (trackers + docs).
  **The gap as filed:** `lint-write-surface.sh:10` hardcoded `SRC="macOS/Sources/ArchiveReader"`, so moving
  discovery into `packages/ArchiveCore` would have moved it out of the Core Directive's automated
  enforcement — and the same gap already exempted ArchiveCore's own `TagWrite.swift`, where `W26.deny`'s bug
  sat unlinted.
  **It was worse than a gap: rule 1 was passing VACUOUSLY.** Measured while fixing it —
  `grep -rnE 'setResourceValue|setResourceValues|setxattr'` over the Reader app target returns **zero** hits,
  because `TagWriter` is now a delta adapter over `ArchiveCore.CoordinatedTagWriter`. The rule had nothing
  left to catch, and its `grep -v '/TagWriter\.swift:'` exemption protected nothing.
  **Proven against its own predecessor, not argued.** A scratch copy of both source trees with two plants in
  ArchiveCore (`setResourceValue` in a new `Corpus/PlantedWalker.swift`; `removeItem` in
  `Corpus/PlantedDelete.swift`) → the OLD script exits **0** `✓ write-surface lint clean`; the new one exits
  **1** and names both files.
  **What shipped:** both trees linted; the suite's entire permitted tag-write surface is now the three exact
  lines in `ArchiveCore/Tags/TagWrite.swift`. Allowances are **`(file, exact source line)` pairs, never whole
  files** (plan §7a.8 — a file-level exemption in the package about to host the corpus walker is a permanent
  unchecked hole). Three audited rule-2 sites are allowed: `RootMarker`'s coordinated new-sidecar identity
  write, `PDFThumbnailer`'s cache write + LRU eviction. The Reader's `TagWriter.swift` file-level exemption
  is **gone** — a deliberate tightening, since the documented architecture is that no app calls
  `setResourceValue` directly.
  **The adversarial pass found the new version could still pass vacuously two ways**, so both now fail loudly:
  a **renamed source root** (grep silently skips a missing path — stderr is suppressed so the report stays
  readable — and the remaining tree passes) and a **stale allowance** whose line no longer exists (an
  unreviewed pre-approved hole waiting to be re-filled).
  **Test:** `ArchiveReader/scripts/test-lint-write-surface.sh` — 9 checks, all against a `mktemp` copy of the
  two trees through a test-only root override, so nothing is ever planted in the real repo. Includes the
  item's own gate (a planted tag write in a new ArchiveCore file), the same plant in the Reader target, a
  fourth differently-spelled write **inside** `TagWrite.swift` itself (a file-level allowlist would miss it),
  a repointed allowed line (`coordURL` → `fileURL`: same file, same API, different target ⇒ must fail), raw
  `setxattr`, planted destructive APIs, and the two vacuous-pass guards.
  **Also corrected:** the header claimed the lint is *"also invoked by the autonomous build"*. Nothing invokes
  it — no caller in `ops/`, `.claude/hooks/`, or any script (measured 2026-08-05). It is honestly labelled a
  manual gate, and wiring it in is filed as **`W26.lint-fu`**. Shell only, no Swift touched.

## Owner-reported bugs (2026-08-02)

- [x] **W25.modelsync [MED · money] — changing the model in Settings did not change the Process Files cost
  estimate, and the run used the OLD model. ✅ DONE 2026-08-02** (this commit; fix + adversarial-review
  fixes + trackers).
  **Reported by the owner:** "when I change the model for OCR, the Estimate per 1,000 files updates in the
  settings panel, but no change happens with the cost estimate in the main UI panel."
  **What was wrong.** Every *other* processing setting is `@AppStorage` — a live UserDefaults observer — so
  changing it in the ⌘, Settings scene re-renders the main `WindowGroup` immediately. The selected model is
  the one exception: its key is **per-provider** (`selectedModelId_<provider>`), so it cannot be `@AppStorage`
  (the wrapper needs a fixed key at init), and `ModelSelectionStore` was a stateless `enum` whose
  `UserDefaults.set` notifies nobody. `OCRView`, `SettingsView` **and** `ToolsView` each held the model as a
  plain `@State` seeded once in `init()`. Settings' pinned cost pane reads its *own* `@State`, so it updated;
  the main window kept the value it was born with. **Not cosmetic:** `startProcessing` passes the same stale
  `selectedModel`, so a run started from that window called the *previous* model — the estimate was honest
  about the run, both were simply a model behind. `ToolsView` had the identical bug and a comment documenting
  it (a diagnostic could bill against a stale model id).
  Three catch-up paths existed and none covers the reported flow: `.onChange(of: selectedProvider)` fires only
  on a *provider* change; `.onReceive(.processingProfileApplied)` only on Apply-a-profile; and the
  `.onChange(of: scenePhase)` "returning from Settings" re-sync cannot fire while the Settings window sits
  **open beside** the main window — which is exactly when the owner saw the two panes disagree.
  **The fix.** `ModelSelectionStore` becomes a `@MainActor ObservableObject` singleton publishing
  `selectedModelIDs` (provider.rawValue → id); the three views drop their `@State` mirror for a computed
  property over it, so one write updates every window on the same render. The static API is unchanged, so
  non-view callers (`ProcessingProfileStore.snapshotCurrent`) read the same resolution. Deleted as now
  redundant: `SettingsView.ensureValidModelSelection()`, `OCRView.currentModels` + its scenePhase model
  branch, `ToolsView.reloadModelAndKey`'s model half — the store's `provider.models[0]` fallback makes a
  ghost id unresolvable-by-construction rather than patched up per view.
  **Tier-2 (adversarial, 3 independent lenses — SwiftUI state / Swift-6 concurrency / money path).** All
  three converged on four real defects in the first cut, every premise re-verified before acting; all four
  are fixed in this commit:
  - **Ghost id never healed.** The read-time fallback masked a deleted custom model's id but left it on
    disk, and `ManageModelsView`'s duplicate check only sees models that *currently* exist — so re-adding
    that id later silently resurrected a discarded selection and the next run billed at it. The old
    `ensureValidModelSelection` + `.onChange(of: selectedModel)` pair used to *persist* the correction.
    Now healed at the choke point: `CustomModelStore.removeById` → `healUnresolvableSelections()` (which
    sweeps every provider, so it also clears ghosts left by builds before this one).
  - **`publish()` read the `@Published` dictionary on the caller's thread** before its `Thread.isMainThread`
    hop — the exact unsynchronized CoW-buffer access the hop existed to prevent, hidden by
    `@unchecked Sendable`. Fixed properly: the type is now `@MainActor` (every reader/writer already was),
    so it is a compile error rather than a convention; the hop is gone. `modelKey` /
    `saved+saveOutputDirectory` stay `nonisolated` (pure UserDefaults; `OCRView.init` reads one).
  - **Two dead `nonmutating set` accessors** in `OCRView`/`ToolsView` — neither view writes the model, and a
    setter keyed on the `@AppStorage` provider is a trap for a future caller changing both at once. Both are
    now get-only; the one real writer (`ToolsView`'s Compare-Models winner) passes its provider explicitly.
  - **`d === UserDefaults.standard` failed OPEN** in `ProcessingProfileStore.apply` while `readIDs()`
    hardcodes `.standard`. Now unconditional: a scratch-suite `d` leaves `.standard` unchanged, so the
    `!=` guard makes it a no-op — it fails *closed* instead. Matters because
    `SessionProcessingConfig` reads the raw key itself, so a cache/disk split would have let Live Capture
    run one model while Process Files quoted another.
  Cleared by the reviewers: re-render coverage in all three views (adding the `customModelStore` observer to
  `ToolsView` is load-bearing, not cosmetic — the model resolves through `provider.models`), write-site
  ordering (no misfiled provider; ⌘⌥P and profile-apply both correct), Picker `.tag()` matching, publish
  feedback loops, sheet seeding, and — the one that matters for money — **`OCRProcessor` pins the model once
  at run start** (`currentModel`/`runConfig.model`), so a live model change still cannot leak into an
  in-flight or resumed run. Verified: full clean build, Swift 6 language mode, zero warnings.
  **Not fixed here (pre-existing, surfaced by the same review):** `ModelChoiceSheet` / `OCRRetrySheet` seed
  their picker with the provider's *first* model rather than the selected one, so "Retry with model" opens on
  Flash Lite even when a larger model is selected. → shipped immediately after as **W25.modelsync-fu** below.

- [x] **W25.modelsync-fu — the retry/re-run sheets opened on the wrong model, and one of them on the wrong
  PROVIDER. ✅ DONE 2026-08-03** (this commit; owner-directed 2026-08-02 straight after W25.modelsync).
  Surfaced as **pre-existing** by W25.modelsync's adversarial review. Investigating found **three** seeding
  defects, not the one filed — and the unfiled one was the worst:
  - **`OCRRetrySheet` hardcoded `.gemini` + `LLMModel.geminiModels[0]`** and nothing ever overwrote them, so
    when an Anthropic / OpenAI / Mistral run hit OCR failures the sheet offered to retry them **on Gemini**,
    on that family's cheapest model — and its `.onAppear` loaded the *Gemini* Keychain key to match. An
    operator accepting the default would have re-OCR'd failures on a provider they never chose.
  - **`ModelChoiceSheet.init`** seeded `initialProvider.models.first` — the filed bug. Hits per-file "Retry
    with model" / "Rotate & re-run" in **both** Process Files and Live Capture.
  - **`ModelChoiceView`'s in-sheet provider Picker** set `model = newProvider.models[0]`, so switching
    provider *inside* the sheet also dropped onto that family's first model.
  **The fix.** Both sheets take `initialProvider`/`initialModel`/`initialThinking` from the caller and resolve
  the model by **membership in `provider.models`**, not merely a matching `provider` — the same rule
  `ModelSelectionStore.model(for:)` uses, so a snapshot naming a since-deleted custom model can't leave the
  Model picker blank with Retry still armed. The in-sheet provider switch reads
  `ModelSelectionStore.savedModel(for:)`. Two deliberate decisions: (a) the retry choice is **never** written
  back to the store — rescuing a few pages with a heavier model is a one-off and must not change what the next
  full run uses, so both sheets keep independent `@State`; (b) **Live Capture seeds from `session.config`, not
  the app-wide selection** — `CaptureSession.activateProcessingIfNeeded` snapshots and *locks* the config at
  session start precisely so mid-session Settings changes don't affect the running session, so the app-wide
  selection would misreport what actually OCR'd that segment. The caller passes the values in rather than each
  sheet reading the store because only the caller knows which notion of "current" applies.
  **A second adversarial pass rejected the first attempt at this fix — three more defects, all fixed here:**
  - **Seeding from the LIVE selection was wrong.** `OCRView.selectedProvider`/`selectedModel` are live
    (`@AppStorage` + the store), and ⌘⌥P cycles the provider app-wide **with no run-in-progress guard**, so a
    200-file Mistral run + one ⌘⌥P mid-run ended with the retry sheet offering Anthropic, estimating in
    Anthropic prices, and one click billing Anthropic for pages that failed on Mistral. Now seeded from
    `processor.activeRunConfig` — the snapshot the run pinned at start, which the retry path
    (`runConfigForRetry`) already trusted for everything else — via new `OCRView.runSeed`/`retrySeed`.
  - **The modal retry loop re-seeded every round, discarding the escalation.** `retryFailedFiles` clears
    `awaitingRetryDecision`, awaits real network calls, then re-raises the sheet for whatever still failed —
    a new sheet identity, so its `@State` re-initialized. An operator who escalated Flash Lite → Pro and had
    2 of 5 pages still fail was offered **Flash Lite again**, and the obvious second click re-billed the
    model that had already failed twice. Added `OCRProcessor.lastRetryChoice`, recorded in
    `retryFailedFiles` and cleared at fresh-run start so no run inherits another's escalation.
  - **`thinkingLevel` was still hardcoded `.low`** — the *same* wrong-seed bug this item exists to fix, and
    one that changes both output quality and output-token spend. A Sonnet run with Thinking = High retried at
    Low and failed again while the operator believed they had retried the run's configuration. Now seeded
    from `activeRunConfig.thinkingLevel` / the session config.
  Also: the Live Capture retry sheet now passes `fileCountForEstimate` (the segment's `pageCount`), because
  `ModelChoiceSheet` renders **no cost line at all** without one — so changing model there, which can move
  you onto a far dearer model, was previously silent.
  **Folded in (owner-approved, same commit) — two small pre-existing bugs in
  `Capture/SessionProcessingConfig.fromDefaults`:**
  - it hand-spelled `"selectedModelId_\(provider.rawValue)"` instead of calling
    `ModelSelectionStore.modelKey(for:)`. One drifted string there would silently snapshot the wrong model
    for a whole live session. (This is what makes `modelKey`'s `nonisolated` load-bearing: `fromDefaults` is
    a `Sendable` struct's static, reachable off-main, and must also read a scratch `UserDefaults`.)
  - `let builtIns = provider.models` then `(builtIns + custom)` **listed every custom model twice**, because
    `provider.models` already includes them. Harmless for the `.first(where:)` it fed, but it read as a bug
    and would have become one the moment anything counted or enumerated that array.
  **Verification:** clean build, Swift 6, zero warnings. `Capture/` is Tier-2, and the on-point $0 gate is
  `scripts/test-manifest-persistence.sh` — **109 checks, ALL PASS**, including `W16.cfg1` / `W16.cfg6` /
  `W16.cfg6-fu2`, which exercise `fromDefaults` directly, and `W16.cfg6-fu3`, which exercises the
  `ProcessingProfileStore.apply` scratch-suite path and so also re-proves that W25.modelsync's now-
  unconditional `reloadFromDefaults()` does not leak a scratch suite into the live store.
  **Correction folded in:** three doc comments from W25.modelsync claimed a SwiftUI `View.init` is not
  main-isolated. It is — conforming to `View` makes a type's members main-isolated, `init` included (verified
  against a no-conformance control that fails with `#ActorIsolatedCall`). The `nonisolated` markings on
  `modelKey` / the output-directory helpers are still right, but the stated reason was wrong; the comments now
  say why they actually hold — and `modelKey`'s is now genuinely load-bearing, since `fromDefaults` uses it.
  **NOT fixed — filed instead, because the answer is an owner decision:** **W25.retry-backend** (in gateway /
  Local Agent mode the retry sheets are decorative — `performOCRCall`'s localAgent → gateway → provider
  precedence never reads them — while Live Capture's retry *drops* the backend for a metered call, which this
  item's seed change made dearer) and **W25.retry-estimate** (retry quotes omit rotation + image scale). Both
  are in `SUITE_TODO.md` → *Owner-reported bugs (2026-08-02) — follow-ons*, with the full write-up in
  `ArchiveProcessor/KNOWN_ISSUES.md`. Fixing the seed did not fix those, and the code now says so rather than
  claiming a parity it does not have.


## ⭐ TOP PRIORITY — pre-flight for a 2-week unattended run (owner, 2026-07-16)

- [x] **Autonomous 2-week unattended hardening** — `execution-plans/autonomous-2wk-hardening.md` — **DONE
  2026-07-16/17** (supervised sessions, each adversarially reviewed + prove-the-mechanism'd before install).
  All workstreams shipped: **WS1** crash-restart posture (launchd KeepAlive; reboot-survival out of scope) ·
  **WS2** disk-space guard (park+alert on low free) · **WS3** worktree reclamation (safe, no unpushed-work
  loss) · **WS4** per-item attempt cap (park a mis-sized item) · **WS5** `STATUS.md` check-in digest · **WS6**
  remote push alerts · **WS7** periodic build+test+coherence health gate (park on red) · **WS8** Morning-Review
  rotation (`compact-plan.sh` Pass 2) · **WS9** `blocked-on` dependency gating (`next-queue-item.sh`) · **WS10**
  needs-owner hold queue · **WS11** paced whole-project review cadence (`next-review-unit.sh`) · **WS12**
  keychain partition-list fix. Each with a committed regression harness (`ops/autonomous/tests/prove-*.sh`).
  Out of scope (owner): reboot/auto-login, cumulative-cost ceiling.
  - [x] **2-week-readiness refinements (2026-07-20).** Two multi-day-duration fixes found in a
    pre-flight audit: (1) **WS3 worktree GC widened** — Phase-1 removal now covers all `wt/*` slugs (was only
    `wt/autonomous*`), so improvised-slug worktrees' `build/DD` no longer strands unbounded; still safe (merged
    gate + plain remove ⇒ only fully-pushed+clean worktrees reclaimed); new regression harness
    `ops/autonomous/tests/prove-housekeeping.sh` (7-case matrix, runs the real `housekeeping()`). (2) **`IDLE_STOP`
    6 h → 72 h** so a long usage-cap outage (a weekly cap can exceed the ~5 h rolling window) reads as *waiting*,
    not *idle*, and doesn't auto-park a healthy multi-day run. NOT addressed (owner, deferred 2026-07-20):
    reboot/auto-login survival.
  **Owner actions to start a long run (standing, not blocking):** run `./ops/autonomous/fix-keychain-access.sh`
  once (DONE 2026-07-17: Gemini/Anthropic/Mistral partition-listed), then `./ops/autonomous/daemon.sh` (the run is
  currently DOWN; `daemon.sh` now defaults to launchd KeepAlive / crash-restart — use `daemon.sh nohup` only if you
  want GUI-verify).


## ⚠️ Known-issues work — Wave 23 (Codex full-suite review; owner-commissioned 2026-07-29) — TOP OF THE DRAIN

- [x] **W23.h1 — launch-time `pruneEmptySessions` recursively HARD-deletes unrecognized content under the
  visible Live Capture root, including pending relay objects [M · HIGH · data loss · no undo].** ✅ FIXED —
  conservative positive-ID prune (`isReclaimableEmptySession` + `isSessionIdName`): only an ISO-8601-named,
  spent session with no recoverable data and no unrecognized content is reclaimed; `_relay` + its pending
  objects, HEIC-/`.jpeg`-only sessions, and unknown-content folders are all kept; every reclaim routes through
  `trashOrRemove` (Trash → Put Back), never `removeItem`. Regression: `LiveCaptureRecoveryTestDriver` Test 8 /
  `scripts/test-recovery.sh` ($0, no OCR/GUI). See `ArchiveProcessor/KNOWN_ISSUES.md`.
  `Capture/CaptureSession.swift` → `pruneEmptySessions(under:)`, called unconditionally from `init()` before
  recovery. **Re-verified 2026-07-29 against `62a10d1` and it is worse than the report says:**
  1. The function treats **every** child directory of `~/Pictures/Archive Processor Live Capture/` as an app
     session. It recognizes only a **top-level `.jpg`** (`hasPhoto`) or a `pdf|jpg|jpeg|json` file directly
     inside `_processed` (`hasProcessed`). Anything else → `try? fm.removeItem(at: folder)`, a **recursive
     permanent delete**. It never positively identifies the directory as an Archive Processor session.
  2. **The relay is a direct child of the pruned root.** `CaptureSession.relayDir(token:)` defaults to
     `backupRoot.appendingPathComponent("_relay")` + `/<token>/`. So `_relay/` contains *only a nested token
     directory* — no top-level `.jpg`, no `_processed` → it reads as empty and **every pending relay object is
     hard-deleted at the next launch.** That is precisely the crash-recovery case the relay exists to survive.
  3. ⚠️ **It contradicts the Recovery Core Directive declared in the same file.** `CaptureSession` defines a
     `trashItem` helper documented as *"the app never permanently deletes an irreplaceable capture"* — and
     prune bypasses it for a raw `removeItem`. **The fix must route through `trashItem`** so anything reclaimed
     stays Finder → Put Back recoverable.
  4. Extra gap found while verifying: the top-level check accepts only `jpg`, while `_processed` accepts
     `jpeg` too. A **HEIC-only or `.jpeg`-only** operator folder is therefore also deleted.
  **Fix:** (a) require **positive session identification** (session-id name shape and/or a session marker
  file) before a folder is ever a prune candidate; (b) **hard-exclude `_relay`** and any configured
  `liveRelayDir`/`LIVECAPTURE_RELAYDIR` path; (c) treat **unknown content as non-disposable** — never delete a
  folder containing files you don't recognize (HEIC, notes, nested recovery material, an unrecognized
  journal); (d) route every reclaim through `trashItem`, never `removeItem`; (e) widen the image-extension set
  to match `_processed`. Functional test on a scratch `ARCHIVEPROC_TEST_BACKUP_ROOT` covering all five cases
  (relay dir with pending objects, HEIC-only, `.jpeg`-only, unknown-journal, genuinely-empty session).
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift | M | **high** | none
- [x] **W23.h2 — two concurrent edits to the same Notes item silently overwrite each other [M · HIGH · silent
  data loss].** ✅ FIXED — `NoteStore.withItem(_:_:)` / `withTemplate(_:_:)` make the **transaction** the unit
  of serialization: load → mutate → save runs inside ONE actor-isolated call, and because `mutate` is
  **synchronous** there is no suspension point between the read and the write, so no other transaction can
  interleave (atomicity enforced by the type system, no new lock). Returns `ItemTransaction` (the item as
  written + its fresh ref) so callers index what landed instead of re-reading. All three read-modify-write
  call sites migrated — `NotesModel.mutateItem` (date / date-uncertain / quality / body),
  `NotesModel.renameTemplate`, `ExtractBuilder.append` (async asset copies stay OUTSIDE the transaction; a
  pre-flight existence check preserves the old error path). No raw `save`/`saveTemplate` survives outside
  `NoteStore`. **Premise measured before fixing — worse than reported:** 24 concurrent same-item appends left
  **1 survivor**, and a racing body edit / date edit / extract-append each vanished **entirely**. Tier-2:
  adversarial self-review + 9 scratch fixtures (`NotesItemTransactionTests`), the 4 RED cases now GREEN
  (24/24 survive); Notes suite **530 tests / 63 suites pass**; 0 new warnings. Two residuals recorded in
  `ArchiveNotes/KNOWN_ISSUES.md` — a transiently stale FTS index row (→ **W23.h2-fu** below) and two-window
  body co-editing still last-writer-wins on the body *text* (inherent); **neither is data loss.**
  `Core/NotesModel.swift` (the body/date/quality edit paths), `Store/NoteStore.swift`,
  `Core/ExtractBuilder.swift` → `append`. Every edit is a **load-whole-item → mutate → save-whole-item** pair
  of separate actor calls. `NoteStore` serializes each *individual* call but **not the read-modify-write
  transaction**; `NotesModel` is `@MainActor` but **reentrant at every `await`**. Two tasks can both load the
  same old item, apply different edits, and save in either order — the later whole-item save silently drops
  the other's body, metadata, or source blocks. Reachable via: two windows on one item; body autosave racing
  a metadata edit; `ExtractBuilder.append` racing an ordinary mutation.
  **Fix:** make the transaction the unit of serialization — a per-item lock/serialized executor inside
  `NoteStore` that spans load→mutate→save (a `withItem(id) { mutate }` closure API), or optimistic
  concurrency (compare-and-swap on a revision/mtime, retry on conflict). Do **not** just add another `await`.
  **Not covered by W15.tu3/tu4** — those are Finder-tag metadata lost-updates, a different seam. Existing
  editor tests cover cross-item selection/autosave races, not two edits to one item; add a deterministic
  same-item race fixture. | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Core/NotesModel,Store/NoteStore,Core/ExtractBuilder}.swift | M | **high** | none
- [x] **W23.h3 — confirming a STALE folder-removal alert trashes a note that still has a valid membership
  [S–M · HIGH · destructive].** ✅ FIXED `8d68e13` (checkpoint 1/2) — the last-instance verdict is now taken
  from **the membership the removal actually applied to**, never from a bare count.
  **Premise re-confirmed empirically before fixing** and the reported two-window repro reproduced exactly: with
  note B filed only in F1, open the alert on `(B, F1)`, let the other window MOVE B from F1 to F2, then confirm
  — `membershipCount(item:) <= 1` still reads 1 (F2 exists), so the stale pair was called "last instance",
  `forceRemoveLastMembership(B, F1)` was a silent no-op, and the note was trashed **with a perfectly valid F2
  membership**. The RED fixture also showed the F2 membership row *surviving* the trash, so the organization
  graph was left pointing at a trashed note.
  Three parts: (a) `OrganizationStore.removeMembership` verifies the specific `(item, folder)` pair exists
  **first** and returns a new `.notPresent` outcome when it does not — that check is what makes the count
  meaningful, since with the pair proven present `count == 1` provably means *this* pair is the only one; it
  also closes a second, quieter lie (a stale pair with ≥2 memberships used to delete nothing and still answer
  `.removed`). (b) New `removeConfirmedLastMembership` **replaces** `forceRemoveLastMembership`, collapsing the
  confirm path into ONE store call returning `.deletedLastInstance` / `.unlinkedNotLast` / `.notPresent`:
  `NotesIndex` is an actor, so the caller's `await` between "was it the last instance?" and an unconditional
  force-remove was itself a suspension point the other window could interleave at (`@MainActor` is reentrant
  there) — the same bug one step later. Deciding *inside* the store *after* the removal closes that window, so a
  membership that appears while the DB write is in flight downgrades the outcome to `.unlinkedNotLast` and the
  file is **kept**; only `.deletedLastInstance` licenses the trash, and the unverified force-remove helper is
  gone so no caller can reintroduce it. (c) `NotesNavigationModel` treats `.notPresent` as a no-op + resync in
  both the quiet-remove and confirm paths, never as a last instance. Every failure mode now errs toward
  **keeping** the note. The batched folder-delete path was re-checked and has **no twin defect** (it already
  intersects the confirmed set with the FRESH orphan set from `deleteFolder`).
  Tier-2 (destructive seam), **scratch fixtures only** — never the owner's real store: adversarial self-review +
  1 nav-level race fixture (the RED repro above, now GREEN, asserting both that the note dir survives *and*
  that the valid F2 membership does) + 6 store-level cases covering both stale-pair variants and all three
  confirmed outcomes. Full Notes suite **540 tests / 64 suites + 189 XCTest pass**; build clean, **0 new
  warnings**. | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Core/NotesNavigationModel}.swift | S–M | **high** | none
- [x] **W23.h3-fu — a replicate can still slip a live membership onto a note already on its way to the Trash
  [S · LOW–MED · residual of W23.h3].** ✅ **DONE** — guard `f40cf47`, tests + trackers in this commit.
  Premise re-confirmed by symbol first. The guard was lifted from the preserved prototype, not redesigned,
  but three things about it had to change because they postdate it. (1) It guarded only `addMembership`;
  **`moveMembership` shipped later (W23.m13) and mints a membership too**, so a stale drag stranded one the
  same way — and worse, `move` reported **no failure at all**, so the UI said the note had moved while it went
  to the Trash. Nothing is lost by refusing it: a guarded item provably has zero memberships, so there is no
  source row to move. (2) The prototype **defined the mechanism but never wired it** — no caller ever opened a
  window. It is now held by `NotesModel.trashItems`, the hard-delete *primitive*, so both existing callers and
  any future one inherit it, and nested one level wider by each caller (`confirmDeletion`,
  `deleteFolderDeletingStranded`) so the window opens the instant the zero-memberships verdict lands rather
  than one `await` later. **That nesting is why it counts instead of flagging** — a `Bool` would let the inner
  `end` unguard while the outer window is still open. (3) It minted a second error type; the store has since
  grown `OrganizationError` for exactly this, so `itemBeingDeleted` is a case there. `replicate` now prefers
  the store's own sentence, because this change introduces a refusal a user can actually provoke.
  **Deterministic, as the item required:** the production window is sub-millisecond, so racing a confirm
  against a replicate would pass on a green run whether or not it ever landed inside the gap. A DEBUG-only
  `NotesModel.hardDeleteWindowHookForTesting` (same shape as `NotesIndex.executeForTesting`, W23.m13) is
  awaited **inside** the open window before anything is trashed, and two tests assert `isHardDeleting` from
  within the hook so a green result can't come from a replicate that never ran. **10 new tests**
  (`HardDeleteWindowTests`), scratch stores only. **Non-vacuity by 4 neuters, each reddening a disjoint set:**
  no `addMembership` guard → 5 RED, the finding test showing the exact original symptom (a live membership in
  memory *and* SQLite pointing at a trashed note); no `moveMembership` guard → 2 RED with the silent-success
  variant; refcount degraded to a flag → only the nesting test; no `defer`-ed `end` → only the balance test,
  which fails twice over because a note the disk **refused** to trash then stayed un-fileable all session.
  All reverted before shipping. **703/703** Notes tests (was 693) + 189 XCTest, clean build, 0 new warnings.
  Notes-internal — no ArchiveCore type, no SPEC change → shared-core rebuild rule N/A. No new view code; the
  only visible effect is the existing sidebar status line, asserted headlessly → nothing for the VM lane.
  **Stated plainly rather than glossed:** the two *caller-level* windows survive no neuter and cannot — the
  statements between the verdict and `trashItems`' first line are all synchronous, so no test can interleave
  there; they are defense-in-depth against a future `await` in that stretch, and what the tests pin is the
  primitive's window. Original finding follows. Filed 2026-07-30 while closing W23.h3 (`ae0e6eb`); **not** covered by
  that fix. `NotesNavigationModel.confirmDeletion` gets `.deletedLastInstance` from
  `OrganizationStore.removeConfirmedLastMembership` and then `await model.trashItems([id])`. Both are
  `@MainActor`, but **`@MainActor` is reentrant at every `await`** — the same mechanism W23.h3 itself turned on —
  so another window's drag-to-folder can run `addMembership(item:folder:)` in the gap between the verdict and
  the trash. The note is still trashed (correctly: at verdict time it genuinely had zero memberships), leaving a
  **membership row pointing at a trashed note** — the same dangling-org-graph symptom W23.h3's RED fixture
  caught, in a much smaller window. Strictly narrower than W23.h3: the trash is recoverable (§5) and the window
  is sub-millisecond, which is why it did not block that item.
  **Fix (design already prototyped — do not redesign from scratch):** a hard-delete guard on `OrganizationStore`
  — a `[UUID: Int]` refcount with `beginHardDelete` / `endHardDelete` / `isHardDeleting`, held across the whole
  confirmed delete via `defer`, with `addMembership` **refusing** a guarded item (`MembershipError
  .itemBeingDeleted`). The refcount (not a Bool) is what lets nested/overlapping guards compose. A working
  version of exactly this exists in the preserved WIP at gitignored
  `old/w23h3-stray-worktrees-20260730/suite-wt-20260730-074048-10923.patch` (an abandoned W23.h3 attempt whose
  core fix was superseded by `8d68e13`, but whose guard is additive to it) — **lift the guard, re-verify it, and
  make sure the caller balances every `begin` with an `end` on every exit path**, including the error path where
  `trashItems` fails. Needs a deterministic fixture that replicates into the gap. Tier-2 (destructive seam,
  scratch fixtures only, never the real store). | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Core/NotesNavigationModel}.swift | S | low–med | none
- [x] **W23.h4 — Android permanently deletes an un-uploaded capture with no confirmation and no upload-job
  cancel [M · HIGH · data loss · Android].** ✅ **DONE** (policy layer `9281fcb`, wiring + trackers in this
  commit). **Premise re-confirmed by symbol before fixing** (the review was 5 commits stale): `deleteItem(id)`
  ran `runCatching { items[i].file.delete() }; items.removeAt(i)` unconditionally on the third tap of the
  select → arm → delete gesture, and never touched `uploadJobs`. The upload coroutine opens the file itself
  (`item.file.readBytes()` in its own IO context), so a delete winning that race left `ok=false` and **no Mac
  copy could ever exist** — while the resulting `FAILED` state write landed on an item already gone from the
  model, so nothing surfaced the loss. iOS has had this guard since 2026-07-09; Android had none.
  All three prescribed parts landed, with the policy pulled into pure `CaptureModels.kt` seams so it is
  provable on the JVM with no device: (a) `requiresDeleteConfirmation(item)` gates an `AlertDialog` on
  anything the Mac hasn't confirmed — including an UPLOADED page with a pending metadata resend — and is
  deliberately the SAME predicate `pendingReportCount` counts (which now delegates to it), so the two can't
  drift; an already-confirmed page still deletes on the third tap. (b) `retireCapture` **cancel-AND-JOINs**
  the item's upload before the bytes go away; the `uploadJobs[id]` read and the `cancel()` share one
  main-thread turn (`viewModelScope` is `Main.immediate`), so no replacement job can slip into the gap, and a
  delete that ends up keeping the photo re-queues it via `prepareDeferredResend`. (c) the dialog's primary
  action is the **recoverable retire** — copy to Pictures/Archive Capture through the existing `PhoneBackup`,
  delete the local file only once that copy is confirmed written, and **KEEP the photo** if it fails
  (`KEPT_RETIRE_FAILED`); "Delete permanently" stays available for a genuinely bad shot.
  Tier-2, scratch only (JVM temp files — the tests cannot see a corpus, a session or the gallery):
  adversarial self-review (it caught a duplicate re-send on the keep path, fixed) + `CaptureDeletePolicyTest`,
  8 new cases. The cancel-and-join case is proven **non-vacuous** — swapping `cancelAndJoin()` for a bare
  `cancel()` turns it RED, GREEN with the join. Android unit suite **25/25**; `assembleDebug` +
  `testDebugUnitTest` BUILD SUCCESSFUL, **0 warnings**. No device/emulator needed or used. Full write-up:
  `ArchiveProcessor/KNOWN_ISSUES.md`. W23.m1 is a separate finding on the same file and stays open.
  | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/{ui/CaptureScreen,capture/{CaptureViewModel,CaptureModels}}.kt + app/src/test/.../CaptureDeletePolicyTest.kt | M | **high** | none
- [x] **W23.h5 — a placeholder-only PDF counts as successfully archived, and finalize then retires the source
  image [M · HIGH · data loss · tag/PDF SPEC-adjacent].** ✅ FIXED — the placeholder substitution is now an
  explicit, propagated outcome instead of a silent success. `PDFGenerator.generate` returns
  `ImagePageOutcome` (`.embedded`/`.placeholder`, `@discardableResult` so the five Process Files call sites
  are untouched — their `try?` swallowing stays W23.m5); `writeSegmentFiles` records the affected **source
  URLs** on the new `StagedSegment.placeholderSources` (a `nil` outcome — threw but still left a file —
  counts as placeholder, so unknown resolves toward keeping the photo); and `finalize` runs its deletion set
  through the new pure `sourcesSafeToRetire(...)`, AND-ing the new gate with the existing filed gate. Per the
  owner's constraint the **placeholder page stays** and the file **still counts as filed** — only the source
  deletion is withheld, and **per page**, so a sibling that embedded fine is still retired. Newly VISIBLE
  where it was silent: `Phase.succeededPlaceholderImage` → amber `ItemState.succeededPlaceholderImage` (row
  explanation + retry/rotate actions) and a finalize-summary warning naming how many photos were kept and
  why. Legacy manifests (no `placeholderSources`) behave exactly as before; the rotation-review regeneration
  path replaces the whole segment, so the flag self-heals on a successful retry. Tier-2: `test-recovery.sh`
  Tests 9–11 (detect · gate · wiring end-to-end) → **45/45 ALL PASS**, both halves proven non-vacuous by
  neutering (gate off → 5 RED; detection off → 2 RED; the regression cases stay GREEN in both);
  `test-merge-safety.sh` + `test-output-file-safety.sh` clean; build clean, **0 new warnings**. $0 — no OCR,
  network, device or GUI. Full write-up: `ArchiveProcessor/KNOWN_ISSUES.md`.
  Original finding — `OCR/PDFGenerator.swift` → `generate(...)`;
  `Capture/LiveCaptureProcessor.swift` (filed-set + finalize); `Capture/CaptureSession.swift`.
  **Re-verified verbatim 2026-07-29:** when `makeImagePage` returns nil, `generate` inserts
  `makePlaceholderImagePage(note: "Original image could not be embedded (…)")` and **returns normally** — a
  successfully-written 2-page PDF whose image page contains **no scan**. Live Capture treats the PDF's
  existence as a complete page, includes it in the filed set, and **finalization moves the corresponding raw
  capture to Trash / drops it from the active session.** A source that becomes unreadable after OCR, or is
  regenerated from a cached OCR result after its bytes go corrupt/unsupported, therefore yields an apparently
  filed archival document with no image — **and the recovery source is retired.** Output-content validity is
  never established.
  ⚠️ The placeholder itself is deliberate (it keeps the 2-page contract + `PDFTextExtractor`'s `pageCount>=2`
  heuristic valid) — **do not delete it.** The defect is that it is **indistinguishable from success** to
  every caller.
  **Fix:** make placeholder-substitution an explicit, propagated outcome — have `generate` return/throw a
  result that says *"image page is a placeholder"*, thread it to the filed-set decision, and make finalize
  **never retire a source whose PDF carries a placeholder image page** (surface it instead, as W3.cap-r1 does
  for tags: still count the bytes, but do not destroy the original). **Not covered by W17.stg1** (that is
  staging-manifest integrity, not per-PDF content validity); the closed immutable-generation proposal does not
  address malformed bytes.
  💡 **PRIOR ART EXISTS — read it before designing the fix (found 2026-07-29).** A 2026-07-17 Codex worktree,
  removed on 2026-07-29 but preserved, already implements essentially the fix described above: a
  `PDFGenerator.generateRequiringEmbeddedImage()` overload plus `PDFError.imageEmbeddingFailed(URL)`, which
  **keeps** the deliberate placeholder for Process Files but makes the **Live Capture** path *throw* instead of
  emitting a placeholder-only PDF that finalize would treat as grounds to retire the raw source. Two copies,
  neither on `main`: branch **`wt/codex-processor-bugfixes-20260712`** and the patch series
  `old/codex-processor-fixes-20260717/` (gitignored). ⚠️ It is **76 commits behind** and predates W16.cfg1–cfg5,
  which rewrote these files — **re-derive against current `main`, do not merge or cherry-pick it blind.** Treat
  it as a design reference that a second author already reached the same conclusion, not as a tested patch.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/{OCR/PDFGenerator,Capture/LiveCaptureProcessor,Capture/CaptureSession}.swift | M | **high** | none
- [x] **W23.m1 — re-pairing Capture leaves an upload owned by the OLD Mac; the phone copy is deleted on the
  wrong acknowledgement [M · MED · misroute · Android].** ✅ FIXED — endpoint identity is now **generational**,
  exactly as prescribed (policy layer `f8d35fa`). Premise re-confirmed by symbol first, against `b31aa03`:
  `enqueueUpload` captures `val c = client` for the whole send, `disconnect()` touched neither `uploadJobs`
  nor `inFlightUploads`, so a re-pair left `resumeUploads()`'s re-enqueue a **no-op** (the stale in-flight id)
  while the orphaned coroutine kept uploading to the old Mac — and any `ok` it returned ran the unconditional
  confirm path (`UPLOADED` → `sentCount` → `delay(650); removeConfirmed`), deleting the phone's copy of a page
  the newly paired Mac never received. `trySendSegmentComplete` had the same hole (`endedSegments.remove` on
  any `ok`), so the new Mac never heard of the document at all.
  New pure layer in `CaptureModels.kt`: **`PairingGeneration`** (a token rotated by every pair *and* unpair via
  `retirePreviousPairing()`, which also cancels the outstanding upload/segment jobs — best-effort, since a POST
  already on the wire finishes, which is precisely why the *generation check* is what makes this safe);
  **`OutstandingSends<K>`** (the in-flight guard, generation-stamped — `claim` still refuses a second send for
  a key **even across a re-pair**, preserving W23.h4's one-coroutine-per-file invariant that the delete join
  depends on, and `release` frees only the caller's OWN claim so a dead send can't free the live one's); and
  **`sendAck(ok, tokenIsCurrent)`** — the ownership rule in ONE place, shared by both kinds of send so they
  can't drift, with staleness outranking success. The upload handler bails out **before** `setState(UPLOADED)`
  (so a crash in that window can't persist a false confirmation either) and its `finally` returns the page to
  the queue via `markSendableAgain` (PENDING, marker cleared, heartbeat re-counted) for the endpoint paired
  now. Absent a re-pair the decisions are bit-for-bit the old ones.
  Tier-2, scratch only (JVM temp files): `CapturePairingGenerationTest`, 8 cases incl. a coroutine driver that
  runs the shipped objects through the real misroute sequence and asserts the phone copy survives, the page
  re-queues, and the NEW Mac then receives it; **non-vacuous** — dropping `sendAck`'s staleness arm turns 4 of
  the 8 RED, the driver among them. Android **33/33** (was 25), `assembleDebug` + `testDebugUnitTest` clean,
  **0 warnings**, no device/emulator. Full write-up: `ArchiveProcessor/KNOWN_ISSUES.md`.
  **iOS twin recorded as PARKED, not fixed** (verified still present by symbol:
  `ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift` `disconnect()` nils `endpoint`/`client` and leaves
  `inFlightUploads` + the upload task alone). Also deliberately left alone: the display-only status heartbeat
  can still deliver one conflated count to the Mac just unpaired from (no bytes, no deletion licensed).
  | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/capture/{CaptureViewModel,CaptureModels}.kt + app/src/test/.../CapturePairingGenerationTest.kt | M | med | none
- [x] **W23.m2 — Reader cannot display or find page 3+ of Processor's intentional merged-PDF format
  [M · MED · CROSS-APP].** ✅ DONE `2689739` (model + find seam) + this commit (functional gate). Premise
  re-confirmed by symbol first — all three defects were live: `imagePage`/`textPage` were `page(at: 0)`/
  `page(at: 1)`, `next()`/`previous()` stepped file URLs, and `DocumentFindScanner` had a literal
  `default: break` on page index ≥ 2. Fixed with a **page-pair** model: new pure `Core/DocumentPagePairs`
  (pair `p` = PDF page `2p` image + `2p+1` OCR text) is the ONE home for that arithmetic, shared by the
  viewer and the find scanner so they can't drift; `pairCount` rounds **up** so a merge of a 2-page doc and a
  bare scan doesn't lose the trailing scan. `DocumentViewerModel` publishes `pair` — cycling walks pairs then
  files (backwards lands on the previous document's LAST pair), `canGoNext`/`canGoPrevious` gate the buttons,
  `positionLabel` adds "· page 2 of 4" only when there is more than one pair (single-pair documents keep the
  original string), and `DocumentFindScanner.pairMatchCounts` buckets every page so `FindNavigator` addresses
  a match by `(doc, pair, pane)` and `applyCurrentMatch` moves the viewer to it. Both viewers now key their
  panes on `pageIdentity` (index+pair) — **required, not cosmetic**: `PDFPaneView`'s reuse fallback compares
  `page.string`, which is nil for both an old and a new *image* page, so a file-index-only `.id` would leave
  the previous scan on screen; `PreviewSheet` had no `.id` at all, so that latent cycling bug is closed too.
  No SPEC change — the SPEC already documented the interleaved variant and the no-2-page-assumption rule;
  this is Reader conforming. `copyArchivePageLink` now names the pair on screen instead of a hardcoded page 1
  (so making pairs reachable doesn't create a NEW wrongness); the focused-pane refinement stays **W23.m4**.
  Tier-2: adversarial self-review (clamped `setPair` for a short/failed load, guarded every `page(at:)`,
  checked `index(for:)`'s NSNotFound path, kept keyboard focus off a non-existent text pane) + 25 functional
  tests on **scratch `mktemp` PDFs only** — 11 new `DocumentViewerPagePairTests` driving the real model over
  real on-disk PDFs, incl. a **pixel render guard** (pair 1's image page rasterizes non-blank AND differs from
  pair 0's, so a non-nil-but-blank `PDFPage` can't pass) and find end-to-end onto page 5. **Non-vacuous, per
  half:** neutering the display half → 4 test cases RED; neutering the find half back to `default: break` →
  3 RED. Reader unit suite **230 tests, 1 failure** = the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot`
  environment artifact (queued as `W20.deeplink-isolation`), unrelated. Clean build, **0 new warnings**, and
  **15/15 Reader UITests pass in the headless Tart VM** (incl. the 5 `ViewerUITests`) — off the owner's screen.
  Full write-up: `ArchiveReader/KNOWN_ISSUES.md`.
  Original report: Processor merges multi-page documents as `image1, text1, image2, text2, …`
  (`OCR/PDFGenerator.swift` merge path; `OCR/OCRProcessor+Tagging.swift` transfers Finder tags to the merged
  PDF), but Reader exposes **only PDF pages 0 and 1**: `Views/DocumentViewerModel.swift` hard-pairs two pages,
  next/previous move between **selected file URLs** rather than internal page pairs, and
  `Core/DocumentFind.swift` **explicitly discards every match on PDF page index ≥ 2**. So for any merged
  document with 2+ source pages, later scans and their OCR text are unreachable in Reader — even though
  Reader's full-text index already extracts all pages.
  **Fix:** teach Reader the interleaved image/text **page-pair** model — derive pair count from
  `pageCount / 2`, make next/previous walk pairs within a document before moving to the next file, and let
  Find return matches on any text page (mapping match → pair). **`SPEC/tag-format.md` says consumers must not
  hard-assume two pages** — this is that assumption. Distinct from **W18** (switching between PDF and
  separately exported JPEG references). | files: ArchiveReader/macOS/Sources/ArchiveReader/{Views/DocumentViewerModel,Core/DocumentFind}.swift | M | med | none
- [x] **W23.m3 — Notes inline-image resolution escapes the item directory and reads another item's asset
  [S–M · MED · provenance corruption].** ✅ DONE `6e72d33` (resolver + its tests) + this commit (wiring +
  read-seam gate). Premise re-confirmed by symbol first, and both defects were live: `ItemAssetStore.resolveAsset`
  and `ScratchAssetStore.resolveAsset` each did `appendingPathComponent(relativePath)` + `fileExists`, and a
  scratch fixture proved `../<OTHER_UUID>/assets/private.png` really did return the other item's bytes.
  Fixed with a new single choke point, `Editor/AssetPathResolver.swift`, returning a typed `AssetResolution`
  (`resolved` / `missing` / `outOfBounds`) instead of a bare optional URL, behind **two** gates: (1) syntactic —
  `assets/`-rooted, no `..`, not absolute/`~`/remote, which catches the reported traversal with no disk access;
  (2) canonical containment — `resolvingSymlinksInPath()` + **component-wise** ancestry, which catches a symlink
  *inside* `assets/` (invisible to every string check, since `fileExists` follows symlinks and
  `standardizedFileURL` does not resolve them) and the `assets-elsewhere/` string-prefix trap. `resolved` carries
  the **canonical** URL, so the byte read follows the already-resolved target (a later symlink swap at the
  original path can't redirect it) — and that canonical URL is exactly the cache key **W23.m11** now needs.
  `EditorAssetStore` requires `resolve` (both stores wired); `resolveAsset` survives as a protocol-extension
  convenience so a refusal reads as nil on the copy/extract path — an extract embeds no foreign bytes, which is
  the provenance half of the finding (`snapshotMarkdown` re-keys assets by *bare filename*). The renderer shows
  a refused reference as a distinct **"Blocked"** placeholder (vs "Missing"), rel-path preserved, so serializing
  never rewrites the note body. Tier-2 gate, scratch fixtures only: **19 new tests** (`AssetPathResolverTests`
  11 + `InlineImageReadSeamTests` 8) — every escape case first asserts the bytes ARE reachable under the old
  rule, so each test documents the hole it closes; 559/559 `ArchiveNotesTests` green, no new warnings.
  Consequence recorded in `ArchiveNotes/KNOWN_ISSUES.md`: a hand-authored ref *outside* `assets/` (item-root, or
  `Assets/` mis-cased) now renders Blocked rather than loading — deliberate per this item's fix spec, and
  recoverable (move the file into `assets/`; nothing is rewritten).
  `Editor/MarkdownBridge.swift`, `Editor/InlineImageAttachment.swift`,
  `Core/NotePassageSource.swift` → `ItemAssetStore.resolveAsset`. Markdown image paths are passed **unchanged**
  to `resolveAsset`, which appends the value to the item directory and only checks that the result **exists**
  — no `assets/` restriction, no component-boundary check, no canonical/symlink containment check. A raw or
  synced note containing `![](../OTHER_UUID/assets/private.png)` renders **another note's image**; more `..`
  components leave `items/` wherever the sandbox grant permits. Copy/extract code can then snapshot those
  bytes into a different item — **corrupting provenance**, not just the visual boundary.
  **Fix:** resolve then **canonically contain** — reject any path escaping `<item>/assets/` after
  `resolvingSymlinksInPath` + component check; return a typed "out of bounds" result the renderer shows as a
  broken image. Existing Notes asset items cover async write failure + same-name write reservation; the
  path-traversal tests protect the **write** seam — this is the **read** seam. Add read-seam tests.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Editor/MarkdownBridge,Editor/InlineImageAttachment,Core/NotePassageSource}.swift | S–M | med | none
- [x] **W23.m4 — Reader page-level durable links are broken at command, creation AND reveal time
  [M · MED · shipped-contract regression].** ✅ DONE `b6093bb` (the three fixes) + `e150234` (18 functional
  tests) + this commit (GUI proof + trackers). Premise re-confirmed by symbol first — all three were live:
  the command's `.disabled(doc == nil || nav == nil)` against a document window that publishes only its
  viewer; `page = imagePageIndex(pair:) + 1` regardless of the focused pane; and `pendingRevealPage`
  written in `revealAndSelect` and **read nowhere** (its only other mentions cleared it).
  Fixed as one seam, since fixing any one alone leaves the feature broken: new `Core/ArchiveLinkTarget.swift`
  carries the root + marker as one `Sendable` value published as a **focused value** by every window that
  shows a document, with an app-level `ArchiveLinkContext` (one `@StateObject`, injected into both scenes)
  ferrying it out of the navigation window — which stays the single writer (`attach(linkContext:)` + a
  `rootStore.objectWillChange` sink), so a root switch can't leave a document window citing the old archive;
  `DocumentViewerModel.focusedPageNumber` cites the **focused** pane's page (degrading to the pair's image
  page when that pane holds none); and `goToPDFPage(_:)` + an additive optional `DocumentSelection.initialPage`
  + `openViewerRequest`/`openViewerSelection` (counter+payload, in the shape of `requestScroll`, since
  `openWindow` is an Environment action only a View holds) make reveal open the viewer ON the cited page
  before clearing the pending state. A link with **no** page still just selects and scrolls.
  Tier-2: adversarial self-review (clamped/out-of-range pages, a cited text page that no longer exists, a
  marker-less root clearing rather than staling the target, no link at all with no document loaded) + **18
  functional tests** (`DocumentPageLinkTests`) driving the real models over real `mktemp` scratch PDFs, incl.
  the full copy → parse → reopen → re-cite round trip and the whole URL → router → nav path. **Non-vacuous,
  per defect:** restoring the image-page-always rule → 3 cases RED; removing the reveal request and pinning
  `goToPDFPage` to pair 0 → 7 RED (the three absence tests correctly stay GREEN). Reader unit suite
  **248 tests, 1 failure** = the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot` environment artifact
  (`W20.deeplink-isolation`), unrelated. Clean build, **0 new warnings**. The menu-enablement half is the one
  thing no unit test can see, so it is covered by a new `ViewerUITests` case that opens a document window and
  asserts the Document-menu item is present AND enabled with only the viewer focused: **16/16 Reader UITests
  pass in the headless Tart VM** (off the owner's screen). That needed `make-gui-fixture.sh` to write a
  `.archive-suite-root.json` marker — without one no durable link exists, so every archive-link command stays
  disabled and the GUI lane could not test them at all.
  Full write-up: `ArchiveReader/KNOWN_ISSUES.md`.
  Original report: three independent defects break the feature end to end:
  1. **Unreachable command.** "Copy Archive Link to This Page" (`ArchiveReaderCommands.swift`) requires both a
     focused `NavigationModel` **and** `DocumentViewerModel`. The full document window
     (`Views/DocumentWindowView.swift`) publishes **only the viewer**, so the command is disabled exactly where
     the user reads a document; it may only be reachable inside the navigation window's `PreviewSheet`.
  2. **Wrong page written.** Direct invocation always writes `page=1` regardless of the focused text/image pane.
  3. **Reveal drops the page.** An incoming link stores `page` in `pendingRevealPage`
     (`Views/NavigationModel.swift`), then **clears it after selecting a row** without ever opening the viewer
     or navigating to that page.
  **Fix all three together** (fixing one alone leaves the feature broken): give the command a viewer-only
  focus path, pass the actually-focused pane's page, and make reveal open the viewer + navigate before
  clearing `pendingRevealPage`. `execution-plans/archive-notes/00-overview.md` §"reveal" is the **shipped
  contract** requiring the page be passed to reveal — this is an implementation regression against it. Not
  W20 (test isolation), not W18 (dual reference).
  | files: ArchiveReader/macOS/Sources/ArchiveReader/{ArchiveReaderCommands,Views/NavigationWindowView,Views/PreviewSheet,Views/DocumentWindowView,Views/DocumentViewerModel,Views/NavigationModel}.swift | M | med | none
- [x] **W23.m5 — Process Files reports Finder tags as applied after silently discarding tag-write failures
  [M · MED · tag/PDF SPEC].** ✅ DONE `ff792a9` (the seam + all 13 sites + surfacing) + `088df94` (the $0
  functional test) + `4cf1fb7` (re-key to the input file) + this commit (adversarial-review fixes +
  trackers) — **W23.h5-fu folded in**, as its entry required. Every Process Files tag write now goes
  through one seam, `OCRProcessor.writeOutputTags`, which RETURNS whether the write landed; the run
  records the verdict against the INPUT file and the "Done." status line + batch log say so. Reuses
  W3.cap-r1's mechanism rather than adding a second warning channel. 13 sites, not the 9 recorded:
  `+Tagging` ×6, `+OCR` ×2, `+Pipeline` ×1 as filed, plus the 4 in `+ReviewFlows` (reclassification ×3 +
  the copy-source restore after rotation regen) — leaving those unrouted would have made the new summary
  trustworthy and wrong. The file still counts as processed (the owner's 2026-07-18 decision); only the
  silence was the bug. Keyed by SOURCE because `organizeOutput` MOVES **and RENUMBERS** every output
  (`00003 Box 12.pdf`), so an output name recorded during the run names a file that no longer exists by
  summary time. Self-healing: a later successful re-write clears the entry, but a step that ATTEMPTS no
  write (a post-run `retryOne`, which regenerates the PDF and does not re-tag it) does not.
  Tier-2: `scripts/test-processfiles-tagwarn.sh` + `ProcessFilesTagWarningTestDriver`, 35 $0 checks
  (`chflags uchg` makes the tagger genuinely fail; a real production site proves the WIRING; the summary
  copy, merge bookkeeping and the h5-fu placeholder path are all driven end to end). Proven non-vacuous
  by four separate neuters, each turning exactly the expected checks RED. Six sibling regressions green.
  Build clean, 0 new warnings. Residual colour-detection finding filed as **W23.m5-fu**.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor{,+Tagging,+OCR,+Pipeline,+ReviewFlows}.swift, Capture/ProcessFilesTagWarningTestDriver.swift, scripts/test-processfiles-tagwarn.sh | M | med | none
- [x] **W23.m5-fu — two read-append-rewrite tag sites still infer the Finder colour from the tag text
  [XS–S · LOW · misfile].** ✅ DONE this commit (checkpoint `5342d2b` code+tests). Found 2026-07-31 while fixing W23.m5 (the audit of the sites it rewrote, not
  a new review). `applyCapturePriorityTags` and `exportOriginalImages` both READ a PDF's tags back off
  disk and re-apply them as a raw `[String]`, so `MacOSTagger` runs its Red/Purple DETECTION over the
  array — the same defect W3.cap-r1 fixed on the Live Capture staging path and KNOWN_ISSUES #5 fixed on
  the batch merge path. A document whose subject tag is literally "Red" (the Red Scare, the Red Cross)
  therefore gets Finder label 6 on the rewrite and loses "Red" as a searchable subject; the Reader reads
  a red label as a **box** photo, so an ordinary document is mis-parsed as archival structure.
  **Deliberately left in W23.m5** (which is about discarded write failures, and passed these two sites
  through unchanged so it could not alter what anyone writes) — and the fix is NOT simply flipping
  `colorIsAuthoritative`: with `appColor: nil` that would STRIP the label from every genuine box/folder
  PDF. Do what `performDocumentMerging` already does: derive the colour from the job's
  `classification` (`.boxLabel` → "Red", `.folderLabel` → "Purple", else nil) and pass it explicitly.
  Both sites iterate `jobs`, so the classification is already in hand. Test: extend
  `scripts/test-processfiles-tagwarn.sh` — a "Red"-subject document keeps the tag and takes no label
  through a rewrite; a box PDF still reads label 6 afterwards.
  **Shipped exactly that, via one seam.** New `OCRProcessor.authoritativeColor(for:)` states the rule in
  one place — box → Red, folder → Purple, anything else → no colour — and both sites now pass its result
  with `colorIsAuthoritative: true`. The `forJob:` overload coalesces `job.classification ??
  job.result?.classification`: every writer keeps the two in sync, but a failed re-OCR can blank the
  result's copy, and falling back to "no colour" is precisely the strip this item warned about. Checked
  the invariant that makes classification trustworthy here rather than assuming it: `preGroupedPriorities`
  is cleared whenever the boundary count mismatches, so a phone priority implies
  `applyPreGroupedClassifications` ran (it sets BOTH fields) and every such job carries a classification.
  Copy-source mode is untouched by construction — `applyTags` passes names through verbatim and never
  writes a label there, so the colour argument is dead in that mode.
  **One correction to this entry's own text, found by driving it:** the subject tag "Red" was **not**
  lost. Detection moves it to the front of the array and re-adds it, so it stayed searchable; the defect
  is the Finder **label** alone (and the Reader's box mis-read that follows from it). The neutered run
  confirms it — with the old code restored, "…and 'Red' is still a searchable subject tag" PASSES while
  only the label checks go RED.
  Tier-2, scratch only: 12 new checks in `ProcessFilesTagWarningTestDriver` (**47 total, ALL PASS**),
  synthetic files in a temp dir — no corpus, no OCR, no network, no GUI, $0. Both REAL production
  functions are driven (`applyCapturePriorityTags`, `exportOriginalImages`), not just the seam, and both
  directions are covered on both sites: a "Red"-subject document takes no label, a box PDF keeps label 6,
  a folder's exported image keeps label 3. **Non-vacuous by two neuters, each reddening exactly the
  expected pair:** restoring detection at both sites → the two "subject Red must not become a label"
  checks RED (this IS the premise re-confirmation, since that is the pre-fix code); the naive
  `appColor: nil` variant → the two "a genuine box/folder KEEPS its label" checks RED. Build clean, 0 new
  warnings; seven sibling regressions green (merge-safety, collection-organize, recovery, batch-resume,
  multipage-reocr, segment-json, output-file-safety). Processor-internal — nothing in ArchiveCore
  changed, so the all-three-app rebuild rule is N/A; no view code, nothing for the VM lane to see.
  **Adjacent finding, filed then fixed the next session: W23.m5-fu2** (below) — the reclassification re-tag in
  `+ReviewFlows` strips the literal words "Red"/"Purple"/"Box"/"Folder" from the tag array, which for a
  document whose SUBJECT is one of those words really does delete it. Different site, different
  mechanism, out of this item's two-site scope.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+Tagging.swift, Capture/ProcessFilesTagWarningTestDriver.swift | XS–S | low | W23.m5
- [x] **W23.m5-fu2 — reclassifying a document DELETES a subject tag that happens to be a structure word
  [XS · LOW · tag loss].** ✅ DONE this commit (checkpoint `7a0043c` = the rule + its checks). Found
  2026-07-31 while fixing W23.m5-fu (audit of the neighbouring rewrite sites, not a new review).
  `OCRProcessor+ReviewFlows` re-tags an output whenever the operator changes its classification, and
  rebuilt the array with `existingTags.removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" ||
  $0 == "Folder" }` before appending the new classification's words. The intent is right — drop the OLD
  structure tags so they can be replaced — but the filter matched on the literal word, so a document
  whose genuine subject tag is "Red" (Red Scare/Red Cross), "Box" (a ballot box file) or "Folder" lost
  it from both the file and `jobs[].appliedTags`, and it never came back. Tag loss, not misfile — the
  mirror image of m5-fu.
  Two new seams beside `authoritativeColor(for:)`: **`structureTag(for:)`** (box→"Box", folder→"Folder",
  else nil — the companion of the colour, so between them they are the complete set a classification
  contributes and therefore the complete set a *re*-classification may take back) and
  **`reclassifiedTags(_:from:to:)`** — remove ONE occurrence of each word the app added for the OLD
  classification, then add exactly one of each for the NEW one in the fresh `GeneratedTags` shape
  (subject word first, colour last). One app copy in, one app copy out, so box → folder → box neither
  piles up duplicates nor eats the operator's own tag.
  **Three things the item did not say, each checked rather than assumed:** (1) **there are THREE sites,
  not two** — `applyReviewEdits`, `updateClassification` and `applyDocumentReviewEdits`, the last of
  which also re-added unguarded, so it could double a word. (2) **The strip fix alone would have
  re-introduced W23.m5-fu's misfile.** All three called `tagOutput` with the DEFAULT
  `colorIsAuthoritative: false`, so `MacOSTagger`'s raw-array detection ran over the array; the item's
  claim that "the Finder LABEL is correct here" held *only because* the strip deleted the operator's
  "Red" first. The moment a subject "Red" survives, detection promotes it back to Finder label 6 — which
  the Reader reads as a box photo. So both halves ship together, exactly as in m5-fu: every site now also
  passes `appColor: authoritativeColor(for: newClassification), colorIsAuthoritative: true`. (3) **which
  field the strip reads matters** — all three read `jobs[].classification` alone, so a page carrying its
  classification only on `result` would have had nothing stripped and kept the app's own "Box"/"Red"
  forever (the same tag rot, other direction). New `taggedClassification(of:)` coalesces both fields, as
  `authoritativeColor(forJob:)` already did.
  **Tier-2, scratch only** (synthetic files in a temp dir; no corpus, no OCR, no network, no GUI, $0):
  27 new checks in `ProcessFilesTagWarningTestDriver` (§8a the rule, §8b all three REAL production
  functions against real files on disk), **74 total ALL PASS**. **Non-vacuous by three neuters, each
  reddening exactly the predicted set and nothing else**: the literal-word `removeAll` restored → 10 RED
  (this is also the premise re-confirmation, being the pre-fix code); `colorIsAuthoritative: false` →
  3 RED, proving the colour half is load-bearing; `taggedClassification` de-coalesced → 2 RED.
  `grep NEUTER` clean before shipping. Build clean, 0 new warnings; six sibling regressions green
  (merge-safety, collection-organize, recovery, batch-resume, multipage-reocr, output-file-safety).
  Processor-internal — nothing in ArchiveCore changed, so the all-three-app rebuild rule is N/A; no view
  code, nothing for the VM lane to see. `applyReviewEdits` / `applyDocumentReviewEdits` went from
  `private` to internal so the headless driver can exercise the real sites; the UI still reaches them
  only through `confirmCollectionReview` / `confirmDocumentReview`.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+ReviewFlows.swift, OCR/OCRProcessor+Tagging.swift, Capture/ProcessFilesTagWarningTestDriver.swift | XS | low | none
- [x] **W23.m6 — Reader can emit durable links carrying a root GUID that was never persisted
  [S–M · MED · broken citations · SHARED CORE].** ✅ DONE `fa8bc02` (ArchiveCore) + `1e0af47` (Reader) + this
  commit (all-three-app rebuild, GUI proof, trackers) — **W23.l3 folded in.** `read` now reports absence *only* for ENOENT
  (new `.unreadable` otherwise), `ensure` throws `.readOnly` (carrying the `provisional` marker) instead of
  returning an in-memory GUID, and first-time creation re-checks/writes/confirms inside **one** write claim.
  Reader mints only from a **durable** identity — `RootFolderStore.rootMarker` is derived from the new
  `Core/RootMarkerState.swift`, so every link path refuses together — and degrades **visibly** with four
  distinguishable reasons instead of "Choose an archive folder first." on an open folder. 5 ArchiveCore + 8
  Reader functional tests, each defect proven live by neutering (the concurrency fixture reproduces l3: 8
  racers, 8 GUIDs, one on disk, 3/3 runs). All three apps rebuilt (shared-core rule). `packages/ArchiveCore/.../Links/RootMarker.swift` →
  `read` / `ensure`; `ArchiveReader/.../Search/RootFolderStore.swift`; `Views/NavigationModel.swift`.
  `RootMarker.read` converts **every** non-ENOENT, non-decoding read failure into "marker absent", and
  `ensure` returns its **newly generated in-memory marker after any write failure or failed confirmation**.
  Reader accepts that as a normal `rootMarker` and mints archive links from it. On a read-only root, disk-full,
  permission failure, or transient marker I/O error, copied links carry a GUID that **changes after relaunch
  and can never resolve** — and a transient read error on an *existing* marker can be mistaken for absence
  before a replacement write. The declared `RootMarkerError.readOnly` is **never used**.
  **Fix:** distinguish *absent* from *unreadable* (propagate the real error; use `.readOnly`), and make
  `ensure` return a **provisional/non-durable** marker that Reader must **refuse to mint links from** —
  degrade visibly instead. ⚠️ **Shared-Core rule** (memory `shared-core-change-rebuild-all-apps`):
  `RootMarker` is ArchiveCore — build+test **all three** app bundles plus `swift test` in
  `packages/ArchiveCore`. Historical W4 material calls read-only operation "degraded" but no live task makes
  Reader distinguish transient from durable. | files: packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift, ArchiveReader/macOS/Sources/ArchiveReader/{Search/RootFolderStore,Views/NavigationModel}.swift | S–M | med | none
- [x] **W23.m7 — Mac tag-card Apply/Skip begins finalization before proving the manifest decision is durable
  [S–M · MED · manifest/finalize].** ✅ DONE `1723331` (the fix) + `0bd8fcc` (18 headless checks) + this
  commit (trackers). Premise re-confirmed by symbol first and it was live, both halves: `_ = writeManifest()`
  at both sites, and `liveProcessor.segmentResolved` called BEFORE that write. Fixed by the neighbouring
  roll-back pattern, re-derived against current `main` (the Codex prior art was read for shape, not
  cherry-picked): both functions now stage the decision, write, and on failure restore
  `macTags`/`resolvedGroupIds` and return `false` — so memory matches disk and the card (derived from the
  in-memory resolved set) stays up with everything typed still in it. Live processing is told through one new
  choke point, `notifySegmentResolved`, reached only after the write succeeds, because that step bakes
  `macTags` into staged output. Failure channel: one shared `CaptureSession.tagDecisionNotDurableMessage`
  drives both the session status line and a new inline red row in the card, so Save/Skip can never again look
  like a no-op. The headless auto-skip loop now stops on a refused write (it would otherwise spin forever on a
  card that rolls itself back). Tier-2: adversarial self-review (found + fixed a stale-`persistFailure`
  carry-over onto the next card; confirmed `.atomic` means a failed write leaves the previous manifest intact,
  so rollback really does restore agreement; no `await` inside either function, so no reentrancy window) +
  **18 functional checks** in `ManifestPersistenceTestDriver` over a real scratch session manifest
  (`ARCHIVEPROC_TEST_BACKUP_ROOT`, synthetic pages; no corpus, no OCR, no network, no GUI, $0), including a
  fresh `CaptureSession()` restore after both the refusal and the retry, and — the ordering proof — a
  notification hook that reads the real `manifest.json` from inside the notification itself. **Non-vacuous per
  half:** restoring the old call order → 5 RED; swallowing the write failure as before → 10 RED; both neuters
  reverted. 86/86 ALL PASS; `test-recovery.sh` 45/45, `test-network-session.sh` 7/7, `test-filerelay.sh` 10/10
  (that last one runnable again — see `682bc7f`); build clean, 0 new warnings. **B9 entry updated** as this
  item asks. Residual, deliberately not widened: `removePhoto`/`removePhotoIfSafe`/`clear`/`clearFiled` still
  discard their `writeManifest` result — they trash photos, and restore skips manifest entries whose file is
  absent, so those degrade safely rather than silently losing a decision. Original report below.
  `Capture/CaptureSession.swift` (Apply/Skip), `Views/LiveCaptureView.swift`.
  Apply/Skip mutates `macTags` + `resolvedGroupIds`, schedules `liveProcessor.segmentResolved`, and
  **discards the `Bool` result of `writeManifest`**. The card vanishes immediately (it is derived from the
  in-memory resolved set) and the UI has **no failure channel**. If the manifest replacement fails and the app
  then crashes, recovery reloads the **old unresolved** state: stage-for-later loses the operator's decision,
  and live processing may already have baked/staged output from volatile tags while relaunch resurfaces the
  group as unresolved — recovered state inconsistent with the produced artifact, and possibly a second
  decision prompt. **Neighbouring sender controls already roll memory back when their manifest write fails —
  follow that pattern.** The "fixed" B9 known issue claimed Apply/Skip persistence but did not handle this
  ignored failure; update that entry.
  💡 **PRIOR ART EXISTS (found 2026-07-29 by symbol-auditing the preserved Codex branch).** Commit `3ea3221`
  *"fix(capture): persist completion before acknowledgment"* on branch **`wt/codex-processor-bugfixes-20260712`**
  (patches: `old/codex-processor-fixes-20260717/`, both off `main`) converts the discarded `writeManifest()`
  calls in `CaptureSession.swift` into checked ones **with memory rollback** — e.g.
  `guard writeManifest() else { let restoredManifest = writeManifest(); … }`,
  `if changed || newlyCompleted, !writeManifest() { … }` — in exactly the completion-set / tag-card region this
  item names. That is the "follow the neighbouring roll-back pattern" fix, already drafted. ⚠️ 76 commits
  behind and never build-verified here: **re-derive against current `main`, don't cherry-pick.**
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/{Capture/CaptureSession,Views/LiveCaptureView}.swift | S–M | med | none
- [x] **W23.m8 — Android's crash-durable `SessionStore` silently ignores current-manifest publication failure
  [M · MED · metadata loss · Android].** ✅ **DONE 2026-07-30** (`5d2c14a` data layer + completing commit;
  Processor `KNOWN_ISSUES.md` "✅ FIXED (W23.m8)"). `save` now returns whether THIS snapshot is durable, a
  set-before-write `session.stale` flag makes that knowledge survive the process that discovered it (the
  loss lands on the NEXT launch, and a first-ever publish failure leaves no manifest to carry the signal),
  and against a stale manifest the recovery sweep adopts pages `needsReview` — kept, visible and counted,
  but refused at `enqueueUpload` until the operator classifies them via the ordinary tag sheet, because a
  default Document group is a classification nobody chose and the Mac's half of that has no undo. En route:
  `File.createTempFile` sat outside `ManifestFileWriter.replace`'s `try`. 24 new headless JVM checks over
  scratch temp dirs; all five mechanisms neuter-proven (11/3/1/2/1 RED); 56/56 pass.
  `data/ManifestFileWriter.kt`, `data/SessionStore.kt`,
  `capture/CaptureViewModel.kt`. `ManifestFileWriter` **reports** replacement failure, but `SessionStore.save`
  returns **no result**, ignores that Boolean, and swallows exceptions — so the writer cannot tell the view
  model that the current snapshot was never committed. After an I/O failure + app termination, a new raw JPEG
  absent from the old manifest is **re-adopted into a fresh default Document group**, losing box/folder
  classification, group boundaries, priority/date/tags, replacement provenance and segment-completion state;
  known files can return with stale metadata.
  **Fix:** propagate the failure up through `SessionStore.save` to the view model, surface it, and **prevent
  lossy orphan adoption** when the current manifest is known-stale. The existing Android manifest fix
  preserves the *previous valid* manifest on failed replacement — it does not propagate failure of the *new*
  snapshot. | files: ArchiveProcessor/ArchiveCapture/app/src/main/java/com/archiveprocessor/capture/{data/ManifestFileWriter,data/SessionStore,capture/CaptureViewModel}.kt | M | med | none
- [x] **W23.m9 — Reader and Notes indexers report successful completion after SQLite failures, and can
  poison the DB handle until restart [M · MED · CROSS-APP].** ✅ **DONE 2026-07-30** (checkpoints `d24b8da`
  half-open recovery + `4ee909a` Reader propagation, then this completing commit). Both modes, both apps.
  **Premise re-confirmed by experiment first:** `sqlite3_open_v2` is lazy, so a 1 KiB garbage file opens
  with `SQLITE_OK` and dies on the first PRAGMA with rc=26 "file is not a database" — the exact half-open
  window. (2) `open()` is now **all-or-nothing** in `ContentIndex` and `NotesIndex`: the PRAGMA/migration/
  schema half runs inside a `do`, whose `catch` releases the handle and clears `db` before rethrowing, so
  the next `open()` re-reads the file. Teardown goes through one `discardHandle()` using
  **`sqlite3_close_v2`**, not `sqlite3_close`: close_v2 never returns BUSY, so clearing `db` can't strand a
  live connection holding the file lock — not theoretical, under the neutered build the stranded handle kept
  the `-shm` sidecar locked and even *replacing* the bad file failed. It reaches further in Notes, whose
  same file holds the app-owned `folders`/`memberships` tables, not just the disposable FTS cache.
  (1) Each driver now publishes a typed `Failure` — `.unavailable(detail:)` / `.incomplete(rows:)` — mapped
  from a pass's `Outcome` in ONE place (`finish`), and `.ok` **clears** it so a transient corruption doesn't
  leave a permanent warning. Reader's five query paths + Notes' two go through `openForQuery()`, which
  records the failure instead of returning a bare empty result (empty ≡ "no matches" to a user); Reader
  shows an amber status-bar line + tooltip carrying the SQLite reason (`ar.status.indexFailure`), Notes
  mirrors to `NotesModel.indexFailure` → the sidebar `statusMessage` banner. Notes' `isIndexReady`
  deliberately still flips on failure — it is the *settled* signal `awaitSettled()`/`bootstrap()` resume
  off, so gating it on health would hang the app before first paint; the health claim is `indexFailure`.
  Fell out: a failed open now **stops** the pass instead of extracting the whole library to discard it batch
  by batch. `pruneIfSettled`'s `try?` deliberately stays (a failed open makes the diff empty → deletes
  nothing), noted in place. Tier-2, scratch only (garbage sqlite3 files + real scratch `.md` notes; no
  corpus, no network, $0): **16 new headless tests** (Reader 3+7, Notes 4+9 → 23; 7 recovery + 16
  propagation), incl. the full arc corrupt → unavailable → replace the file → pass succeeds → failure
  cleared AND the row actually written, and the end-to-end Notes shape (real notes on disk + dead index →
  settled but NOT presented as healthy). **Non-vacuous per mechanism, by neutering:** dropping
  `discardHandle()` → Reader 2/3 + Notes 3/4 RED ("no such table: items"/"folders", "an error was expected
  but none was thrown"); restoring `try?` in `launch`/`openForQuery` → Reader 4/7 + Notes 4/9 RED, each on
  its own mechanism. All reverted. Reader 266/266 but for the known `DeepLinkTests.testRevealAndSelectNoRoot`
  environment flake (W20.deeplink-isolation); Notes **572/572**; clean builds, 0 new warnings, write-surface
  lint clean. `ContentIndexer` gained an `init(url:)` seam (app path is now `convenience init()`). Residual
  filed as **W23.m9-fu** (LOW). Write-ups: `ArchiveReader/KNOWN_ISSUES.md`, `ArchiveNotes/KNOWN_ISSUES.md`.
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/{ContentIndexer,ContentIndex}.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/NotesIndexer,Index/NotesIndex,Core/NotesModel}.swift | M | med | none
- [x] **W23.m9-fu — Notes' *model-level* search still can't report an unavailable index [XS–S · LOW].**
  Residual of W23.m9, filed 2026-07-30. `NotesModel.search(_:)`/`summary(for:)` query the shared
  `NotesIndex` **directly** rather than through `NotesIndexer`'s wrappers, so they never attempt an open and
  never set a `Failure`: after the banner is dismissed, a session whose index died at launch answers every
  search with `[]` and says nothing more. Not a re-open of m9 — the launch-time failure *is* surfaced (the
  build reports it and the sidebar shows it), so this is residual visibility for the rest of the session,
  plus the missed chance to recover if the bad file is replaced while the app runs. Fix: route those two
  through the same `openForQuery()` seam the indexer uses (or share one health-aware accessor), and let the
  banner re-arm. Notes `Core/NotesModel.swift`, `Index/NotesIndexer.swift`. | Tier-1 | XS–S | LOW
  — ✅ **DONE 2026-07-31** (checkpoint `cc9fb59` code+tests): both model-level reads go through one
  `NotesModel.openIndexForQuery()`, which delegates to `NotesIndexer.openForQuery()` (now internal) so the
  driver stays the single owner of index health, and opens directly under the same all-or-nothing contract
  for a model injected with a bare index — the report must not depend on which initializer ran.
  **One correction to the item's text:** `NotesModel` has no `summary(for:)`; its second direct read is
  `reloadItems()` → `allSummaries()`, the note-list projection, so that is the second path routed.
  Three things the item didn't name, each measured rather than assumed. (1) **Re-arming the banner is not
  the same as reporting once** — `adoptIndexFailure` now re-posts the line on every read that hits a
  degraded index, so a dismissed banner comes back instead of leaving the next empty result unexplained;
  the `@Published indexFailure` assignment is change-guarded because a 150 ms-debounced search would
  otherwise republish an identical value per keystroke. (2) **Retraction had to be added with it** — a
  recovering index otherwise leaves a now-false "unavailable" banner up for the rest of the session; the
  model records the line it posted and clears *only* that one, since `statusMessage` is shared with every
  other degradation. (3) **A failed `reloadItems` must not publish its empty read** — `allSummaries()`
  answers `[]` for an unopenable index exactly as for an empty one, so publishing it erased the visible
  library on the strength of a query that never ran; a *successful* read still publishes whatever it found,
  empty included. Writes (`upsertBatch`/`deleteItems`) were deliberately left out of the seam: they already
  throw and are reported, and an accessor that can return nil would turn that loud failure into a silent
  skip. **Tier-1, scratch only** (garbage/empty sqlite3 files + real `.md` notes in per-test temp dirs; no
  real store, no corpus, no network, $0): 11 new tests (`NotesModelIndexHealthTests`). **Non-vacuous,
  measured twice over:** against the pre-fix code the 6 report/recover assertions were RED and the 5
  must-not-over-report guards GREEN (blank query, healthy-empty index, healthy `reloadItems`, driver-less
  search, index-less model); then 3 neuters each reddened exactly one predicted assertion and nothing else
  (A unconditional retraction → the trash-failure line is swallowed; B no retraction → the false banner
  stays up; C publish the failed read → the library is erased). All reverted; `grep NEUTER` clean.
  **714/714** Notes + 189 XCTest, clean build, 0 new warnings. No ArchiveCore type and no SPEC change →
  Reader/Processor untouched, so the shared-core all-three-app rebuild rule is N/A. No new view code — the
  only visible surface is the existing `an.sidebar.status` line, and no GUI fixture can produce a corrupt
  index, so there is nothing for the VM lane to see (same as m9). Residual filed as **W23.m9-fu2** (below).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Core/NotesModel,Index/NotesIndexer}.swift
- [x] **W23.m9-fu2 — a repaired index becomes queryable again but stays EMPTY until the next launch
  [XS–S · LOW].** ✅ DONE — code in checkpoint `45b3854`, tests + trackers in this commit. The `unavailable → open`
  **edge** now schedules `repopulateIndexAfterRecovery()`, which is `buildIndexFromDisk()` verbatim — so a
  repaired index is refilled the same way a fresh one is, and a search moments later answers from real rows
  instead of an empty file. **Edge, not state, is the whole point:** the item was *filed* rather than fixed
  because the obvious version walks the store once per keystroke of a 150 ms-debounced search; triggering on
  the transition walks it once per recovery. (`.incomplete` deliberately stays out — unlike `.unavailable`
  it is not cleared by a successful open, so triggering on it would be state-triggered by the back door.)
  It also runs **off the read's critical path** (the read that notices returns its still-empty result at
  once; the rows land on a later read, as after any launch build) and **one at a time** (the pass re-enters
  the accessor via `reloadItems()`, and a flapping file would otherwise stack rebuilds). Reusing
  `buildIndexFromDisk()` rather than a bespoke path is deliberate: the two cannot drift, its upserts are
  mtime-skipped (a volume that returns with its rows intact costs one directory walk and no writes), and it
  repairs the *partial* index a mid-pass failure leaves, which an "only rebuild when it reads empty" shortcut
  would skip. Read-only w.r.t. the note store; prunes nothing — asserted, not merely claimed. The second half
  of the item's own objection is accepted on purpose: the pass **does** bump `isIndexReady`/`indexGeneration`,
  which is the behaviour change this item was split out to make deliberately — the token means "a build
  settled", and one did, and `isIndexReady` only ever goes true, so the hidden `an.status.indexReady` probe
  cannot regress to "building" under a test. No driver / no store is a no-op (nothing to walk). **Tier-1,
  scratch only** (garbage/empty sqlite3 files + real `.md` notes in per-test temp dirs; no real store, no
  corpus, no network, $0): 10 new tests (`NotesIndexRepopulationTests`). **Non-vacuous, measured four
  ways:** neutering the whole fix reddened 4 of 10 (refilled-on-a-later-read, `reloadItems` republish,
  exactly-one-rebuild, ready-token-advances) while all 6 guards stayed green; then three targeted neuters
  each reddened exactly ONE predicted test and nothing else — **state-triggered** (schedule on every
  successful open) reddened only "searching a healthy index never schedules a rebuild"; **inline-blocking**
  (await the rebuild on the read) reddened only the off-the-critical-path assertion; and **schedule-before-
  checking-`opened`** reddened only "a read over a still-dead index schedules no rebuild" — the case where
  a file that never comes back would walk the store on every keystroke. All reverted; source `git diff`
  empty against the checkpoint and `grep NEUTER` clean. **724/724** Notes (was 714), clean build, 0 new warnings. No
  ArchiveCore type and no SPEC change → Reader/Processor untouched, so the shared-core all-three-app rebuild
  rule is N/A. No new view code, and no GUI fixture can corrupt an index mid-session, so there is nothing for
  the VM lane to see (same as m9/m9-fu) — the one GUI-adjacent surface, the `an.status.indexReady` probe, is
  argued above and held by a headless test. **W23.m10-fu stays open**: same shape, but a different subsystem
  (`OrganizationStore`'s mirror) with its own retry seam — pairing them was a suggestion, not a dependency.
  | files: ArchiveNotes/macOS/{Sources/ArchiveNotes/Core/NotesModel.swift, Tests/ArchiveNotesTests/NotesIndexRepopulationTests.swift}
  *Original finding:* residual of W23.m9-fu, filed 2026-07-31 (`cc9fb59`). A read that re-opens an index which
  had been reported unavailable now retracts the false banner and hands back a live handle — but nothing
  repopulates it: rows are rebuilt only by `buildIndexFromDisk()` at launch (or one at a time by a later
  mutation's `upsertBatch`). So in the rare window where the bad file is repaired mid-session (operator
  replaces it, a sync client heals it, the volume returns), search goes back to answering `[]` with nothing
  said. Not a re-open of m9-fu: a dead index is now reported on *every* model-level read, and the
  retraction is correct — the "unavailable" claim really is false once the file opens. **Filed rather than
  fixed deliberately:** the obvious fix (kick `buildIndexFromDisk()` on the `.unavailable`→healthy
  transition) starts a full disk walk from a keystroke and bumps `isIndexReady`/`indexGeneration`
  mid-session, which the XCUITest `an.status.indexReady` probe reads — a behaviour change that deserves its
  own item rather than riding along on a LOW visibility fix. Same shape as **W23.m10-fu** (a recovered
  volume doesn't re-mirror until the next organization mutation), and worth doing with it. Notes
  `Core/NotesModel.swift`, `Index/NotesIndexer.swift`. | Tier-1 | XS–S | LOW
- [x] **W23.m10 — `organization.json` export failure is reported as a successful organization change
  [S · MED · durable-mirror rot].** `Index/OrganizationFile.swift`, `Index/OrganizationStore.swift`.
  `organization.json` is documented as **the authoritative durable mirror** that survives DB wipes and
  computer moves — but its export function returns `Void` and **suppresses both encode and atomic-write
  failures**, and every organization mutation commits SQLite/in-memory **first** then calls that nonthrowing
  exporter. On a full, read-only or unavailable Notes volume the UI reports folder / membership /
  template-assignment changes as successful while the mirror stays **stale** — and a later DB loss or
  migration restores obsolete organization state.
  **Fix:** make the exporter `throws`, propagate to the mutation's result, and surface failure (the mutation
  is not "done" until its durable mirror is). The existing DB-first shadowing note is about which source wins
  at startup/under test — not export failure after an interactive mutation.
  — ✅ **DONE** (checkpoint `0b9ded1`): the exporter throws, and the failure is now something the app both
  knows and says. **Premise re-confirmed by experiment first:** an atomic write into a missing directory
  throws, into a read-only directory throws **and leaves the previous bytes in place** — so the mirror does
  not go missing, it goes quietly *wrong* — and the old `try?` shape returned normally having written
  nothing. `OrganizationFile.export` now `throws`; `OrganizationStore` publishes
  `mirrorFailure` (`.writeFailed(detail:)` / `.noStoreRoot`) + `isMirrorStale`, cleared by any later
  successful export — correct because the export is **whole-graph, not incremental**, so one working write
  re-syncs the mirror *including* the changes whose own exports failed (proven, not assumed).
  **The load-bearing decision:** this is observable STATE, not a `throws` out of each mutation, and the
  reasoning is recorded in code so it isn't "simplified" back. The export is the LAST step, so by the time it
  can fail the change HAS committed — throwing would make ~17 call sites report "Couldn't create the folder"
  about a folder that exists and skip the `rebuild()` that shows it (a worse lie than the silence), and three
  existing callers use `try?` (`clearDanglingAssignments`, `deleteTemplate`, `move`'s source removal), so a
  thrown error would be swallowed on exactly the paths at issue. It is also the synchronous post-`await` seam
  **W23.m13** needs. `NotesModel.adoptMirrorFailure()` surfaces it on the existing sidebar status line (the
  W23.m9 `adoptIndexFailure` idiom), called LAST on all 17 organization-mutating paths in `NotesModel` +
  `NotesNavigationModel`, so a real degradation outranks that path's own status text and no caller loses its
  return value or its UI update. No trash/delete decision changed — mirror *atomicity* stays W23.m13.
  Tier-2, scratch only (`temporaryDirectory` fixtures; no corpus, no network, $0): **9 new headless tests**
  covering the seam, a healthy volume, the stale-mirror divergence read back off disk, whole-graph recovery,
  no-store-root, **each of the 9 mutation kinds attributed individually**, and the façade + navigation
  surfaces. The DB is deliberately placed OUTSIDE the store root so a read-only root breaks the mirror write
  and nothing else (co-located, SQLite couldn't write its journal and the mutation would fail *before* the
  export — testing the wrong thing). **Non-vacuous per mechanism, by neutering:** restoring `try?` → 6/9 RED
  incl. all 9 mutation cases; dropping `adoptMirrorFailure` → the 2 UI-surface tests RED; dropping the
  success-clear → the recovery test RED, each with the healthy-path checks correctly staying GREEN. All
  neuters reverted. Notes **581/581**; clean build, 0 new warnings. No ArchiveCore/SPEC change → Reader and
  Processor untouched, shared-core rebuild rule N/A. No new view code (the `an.sidebar.status` line already
  existed and is GUI-covered), so nothing for the VM lane. Residual filed as **W23.m10-fu** (LOW).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationFile,Index/OrganizationStore,Core/NotesModel,Core/NotesNavigationModel}.swift | S | med | none
- [x] **W23.m10-fu — a recovered volume doesn't re-mirror until the next organization mutation
  [XS · LOW].** Residual of W23.m10, filed 2026-07-30. `mirrorFailure` is cleared by the next *successful
  export*, and the only thing that exports is a mutation — so if the disk frees up (or the volume comes back)
  and the operator never touches folders again, `organization.json` stays stale for the rest of the session
  with nothing on screen saying so once the status line has been tap-dismissed. Not a re-open of m10: the
  failure IS reported when it happens, and any later organization change self-heals the whole mirror. Fix:
  retry the export opportunistically while `isMirrorStale` (on app activate / periodically / before
  terminate), or make the sidebar line sticky while stale rather than dismissible. Notes
  `Index/OrganizationStore.swift`, `Core/NotesModel.swift`. | Tier-1 | XS | LOW
  — ✅ **DONE** (checkpoints `bd2ac11` = code, `7a5cf04` = tests). `OrganizationStore.retryStaleMirrorExport()`
  re-runs the same **whole-graph** export — so one working write recovers everything that missed the mirror,
  with no queue of changes to replay — and `NotesModel` hangs it off **app activation** and **app terminate**.
  Those two, not a timer: activation is the moment correlated with the volume having come back, terminate is
  the last moment the file can be written before the next launch inherits it (the DB wins at startup, so
  nothing else re-syncs it), and this app does no background polling. **Three guards, each a way the obvious
  implementation goes wrong.** (1) It runs **only while stale**, so no app switch rewrites a healthy
  `organization.json` — the whole reason it is safe to hang off something that frequent. (2) It requires the
  graph to have **finished loading**: `load` assigns `storeRoot` before it awaits the DB, and a speculative
  export in that window would put a half-built forest in the user's file. (3) The stale line is **re-posted**
  on every activation while the volume is still bad (the m9-fu "a dismissed banner comes back" idiom) and
  **retracted** when the mirror heals — narrowly, only if the line still showing is the one this model posted,
  since `statusMessage` is shared. Retraction had to ship *with* the retry: before it, `mirrorFailure` could
  only stop being true via a mutation, so nothing could leave a false claim on screen. **Reentrancy checked,
  not assumed:** the trigger is a synchronous notification, so it can land on the main actor while a mutation
  is suspended at its `await` (`@MainActor` is reentrant) — but every mutation in the store commits DB
  transaction → memory → export with **no suspension between the last two**, so the only state a retry can
  observe mid-mutation is the consistent *pre-mutation* graph, which that mutation's own export supersedes a
  moment later (and if it throws instead, the pre-mutation graph was the right thing to have written). Noted
  next to the convention it depends on. The observers live in a small non-isolated box so they are removed
  when the model dies — a `@MainActor` type's `deinit` cannot touch its own token array. Tier-1 but gated
  like Tier-2 (it writes a durable file), scratch only (`temporaryDirectory` fixtures + a `0555` root, index
  deliberately outside it; never the real store, no corpus, no network, $0): **9 new tests**
  (`OrganizationMirrorRetryTests`), including sentinel bytes to prove a healthy mirror is *not* rewritten.
  **Non-vacuous by 4 neuters, each reddening exactly the predicted tests and nothing else:** dropping the
  stale-only guard → the 2 "healthy mirror untouched" tests; dropping the loaded-graph guard → the no-root
  test; unwiring the triggers → the 4 notification tests; dropping the retraction → the recovery test only
  (the "don't swallow another subsystem's line" test correctly stayed green). All reverted, `grep NEUTER`
  clean. A 5th measurement corrected a *comment* rather than code: `queue: .main` also runs inline when the
  post is already on the main queue, so the doc no longer claims a behavioural difference it doesn't have —
  `queue: nil` is kept for the documented synchronous-delivery guarantee the terminate leg rests on.
  **733/733** Notes (was 724), clean build, **0 new warnings**. Notes-internal — no ArchiveCore type and no
  SPEC change → the shared-core all-three-app rebuild rule is N/A. No new view code (the `an.sidebar.status`
  line already existed and is GUI-covered) and no GUI fixture can make a volume read-only mid-session, so
  there is nothing for the VM lane to see — same argument as m10/m9-fu2.
  | files: ArchiveNotes/macOS/{Sources/ArchiveNotes/Index/OrganizationStore.swift,
  Sources/ArchiveNotes/Core/NotesModel.swift, Tests/ArchiveNotesTests/OrganizationMirrorRetryTests.swift}
- [x] **W23.m11 — the app-wide inline-image cache can display another note's same-named image
  [S · MED · wrong content shown].** ✅ DONE this commit. Premise re-confirmed by symbol first and it was
  live: `MarkdownBridge.swift:248` passed `cacheKey: ref.path` into the **static** (app-wide)
  `thumbnailCache`, so two notes each owning their own `assets/x.png` — ordinary, and explicitly supported
  by the store — shared one entry, and note B displayed note A's image without ever opening B's file.
  Fixed by deriving the key from the **resolved canonical URL** *inside* `loadThumbnail`, which no longer
  accepts a caller-supplied key at all: a caller-named key is how the coarse key got used, so the seam is
  gone rather than merely used correctly. **Two deliberate deviations from this item's fix sketch, both
  documented at the symbol:** (1) *no separate item UUID* — the resolved URL already spells out
  `…/items/<uuid>/assets/<name>` (`NoteStore.itemDir`), so the item is in the key by construction, and two
  items can only collide by literally sharing the file, where one shared entry is the correct answer (a test
  pins that a same-item symlink and its target share one); adding a UUID would only split it in two.
  (2) *no per-item invalidation* — an asset path is **write-once** in this app (`writeReservedAsset` throws
  rather than overwrite, `importAsset` disambiguates, UUIDs are never reissued), so a purge would have had
  no caller. `maxPixels` **is** in the key, closing the same aliasing bug one size-shift away. Normalization
  is string-only, so a cache hit still costs zero disk I/O. **8 new tests** (`InlineImageCacheKeyTests`),
  each non-vacuous: note B renders its own blue pixels after A warmed the cache with red under the same
  relative path; a red sentinel planted under the *exact* pre-fix key is asserted to be a live hit and then
  shown to be ignored by the render; the hit path is proven by serving a warm entry with the file's bytes
  replaced by garbage. 589/589 `ArchiveNotesTests` green, no new warnings. Residual filed as **W23.m11-fu**
  (LOW). Write-up: `ArchiveNotes/KNOWN_ISSUES.md`.
- [x] **W23.m11-fu — an inline image replaced OUTSIDE the app keeps showing its old thumbnail
  [XS · LOW · stale display].** Residual of W23.m11, filed 2026-07-30. Cache entries never expired, which is
  sound for every in-app writer (asset paths are write-once — see m11), but the Notes store root can live in
  a synced folder, and a sync client rewriting bytes at an existing `items/<uuid>/assets/<name>` left the
  editor showing the previous thumbnail until the entry was evicted or the app restarted. **Display only** —
  the file on disk, the note body, and the copy/extract path (which reads bytes fresh) were all correct,
  which is why this was LOW and not a re-open.
  ✅ **DONE this commit** (checkpoint `136453b` = the code). Took the first option: `cacheKey` folds in the
  file's **version** — size + nanosecond `st_mtimespec` from one `stat(2)` — so a stale entry is never looked
  up again. Nothing expires and nothing is purged; it ages out of a bounded cache under a name nothing asks
  for. `cacheKey` returns **nil** for a file that cannot be stat'ed, so a vanished asset has no cache identity
  and is read (and fails) rather than answered out of memory; `cached: false` skips the stat entirely.
  **The item said "measure first". Measuring reversed a design choice and demoted the objection:**
  (1) **`stat(2)`, not `URL.resourceValues`** — `URL` caches resource values on its backing `NSURL`, so
  rewriting a file 100→250 bytes between two calls *on the same `URL` value* read back **unchanged on both
  fields**; the idiomatic Foundation call would have defeated the fix silently (`FileManager
  .attributesOfItem` is honest but ~437 µs vs ~15 µs). (2) **A hit got cheaper, not dearer** — the ~15 µs
  `stat` *replaces* a `standardizedFileURL` that cost ~53 µs and itself touched the file system (12.8 µs on a
  path that does not exist, 52.7 µs on one that does), so key construction goes ~76 µs → ~17 µs; the premise
  behind the objection ("a hit does no disk I/O") was not true to begin with. The decode a hit avoids is
  ~3,200 µs. (3) **Nanosecond mtime is sharp enough** — 20 back-to-back same-size rewrites of one file gave
  20 distinct versions on APFS; the only rewrite still invisible is same-length *and* same-timestamp, which
  needs a coarser-timestamp volume (SMB) and still recovers on eviction/relaunch as before.
  The other option (purge on an observed external change) was rejected with a reason, not skipped: the store
  observes nothing — Notes has **no file-system watcher**, as W23.m9-fu2 records for the index — so that is a
  new subsystem, not a key change. **Tier-1, scratch only** (temp-dir stores; never the real Notes store, no
  corpus, no network, $0): **5 new tests** in `InlineImageCacheKeyTests`, each first showing the stale entry
  is *still live in the cache*, so what they prove is the keying and not an eviction. One existing test was
  changed rather than deleted — `repeatRenderStillHitsTheCache` proved a hit by replacing the bytes with
  garbage, which is now a different file; it pins the mtime to a whole second (restorable exactly), swaps in
  **same-length** garbage and restores that timestamp, keeping its intent and documenting the granularity.
  **Non-vacuous by 4 neuters, each predicted in advance and each reddening exactly the predicted set:**
  drop the version → the 3 detectors; drop the nil-on-missing contract → the 1 vanished-asset assertion; drop
  the path → the 2 tests pinning m11's own result; invalidate on *every* call → the cache-hit guards (which
  is what proves those guards aren't vacuous). All reverted; source diff clean, `grep NEUTER` empty.
  **738/738** Notes green (was 733), clean build, **0 new warnings**. Notes-internal — no ArchiveCore type,
  no SPEC change → the shared-core all-three-app rebuild rule is N/A. GUI: the visible effect *is* the decoded
  pixels, asserted headlessly at attachment level (as in m11), and no GUI fixture can rewrite a file behind
  the app's back → nothing for the VM lane to see. Write-up: `ArchiveNotes/KNOWN_ISSUES.md` (folded into the
  m11 entry, whose now-false "no disk I/O on the hit path" cost claim is corrected there).
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Editor/InlineImageAttachment.swift | Tier-1 | XS | LOW
- [x] **W23.m12 — a FAILED move-to-Trash still removes the surviving note from the index [S · MED · note
  disappears].** `Core/NotesModel.swift` → `trashItems`. It **logged** each `NoteStore.delete` failure but then
  deleted **every requested ID** from `NotesIndex` and reloaded the list. A note whose directory is still on
  disk therefore vanished from **All Notes for the rest of the run** — there is no watcher to restore it, and
  the full disk rebuild runs only at bootstrap. This **contradicted the method's own stated safety invariant**
  that a trash failure leaves the note on disk *and discoverable* under All Notes.
  ✅ **DONE 2026-07-30** (checkpoint `8e15b59` fix + tests/docs in the completing commit): a row is dropped
  only once its note is **provably absent**, decided by asking the disk (new read-only `NoteStore.itemExists`)
  rather than by classifying the error — because `delete` *also* throws when the directory was already gone
  (`StoreError.notFound`), where keeping the row would strand a phantom note that opens on nothing. A refused
  note keeps its row (still under All Notes, 0 memberships) and the sidebar status line says where it is;
  `trashItems` returns the survivors. Same seam, opposite direction: a failing `NotesIndex.deleteItems` is no
  longer swallowed by a bare `try?`. 9 new scratch tests (`NotesTrashFailureTests`) over a real
  store+index+indexer, with a **per-item** `UF_IMMUTABLE` refusal so one note in a batch fails while its
  sibling trashes normally; both real callers covered; non-vacuity measured by 3 neuters (pre-fix → the 4
  finding tests RED; over-correct → only the already-absent guard RED; `try?` → only the index-write test RED).
  598/598 Notes green, 0 new warnings.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesModel.swift | S | med | none
- [x] **W23.m13 — several multi-step Notes organization operations leave partial state after a failure
  [M · MED · fault atomicity] (blocked-on: W23.m10).** `Index/OrganizationStore.swift`,
  `Core/NotesModel.swift`, `Core/NotesNavigationModel.swift`. The Notes façade **claims organization mutations
  are atomic**, but three span independent awaited writes with no transaction or rollback:
  - `deleteFolder` mutates each child **in memory** before its individual DB update, then separately deletes
    memberships, assignments and the folder — a later SQLite failure leaves a partially reparented/deleted
    graph in memory **and** on disk.
  - `deleteTemplate` clears **every** folder assignment before attempting to move the template to Trash — if
    Trash fails the template survives but its assignments are gone.
  - `move` adds the target membership first then **suppresses source-removal failure** — the UI reports a move
    while the item is actually **replicated in both folders**.
  **Fix:** wrap each in a real SQLite transaction (or an explicit compensating rollback), and only mutate
  in-memory state after the durable write commits. Blocked-on W23.m10 because that item makes the export leg
  of these same mutations failable — do the error-propagation seam once. No active item covers this.
  ✅ **DONE 2026-07-30** (checkpoint `59fc57c` = the three fixes; completing commit = tests + trackers): all
  three are now real SQLite transactions, and **no in-memory state moves until the disk says it committed.**
  `NotesIndex` gains `deleteFolderGraph` / `moveMembership` / `deleteTemplateAssignments` — whole methods, not
  exposed BEGIN/COMMIT, because this actor's invariant is *no suspension between BEGIN and COMMIT* and
  `OrganizationStore` is `@MainActor` (reentrant at every await). `deleteFolder` builds the reparented children
  as copies and applies them after the commit; the folder-delete await count drops 4 → 1. `move` goes through
  a new `OrganizationStore.moveMembership` that keeps **both** properties the old add-then-`try?`-remove order
  existed for (the insert precedes the delete *inside* the transaction, so the item is never member-less and
  MOVE can't trip the §3.6 guard) while making a failure total — and `NotesNavigationModel.move` now says
  "it's still where it was", which only the rollback makes an honest thing to say. `deleteTemplate` **trashes
  first** and clears assignments only once that succeeded (the reverse of its old order): a refused trash now
  changes nothing, and the opposite failure leaves only a dangling assignment, which `TemplateResolution`
  already skips and `effectiveTemplate` lazily clears. The measured surprise worth recording: the DB-side loss
  was **silent, not loud** — memory was *also* unchanged (the throw skipped its own cleanup) while the
  memberships were already gone from SQLite, and `load()` prefers the DB, so the next launch adopted the lossy
  half and orphaned those notes with no §3.6 prompt ever shown. 16 new scratch tests
  (`OrganizationAtomicityTests`) with **real SQLite fault injection** — a `BEFORE DELETE … RAISE(ABORT)`
  trigger, targeted by row where a batch needs the first delete to succeed and the second to fail (an
  all-rows refusal cannot tell a rollback from a half-applied batch); 2 assert the fixture's own honesty.
  Non-vacuity measured by 4 neuters, each reddening a disjoint set: pre-fix `deleteFolder` → the 3 folder
  tests (7 assertions); pre-fix `move` → the 2 move-failure tests (5); pre-fix `deleteTemplate` order → the
  template test (assignments go to `[]` while the template survives); non-transactional batch clear → the
  batch test. All neuters reverted (`git diff` empty). 614/614 Notes green, clean build, 0 new warnings.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Index/OrganizationStore,Index/NotesIndex,Core/NotesModel,Core/NotesNavigationModel}.swift | M | med | none
- [x] **W23.m14 — resolving a missing Reader link synchronously scans the whole archive on the main actor
  [S–M · MED · UI freeze].** `Links/ReaderLinkResolver.swift`. The resolver is `@MainActor`; when an exact
  relative path is missing, `resolve` **synchronously enumerates every descendant** of the granted Reader root
  looking for a matching basename. Clicking **one** broken or moved source link therefore freezes all Notes UI
  for the duration of a **100k–150k-file** archive walk, with **no cancellation**. (The basename fallback is
  intended behaviour — doing it synchronously on the UI actor is the defect.)
  **Fix:** move the fallback off the main actor into a cancellable async task with progress + a bound, and
  keep the resolver's fast exact-path hit synchronous. Notes W9 C6 covers Notes-index scale, not Reader-root
  fallback scanning.
  ✅ **DONE 2026-07-30** (checkpoint `71cb722` = the split + the popover; completing commit = tests +
  trackers). Premise re-confirmed by symbol first. Resolution is now two stages: `resolveExact` keeps the
  cheap answers (unknown root, containment refusal, exact hit) synchronous on the main actor and returns
  `.needsBasenameSearch` **instead of** searching, and `nonisolated static scanForBasename` does the walk on
  the cooperative pool. **The synchronous full-walk API is gone rather than deprecated** — the defect was not
  that one call site was slow, it was that the resolver *offered* a main-actor walk over a 100k–150k-file
  archive, so `resolve` is async-only and a future caller cannot re-introduce the freeze.
  **A search that did not finish is never reported as absence:** the new `.searchIncomplete(scanned:)` case
  covers cancellation, the entry bound, and an unwalkable root, and the popover says the file "may still be
  there" instead of "not found". The bound is `1_000_000` entries — an order of magnitude clear of the real
  corpus (~102k PDFs + JPEG partners + folders), because it exists to stop a pathological mount, not to cap a
  legitimate archive. A root that **doesn't exist** still reports `.notFound` (nothing can be under it), which
  is what keeps the shipped W8-S9 computer-move contract intact — a distinction the E2E suite caught.
  Cancellation is checked every 64 entries; the popover cancels on dismiss/re-show and shows a live
  "N items checked" readout, generation-scoped so a finished search's straggler ticks can't inflate the next
  one's count. **10 new tests** (`ReaderLinkScanTests`), scratch temp trees only, `readerRootBookmarks`
  snapshot/restored so host defaults are left byte-identical. **Non-vacuity measured by 3 neuters, each
  reddening a disjoint set:** pre-fix main-actor walk → 4 tests; unfinished-search-reported-as-`notFound` →
  the 2 honesty tests; `@MainActor` scanner → the 2 off-actor tests. The off-actor proof is structural, not
  timing-based — the raw progress callback runs on the scanning thread, so `Thread.isMainThread` inside it
  answers the question directly. **624/624** `ArchiveNotesTests` green, clean build, 0 new warnings. Notes-only
  — no ArchiveCore type touched, so the shared-core rebuild rule is N/A. VM UITest lane re-run: the same 4
  pre-existing failures as the 19:44 baseline (G3/G6/G8/G11, already tabled in `ArchiveNotes/KNOWN_ISSUES.md`),
  no regression. Containment still uses `standardizedFileURL` **on purpose** — W23.l1 (blocked-on this item)
  is the symlink-containment fix and stays a clean one-line change on this seam, now unblocked.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/Links/ReaderLinkResolver.swift | S–M | med | none
- [x] **W23.m15 — deleting the Inbox or Extracts system folder is permanent and creates ghost memberships
  forever [S–M · MED].** ✅ **DONE 2026-07-31** (checkpoint `cf03fe1` = the three Swift refusal layers,
  the by-id restore and 13 tests; completing commit = the SQL foreign key, its migration and the
  trackers). Rename/Delete are disabled
  on a system folder in the sidebar, refused with a readable sentence by `NotesModel` (and refused
  *before* `deleteFolderDeletingStranded` trashes anything), and refused by `OrganizationStore` as the
  backstop; `load` restores a missing system folder **by id** on every path — a no-op for a healthy
  store, never clobbers a rename, and revives the memberships the deleted folder stranded;
  `addMembership`/`moveMembership` refuse an unknown folder, and `memberships.folder_id` is now a real
  FOREIGN KEY with an in-place migration that carries a legacy DB's ghost rows across rather than
  deleting durable data to satisfy a constraint added after the fact. **NO ACTION, not ON DELETE
  CASCADE** — a cascade would let any stray folder-row delete silently empty the folder. Two claims the
  tests corrected: an `INSERT OR REPLACE` on `folders` is *survivable* under NO ACTION (SQLite checks an
  immediate FK at statement end, so delete-then-reinsert of the same key nets to zero), so the
  `updateFolder` rewrite is justified by non-upsert semantics rather than that hazard; and
  `replaceOrganization`'s delete order **is** load-bearing (children before parents). 20 new tests
  (`SystemFolderIntegrityTests`), scratch fixtures only; 644/644 green; non-vacuity proven by 6 neuters,
  each reddening a disjoint set. Residual **W23.m15-fu** (LOW) filed in the LOW section.
  `Views/NotesFolderTreeView.swift`, `Index/OrganizationStore.swift`,
  `Core/NotesModel.swift`, `Index/NotesIndex.swift`. Every folder — **including the fixed-ID Inbox and
  Extracts** — gets Rename and Delete actions, and `deleteFolder` accepts those IDs. System folders are
  reseeded **only when the entire folder table is empty**, so deleting one is **permanent**. Worse, new notes
  and extracts keep filing memberships under the deleted fixed IDs: `addMembership` **does not verify the
  folder exists** and SQLite declares **no foreign key** — so the graph accumulates memberships to a folder
  that can never appear in the tree or be restored by normal startup.
  **Fix:** (a) refuse Rename/Delete on the two system folder IDs in both the UI *and* `deleteFolder`
  (defence in depth); (b) reseed a missing system folder at startup by **ID**, not only on an empty table;
  (c) make `addMembership` reject a nonexistent folder, and add the FK/constraint.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Views/NotesFolderTreeView,Index/OrganizationStore,Core/NotesModel,Index/NotesIndex}.swift | S–M | med | none
- [x] **W23.l1 — the Notes Reader-link containment check is bypassable through a symlink [S · LOW · scope
  bypass] (blocked-on: W23.m14).** ✅ **DONE 2026-07-31** (checkpoint `2f13d25` = the exact-path stage + 8
  tests; completing commit = the basename walk, its 2 tests and the trackers). Premise re-confirmed on a
  scratch tree before anything changed: the old rule really did accept the escape — `standardizedFileURL`
  normalizes `..` lexically and does **not** resolve symlinks, while `fileExists` **does** follow them, so
  `<root>/alias.pdf` → a PDF outside the granted Reader root came back `.resolved`. Containment now goes
  through one seam, **`ReaderRootContainment`**: `canonical()` = `resolvingSymlinksInPath().standardizedFileURL`
  applied to **both sides** (so a root reached through a symlinked ancestor, or the `/var` ↔ `/private/var`
  alias, still contains its own files) and `isContained()` compares **path components** (so `…/root-extra/x.pdf`
  is not "under" `…/root`). Both doors are closed, not just the one in the finding: the **basename walk** was
  the other one — the enumerator lists a symlink as an ordinary entry, so an escaping twin could still be
  offered as `.renamedCandidate`; it is now skipped, and *skipped* rather than stopped, so a genuine copy
  further on is still found and absence is still established (`.exhausted` → `.notFound`, never
  `.searchIncomplete`). `.resolved` still carries the URL the link named, not its canonical form — that is the
  spelling the granted root's security scope covers, and containment is proven by then. `ReaderPreviewPopover`
  needed **no change**: it presents whatever the resolver decides, and the resolver is the seam. Kept honest in
  the other direction — an in-root symlink still resolves, a root under a symlinked ancestor still resolves its
  files, and a **dangling** symlink is not an escape (there is nothing to escape to): it falls through to the
  basename search like any other missing file. **10 new tests** (`ReaderLinkContainmentTests`), scratch temp
  trees only, `readerRootBookmarks` snapshot/restored so host defaults are left byte-identical; **every escape
  case first asserts the pre-fix rule accepted the fixture**, so none can pass vacuously (the W23.m3
  `AssetPathResolverTests` pattern). One fixture correction worth recording: a root that IS a symlink cannot be
  registered at all — security-scoped `bookmarkData` refuses one — so that guarantee is proven at the predicate
  level and the end-to-end test uses the shape that does occur, a symlinked *ancestor*. **654/654**
  `ArchiveNotesTests` green, clean build, 0 new warnings. Notes-only; no ArchiveCore type touched, so the
  shared-core rebuild rule is N/A. No view or interaction code changed, so no VM UITest run was needed.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Links/ReaderLinkResolver,Views/ReaderPreviewPopover}.swift | S | low | none
- [x] **W23.l2 — a cancelled prune task can still defeat the two-emission absence gate [S · LOW · residual
  race] (blocked-on: W23.m9).** ✅ DONE `ad5e5cb` (Reader) + this commit (Notes + trackers).
  **Premise re-confirmed empirically first, and the first probe refuted itself** — which is the useful part.
  Replaying the pre-fix shape under the real concurrency runtime showed back-to-back emissions are actually
  **safe** (task A dies at its first cancellation check, never having started); the race needs A genuinely
  mid-flight, which is the real case since `allPaths()` over a large index takes real time. Parked past A's
  last check, all four questions confirmed: A observed `Task.isCancelled == true` and ran its hops anyway; a
  superseded A overwrote state a newer emission had just written; that stale stash deleted a path after only
  ONE current absence; and in the other interleaving A deleted a path the newest snapshot said was present.
  **Fix = a prune epoch, with two load-bearing halves:** `commitPruneDecision` does read-decide-write in ONE
  main-actor hop (a split read-then-write is the window the newer emission interleaved through, so the
  generation check alone would not have closed it), and the row delete re-checks the epoch — skipping a
  superseded delete costs only another two-emission cycle, while deleting wrongly costs search hits until a
  reindex. `resetPruneState` bumps the epoch too, or an in-flight task from the OLD root re-stashes its
  absences over the cleared state. Reader also gained a pure `pruneDecision` mirroring Notes', which moves the
  empty-snapshot guarantee inside the decision (no reachable behaviour change — `NavigationModel` already
  refuses to call with an empty set — it just can't be lost to a future caller). **Notes' half is preventive
  and labelled as such:** `pruneIfSettled` there still has no production caller, but it is a fork of the
  Reader file and both were fixed together so the day one is wired it inherits the gate, not the race.
  **16 new tests** (Reader `ContentIndexerPruneRaceTests` 10, Notes `NotesIndexerPruneRaceTests` 6), scratch
  sqlite / scratch store only. Both race interleavings are driven **deterministically through the epoch seam**
  rather than by trying to win a real race, and each re-implements the PRE-FIX ungated logic against the same
  fixture and asserts it produced the harmful outcome, so none can pass vacuously; plus a guard that
  `pruneIfSettled` really opens a new epoch (so a future edit can't silently drop it), the reset case, and
  four end-to-end passes over a real index and the real driver — awaited via `inFlightPruneTask`, not slept
  on — since the refactor moved the delete after the state write. Clean builds, 0 new warnings; Notes
  **660/660**, Reader green apart from the known `DeepLinkTests.testRevealAndSelectNoRoot` host-defaults flake
  (tracked as W20.deeplink-isolation). No ArchiveCore type touched → shared-core rebuild rule N/A; no view or
  interaction code → no VM UITest run needed. Original finding follows.
  Reader `Search/ContentIndexer.swift`, Notes `Index/NotesIndexer.swift`.
  Starting a prune cancels the prior detached task, but **cancellation is cooperative**: after the old task's
  final cancellation check it can still read `pendingPrune`, delete rows, and later overwrite pending state in
  separate main-actor hops. A newer emission can interleave in that window, so an old task compares against
  **stale absence state** and deletes after what is effectively only **one** current consecutive absence. The
  source files are safe (these are disposable indexes) but search results can vanish until reindexing.
  **Fix:** add the missing **post-cancellation generation gate** — stamp each prune task with a generation and
  make every write (row delete + `pendingPrune` update) a no-op if the generation is no longer current.
  W6.1b and the Notes prune work are marked fixed by cancellation + a two-emission gate; this is a **residual
  race in that fix**, not a duplicate. ⚠️ Codex confirmed the missing gate **by inspection only** — it did not
  run a deterministic race fixture; re-confirm, ideally with one.
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Search/ContentIndexer.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/Index/NotesIndexer.swift | S | low | none
- [x] **W23.l3 — concurrent first-time root-marker creation can orphan newly copied links [S · LOW · SHARED
  CORE].** ✅ DONE `fa8bc02` + this commit — folded into **W23.m6** as this
  entry anticipated. The absence check moved *inside* the write claim and a racer that finds a winner adopts
  it. Codex's inspection-only finding is now reproduced by a deterministic fixture:
  `RootMarkerDurabilityTests.concurrentFirstTimeEnsureAgreesWithWhatLandedOnDisk` — with the old ordering,
  8 concurrent callers were handed 8 different GUIDs while one landed on disk (RED 3 runs out of 3). `packages/ArchiveCore/.../Links/RootMarker.swift` → `ensure`. It checks for absence **before**
  entering write coordination, generates a UUID, then blindly writes it. Two processes can both observe
  absence and serialize writes of **different** markers: process A can re-read and return A before process B
  writes B as the final disk value — so A-based links get copied even though the root ultimately identifies as
  **B**. Sequential idempotency + the final re-read do **not** close this cross-process check-then-write race.
  **Fix:** do the absence check **inside** the write coordination and create exclusively
  (`O_EXCL`-equivalent / coordinated read-then-write in one critical section); on losing the race, adopt the
  winner's marker. ⚠️ Shared-Core rule: build+test all three apps + `swift test` in `packages/ArchiveCore`.
  W15's per-path serialization is Finder-tag writes and in-process callers only. Natural companion to
  **W23.m6** (same file) — if m6 lands first, fold this in.
  | files: packages/ArchiveCore/Sources/ArchiveCore/Links/RootMarker.swift | S | low | none
- [x] **W23.l4 — Notes accepts impossible day-precision calendar dates [XS–S · LOW].**
  ✅ DONE `dee05ab` (the calendar) + this commit (the three seams + trackers). **The finding named two seams;
  there are three.** `ZoteroAutoFill.mappedDate()` carried the identical independent `1…31` check, and it
  matters more there: `AutoFillPlan.apply` writes `date`/`date_precision` straight onto the item, so
  `Item.normalizedDate` never sees it — a CSL record saying `date-parts: [[1968, 2, 31]]` was the one path
  where nothing downstream could catch the day. All three now ask one new `GregorianDay`.
  **`Calendar` is the wrong tool here, measured not assumed.** `DateComponents.isValidDate(in:)` — identically
  for `.gregorian` and `.iso8601`, both ICU Julian→Gregorian hybrids — calls `1500-02-29` **valid** (a Julian
  leap year), so it would not have closed the bug before the cutover, and calls `1582-10-10` **invalid** (ICU
  deletes the ten cutover days), so it would have silently rejected a real date off an early-modern document.
  `Calendar.current` is additionally locale-dependent. `GregorianDay` is therefore plain arithmetic, and
  February takes 29 days when the year is a leap year under **either reckoning that could have produced the
  date** — proleptic Gregorian, or Julian before 1582. The 1582 boundary is a stated trade-off: regions on the
  old calendar into the 20th century did have `1900-02-29`, but honoring that re-admits the likeliest modern
  typo. **Coarsen, never clamp:** `2026-02-31` ⟹ `2026-02` at month precision, which states what is known,
  where clamping to Feb 28 would assert a day the source never said. That reuses the downgrade rule
  `normalizedDate` already had for a missing component, so no new behavior category. ArchiveCore's shared
  `sortDateKey` was **not** touched (per the item's constraint) → shared-core rebuild rule N/A.
  **The month menu, not the "Set" button, was the live path**: the picker commits on selection, so choosing
  February with 31 already typed reached the store with no button to intercept — so the compose rule refuses
  the day and an inline orange note (`an.detail.date.dayWarning`) says *"February 2026 has 28 days — the day is
  ignored."*, and the day row's Set goes dead only for a day that month cannot have (its old cases, incl. no
  month chosen, still commit). The view's field rules moved into a pure `DateFieldEntry` so they are testable
  without a window; the view is now just `@State` + bindings, and no UITest is needed for the logic.
  **+33 tests, Notes 693/693, clean build, 0 new warnings.** `GregorianDayTests` (month lengths, century/400,
  day 0/32, month 0/13, the pre-cutover carve-out, the cutover gap, and two equivalence sweeps against
  Foundation over the post-1582 range where Foundation is trustworthy); `DateFieldEntryTests` (incl. the
  month-menu path and a cross-product proving a live Set and a shown warning are mutually exclusive);
  `FrontMatterDateWriteTests` +4 driving the real model → `NoteStore` → front-matter path on a scratch store,
  incl. every real month-end surviving at day precision; `ZoteroAutoFillTests` +3 through `apply()`. Every
  impossible-day case also re-runs the pre-fix predicate and asserts it said yes, so none can pass vacuously.
  Read path deliberately untouched: a `date:` a human hand-edited into a note file is their data, and its sort
  key is harmless (`20260231` lands between Feb 28 and Mar 1).
  **GUI (off the owner's screen, `ops/gui/vm-gui-runner.sh notes both`):** Notes UITests in the Tart VM =
  **12 executed, 8 passed, 4 failures — exactly the tabled deterministic G3/G6/G8/G11** (`ArchiveNotes/
  KNOWN_ISSUES.md`), so no regression; the sighted VNC capture shows the app launching and drawing (list +
  Date column) with this change in the build. **Stated plainly: no UITest drives the metadata strip**, so the
  new warning row's pixels were not eyeballed — its logic is what `DateFieldEntryTests` pins, and a 10-second
  owner check is in Morning Review. Also found: `vm-gui-runner.sh` reports `VM 'archive-gui-runner' not found`
  when `tart` merely isn't on a non-login shell's PATH — a misdiagnosis worth folding into W21.vmgui-a's
  "make it LOUD" work (`export PATH=/opt/homebrew/bin:$PATH` first). Original finding follows.
  `Views/NoteMetadataInspector.swift`, `Store/Item.swift`. The UI and normalization logic validate month as
  1…12 and day as 1…31 **independently**, never validating the combination against a calendar — so
  `2026-02-31` is persisted as a day-precision date and receives a normal chronological sort key.
  **Fix:** validate the (year, month, day) triple against `Calendar` before accepting/normalizing; reject or
  clamp with a visible message. ⚠️ Sort keys come from ArchiveCore's shared
  `DocumentTags.sortDateKey(year:month:day:decade:)` — **validate at the input seam, do not change the shared
  sort formula.** No current Notes date-validation item covers impossible combinations.
  | files: ArchiveNotes/macOS/Sources/ArchiveNotes/{Views/NoteMetadataInspector,Store/Item}.swift | XS–S | low | none
- [x] **W23.h5-fu — Process Files still can't tell a placeholder PDF from a real one (the signal now exists;
  nothing there reads it) [XS–S · LOW].** ✅ DONE inside **W23.m5** exactly as this entry required —
  `ff792a9` (all five `generate` call sites now capture `ImagePageOutcome`, surfaced through W23.m5's
  per-run warning channel, not a second one) + `4cf1fb7` (keyed to the source photo, which is the page
  to re-run) + this commit (trackers). The multi-page re-OCR assembly reports a placeholder if ANY page
  fell back; the merged-PDF case keeps the warning against the photo it came from; a regen that embeds
  the scan clears it. Covered by `scripts/test-processfiles-tagwarn.sh` (a real `PDFGenerator` run on a
  decodable vs. an undecodable image drives the record end to end; the PDF is still written with both
  pages and the source image is confirmed untouched). Original finding below.
  Found 2026-07-30 while fixing W23.h5.
  *(The `blocked-on` was added 2026-07-31: the prose below already said "do this inside W23.m5", but with no
  machine-readable dependency `next-queue-item.sh` offered h5-fu as actionable AHEAD of m5 — which would have
  produced exactly the second warning channel this item forbids.)* `PDFGenerator.generate` now
  returns `ImagePageOutcome`, but the change was kept `@discardableResult` so the **five Process Files call
  sites** (`OCRProcessor+{OCR,Pipeline,Tagging,ReviewFlows}`) compile untouched — they still treat "didn't
  throw" as full success and will happily report a scan-less PDF as a clean result. **Deliberately NOT data
  loss, which is why this is LOW and not a re-open:** unlike Live Capture, that path never trashes the source
  image (checked by symbol — no `trashItem`/`removeItem` on a source URL in the OCR pipeline; source cleanup
  goes through `OutputFileSafety`'s verified-move transaction, which relocates rather than destroys). So the
  gap is **operator visibility**, not recoverability. **Do this inside W23.m5**, which already rewrites those
  exact call sites for the `tagsApplied` warning — surface "image not embedded" through the same per-artifact
  warning channel rather than adding a second one. Cheap there, wasteful as its own pass.
  | files: ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/OCRProcessor+{OCR,Pipeline,Tagging,ReviewFlows}.swift | XS–S | low | W23.h5


## Provider expansion — Wave 13 (Processor; daemon-buildable) — queued 2026-07-16

- [x] **W13.oai-1 — native provider wiring.** Append `case openai` to `LLMProvider` (append-only), add
  `LLMModel.openaiModels` + the model-family param adapter (`max_completion_tokens`/no-`temperature`/
  `reasoning_effort`), route `.openai` through the reused `OpenAICompatibleClient` at the ~6–8 switch sites.
  ⚠️ Model IDs + pricing = clearly-marked `// VERIFY` placeholders (a wrong price is a silent estimator bug →
  Morning Review). | files: Models/ProviderModels.swift, OCR/OCRProcessor+OCR.swift, OCR/LLMTextClient.swift,
  OCR/LLMRotationDetector.swift, Models/KeychainHelper.swift | M | low | none
  — ✅ shipped: `.openai = "OpenAI"` appended; `openaiModels` (all IDs/pricing `// VERIFY`); param adapter
  (`OpenAICompatibleClient.openAI(model:apiKey:)` → `max_completion_tokens` for reasoning models, gateway path
  byte-identical); `.openai` arms added to all **12** exhaustive `LLMProvider` switches (OCR/classify/text route
  via the factory; batch/cancel/rotation defensive-`nil` since `supportsBatch=false`; CostEstimator image-tokens
  placeholder + rotation `nil`). Additive + opt-in — default provider unchanged. KeychainHelper needed no change
  (account = `provider.rawValue`). Build clean, 0 new warnings. **Live OCR + model-ID/pricing verification =
  keyed/owner tail → Morning Review** (Processor has no unit target; smoke needs a live key). ProviderKeySpec /
  onboarding / validation / CostEstimator rows = W13.oai-2; gateway preset + docs = W13.oai-3.
- [x] **W13.oai-2 — onboarding + validation + cost.** `ProviderKeySpec.openai` (+ `onboardable`),
  `KeyValidator.validateOpenAI` (`GET /v1/models`), `ThinkingLevel → reasoning_effort`, `CostEstimator` rows
  (placeholder-priced per above). | files: Models/ProviderKeySpec.swift, OCR/KeyValidator.swift, Models/CostEstimator.swift | S | low | none
  — ✅ shipped: `ProviderKeySpec.openai` added to `onboardable` (guided wizard now offers OpenAI: platform.openai.com
  deep links, `sk-` precheck, no-free-tier cost/card notes, API-not-trained privacy note; URLs/wording `// VERIFY`
  → keyed tail). `KeyValidator.validateOpenAI` (cheap `GET /v1/models` Bearer → 200 works / 401·403 invalidKey /
  429 rateLimited / 5xx providerBusy; mirrors `validateMistral`; documents that /v1/models 200s even with no
  credits → live smoke surfaces insufficient-quota). `ThinkingLevel.openAIReasoningEffort` (low/high) wired through
  the `openAI(model:apiKey:thinkingLevel:)` factory, **gated on `supportsThinking`** so `reasoning_effort` is sent
  only to reasoning models; threaded at the OCR + tagging-text call sites (classification stays reasoning-free).
  Settings gained an **OpenAI manual key field** (generic `keyField` helper, Save/Validated chips) + guided-button/
  help wording; `ContentView.hasAnyKey` counts an OpenAI key. `CostEstimator` `.openai` arms already landed in
  oai-1. Additive + opt-in — default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **GUI visual (Settings OpenAI row + wizard) + live OCR smoke = keyed/owner tail → Morning Review** (GUI blocked
  this run by the Keychain "Always Allow" seed still being unset under the stable dev cert).
- [x] **W13.oai-3 — gateway "OpenAI" preset + docs.** One-click preset prefilling base URL/model/cost (note:
  custom base URL covers Azure OpenAI / proxies); update CLAUDE.md provider list + README. | files: Views/SettingsView.swift, docs | S | low | none
  — ✅ shipped (code `d866924`; docs/tracker this commit): a **"Fill in OpenAI preset"** button in the
  API-Gateway settings section (`Views/SettingsView.swift` → new `applyOpenAIGatewayPreset()`) prefills the
  public OpenAI endpoint (`https://api.openai.com/v1`), the default model, a display name, and the `.openai`
  cost profile — reading the model ID + pricing from the single source of truth `LLMModel.openaiModels`
  (now the verified GPT-5 gen from `3be8c3d`), so a later pricing/ID edit flows through automatically. It fills
  the cheapest **non-reasoning** model (`gpt-5.4-mini`): the gateway path sends plain `max_tokens`, which OpenAI
  reasoning models reject — the param adapter lives only on the native `.openai` path — so reasoning models go
  via Direct API. A
  HelpButton notes a custom base URL covers **Azure OpenAI / OpenAI-compatible proxies** and that the key goes
  in the Gateway key field. Docs in this commit: Processor **CLAUDE.md** (OpenAI added to the built-in
  provider/model list + the preset note), **README** (4th provider row + table + preset + batch/key-field
  accuracy), **POTENTIAL_FEATURES** (retired the first-class-OpenAI wishlist item). **Plan
  `execution-plans/openai-chatgpt-provider.md` DELETED** — all daemon-buildable OpenAI sub-tasks (W13.oai-1/2/3)
  shipped. Additive + opt-in; default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **Keyed/owner tail → Morning Review:** the live-key 2-image OCR smoke through gateway + native `.openai`
  (final model-ID confirmation) + OpenAI Batch API (Phase 4); GUI visual (preset button + field fill) deferred
  (GUI off this run).
- [x] **W13.cli-1 — client + config + additive threading.** `472f850` (config) + `9778572` (client) + `02471bb`
  (threading) + `44730bc` (tests) — `Models/LocalAgentConfig.swift` (Codable/Sendable, append-only
  `LocalAgentTool` claude/gemini/codex, no key) + `OCR/LocalAgentClient.swift` (ocr + textCompletion via
  `Process`: no shell, prompt on stdin not argv, absolute-path binary not `$PATH`, temp-JPEG-by-path,
  concurrent-drain + SIGTERM→SIGKILL timeout, friendly errors never raw stderr; `claude` validated, gemini/codex
  `// VERIFY`) + `localAgent: LocalAgentConfig?` (default nil) threaded into `PendingRun` + `SessionProcessingConfig`
  beside gateway. Tests: committed fake-CLI stub + `localagent-mechanism-test.swift` (standalone $0, **14/14 PASS
  this session** — subprocess plumbing + resume-safety Codable semantics) + in-app `LocalAgentTestDriver` (real
  client + real PendingRun round-trip; RUN via `test-localagent.sh` **deferred → Morning Review**, GUI-off). Tier-2
  gate met unattended (adversarial review + headless functional proof + build clean, 0 warnings). | M | med | none
- [x] **W13.cli-2 — validator + Settings.** `a2be2c7` (checkpoint 1/2: validator+probe) + this commit
  (checkpoint 2/2: Settings). `OCR/LocalAgentValidator.swift` — CLI analog of `KeyValidator`: `detectAndVerify`
  does resolve-binary → `--version` liveness → 1-token round-trip and maps to a plain-English `Status`
  (`cliNotFound`/`cliNotLoggedIn`/`cliEntitlementMissing` + reused `rateLimited`/`offline`/`providerBusy`);
  pure `classify` code→Status. `LocalAgentClient` gained public `probe()`+`ProbeOutcome` (prompt-only round-trip,
  no image ⇒ zero corpus surface) + `cli_entitlement_missing` in the shared error taxonomy (never raw stderr;
  preserves the `fail`→`cli_exit_3`/`notlogged`→`cli_not_logged_in` invariants). Settings: a 3-way **OCR backend**
  picker (Direct API / API Gateway / **Local CLI Agent**) over a `backendMode` binding that centralizes the
  `useLocalAgent` XOR `useGateway` invariant; tool picker + path/model fields + a **Detect & Verify** button
  (wired to the validator) + `?` help; additive `DefaultsKeys`. Additive + opt-in; default backend unchanged.
  **Tier-2** gate met unattended: build clean 0 new warnings + `$0`/no-key/no-GUI `scripts/localagent-validator-test.swift`
  (**27/27 PASS** — exhausts the code taxonomy incl. entitlement + drives the real fake CLI e2e) + adversarial
  self-review. **Interim state (until W13.cli-4 wires the pipeline):** selecting Local Agent mode *persists* the
  config but the pipeline still routes Direct/Gateway (config inert, same as cli-1's threaded-but-unconsumed
  carrier). Live Detect+Verify round-trip + visual gray-out + the cost-pane "subscription" branch (cli-3) →
  GUI/Morning Review. | M | low | none
- [x] **W13.cli-3 — wizard + cost pane + pacing.** `03e65ec` (pacing) + `971c9fd` (wizard) + `584eb32`
  (cost pane). **PACING:** `LocalAgentClient` wraps `invoke()` in a dedicated `RequestLimiter(limit: 2)` (the
  subprocess path bypasses `NetworkSession`'s HTTP limiter) + `parseUsageWindowReset()` reads a reset instant
  out of a CLI rate-limit message (relative / bare-Retry-After / absolute "resets 3pm", with a
  window-size-vs-wait guard + next-occurrence rollover) into `lastUsageWindowResetAt`; the finer per-run 1–2
  cap + OCR-loop honoring land in cli-4. **WIZARD:** `LocalAgentSpec` (claude + gemini; Codex stays on the
  Settings tool picker) + `LocalAgentWizard` (mirrors `ProviderKeyWizard`) wired into Settings via a "Set up
  (guided)…" button + sheet. **COST:** "Included in your subscription — usage limits apply" branch in the
  SettingsView pinned pane + the OCRView Files-tab card (display-only — Local Agent isn't an `LLMProvider`, no
  `CostEstimator` math change). **Tier-2 gate met unattended:** build clean 0 new warnings +
  `scripts/localagent-pacing-test.swift` **18/18 PASS** ($0/no-key/no-GUI: parser table incl.
  guards/rollover/nil + the `RequestLimiter(2)` ceiling holds & every acquire is released) + adversarial
  self-review. **Keyed/GUI tail → Morning Review:** live wizard Detect+Verify + cost-pane/wizard visual (a
  GUI launch this session hit the blocking Keychain modal — owner "Always Allow" seed still needed) +
  install-link/wording verify. | S | low | none
- [x] **W13.cli-4 — pipeline wiring.** `4ee2475` (ckpt1: seams) + `23166b9` (ckpt2: thread+populate) + this
  doc-sync commit. `LocalAgentConfig.fromDefaults` + `currentLocalAgent` mirror; client-construction seams
  (`LLMTextClient.complete`, `performOCRCall`, `classifyViaLLM`) prefer `localAgent` (localAgent > gateway >
  direct); threaded the companion `localAgent:` beside every `gatewayConfig` (TagGenerator, CollectionSegmenter,
  the OCRProcessor OCR/Tagging/Pipeline/ReviewFlows sites, multi-page re-OCR, LiveCaptureProcessor, OCRView,
  ToolsView, `SessionProcessingConfig.fromDefaults`). **Batch + LLM-rotation skipped when active** (OCRView forces
  batchMode=false + defensive dispatch/history guards; `detectRotation` → local Vision). **Resume-safe:** the
  production `PendingRun` persists `localAgent` and both fresh-run + resume paths restore `currentLocalAgent`
  (self-review caught both were missing). `test-smoke.sh` gains a `[3.5]` **fake-CLI** section (runs the $0
  standalone tests + real-CLI probe with graceful skip). Build clean, 0 new warnings; Tier-2 gate met unattended
  (adversarial self-review + `localagent-wiring-test.swift` 18/18 + `localagent-mechanism-test.swift` 14/14).
  Plan `execution-plans/local-agent-cli-provider.md` DELETED (shipped). **Keyed/owner tail → below.** | M | med | none


## Known-issues work — Wave 14 (cross-app; owner-requested 2026-07-16)

- [x] **W14.1 — Android/iOS straggler: never finalize a partial segment [HIGH]** _(Processor KNOWN_ISSUES →
  "Per-capture streaming — residual refinements" #1; focus path: Android + LAN)._ The data-loss guard already
  ships (a straggler is never deleted), but a page still un-UPLOADED when `segment/complete` arrives is **not
  auto-filed** — it lingers unfiled in the Captured pane. **Fix (both companions, kept in sync):** the phone
  **defers `sendSegmentComplete`** (and `finishSession`'s `/session/complete`) until **every page of the segment
  is confirmed `UPLOADED`** — record a pending-complete group, flush it when its last page hits `UPLOADED` from
  BOTH the upload-success path and the auto-retry path. So the Mac never finalizes a partial segment. **Tier-2**
  (Capture/Net, phone↔Mac protocol — no wire-format change: this is send-*timing*, not a new field). Daemon-buildable:
  Android `./gradlew :app:assembleDebug` + iOS `xcodebuild` build-clean + adversarial self-review of the
  defer/flush logic on both companions. **Keyed/owner verify tail:** the on-device / emulator E2E
  (`scripts/e2e-phone-mac.sh`, needs a Gemini key + the `ap_test36` emulator; XCUITest admin-prompt caveat) →
  Morning Review. | files: ArchiveCapture/capture/CaptureViewModel.kt, ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift | M | med | none(build)/owner(E2E)
  **✅ ALREADY SHIPPED `ce55511` (2026-07-07); verified + tracker-reconciled 2026-07-17.** The defer/flush fix
  was already in code on BOTH companions: `endedSegments` is the pending-complete record; `trySendSegmentComplete`
  gates on ALL pages `UPLOADED` (Android `CaptureViewModel.kt:527` / iOS `:369`) and is the ONLY caller of the
  transport `segmentComplete(...)` — flushed from the upload-success path (Android `:622` / iOS `:456`), the
  auto-retry loop (Android `:229` / iOS `:524`), and reconnect (`:209`/`:508`). The `session/complete` this item
  also named is **dead code** on the phone (the transport `sessionComplete()` has no caller — the phone "Finish"
  button that once sent it was removed; "Finish session" is a Mac-side backstop). Adversarial refutation (independent
  read of both companion trees) could not break the gate on either side. KNOWN_ISSUES #1 marked FIXED-in-code to
  match #2/#3/#4. **Keyed/owner tail unchanged:** on-device/emulator E2E (`scripts/e2e-phone-mac.sh`) → Morning Review.
- [x] **W14.2 — Reader write-target identity re-verification (Safety §6) [MED]** — shipped `838b456` (primitive)
  + `d393ff3` (Reader adapter). Added opaque `FileIdentity` (backed by `fileResourceIdentifier`, compared via
  `isEqual:` — **never** `.documentIdentifierKey`, which mutates on read) + an opt-in `expectedIdentity:` param on
  `CoordinatedTagWriter.write` that **re-verifies the resolved URL's identity inside the `NSFileCoordinator` block
  before any write and aborts with `.identityMismatch`** on a moved/replaced file; threaded `expecting:` through the
  Reader `TagWriter.apply`/`setReadState` adapter (default nil = behavior-preserving). Tier-2 gate met unattended:
  build clean, 0 new warnings; +8 scratch-copy tests (4 primitive + 4 adapter; the deterministic safety case =
  a *different* file at the same path → abort + replacement untouched) — ArchiveCore 100 green (stable ×3),
  ArchiveReaderTests 23 green. **Follow-up (armed below):** wire capture-at-selection at live call sites so the
  mechanism is armed in production — see "W14.2-fu". | M | med | none
- [x] **W14.2-fu — Arm §6 identity check at live Reader call sites [MED, follow-on to W14.2]** — shipped
  `1a7c6cb` (checkpoint: `ArchiveFile.liveIdentity()` on-demand capture + the identity-carrying
  `TagWriter.apply(_:to:[(url,identity)])` batch overload + a scratch-copy test) + this commit (arming +
  docs). All **6** `NavigationModel` `TagWriter.apply`/`setReadState` call sites — `mark`, group edit
  (⌘I), inline edit/read-state, corpus-wide rename (via the batch overload), and **undo** — now capture
  the file's `FileIdentity` **lazily at edit time** (via `liveIdentity()`, never at bulk discovery, so the
  `ArchiveFile` "no per-file I/O" fast path is untouched) and pass it through `expecting:`. Undo re-verifies
  against the identity captured at the ORIGINAL edit (undo stack now carries per-write identity), so a file
  swapped under its path between edit and undo is skipped, not mis-tagged. **Tier-2 gate met unattended:**
  build clean, 0 new warnings; behavior-preserving threading (identical accounting) + the §6 write-path is
  fully unit-tested on scratch copies (existing 3 §6 adapter tests + the new batch test) + adversarial
  self-review; ArchiveReaderTests 199/200 (the 1 failure is the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot`
  env flake, unrelated). No visible UI effect (invisible safety guard, only fires on a file swap), so no
  GUI drive; an optional live regression smoke on a scratch corpus → Morning Review. | files: ArchiveReader
  Views/NavigationModel.swift, Core/ArchiveFile.swift, Core/TagWriter.swift | done
- [x] **W14.3 — Notes: extract-paste imports inline-image BYTES [MED]** _(Notes KNOWN_ISSUES → "Extracts
  create/copy-paste follow-ups")._ The copy side embeds image bytes and Create/Append persist them, but the live
  extract-editor **paste** handler still inserts image *references* without importing the payload's bytes into the
  extract's own `assets/` (and rewriting refs on name collision) — so a live copy→paste renders missing-asset
  placeholders until re-saved via Create/Append. **Fix:** in `MarkdownEditorView.handlePassagePaste` →
  `ExtractBuilder.pastedExtractMarkdown`, import the `com.archivenotes.passage` payload bytes into the extract's
  `assets/` (reuse `ItemAssetStore` reserve→write; no-overwrite guard) and rewrite refs on collision. Store +
  payload bytes both already exist. **Tier-1/2** (writes to the Notes store — scratch-testable). Daemon-buildable +
  unit-testable (`ExtractBuilder`/`ItemAssetStore` tests); GUI copy→paste drive → Morning Review. | files:
  ArchiveNotes/.../Editor/MarkdownEditorView.swift, Core/ExtractBuilder.swift | done — new
  `pastedExtractMarkdown(from:importingAssetsVia:)` overload imports each segment's bytes into the extract's own
  `assets/` via `ItemAssetStore.addAsset` (reserve→write, no-overwrite guard) + rewrites `](assets/…)` refs on
  collision; `handlePassagePaste` wires it in. +3 scratch Tier-2 tests (byte-on-disk, no-clobber disambiguation,
  nil-import resilience); full ArchiveNotesTests green (189 XCTest + 513 swift-testing). Also unbroke the Notes
  test bundle (`67f8938`: W14.2's new `TagWriteError.identityMismatch`). GUI copy→paste drive → Morning Review.
- [x] **W14.4 — Notes W7 polish cluster [LOW]** ✅ COMPLETE 2026-07-17 (`592049a` a + `7ef833d` d + `d615589` c +
  this commit b/docs) _(Notes KNOWN_ISSUES → W7-S2/S3/S4 follow-ups, all four addressed)._ (a) dropped the
  always-succeeds `[NSValue]` cast in `EditorPassageSource` (warning gone); (b) `NoteEditorPane.handleOpen` now
  fronts+focuses the featuring window (`openWindow(id:)` + `NSApp.activate`) on jump-to-source, and
  `NotesModel.create/appendToExtract` route the new/updated extract through `openItem` so the Extracts window
  selects (and raises) it; (c) new `NotesModel.itemsGeneration` (bumped in `replaceItems`) drives a reactive
  chip re-style in `MarkdownEditorView` on any item-set change — gated to chip-bearing docs, scroll preserved;
  (d) per-window `NotesAppSettings.windowHiddenColumns(for:)` (Note window hides the always-blank Sources
  column, Extracts shows it), wired through `NotesTableView`/`ColumnPickerHeaderView`. +7 unit tests; full Notes
  unit suite 709 green (520 swift-testing + 189 XCTest), build clean 0 new warnings. **Tier-1.** **Live GUI drive
  → Morning Review:** window raise/focus (b), cross-window chip recolor (c), two-window column visibility (d).
- [x] **W14.5 — Processor legacy staging-manifest rotation review [LOW, do last]** ✅ COMPLETE 2026-07-17
  (Processor KNOWN_ISSUES #1). Fix option 1 shipped: `loadStagingManifest()` now migrates a legacy manifest
  (bare `[StagedSegment]`, no `retained`) via new `migrateLegacyManifestSegments(_:sourcesPresent:)` — it
  DROPS each legacy segment whose source photos all still exist (deleting its stale staged output) so the
  existing resume path re-processes it from scratch (re-OCR + re-tag → proper `retained` → a COMPLETE rotation
  review), then rewrites the manifest in current format (idempotent). **Data safety (Recovery Core Directive):**
  a legacy segment whose source is gone is KEPT as-is (today's behavior) — we never delete regenerable output we
  can no longer rebuild; raw sources always stay in the backup folder. Tier-2 met unattended: build clean, 0 new
  warnings; +5 scratch checks in `LiveCaptureRecoveryTestDriver` (drop-reprocessable / keep-unreprocessable /
  delete-stale-output / preserve-unrecoverable) → **ALL PASS ($0, no OCR)** + adversarial self-review (confirmed
  `session.groups` is computed from `session.photos`, so dropped segments' pages are guaranteed present to
  re-OCR). **Full E2E verify (legacy manifest + OCR key to actually reprocess) → keyed/owner → Morning Review.**
  | files: Capture/LiveCaptureProcessor.swift, Capture/LiveCaptureRecoveryTestDriver.swift | S | low | owner(verify)


## Known-issues work — Wave 15 (shared tag writer; owner-reviewed 2026-07-18)

- [x] **W15.tu0 — pin the macOS duplicate-tag fact in SPEC + a test [S].** DONE 2026-07-29 — added
  `ArchiveCoreTests/DuplicateTagPremiseTests` (hard-asserts `["A","A","B"]` survives a raw
  `setResourceValue(.tagNamesKey)` write→read round-trip on a scratch temp file — the test RAN, not skipped)
  and recorded the fact in `SPEC/tag-format.md` §"Finder tag model" beside the multiset-comparison rule
  (duplicate tag strings persist verbatim; a `Set`-collapse would drop a duplicate on undo — the premise all
  of Wave 15 rests on). Pure test + doc, **no behavior change, no ArchiveCore Sources/API touched** → app
  bundles unaffected (shared-Core rebuild rule's type-change trigger not met), so ArchiveCore `swift test` is
  the correct-and-sufficient gate: premise test 1/1 green + full suite exit 0, **0 warnings**. Tier-2 APPROVE
  (adversarial self-review + scratch functional test; never the corpus).
  | files: packages/ArchiveCore/Tests/ArchiveCoreTests/DuplicateTagPremiseTests.swift, SPEC/tag-format.md | S | low | none
- [x] **W15.tu1 — occurrence-aware undo inverse in ArchiveCore [M].** DONE 2026-07-28 (recovered from a
  preserved dead-session WIP — `old/w15tu1-divergent-wip-20260728/attemptA` — and independently re-verified).
  New `TagOccurrenceDelta` (multiset peer to `TagDelta`) + `TagWriteResult.occurrenceInverse`, computed via
  `tagOccurrenceInverse` / `multisetDifference` (no `Set` collapse), so an inverse carries per-token
  multiplicity (`["A","A"]`→`[]` undoes to `["A","A"]`, not `["A"]`). Purely ADDITIVE — `inverse: TagDelta`
  and all consumers untouched (new init param defaulted); occurrence-only (count, not order). Verified HERE
  (not the WIP's self-claim): ArchiveCore `swift test` 100/100 green incl. 6 new W15.tu1 tests (the
  end-to-end duplicate test RAN, not skipped — macOS persisted the dup); all three app test bundles
  `build-for-testing` SUCCEEDED; 0 new warnings. NOTE: W15.tu0 (SPEC doc + premise test) landed separately
  (DONE 2026-07-29); the undo/restore consumers are rewired in W15.tu2.
  | files: packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift | M | med | none
- [x] **W15.tu2 — multiplicity-aware apply/restore + wire Reader undo** (blocked-on: W15.tu1) **[M].** DONE
  2026-07-28. Added `TagWriter.applyOccurrence(_:to:expecting:)` — a **bounded reconcile step**: an
  occurrence-precise multiset diff against the FRESH read inside `CoordinatedTagWriter`'s coordination block
  (§2/§3), stripping EXACTLY the delta's occurrence count of each removed token and APPENDING the listed
  copies of each added token, so it re-introduces a duplicate the set-based `apply` (add-when-absent,
  `TagWriter.swift:52`) refuses to. Wired `NavigationModel.undoLast` to `result.occurrenceInverse` +
  `applyOccurrence` (was the set-based `result.inverse`, the sole production consumer). **Safety §9
  preserved** — only named tokens are touched, each by ≤ its listed multiplicity, so an unrelated concurrent
  edit (and any extra copy a concurrent edit added of a named token) survives; undo stays in-memory (no
  persisted ledger). Behavior-identical for the common non-duplicate case; §6 identity re-verify unchanged.
  Tier-2 APPROVE (adversarial self-review, 11 vectors). Verified: Reader `ArchiveReaderTests` 210/211 green
  incl. 5 new occurrence tests (`["A","A","B"]` round-trips; §9 concurrent-survive; exact-count strip; color
  restore) — the 1 failure is the pre-existing `DeepLinkTests.testRevealAndSelectNoRoot` env flake (W20),
  unrelated; Notes test bundle + Processor app build green; 0 new warnings. (Umbrella KNOWN_ISSUE stays open
  for tu3/tu4.)
  | files: ArchiveReader/macOS/Sources/ArchiveReader/Core/TagWriter.swift, Views/NavigationModel.swift | M | med | none
- [x] **W15.tu3 — per-path write serialization → closes the Notes lost-update race** (blocked-on: W15.tu1)
  **[M].** DONE 2026-07-28 (mechanism `f52756d`; doc-sync this commit). Added an in-process,
  per-resolved-path serialization lock INSIDE `ArchiveCore.CoordinatedTagWriter` (Safety §10): a refcounted
  registry of per-path `NSLock`s (`PathWriteSerializer`) wraps the ENTIRE read→modify→verify→write, so two
  concurrent in-process writers to the same file can no longer both read pre-write state and clobber each
  other (the lost update). Distinct paths never contend (unrelated writes stay parallel); an entry is
  discarded once its last holder releases (bounded map). Synchronous `NSLock`, not an actor — keeps `write`
  synchronous so all three callers (Reader `TagWriter`, Processor `MacOSTagger`, Notes `NotesTagProjector`)
  are unchanged; public API is byte-identical (additive). **Cross-PROCESS writers explicitly out of scope**
  (documented in code, not implied). Tier-2 APPROVE (adversarial self-review: deadlock/lock-ordering,
  refcount handoff, balanced acquire/release via `defer`, unchanged single-writer semantics). Functional
  test (ArchiveCore, scratch temp files only): two concurrent same-path writers each appending a distinct
  tag BOTH survive — PROVEN non-vacuous (fails deterministically, racing tag lost, when the §10 lock is
  removed); plus a different-paths fan-out. Verified all three per the shared-Core rule: ArchiveCore 101
  tests green (incl. 2 new §10); Reader `ArchiveReaderTests` 210/211 (the 1 = pre-existing
  `DeepLinkTests.testRevealAndSelectNoRoot` env flake, W20, unrelated); Notes `ArchiveNotesTests` 189/189;
  Processor app BUILD SUCCEEDED; 0 new warnings. Notes KNOWN_ISSUES race marked FIXED (mechanism); the
  cross-app fixture matrix + Notes `concurrentProjectionsNeverCorrupt` assertion flip land in W15.tu4.
  | files: packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift, ArchiveNotes/macOS/Sources/ArchiveNotes/Core/NotesTagProjector.swift | M | med | none
- [x] **W15.tu4 — cross-app duplicate + concurrency fixtures** (blocked-on: W15.tu2, W15.tu3) **[M].** DONE
  2026-07-28. Cross-app regression matrix pinning the W15 duplicate-survival + no-lost-update fixes at each
  real caller, honoring each adapter's shape: **(a)/(b)** the dup→remove→undo→multiset-survives and
  concurrent-unrelated-tag-survives cases were already pinned at the Reader `TagWriter` boundary by W15.tu2
  (`testOccurrenceInverseRestoresDuplicateTag`, `testOccurrenceUndoPreservesConcurrentUnrelatedTag`) and at
  the ArchiveCore primitive by W15.tu1; this wave ADDED the fresh-write analog for the Processor `MacOSTagger`
  adapter (which has no undo path) — a *duplicated subject survives a fresh write as a multiset*
  (`MacOSTaggerParityTests.testDuplicateSubjectSurvivesFreshWrite`). **(c)** two parallel same-path writes:
  ADDED a Reader `TagWriter` concurrent fixture (both added tags survive — the delta adapter inherits §10,
  `testConcurrentAdapterWritesBothSurvive`), a MacOSTagger concurrency parity fixture (fresh-write adapter:
  neither writer throws `.verificationFailed` and the final array is one complete write — "both survive"
  doesn't apply to an overwrite, `testConcurrentFreshWritesNeitherThrowsAndFinalIsWhole`), and **flipped**
  `NotesTagProjectorSafetyTests.concurrentProjectionsNeverCorrupt` to require **both racing subjects survive**
  (not just the marker) now that W15.tu3's §10 lock closed the lost update. Case (a) is N/A for the Notes
  projector (set-based, dedups, no undo — duplicates are unreachable through it by design). KNOWN_ISSUES
  reconciled (the race is now FIXED + regression-pinned). Gate MET: ArchiveCore `swift test` 103 XCTest + 100
  swift-testing green; Reader `ArchiveReaderTests` 212 (only the pre-existing `DeepLinkTests` env flake, W20,
  unrelated); Notes `ArchiveNotesTests` green; Processor app BUILD SUCCEEDED. Test/doc-only — no production
  change. Two Tier-2 checkpoints (`19228ee` ArchiveCore, `005fa96` Reader) pushed before this completing commit.
  | files: packages/ArchiveCore/Tests/, ArchiveReader/Tests/, ArchiveNotes/macOS/Tests/ | M | med | none


## Known-issues work — Wave 16 (Processor: LAN credential · run config · paid-batch; owner-reviewed 2026-07-18)

- [x] **W16.bat11 — `retryHighUseFailures` read `jobs[index]` across its OCR call with no guard at all
  [S · MED].** DONE 2026-08-03 — `7bdf854` (the guard, later withdrawn) + `24c6fad` (the driven regression) +
  `b138615` (the adversarial pass's rework: the read DELETED) + this commit. Filed 2026-08-03 from the
  `W16.bat10` adversarial pass; **pre-existing** (bat10 changed only the loop's iteration variable there).
  `OCR/OCRProcessor+OCR.swift:1612` subscripted the live array after `await Self.performOCRCall(...)` with
  neither a bounds check nor an identity check, and with no `Task.isCancelled` between the suspension and the
  read: Stop during a busy retry → **Clear** (`jobs = []`) → the in-flight call returns with text →
  **SIGTRAP**. Re-dropped instead of cleared it was quiet rather than fatal — the LIVE run's failure entry was
  pruned under a stopped row's filename, so that run's own "N failed" summary and `.txt` log under-counted.
  Reachable from all three pipeline call sites (`+Pipeline.swift:1275`, `:1619`, `:2543`).
  **Shipped as a DELETION, not the two-clause guard this item prescribed — that is the item's one real
  finding.** The guard shipped first (`7bdf854`) and the Tier-2 adversarial pass refuted it: the prune was
  redundant. `handleOCRResult` prunes the same filename, off the same `(index, jobID)` pair, under the same
  `result.text != nil` condition, behind the identity guard `W16.bat10` gave it — and nothing observes
  `failedFiles` between the two. So in every case both pruned the same name (honest) or both refused (stale),
  and the guard only bought a second copy of an invariant. The READ is gone instead: the prune has ONE owner,
  the loop reads `jobs` only where it is main-actor-synchronous, and the trap is fixed by the strongest
  available means — the subscript does not exist. Recorded at the site so it is not "restored". Measured, not
  argued: neutering `handleOCRResult`'s prune reds the retry's own honest-prune check and **nothing else in
  377**.
  New `RetryPruneIdentityContract` (driver section 24; test-batch-resume 371 → 377) drives the REAL loop
  through the `NetworkSession.testTransport` seam (`W16.bat7-fu`) — real retry selection, real 10-second
  sleep, real `GeminiClient`, real `handleOCRResult` — with the STUB mutating the file list from inside the
  request, i.e. exactly while the main actor is suspended in the OCR call. That is the seam the item predicted
  the driver would need, and it puts the call site under test rather than a helper. Costs two real 10-second
  waits (suite 12s → 32s). **Three mutants measured:** the unguarded read put back → **no report at all** (it
  TRAPS the driver, 0 of 377 checks written); the read put back with bounds only → **2 RED**, both of §2, the
  quiet case; `handleOCRResult`'s own prune neutered → **1 RED**, §1's honest prune.
  **Adversarial pass** (independent) refuted two things, both fixed here: the redundancy above, and the
  header's claim that §1 proved non-vacuity for the guard — it never did, because `handleOCRResult` pruned
  that name regardless. With the deletion the same check becomes attributable and reds if that prune ever goes
  away. It also confirmed the item's exclusion of the loop's two OTHER unguarded reads (`jobs[index].status =
  .processing` at `:1594`, `fileURLs[index]`) with a stronger reason than the item gave: `cancel()` cancels
  the `processingTask` all three call sites run on, **Clear** is `.disabled(processor.isProcessing)`, and a
  row that vanishes mid-call makes `handleOCRResult` return `false` so the loop exits before the next
  iteration's write. Only a path that TRUNCATES `jobs` while keeping the surviving rows' ids would reach them,
  and production has none — every mutation of `jobs` is a whole-array reassignment at a run's entry or the
  Clear button. **No residual filed.**
  Verified $0/headless: batch-resume 377 ALL PASS ×2 consecutive runs, plus tagwarn 74 / multipage-reocr 29 /
  merge-safety 15 / manifest-persistence 109 / recovery 89, all ALL PASS; clean build, no new warnings. The
  smoke test's paid OCR round-trip was NOT run (it spends real money on request shapes this change does not
  touch).
  | files: OCR/OCRProcessor+OCR.swift, OCR/RetryPruneIdentityContract.swift, Capture/BatchResumeTestDriver.swift | S | med | none

- [x] **W16.bat10 — a stopped run's in-flight result could still land on the NEXT run's jobs [S · LOW].**
  DONE 2026-08-03 — `b9a4ac1` (the fix) + `52608df` (the driven regression) + `b68ddb2` (mutants + the one
  that survived) + this commit. Filed from the `W16.bat9` adversarial pass; the residual that item
  deliberately did not widen into. **Pre-existing.**
  `handleOCRResult` bound its `jobs[index]` writes on `guard index >= 0 && index < jobs.count` — bounds, and
  nothing else. Every caller picks its index BEFORE a network round-trip, and the operator can spend that
  round-trip pressing Stop, then **Clear** (`jobs = []`), re-dropping files and pressing **Start**. The new
  run's jobs take the same indices, so the bounds check passed and a stale result overwrote a LIVE job's
  status and text with another file's — and, because the output name is derived from `jobs[index].sourceURL`,
  wrote a PDF named for the row it landed on holding the text of the file that was actually OCRed. bat9 had
  closed this for the completion sweep and for the writes AFTER the detached PDF write; this closes it for
  the writes before, and for the other six callers.
  **The token is the JOB's `id`, not the run's and not `url`.** `OCRJob.id` is a fresh UUID per instance, so
  a list cleared and re-dropped with the very same files at the very same indices still compares unequal — no
  assignment site has to remember to bump a generation counter, because the identity travels in the data.
  `jobs[index].sourceURL == url`, the guard the item warned about, is WRONG: `retryOne` legitimately passes a
  rotated temp JPEG. The parameter is REQUIRED rather than optional for the reason `rotationMode` is
  (W16.cfg6) — the compiler, not a code review, is what stops the next call site falling back to bounds-only.
  Refusing at the entry writes NOTHING and reports "not persisted", which is deletion-reducing on every path:
  no PDF exists yet at that point, so there is nothing for a resume to be told about (the distinction from
  the post-await bail-out bat9 rejected), and every reader of `false` treats it as an interruption and KEEPS
  the paid journal. Threading it surfaced two subscripts that had to NOT be added — both task groups' refill
  sites run after a `handleOCRResult` that may have suspended, so they take an immutable snapshot beside the
  `.processing` loop instead of re-reading `jobs`.
  New `StaleRunResultIdentityContract` (driver section 23; test-batch-resume 360 → 371) drives the real
  function with five fixtures, three of which exist to stop a wrong fix passing. **Five mutants measured:**
  bounds-only → 5 RED; `sourceURL == url` → 2 RED; a bare `return false` → 17 RED (fourteen of them in
  sections 20/21/22, which drive this function for real); refusing but returning `true` → 3 RED. The fifth —
  reverting the completion sweep's own slot check from the job id back to `sourceURL` — **SURVIVED all 370**,
  because every `BatchSweepClearedListContract` fixture re-drops a *different* file; new §5b re-drops the
  SAME ones and reddens it alone. There the writes are refused one frame down either way, so what the slot
  check decides is whether a batch that genuinely finished is reported interrupted and keeps its journal.
  Adversarial pass: all eight call sites verified to bind the identity at dispatch; no production path
  replaces `jobs` mid-run, so no honest write is refused; every post-await `jobs[index]` write stays behind
  `slotIsStillOurs`. It filed one residual — **W16.bat11**, an unguarded `jobs[index]` read in
  `retryHighUseFailures` that can still TRAP. Verified $0/headless: batch-resume 371 ALL PASS ×3 consecutive
  runs, plus tagwarn 74 / multipage-reocr 29 / merge-safety 15 / manifest-persistence 109 / recovery 89, all
  ALL PASS; clean build, no new warnings. The smoke test's paid OCR round-trip was NOT run (it spends real
  money to exercise request shapes this change does not touch); its $0 components ran green.
  | files: OCR/OCRProcessor+OCR.swift, OCR/OCRProcessor+Pipeline.swift, OCR/StaleRunResultIdentityContract.swift, OCR/BatchSweepClearedListContract.swift, Capture/BatchResumeTestDriver.swift | S | low | none

- [x] **W16.bat9 — the paid-batch completion sweep could TRAP (app crash) if the file list was cleared while
  it was mid-write [S · MED].** DONE 2026-08-03 — `5437355` (first shape) + `22a9a99` (the driven crash) +
  `5aa75b3` (the adversarial pass's rework) + this commit. Found by the `W16.bat7` adversarial pass;
  **pre-existing** (identical before that item's extraction).
  `sweepJobsWithNoBatchResult` looped `for i in jobs.indices where jobs[i].status == .processing`:
  `jobs.indices` is snapshotted ONCE while the `where` clause re-subscripts `jobs[i]` every iteration —
  across the `await` in `handleOCRResult`, which awaits a **detached** task and so keeps running after the
  parent is cancelled. `cancel()` sets `isProcessing = false` synchronously (its own comment: the run "goes
  on unwinding afterwards"), which un-disables the **Clear** button (`.disabled(processor.isProcessing)`,
  action `processor.jobs = []`). One click during that suspension and the next subscript was out of range:
  SIGTRAP on the money path.
  **Fixed at TWO sites, because it is one window seen from two frames.** The filed "smallest fix" — the
  sweep's `where` clause re-reading `jobs.indices` — is necessary but NOT sufficient, and this item's own
  trace is what found that: `handleOCRResult` re-subscripts `jobs[index]` three times *after* its detached
  PDF write, with only an entry bounds guard taken seconds earlier, so with the sweep alone fixed the
  identical crash still lands one frame down whenever the PDF write fails or copy-source tags are applied
  (measured — a mutant with only the loop fixed still traps, `ContiguousArrayBuffer:705`). Both sites check
  IDENTITY, not just bounds, and the sweep's loop re-validates each slot against **the list it started
  for**.
  **Two things the item's own Tier-2 adversarial pass changed about the fix** (`5aa75b3`), both money:
  1. The first shape bailed out of `handleOCRResult` with `false`. That also skipped
     `saveResultToPendingRun` — and on the non-batch path that record is the only thing stopping a resume
     from OCRing the file a SECOND time and paying again, for a file that was fully OCRed with its PDF
     already on disk. It dropped `outputURLMap[sourceURL]` too, orphaning that PDF from the tagging/merge
     phases and letting a resume allocate `base (2).pdf` beside it. Now exactly the three `jobs[index]`
     writes are guarded and everything durable still happens, so the return value is once again
     `saveResultToPendingRun`'s — no caller sees a `false` it would not have seen before.
  2. Bounds alone cannot tell **Stop → Clear → re-drop → Start** from the honest case: the new run's jobs
     take the same indices and are set `.processing`, which is exactly what the sweep looks for, so a stale
     sweep would mark a LIVE run's jobs failed and write "no result" outputs over them. The crash this item
     was filed for is the same defect with an empty array instead of a repopulated one.
  `OCRJob.sourceURL` is a `let` and `jobs` is only ever replaced wholesale (run start, Clear), so the
  identity test cannot fire on any legitimate mid-run mutation.
  **How it is measured.** New `BatchSweepClearedListContract` (driver section 21; `test-batch-resume`
  321 → 329 checks) drives the real sweep, the real `handleOCRResult`, the real persistence path and the real
  first-run tail across five fixtures — the list cleared with the output write failing, cleared with it
  succeeding, shrunk, refilled with a different file, and replaced by a live new run. No seam and no stub: a
  `Task { @MainActor in … }` enqueued before the sweep starts can only be reached at its first genuine
  suspension, the detached PDF write, which is exactly when a click on Clear lands. Every check ANDs in
  whether its mutation really landed *while the sweep was in flight*, so a fixture that failed to reproduce
  the race fails instead of passing the rest for the wrong reason; two fixtures make `PDFDocument.write(to:)`
  fail for real (a read-only output directory) because the trap they reproduce is in the branch past the
  write. §2 is the money statement: the resume snapshot still records a file whose row was cleared mid-write.
  **Non-vacuity, measured on four mutants — and two of them do not print FAIL, they TRAP the driver**, which
  is the honest shape of this bug: drop the loop's slot re-validation → traps (rc=133, "Index out of range",
  `ContiguousArrayBuffer:692`); drop the post-await slot guard → traps (rc=133, `…:705`); replace that guard
  with the first shape's early `return false` → **3 RED** (§2, §5, §6); reduce both checks to bounds only →
  **2 RED** (§4, §5). `test-processfiles-tagwarn.sh`, which drives `handleOCRResult` on the post-run retry
  path, is unchanged and green (74 checks).
  **Deliberately NOT done, both stated in the contract's header rather than left implicit:** the
  `Task.isCancelled` guard the filing offered to weigh (aborting the sweep changes what a cancelled paid
  batch records — jobs would stay `.processing` for good with no failure output — and the crash is fixed
  without it), and the pre-await `jobs[index]` writes `handleOCRResult` makes for its OTHER callers, which a
  stale run can still land on a new run's jobs → filed as **`W16.bat10`**.
  | files: OCR/OCRProcessor+OCR.swift, OCR/BatchSweepClearedListContract.swift, Capture/BatchResumeTestDriver.swift | S | med |

- [x] **W16.bat7 — four exits in `pollBatchUntilComplete` returned a "poll completed" flag they never set,
  and the caller then DELETED the paid batch's journal [S · MED · money].** DONE 2026-08-03 — `f417301`
  (the fix) + this commit (the extraction, the measured regression, and the docs). ✅ Owner-AUTHORIZED
  2026-08-02, **ALL FOUR EXITS** — the narrow one-exit variant was offered and declined, because leaving three
  exits safe-only-by-upstream is the coupling that broke in `W16.bat3-fu`. Grant discharged in
  `OWNER_AUTHORIZATIONS.md`.
  `pollBatchUntilComplete` assigns `batchPollInterrupted = false` on entry, and that one flag is what both
  callers read to decide whether the paid batch's recovery journal — a server-side job the operator has
  already paid for, and its only local record — is kept or DELETED. Four exits then returned without touching
  it, so a run unwinding from a step that could not WRITE reported "the poll finished cleanly": the first run
  retired the journal (`retirePaidBatchJournalIfPollCompleted`) and a resume ran `deletePendingBatch()` and
  carried on into tagging/finalize. All four now set it — the Anthropic and Mistral arms' `processBatchResults`
  guards, the `materialized` half of the Gemini arm's guard, and the completion sweep's `handleOCRResult`
  guard.
  **How it is measured.** The completion sweep was extracted into `sweepJobsWithNoBatchResult` — behaviour
  unchanged, for exactly the reason `retirePaidBatchJournalIfPollCompleted` was extracted in `W16.bat3`: the
  surrounding poll needs a real paid submission, so that exit could only be READ, never driven. New
  `BatchPollPersistFailureContract` (driver section 20; `test-batch-resume` 316 → 321 checks) then runs the
  real sweep, the real `handleOCRResult`, the real persistence path under it, and the real first-run tail —
  forcing a genuine `Data.write` failure by creating a DIRECTORY at the redirected `pending_run.json` path, so
  no stub and no new seam. The whole section is refused unless the harness's redirect is in force. Its last
  two checks are the money statement in the only unit that matters: after a sweep that could not persist, the
  real journal FILE is still on disk; after one that completed, it is retired.
  **Non-vacuity, measured on three mutants:** revert the four assignments (pre-fix code) → **2 redden**,
  including the journal file disappearing from disk; set the flag unconditionally → **2 redden** (the
  anti-"report everything as interrupted" pair); neuter the sweep to a bare `return true` → **4 redden**.
  Reverting only the three provider-arm assignments reddens nothing, which is the honest limit: those three
  sit on the far side of a provider call and reaching them costs a real paid batch, so their bodies — one
  statement, textually identical to the driven one — are structural. The contract's header says so; cite it
  for "the poll's persist-failure exit keeps the journal", not for "all four exits are covered by a test."
  ⬆️ **That limit is CLOSED as of `W16.bat7-fu` (2026-08-03, below):** all three provider-arm exits are now
  driven through a fail-closed transport seam, each with its own measured mutant, so the header — and this
  entry — no longer carry that caveat. Cite the contract for all four exits.
  **Two findings filed from the adversarial pass, neither a defect in this change:** `W16.bat8` (a stale
  in-memory run manifest makes a paid batch journal its results into the wrong file → duplicate charges on
  resume; **owner-gated, money**) and `W16.bat9` (the sweep's loop can trap if `jobs` is cleared mid-write).
  `W16.bat8` also **withdrew a claim this item shipped with**: the sweep's persist-failure exit was filed as
  reachable only in a state "which could not be constructed from the current call graph." It can be, and the
  contract's header now traces how — so the exit is live, not merely defensive.
  Clean Debug build, 0 new warnings; `scripts/test-batch-resume.sh` ALL PASS (321 checks, sections 1-20).

- [x] **W16.bat7-fu — the coverage gap `W16.bat7` shipped with is closed: the poll's THREE provider-arm
  persist-failure exits are DRIVEN, through a headless transport seam [M · MED].** DONE 2026-08-03 —
  `9ce8f51` (the seam + its refusal sweep) → `018ddfe` (the three arms + the measured mutants) → this commit
  (the header the fix makes false, and the trackers). No new grant needed: `W16.bat7`'s is discharged and this
  changes no production decision — it adds a test-only seam and nine checks.
  `W16.bat7` fixed all four exits but could only MEASURE one. The completion sweep runs after the loop; the
  other three (`processBatchResults` in the Anthropic and Mistral arms, and the `materialized` half of the
  Gemini arm's guard) sit below the `switch provider`, past a real provider status check, so reaching them
  cost either a paid batch or a seam.
  **The seam.** `NetworkSession.testTransport` — a `@Sendable (URLRequest) async throws -> (Data, URLResponse)`
  stand-in resolved at `data(for:policy:)`, the public entry point every batch client goes through (not
  `performWithRetry`'s existing private `transport:`). It diverts a request only when `BATCHRESUME_TEST` reads
  exactly `"1"` **and** a closure has been installed; the only assignment in the tree is inside
  `BatchPollPersistFailureContract`, which itself runs only under that flag. Same two-condition fail-closed
  shape, and the same reasoning, as the journal redirect in `OCRProcessor.pendingStateDirectory` — no
  `#if DEBUG`, no test-bundle sniffing. Production takes a BRANCH to the byte-identical call it always made,
  and the closure is tested before the flag so a shipped build does no `ProcessInfo.environment` work per
  request. Also `pollBatchUntilComplete(pollInterval:)`, a defaulted parameter (nil in production) so the
  exits can be driven without waiting out the 30s/60s schedule.
  **What is driven.** A real poll per provider through the real batch client, the real status/results parsers,
  the real `processBatchResults` → `handleOCRResult` → persistence chain, a real journal on disk, and the real
  `retirePaidBatchJournalIfPollCompleted()` tail — only the wire replaced, by literal provider bodies. The
  trigger is `handleOCRResult`'s bounds guard, a real array disagreement (`processBatchResults` admits an entry
  on `index < fileURLs.count`, then hands it to a guard measuring `jobs.count`). Both directions run the SAME
  fixture one job apart, so what separates "the journal is kept" from "the journal is retired" is only whether
  `jobs` was long enough for the result the provider returned for index 1.
  **Non-vacuity, measured on four mutants — one-to-one attribution:** dropping `batchPollInterrupted = true`
  from the Anthropic exit reddens exactly the Anthropic interrupted check, Mistral exactly Mistral's, the
  Gemini `materialized` half exactly Gemini's; and the counterweight (entry `= false` → `= true`, i.e. wedge
  every batch into "interrupted") reddens exactly the three HEALTHY checks. So neither direction can be
  satisfied by an implementation that always keeps, or never keeps. It is non-vacuous because the refusal lands
  at `handleOCRResult`'s ENTRY — before `saveResultToPendingRun`, so `persistPendingBatchMutation`'s own
  `reportInterruptedPaidBatch` (W16.bat3-fu) cannot set the flag upstream of the exit under test. Gemini's is
  the `materialized` half specifically: Swift short-circuits the comma, so a false `materialized` never
  evaluates `markBatchChunkConsumed`, which is the half that already reports itself.
  Each section also asserts the seam was dormant before it ran and dormant again after, and section 0 sweeps
  eleven approximate spellings of the flag (`nil`, `""`, `" "`, `"0"`, `"true"`, `"TRUE"`, `"yes"`, `"1 "`,
  `" 1"`, `"01"`, `"11"`) through the pure `testTransportIsEnabled(flag:)` before any stub exists. The seam's
  doc also records what it does NOT cover — `KeyValidator` and `Net/DriveClient` hold `URLSession.shared`
  directly; neither is on a path driven here.
  Tier-2 (Net/, money path): temp fixtures only, never a real endpoint, never the operator's
  `pending_batch.json` (every check past section 0 is refused unless the harness's state-root redirect is in
  force). Clean Debug build, 0 new warnings; `scripts/test-batch-resume.sh` ALL PASS — 331 → **340** checks.
  The killed session's WIP that this started from (stray worktree `suite-wt-20260802-122142-12795`) is
  superseded and removed.

- [x] **W16.bat3-fu2 — after a Stop, the submission-failure message tells the operator the opposite of what
  happened [S · MED].** DONE 2026-08-02 — `80dc4bd` (code + contract) and this commit (docs). Found by the
  W16.bat3-fu second read; **pre-existing**. `performBatchOCR`'s catch computed
  `activePendingBatch?.submittedChunkIds.count ?? 0`, but `cancel()` nils that journal and a Stop mid-submit
  is precisely how the catch is reached (the chunk callback throws as soon as `recordSubmittedBatchChunk`
  finds the journal closed) — so it read **0** with server jobs already created and journaled, told the
  operator *"No server ID was received; the recovery journal was kept"* without looking at the file, and
  overwrote the `pendingBatchJournalClosedMessage` W16.bat3-fu had just written. Every clause is now a
  measurement: `paidJobsCreatedThisSubmission` is appended by `recordSubmittedBatchChunk` where a created job
  is FIRST known (before the ID is validated or journaled — a job with an unusable name is still billed) and
  `cancel()` cannot reach it; `paidBatchJournalState()` reads the FILE so "kept" is only said about one that
  is there; jobs created but MISSING from the journal — the one shape Resume cannot reach — are named; and
  `reportInterruptedPaidBatch` retains its message in `lastPaidBatchInterruptionReport` so the cause leads
  the summary instead of being replaced by it. The catch body is extracted as
  `reportInterruptedBatchSubmission()` and the wording as the pure `interruptedSubmissionMessage(...)`, so
  the exit is drivable without a paid submission. **New `BatchSubmissionMessageContract` (driver section 19,
  17 checks, $0/no-network)**: the regression itself (post-Stop the old expression reads 0 while the tally
  reads 1), an unusable ID still counted, no double-counting, the cause retained, the six message shapes, a
  swept invariant that "the recovery journal was kept" is never said when the file is absent and that the
  number read is never the journal's, and the whole exit driven against a real (redirected) journal in both
  directions — kept, and genuinely gone. `test-batch-resume.sh` → **ALL PASS**; clean Debug build, no new
  warnings. Docs moved with it: `README.md`'s uncertain-outcome section quotes the new wording and explains
  which follow-on clause means Resume is enough, and the `KNOWN_ISSUES.md` lost-create entry records that its
  *"stopped after N server jobs"* sibling is no longer unconditionally benign. ⚠️ Scope, honestly: the
  four-line `catch` itself is still undriven (reaching it needs a real paid submission) — what it now
  contains is one call to the method section 19 drives end to end. Two siblings deliberately NOT touched:
  the `batchId`-mismatch guard below the catch cannot be reached with a nil journal (no suspension point
  between it and `markBatchSubmissionComplete()`), and W16.bat7's four poll exits are a different trigger.
  | files: OCR/OCRProcessor+OCR.swift, OCR/OCRProcessor+Pipeline.swift, OCR/OCRProcessor.swift,
  OCR/BatchSubmissionMessageContract.swift, Capture/BatchResumeTestDriver.swift, ArchiveProcessor/README.md,
  ArchiveProcessor/KNOWN_ISSUES.md | S | med | none

- [x] **W16.lan1 — write the LAN threat-model + accepted-risk doc [S].** DONE 2026-07-28 (this commit). Docs
  only, no code. Added a durable **LAN transport security — accepted risk** bullet to `ArchiveProcessor/CLAUDE.md`
  §"Primary Function 3: Live Capture": records the plaintext-HTTP + persistent-token exposure, the
  client-isolation correlation (venues that block LAN entirely are why USB/Drive exist → LAN runs precisely on
  the sniffable open/shared-PSK networks, so the low risk is *real*), the owner's accepted-risk rationale (public
  records → confidentiality ≈ worthless; integrity bounded by the Recovery Core Directive; needs a co-located
  adversary; do NOT re-promote LANSEC-5/6/7), operator guidance (USB bridge / Drive relay on untrusted venue
  Wi-Fi), a forward-ref to the W16.lan2 credential fix, and the corrected stale sub-item (`_archivecap._tcp` is
  advertised at `CaptureServer.swift:68` but **neither companion browses it** — no `NWBrowser`; pairing is
  QR-only). Also marked W16.lan1 DONE in `ArchiveProcessor/KNOWN_ISSUES.md` §"Live Capture LAN channel". Facts
  re-verified against the tree: the `:68` advertise, the `CaptureSession.swift:275-282` 31-char/~29.7-bit token,
  no companion `NWBrowser`, and the USB/Drive alternatives.
  | files: ArchiveProcessor/KNOWN_ISSUES.md, ArchiveProcessor/CLAUDE.md | S | low | none
- [x] **W16.lan2 — high-entropy LAN token + failed-auth throttle [S].** DONE 2026-07-28 (`c335abd` checkpoint +
  this commit). SPLIT the credentials per the owner decision: added `CaptureSession.lanToken` — a fresh **~158-bit**
  LAN credential (32 chars over the 31-symbol alphabet, CSPRNG-drawn via `randomElement()`, persisted under a new
  `LiveCaptureLANToken` key) — now authenticated by `CaptureServer` and carried in the QR's `token` field, while the
  6-char **Drive-relay `token` is untouched** (still `appProperties.relayToken` + QR `relay`; `SPEC/relay-object-format.md:38`
  + golden fixtures + the shipped Android transport ride on it). Added a **per-source failed-auth throttle**
  (`CaptureServer.AuthThrottle`: 5 free 401s → exponential backoff capped at 30 s, keyed per remote IP, fail-open on
  an undeterminable source, cleared on any authenticated request) so a hostile LAN peer can't sweep tokens at
  connection speed. Both companions parse `token` as opaque (Android `MacEndpoint.fromQrPayload`, iOS
  `MacEndpoint.decode` — non-empty check only), so the sole migration cost is **one QR re-scan per phone** for LAN;
  Cloud is unaffected. Tier-2 APPROVE (adversarial self-review; happy-path unaffected, per-IP isolation, bounded
  map, no new timing side-channel). Verified headlessly: standalone algorithm test (22 checks — token entropy + the
  full throttle schedule 2→4→8→16→30-capped + idle-reset + fail-open) PASS; committed `ManifestPersistenceTestDriver`
  W16.lan2 checks exercise the real types (run defers to the next smoke/VM — host app-launch is denied in the
  autonomous scope); Processor Debug build clean, 0 warnings. KNOWN_ISSUES §"Live Capture LAN channel" B marked FIXED.
  | files: Capture/CaptureSession.swift, Net/CaptureServer.swift, Views/LiveCaptureView.swift | S | med | none
- [x] **W16.cfg1 — make `SessionProcessingConfig` the single run config [S].** DONE 2026-07-29 (this commit).
  `SessionProcessingConfig` is now explicitly `Sendable`; its existing `fromDefaults()` builder snapshots
  `ocrWorkerCount` with the same 1…12 clamp/fallback of 4 as `OCRProcessor.loadStandardImageMB()`. A dedicated,
  then-unused `fromProcessFilesRunStart()` builder centralizes that method's complete normalization (worker
  count, all three finite 0.5…20 image sizes, and 1…4 text columns) for W16.cfg2/3 without changing Live Capture
  behavior in this checkpoint. The field defaults to 4 for the two direct Live Capture test-driver configs; no
  scheduling/output call site reads it yet. Kept app-local (no ArchiveCore/SPEC/protocol change). Processor
  Debug build succeeded with no new code warnings; the scratch-only manifest/config regression uses volatile
  defaults to cover the returned configs' worker wiring/bounds and complete Process Files normalization, and
  passed all checks.
  | files: Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift | S | low | none
- [x] **W16.cfg2 — thread the run config into OCR scheduling + PDF generation reads [M].** DONE 2026-07-29
  (this commit). Fresh Process Files runs now capture one normalized `SessionProcessingConfig` and pass it through
  multi-page re-OCR, paid-batch result materialization, sequential/parallel OCR, timeout/high-use retries, the
  interactive retry loop, and PDF writes. OCR calls receive its `standardImageMB`; schedulers use its bounded
  `ocrWorkerCount`; PDF generation uses its `pdfImageMB`/`textColumns`. The exact sizing/scheduling values used
  are also written to `PendingRunRuntimeConfig`, rather than re-read from globals. The processor retains the
  snapshot for the Files pane's post-run per-item Retry / Retry with model / Rotate & re-run actions (an
  adversarial-review catch). Resume paths explicitly pass nil and preserve the existing validated static fallback
  until W16.cfg5, so this checkpoint changes no recovery schema or legacy behavior. Debug build succeeded; the
  scratch config/manifest, multi-page PDF, and batch/non-batch resume suites all passed. The general smoke wrapper's
  two self-contained Local Agent checks passed; its unrelated build/launch/corpus stages remain unusable in an
  isolated worktree because the script assumes a nonexistent nested `ArchiveProcessor/` path and untracked
  `Test Files`. Tier-2 adversarial review approved after the per-item retry gap was fixed.
  | files: OCR/{OCRProcessor,OCRProcessor+OCR,OCRProcessor+Pipeline}.swift,
    Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver,MultiPageReOCRTestDriver}.swift | M | med | none
- [x] **W16.cfg3 — thread the run config into review/regeneration + tagging reads** (blocked-on: W16.cfg1,
  W16.cfg2) **[M].** DONE 2026-07-29 (this commit). Fresh standard-image and pre-OCRed runs now pass the
  same immutable snapshot through rotation/manual PDF regeneration, segmentation and collection review
  reclassification, automatic/manual tag writes, Live Capture priority layering, sized-original export, and
  merged-PDF tag transfer. The late-stage resolver uses explicit config first, then the retained active-run
  config for post-run UI edits; resume deliberately supplies nil and preserves its current validated
  static/instance fallback until W16.cfg5. Process Files snapshots the controller's exact tagging/merge/export policy,
  so headless `.none`/`.copySource` runs cannot inherit unrelated UserDefaults values; every copy-source
  write remains explicitly non-stamping. Processor Debug build plus scratch manifest/config, merge-safety, and
  batch/non-batch resume regressions passed. Tier-2 adversarial review found and closed the remaining live
  tagging/merge/export decision gates, then approved call-path coverage, copy-source behavior,
  trailing-closure compatibility, and the MainActor/detached-task boundary.
  | files: OCR/{OCRProcessor+OCR,OCRProcessor+Pipeline,OCRProcessor+ReviewFlows,OCRProcessor+Tagging}.swift,
    Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift | M | med | none
- [x] **W16.cfg5 — resume constructs a run config instead of fanning out to globals** (blocked-on: W16.cfg2,
  W16.cfg3) **[M].** DONE 2026-07-29 (this commit). Modern `PendingRun` resumes now reconstruct one
  `SessionProcessingConfig` from the validated runtime snapshot; legacy `PendingRun` and `PendingBatch`
  resumes combine their persisted identity/policy with the same current normalized defaults as before
  (including the prior 1%…100% image-scale clamp). Every resume stores the non-nil snapshot in
  `activeRunConfig` and threads it through OCR/PDF/retry/pre-OCRed/review/tag/export/merge seams. The six
  resume assignments and fresh-run static fan-out are gone; fresh runs and standalone Tools diagnostics
  pass rotation/size explicitly, so no production path depends on a stale process-global value. The
  manifest validator and schema version are unchanged. `BatchResumeTestDriver` now asserts modern,
  legacy-run, legacy-batch, malformed-default, and no-global-fan-out behavior. Debug build plus scratch
  batch/non-batch recovery, manifest/config isolation, multi-page PDF, and merge/tag safety suites passed.
  Tier-2 adversarial review found and closed the Tools static escape hatch, two missed run-config seams,
  and the legacy image-scale clamp mismatch, then approved.
  | files: OCR/{OCRProcessor,OCRProcessor+OCR,OCRProcessor+Pipeline}.swift,
    Capture/{BatchResumeTestDriver,SessionProcessingConfig}.swift, Views/ToolsView.swift | M | med | none
- [x] **W16.cfg6-fu — `MacOSTagger.stampUnread` and the `taggingMode.didSet` that armed it are deleted
  [XS · verified].** DONE 2026-08-01 (this commit; checkpoint `5e72f15`). Filed by W16.cfg6. It was the suite's
  last ambient tagging global. Nothing in production read it — W16.cfg4 had already made `stampUnread:` a
  required per-call parameter at all 13 `applyTags` sites — so what kept it alive was three test drivers, plus
  the standing possibility that a driver whose `defer` a crash skipped would leave a stale value behind.
  `MacOSTagger` now holds no state at all; which semantics a tag write uses is an argument at the call site and
  nothing else. The drivers now assert the injected per-call value: `MergeSafetyTestDriver`'s two stamping cases
  were already driven by the processor's own `taggingMode` (`performDocumentMerging` reads
  `taggingMode.stampsUnread`), so the global assignments beside them were simply redundant;
  `ProcessFilesTagWarningTestDriver` only saved/restored it. **`ManifestPersistenceTestDriver`'s B8 check had
  lost its subject entirely** ("activation does not arm the tagging global") and got a NEW one rather than
  retirement: a run holding no snapshot answers from pure UserDefaults reads, so the only channel by which Live
  Capture could still reach a later Process Files run is by PERSISTING its config. B8 now hands
  `beginLiveSession` a config differing from disk in all **seven** such values (five sizing + rotation mode +
  tagging mode) and proves each key reads back byte-identical — split into two checks so a failure says which
  half broke, the first comparing per-field precisely because one struct-level `!=` would let six of the seven
  silently stop being covered. **Verified $0, scratch-only, no network:** manifest-persistence 105 PASS / 0 FAIL,
  merge-safety 15 PASS / 0 FAIL, tagwarn 74 PASS / 0 FAIL; Debug build clean, no new warnings. **Non-vacuity
  measured against 4 mutants** (activation persisted the sizing config / the config didn't actually differ from
  disk / a rotation-mode leak / a tagging-mode leak) — all RED, restored green. **Tier-2 adversarial review
  found four real defects in the replacement B8 check and all four were fixed before the final commit:** the
  comment claimed `runSizing()` was the *only* terminal fallback when `defaultRotationMode()` is a sixth (so a
  future "remember the last live rotation choice" write would have leaked past a green check — the rotation
  conjunct exists because of this finding); the honesty guard was a struct-level `!=`; `taggingMode` was
  hardcoded to `.automatic`, the near-certain on-disk value, making its conjunct nearly vacuous; and the comment
  asserted "read-only throughout — nothing writes `UserDefaults.standard`", which is **false** — constructing
  `CaptureSession` mints the two capture-token defaults when absent, and `activate` prunes orphaned legacy
  staging. The comment now says what is true and why those writes are tolerable. Review also confirmed the SPEC
  citation `Tagging/MacOSTagger.swift` (`stampUnread`) still resolves — `stampUnread` remains the parameter
  label on both `applyTags` overloads — so **no owner-gated SPEC edit was needed.**
  | files: Tagging/MacOSTagger.swift, OCR/OCRProcessor.swift,
    Capture/{ManifestPersistence,MergeSafety,ProcessFiles,ProcessFilesTagWarning}TestDriver.swift | XS | low | none
- [x] **W16.cfg6-fu4 — the killed session's two B8 coverage ideas are folded in, and B8 now asks the
  production READ PATH as well as the storage [XS · verified].** DONE 2026-08-01 (this commit). Filed by
  `a720659` to preserve the delta of a daemon session (worktree `wt/autonomous-20260801-173656-39537`) that
  did W16.cfg6-fu independently and was killed before it pushed. Both ideas are now in, **alongside** the
  shipped raw-key check rather than replacing it — that was the item's explicit instruction and it turned out
  to matter (see below).
  1. **A channel-agnostic subject.** An independent, snapshot-less `OCRProcessor` is sampled either side of
     `beginLiveSession` through the three seams a Process Files run actually resolves through —
     `lateRunOutputSettings` (pdf/exported sizing + tagging/merge/export), `ocrCallValues` (rotation mode +
     standard image size) and `schedulingWorkerCount`. The raw-key check names the STORAGE; this one names
     only the ANSWER, so a future leak through a channel nobody enumerated — a reintroduced global, a
     singleton consulted inside `defaultRotationMode()`/`runSizing()` — moves this observable while all seven
     named keys stay green. Its tagging/merge/export values are set to the far side of the live config so an
     override is visible rather than coincidentally equal.
  2. **A third interleaved tag write.** The sequence is now `true`, `false`, `true`, the last two on the same
     file, so it also rules out residue in the direction a `true`-then-`false` pair is blind to: a
     copy-source write suppressing a later stamp.
  **The killed session's version was extended in three places its own review had not reached.** Its PF
  processor was hardcoded to `.none` tagging and `mergeDocuments: false` — the first is only the *opposite*
  of the live config when the on-disk mode happens to be `.none`, and the second is never opposite, so two of
  its three tagging conjuncts were near-vacuous; both now derive from `liveConfig`. And its observable covered
  only `lateRunOutputSettings`, which surfaces just four of the seven pinned values — `rotationMode`,
  `standardImageMB` and `ocrWorkerCount` resolve through `ocrCallValues`/`schedulingWorkerCount` and were
  invisible to it, so a reintroduced *rotation* global (the exact W16.cfg6 shape) would have passed. Those two
  seams are now sampled too.
  **Verified $0, scratch-only, no network:** manifest-persistence **109 PASS / 0 FAIL** (was 105), merge-safety
  15 / 0, tagwarn 74 / 0; Debug build clean, no new warnings. **Non-vacuity measured against 4 mutants**, each
  rebuilt and rerun: a tagging-mode override and a live-config snapshot bleed each reddened exactly the new
  observable checks **while the shipped raw-key check stayed green** (the complementarity claim, demonstrated
  rather than asserted); an `ocrCallValues(for: liveConfig)` bleed reddened only the new OCR-inputs check; and
  flipping the third write's `stampUnread:` reddened only the new re-stamp check, leaving the pre-existing
  two-write check green. All restored.
  **Tier-2 adversarial review found five real defects — one contract violation and four false comment claims —
  all fixed before this commit.** (a) The re-stamp assertion compared the tag array **by position**
  (`== ["Subject","Unread"]`), which `SPEC/tag-format.md` forbids — macOS may reorder on write, which is why
  `CoordinatedTagWriter` verifies with `multisetEqual`; both it and the adjacent pre-existing
  `.last == "Unread"` now compare as multisets, removing a latent flake that would have failed the whole
  driver with no defect. (b) The comment claimed the observable was "blind to nothing" when it missed three of
  the seven values — fixed by *adding the two seams* (above) rather than by softening the claim. (c) It called
  the sizing values the processor's "own settings"; they are pure defaults reads to which the instance
  contributes nothing, so that half **overlaps** the raw-key check and must not be read as superseding it —
  the comment now says so explicitly, because a maintainer acting on the old wording would have deleted the
  raw-key check and silently dropped two keys plus the value-equal-rewrite detection only a raw-string
  comparison has. (d) "true, false, true on the SAME file" described three writes to one file when the first
  targets a different file. (e) A parenthetical conflated the block's non-vacuity precondition with its
  must-not-move assertion. Review also confirmed, and this commit relies on: `unlike()` cannot produce a
  spurious red under any clamped/out-of-range/unset on-disk value (`b8SizingBefore` is already normalized), and
  constructing an `OCRProcessor` mid-block is genuinely inert (no custom init, no defaults registration, no
  notification wiring), so it cannot perturb what the surrounding checks pin.
  | files: Capture/ManifestPersistenceTestDriver.swift | XS | low | none
- [x] **W16.cfg6-fu3 — the WRITERS of the five sizing settings were unbounded; only the reader saved them
  [S · verified].** DONE 2026-08-01 (this commit; checkpoints `eb8a70d`, `42285f4`). Filed by W16.cfg6-fu2's
  adversarial review. fu2 made every *defaults read* clamp, so nothing out of range could reach a run; this
  item was the visible-vs-effective divergence left over — typing `500` into an MB field beside its 0.5…20
  stepper persisted 500 and kept displaying 500 while every run used 20 and the cost pane quoted 500.
  **`SessionProcessingConfig.Bounds`** is now the one declaration of the three ranges (0.5…20 MB, 1…12
  workers, 1…4 columns). It replaced **six** literal sites, not the four the checkpoint commit claimed — the
  adversarial review found two more that the first pass missed, and they were the two that mattered most:
  `OCRProcessor.schedulingWorkerCount` and `PDFGenerator`'s column clamp, i.e. exactly the downstream pair
  that would keep running 12 workers / 4 columns if the shared bound were ever widened, recreating the
  divergence this item exists to kill. Both substitutions are value-identical for every `Int`
  (`min(12, max(1, x))` ≡ `clampOCRWorkers(x)`; `max(1, min(x, 4))` ≡ `clampTextColumns(x)`), so no behaviour
  moved. The fail-closed resume validator `pendingRunRuntimeConfigIsValid` reads `Bounds` too, with all three
  `.isFinite` guards intact and in place — verified value-identical, since a stricter validator there would
  refuse a resumable **paid** batch.
  **`normalizeSizingDefaults(_:)`** is the writer half: it writes back exactly `runSizing(d)`, so writer and
  reader cannot disagree about a bound or a fallback. An UNSET key stays unset (`ProcessingProfileStore`
  reads stored-vs-defaulted), and a key already equal to its normalized value is not rewritten, so it is
  idempotent. Wired at the four sites the fu2 review named: Settings `.onAppear` + four `.onChange`; the two
  panes that quote a size to the operator; `TimeEstimator` (now clamps workers at BOTH ends — `max(1, …)`
  alone let a stored 100 quote an ~8× optimistic ETA while the pipeline ran 12); and
  `ProcessingProfileStore.apply`, which also gained a `to d: UserDefaults = .standard` parameter so the
  headless driver exercises it on a scratch suite rather than the real settings.
  **The design question the item posed is answered, not skipped:** a big number no longer means "keep the
  original bytes". fu2 already ended that — every read resolves 500 → 20 — so normalizing destroys an intent
  that had already stopped working, and there is no production material to preserve it for. If a
  never-re-encode mode is ever wanted it should be an explicit setting, not a magic large number.
  **Verification:** Debug build clean, 0 new warnings; `test-manifest-persistence.sh` **104 PASS / 0 FAIL**
  and `test-batch-resume.sh` **241 PASS / 0 FAIL** ($0, no network, no key, scratch suites only), the latter
  run because this touched the resume validator. **Non-vacuity MEASURED across three mutants:** dropping the
  unset-guard / the equality-guard / the `TimeEstimator` clamp / the `apply` call turns exactly 4 red;
  clamping ∞ to the ceiling instead of resolving it turns 3 red; rounding every size to the nearest 0.5 turns
  exactly 1 red. **The adversarial review earned its keep four times** — it found the two missed literal
  sites; it killed a near-vacuous check (comparing stored against `fromDefaults` *after* normalizing proves
  nothing, because the reader agrees with any in-range number handed to it — measured, the clamp-to-ceiling
  mutant left it green, so it was rewritten to compare against the PRE-normalization read); it produced the
  round-to-0.5 mutant that no existing check caught, now closed by an in-range-value-untouched check; and it
  refuted two doc-comment overclaims (the validator can still be *looser* than the app — the columns Picker
  offers only 1/2/3 while `Bounds` admits 4 — and "what Settings shows is what a run uses" is true only to
  the field's one-decimal display: a stored 19.96 still renders as 20, measured, and is left alone).
  ⚠️ **One check deferred, not skipped:** whether the MB field visibly redraws when the normalizer writes
  behind it while the field still has focus. The Processor has no UITest target or VM lane yet
  (`W21.vmgui-d`), so the off-screen route does not exist and the host screen is the owner's. Proven safe
  regardless — it cannot loop (the write is gated on inequality, converging in two passes) and no run reads
  the raw value — but the redraw itself is unseen. → Morning Review.
  | files: Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift,
    OCR/{OCRProcessor+Pipeline,OCRProcessor+OCR,PDFGenerator}.swift,
    Views/SettingsView.swift, Models/{TimeEstimator,ProcessingProfileStore}.swift | Tier-2 | S | none
- [x] **W16.cfg6-fu2 — `fromDefaults()` clamped looser than `runSizing()`, so Live Capture got unclamped image
  sizes [S · verified].** DONE 2026-08-01 (this commit). Filed by W16.cfg6's adversarial review and re-verified
  on both halves during the 2026-08-01 owner walkthrough. `fromDefaults()` built `pdfImageMB`/`exportedImageMB`
  from bare inline closures (`p > 0 ? p : 2.0`) — no `.isFinite` guard, no 0.5 floor, no 20 ceiling — while
  `standardImageMB`/`ocrWorkerCount` went through the strict shared helpers. **Live Capture snapshots its whole
  session config from `fromDefaults()`** (`CaptureSession.swift:230`), so those closures were the only clamp an
  out-of-range default met on the live path: a 21 MB `pdfImageSizeMB` stayed 21 for a live capture (Process
  Files made it 20), and `+.infinity` — which UserDefaults really does round-trip, measured — passed straight
  through, since `inf > 0`. Fixed by taking **all five** sizing values in `fromDefaults()` from `runSizing(_:)`,
  so there is one normalization per defaults read. `fromProcessFilesRunStart()` therefore had nothing left to
  correct: it is now a one-line forward, and the callerless `applySizing(_:)` is deleted. `textColumns`'
  old closure was already numerically equivalent (`tc > 1 ? min(4, tc) : 1` ≡ `min(4, max(1, tc))` for every
  `Int`, `Int.min` included) — merged for one definition, not to change behaviour.
  **Verification:** Debug build clean, 0 new warnings; `test-manifest-persistence.sh` **96 PASS / 0 FAIL**
  ($0, no network, no key, scratch suites only) including six new `W16.cfg6-fu2` checks. **Non-vacuity
  measured**, not asserted: restoring the two pre-fix closures turns 4 of the 6 red (ceiling, builder
  agreement, 0.5 floor, non-finite). The other two — unset-defaults fallback and negative-falls-back — are
  green pre-fix by design: they guard against a *wrong fix* (e.g. `max(0.5, v)` without the `.isFinite && > 0`
  test), not against the original bug. **Adversarial review** (opus, refute-first) killed two weaker checks and
  one overclaim: a "REAL defaults are in range" check that was unfalsifiable while the clamp exists was
  deleted, a "negative or NaN" check that the old code also passed was re-scoped onto `+.infinity` (which it
  did not), and the new doc comment's "one clamp per value, app-wide" was corrected to per-defaults-read after
  the reviewer produced four counterexamples. Its claim that the resume path applies a runtime config
  unclamped was checked and does not hold — `pendingRunRuntimeConfigIsValid` fail-closes on the same ranges.
  Residual writer-side gaps filed as **W16.cfg6-fu3**.
  | files: Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver}.swift | Tier-2 | S | none
- [x] **W16.cfg6 — delete the six `nonisolated(unsafe)` statics; injection mandatory** (blocked-on: W16.cfg2,
  W16.cfg3, W16.cfg5) **[S].** DONE 2026-08-01 (this commit; checkpoints `6713e43`, `2373d30`). All six are
  gone — `rotationModeForRun`, `standardImageMB`, `ocrWorkerCount`, `pdfImageMB`, `textColumns`,
  `exportedImageMB` — with `loadStandardImageMB()`. **Nothing process-global decides how a Process Files run
  sizes an image, columns a text page, or schedules its workers any more.** Two parameters became required, so
  the compiler (not a reviewer) enforces completeness: `targetDimensionScale(forFileAt:sizeFraction:standardImageMB:)`
  and `performOCRCall(…, rotationMode:, standardImageMB:)`; all 11 `performOCRCall` sites resolve both once per
  function via the new `OCRProcessor.ocrCallValues(for:)`, hoisted before any actor hop. Where an optional
  `runConfig` legitimately remains (`pdfGenerationSettings`, `schedulingWorkerCount`, `lateRunOutputSettings`,
  `makePendingRunRuntimeConfig`), the terminal fallback is now `SessionProcessingConfig.runSizing()` /
  `defaultRotationMode()` — **pure, lazily evaluated, Keychain-free** defaults reads, so an injected config
  short-circuits them and the per-file loops never touch UserDefaults. `fromProcessFilesRunStart()` normalizes
  through the same `runSizing()`, so there is now **one clamp per value in the whole app** ⚠️ *(overclaim —
  see W16.cfg6-fu2 below: `fromDefaults()`, which is Live Capture's builder, did NOT go through it; the honest
  scope even after fu2 is one clamp per **defaults read**)*. Behaviour: every
  production path injects a config (cfg2/cfg3/cfg5), so the only branch whose value changes is the one no
  production caller reaches — and there it goes from the deleted statics' *initial* constants (pdfImageMB 0,
  exportedImageMB 0, rotation `.localVision`, which is what a post-cfg5 process would serve since nothing wrote
  them any more) back to the normalized run-start defaults `loadStandardImageMB()` produced pre-cfg5. A
  restoration, not a new rule. The three drivers **stop poking globals** — exactly the pattern this item
  existed to delete, since a crash between a driver's write and its `defer` restore left a REAL run exporting
  at the test's size: `ProcessFilesTagWarningTestDriver` injects its 5 MB export target,
  `BatchResumeTestDriver`'s "no fan-out to statics" check became a bystander-processor check (nothing left to
  fan out to), and `ManifestPersistenceTestDriver` gained five W16.cfg6 checks pinning what a static could never
  offer — read twice, same answer; change a default, seen immediately; nothing cached, nothing retained.
  **Verification:** Debug build clean, 0 new warnings; `test-manifest-persistence.sh`, `test-batch-resume.sh`,
  `test-processfiles-tagwarn.sh`, `test-merge-safety.sh`, `test-multipage-reocr.sh`, `test-recovery.sh`,
  `test-output-file-safety.sh`, `test-collection-organize.sh`, `test-localagent.sh`, `test-segment-json.sh`,
  `test-incremental-skip.sh` — **all pass** ($0, scratch/temp dirs only, no corpus). `test-tier2.sh` needs a
  live Gemini key (pre-existing keyed tail, not run). Two-lens adversarial refute-verify
  (reachability+numeric-equivalence; call-site mechanics+concurrency+test integrity) — see below.
  | files: OCR/OCRProcessor{,+OCR,+Pipeline,+Tagging}.swift, Capture/{SessionProcessingConfig,ManifestPersistenceTestDriver,BatchResumeTestDriver,ProcessFilesTagWarningTestDriver}.swift | S | med | none
- [x] **W16.cfg4 — make `stampUnread` injection explicit at all `MacOSTagger` call sites [M].** DONE 2026-07-18
  (`806a6d3`). `applyTags`'s `stampUnread` is now a **required non-optional** parameter (both overloads);
  the process-global is no longer read by `applyTags` (retained only as a test-driver affordance + `taggingMode.didSet`
  writer, to be deleted with the run-config globals in W16.cfg6). All 13 sites audited individually: the four
  copy-source pass-through sites (`+OCR.swift:168/1064`, `+Pipeline.swift:1091`, `+ReviewFlows.swift:388`) pass a
  literal `false`; the nine real-tagging sites pass `taggingMode.stampsUnread`. The merge path's direct global
  *read* for job selection (`+Tagging.swift:825`) was also moved to `taggingMode.stampsUnread` so it can't disagree
  with its paired write (:834). The image-mirror detached task hoists `taggingMode.stampsUnread` onto the MainActor
  before detaching. **The `⚠️` copy-source-regression hazard was confirmed real and avoided** (the four false sites);
  the `MergeSafetyTestDriver` "empty non-stamping merge skips unnecessary tag writer" case had to be re-expressed via
  `taggingMode = .none` because a fresh `OCRProcessor()` defaults `taggingMode` to `.automatic` and an init default
  doesn't fire `didSet`. **Verification:** non-optional param → compiler-proven site completeness; build clean, 0 new
  warnings; `MergeSafetyTestDriver` (15/15) + `ManifestPersistenceTestDriver` (42/42) ALL PASS; **4-lens adversarial
  refute-verify (equivalence/lifecycle/invariant/concurrency) — 0 findings, none could refute behavior-preservation**
  (the invariant lens proved `enableTagging` is derived, so `passSourceTags && enableTagging ≡ (mode==.copySource)`,
  closing the one hypothesized hole). Behavior-preserving for every production path.
  | files: Tagging/MacOSTagger.swift, OCR/OCRProcessor+{OCR,Tagging,ReviewFlows,Pipeline}.swift, Capture/MergeSafetyTestDriver.swift | M | **high** | none
- [x] **W16.bat1 — provider contract fixtures for the three batch clients' response parsing [M].** The **only
  unmet item in the entry's own verification plan**, and the highest-value remaining slice. `GeminiBatchClient.checkStatus`
  parsed **six alternative JSON shapes** with **zero tests** — a provider response-shape change would silently
  have marked an entire paid batch as failed.
  ✅ **DONE this commit** (checkpoints `8f51c9b` = the seams, `85c3b96` = the checks). Each client's parse body
  was lifted **verbatim** out of its `async throws` network call into a pure static seam — `parseStatusBody(_:)`
  and `parseResultsJSONL(_:)` on all three clients — and `parseInlinedResponses` / `parseSingleResponse` /
  `parseBatchErrorBody` went `private` → internal. No behaviour change is possible by construction: the diff
  moves whole statement runs and adds no logic. `OCR/BatchParseContract.swift` then drives literal
  Anthropic/Gemini/Mistral bodies through those seams as section 12 of `BatchResumeTestDriver`, so
  `scripts/test-batch-resume.sh` covers the whole paid-batch surface: **81 new checks, 144 total, ALL PASS, $0,
  no network, no keys.** Every shape the item asked for is pinned — all six result-file spellings *individually*
  plus the order they resolve in; state under `state` vs `metadata.state` and inline results under `response.…`
  vs `metadata.output.…`, both with their precedence; inline results read ONLY once terminal; all eight terminal
  states across the BATCH_/JOB_ vocabularies; blockReason / RECITATION as stated refusals; entry-level errors
  with their code; the `'0'` → `'file-0'` normalization (and that an unattributable entry is DROPPED, never
  misfiled onto another page); empty + malformed result sets; Anthropic succeeded/errored/expired lines and the
  rule that a non-text block is excluded by TYPE even when it carries a `text` field (thinking must not leak
  into a transcription); Mistral's five terminal statuses, `pages[].markdown` + `text` fallback and its error
  ladder; the shared HTTP error body incl. an HTML gateway page. Across all three: one unreadable JSONL line
  never costs the other paid pages. **Non-vacuity measured, not assumed** — 7 neuters reddened 14 checks
  (8 predicted; the 6 extras all traced to the shared key-normalization neuter's wider blast radius), and every
  neuter reddened at least one check. The operator note also shipped (`README.md` §"Batch Processing → If a
  batch submission reports an uncertain outcome"). Processor builds clean, 0 new warnings. Residual filed as
  **W16.bat1-fu** below.
  | files: OCR/BatchOCR.swift, OCR/BatchParseContract.swift, Capture/BatchResumeTestDriver.swift, scripts/, README.md, TESTING.md | M | low | none
- [x] **W16.bat1-fu — an EMPTY inlined-results container makes the poll consume a paid Gemini chunk with zero
  pages [XS–S · LOW · measured, never observed].** Found by measurement while writing the W16.bat1 fixtures, and
  pinned there as a fact rather than an endorsement (`gemini: an EMPTY inline container parses to a non-nil
  empty set`). `GeminiBatchClient.parseStatusBody` sets `inlineResults` to a **non-nil empty dictionary** when a
  terminal batch carries `inlinedResponses: []`, and the poll then takes the inline arm — `if let inlineResults
  = status.inlineResults { … } else if let fileName = status.resultFileName { … }`
  (`OCRProcessor+OCR.swift:776-785`) — so the result **file is never fetched**. `processBatchResults` returns
  `true` on an empty set (`:874`), so the chunk is marked *consumed* and never retried: that chunk's paid OCR is
  lost while the run reports success. Requires the provider to emit an empty container on a SUCCEEDED batch
  (never seen here), hence LOW — but it is exactly the response-shape class W16.bat1 exists to catch. Fix is one
  condition (`if let inline = status.inlineResults, !inline.isEmpty`) plus a decision on what an empty container
  with **no** file spelling means (fail the chunk loudly rather than consume it). Touches the paid poll →
  **Tier-2**, and the existing pin must be flipped to assert the new behaviour.
  ✅ **DONE this commit** (checkpoints `43b53e9` = the ranking seam, `c9490ac` = the poll + the outcome rule,
  `94c39a9` = the terminal-verdict rewrite the Tier-2 review forced). Both halves of the decision are now pure
  and pinned rather than inline in the poll. `resultsSource(for:)` ranks the two retrieval arms and treats an
  empty inline container — **and a blank or whitespace-only result-file name** — as *not a source*, so the
  result file is still fetched. `chunkOutcome(resultCount:emptyObservations:limit:)` then judges the **raw
  provider results**, which is where the judgement has to happen: `processBatchResults` returns `true` for an
  empty set *by design*, because a resumed chunk whose pages all persisted already legitimately yields no new
  entries — so it can never be the gate.
  **The verdict is terminal, not blocking** — and getting that wrong first is the lesson worth keeping. The
  adversarial review killed checkpoint 2's design: it set `batchPollInterrupted` and returned, with a
  poll-local observation count, so every Resume restarted the grace and aborted again and **nothing ever
  converted an empty chunk to failed** — the run could never finalize, tag, or retry, and sibling chunks still
  hours from finishing were abandoned. Its worst case: a result file that 404s after Gemini's ~48h retention
  (`NetworkSession` does not throw on non-2xx, so the error body parses to zero results) on a chunk whose pages
  are **all already on disk** → a run blocked forever with nothing missing. Now: the chunk is still never
  marked consumed, but the batch COMPLETES, and the existing completion sweep gives each unmaterialized file an
  explicit `no_result` failure the retry pass can act on (resume restores already-persisted results as
  `.succeeded`/`.failed`, so they are not re-failed). Given-up chunks are remembered so later polls don't
  re-fetch them. Grace is 5 polls (~2–4 min); 3 gave the late-attach case it exists for only ~90s.
  **17 new $0 checks** (`test-batch-resume.sh` 144 → 161, ALL PASS), including the invariant swept over BOTH
  axes — every observation count against every limit from −5 to 100,000 — in both directions: zero results
  never materialize, and pages are never withheld. Non-vacuity MEASURED with 4 neuters, each reddening exactly
  its own checks. The W16.bat1 pin was kept but renamed: the *parse* still reports the empty container
  faithfully; what changed is that the poll no longer acts on it. Adjacent `test-network-session`,
  `test-manifest-persistence`, `test-recovery` green; clean build, 0 new warnings. Operator note in
  `ArchiveProcessor/README.md`. Two **pre-existing** defects the review surfaced are filed separately, not
  fixed here: **W16.bat3** (Stop deletes the paid journal) and **W16.bat4** (the Resume control is not
  re-surfaced after an interrupted first run).
  | files: OCR/BatchOCR.swift, OCR/OCRProcessor+OCR.swift, OCR/BatchParseContract.swift | XS–S | low | none
- [x] **W16.bat2 — headless coverage for the cancel path's journal-retention contract [M].** DONE 2026-08-01
  `c3dc615` + `72b1ed7` + this commit — the delete-only-if-all-confirmed rule was the one shipped safety
  guarantee on the money path with no regression test, because it was welded to three live network clients.
  It now lives in one seam, `performServerBatchCancellation` (`+Pipeline.swift:1565`), which takes the
  provider's per-chunk cancellation as an injectable closure and returns what it did to the journal
  (`BatchCancellationOutcome`, incl. which chunks it actually attempted); `cancel()` keeps only the
  provider-specific *how*. Behaviour-preserving: same switch, same order, same message (now a pinnable
  constant), same single delete condition.
  **28 new $0 checks** (`test-batch-resume.sh` 161 → 189, ALL PASS) in `BatchCancelContract`, driven through
  the real seam with a stub canceller and a **real temp file**, so "kept" means a file that is still on disk.
  Named cases for every rule the item asked for — all-confirmed deletes; one refusal keeps; multi-chunk
  Anthropic/Mistral is neither confirmed nor *half*-cancelled (no chunk attempted); zero chunks is a failure
  to confirm, not a vacuous success; OpenAI never confirms — plus Gemini's no-early-exit loop (a live chunk
  is what costs money) and "the words and the disk cannot disagree". Then the invariant swept over both axes:
  4 providers × chunk counts 0–6 × no refusal / each chunk refused in turn / all refused = **132 trials**,
  asserting *deleted ⟺ confirmed* in the outcome AND on disk, confirmation matching an independently written
  statement of the providers' capabilities, no attempt a provider's rule could not act on, message ⟺
  survival, and delete called at most once. Non-vacuity MEASURED with **5 neuters**, each reddening exactly
  its own checks — including one shaped like W16.bat3 (journal deleted while the outcome still says "kept"),
  which reddens 13. Clean build, 0 new warnings; `test-network-session`, `test-recovery`,
  `test-manifest-persistence` green.
  **Scope note — what a green section 13 does NOT buy:** it pins the *rule*, in the seam, not the whole Stop
  path. No check goes through `cancel()`, and `deletePendingBatch()` is executed by none of them (the stub
  deletes a temp fixture), so the *wiring* is unproven — filed as **W16.bat2-fu**. And W16.bat3's bug is
  downstream of this seam entirely, in the poll's cancellation guards; it stays open + owner-gated and must
  not be closed by citing this. Both caveats are now written into the code comments too, because the code
  comment is what the next maintainer reads.
  The adversarial review could not refute behaviour equivalence (case-by-case against `69f3bbc`: identical
  call counts, byte-identical message, same single delete condition, same MainActor executor, clients already
  constructed before the count check). Its findings drove one extra tripwire check (OpenAI's rule is only
  correct because `supportsBatch == false` — reddens if Phase 4 lands), a non-vacuity guard on the
  "never announced as kept" case, honest scoping in both doc blocks, and two new items (W16.bat2-fu, W16.bat5).
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchCancelContract.swift, Capture/BatchResumeTestDriver.swift | M | med | none
- [x] **W16.bat2-fu — the cancel WIRING is untested, only the rule is [S · LOW].** DONE 2026-08-01
  `b4b871f` (seam) + `1c8bf22` (18 checks) + `183f792` (review gaps) + this commit. `BatchCancelContract`
  proved the RULE; nothing proved `cancel()` fed it the truth, and five separate mutations to the cancel block
  left all 189 checks green. The block's choices became data — `BatchChunkCanceller` (provider + how to cancel
  one chunk + which client it closed over), `BatchCancellationJournal` (the ONE durable file a confirmed
  cancellation may remove, as a value), `cancellationChunkIds` (pure), and two per-instance factories
  (`makeBatchChunkCanceller`, `makeBatchJournalDeleter`) — then `BatchCancelWiringContract` drives the **real
  `cancel()`** with both seams stubbed and a real temp file: **24 new $0 checks** (`test-batch-resume.sh`
  189 → 213, ALL PASS), no network, no key, no cent, and `deletePendingBatch()` executed by none of them.
  Non-vacuity MEASURED with **12 neuters** — the five the item named, the pending_run variant (via a second
  journal case), and six for the checks the review added — each reddening its own checks and no pre-existing
  one. Two-reader Tier-2 review: the equivalence reader could not refute the refactor (nothing moved INTO the
  spawned Task, `cancel()` has no `await` so the summary is still assigned before the Task can start, all three
  batch clients are pure value structs, the rule body differs by two lines, the chunk-ID expression is
  textual, both new file-name constants equal the literals they replaced). The test reader killed a tautology:
  the provider check compared a LABEL production passes as a literal, so a Gemini job cancelled through the
  Mistral client — or an arm short-circuited to always-confirm — stayed green while deleting the journal. Fixed
  with `clientTypeName`, read off the constructed client; plus the seams' DEFAULTS (previously covered by
  nothing), a non-Gemini Stop, and a sentinel proving the resume banner is refreshed.
  **Scope note — what a green section 14 does NOT buy:** the default *deleter* is unprovable without deleting
  the operator's real journal (→ **W16.bat2-fu2**), and the kept-journal warning is proven *assigned*, not
  *survived* (→ **W16.bat6**). Both are written into the file header, not just here.
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchCancelWiringContract.swift, OCR/BatchCancelContract.swift, Capture/BatchResumeTestDriver.swift | S | low | none
- [x] **W16.bat2-fu2 — make the paid-batch journal path redirectable under test, so the default deleter is
  provable [S · HIGH].** DONE 2026-08-01 `5424054` (production) + this commit (the contract).
  ✅ **OWNER-AUTHORIZED 2026-08-01** and sequenced FIRST of the three W16 money-path items, because it is what
  lets `W16.bat3`/`W16.bat5` be proven against the REAL deleter rather than a stub. Was: two gaps, one cause.
  (a) Every wiring check replaces `makeBatchJournalDeleter`, so its DEFAULT — the one line that actually
  removes `pending_batch.json` — was verified by grep, and mutating it to `{ }` kept all 241 checks green.
  (b) With the path pinned to Application Support, any future un-seamed deletion in the cancel block would
  have made *running `test-batch-resume.sh` on the owner's machine delete his live journal*.
  Both journals now resolve through one function, `OCRProcessor.pendingStateDirectory(testFlag:overrideRoot:)`,
  honouring `ARCHIVEPROC_TEST_STATE_ROOT` **only** when `BATCHRESUME_TEST` reads exactly `"1"` **and** the
  override names a usable absolute directory. Unset, empty, whitespace, `"0"`, `"true"`, `"1 "`, relative,
  `~`-relative, a path naming a file, or one that cannot be created all resolve to the REAL path — the
  binding constraint, kept verbatim, because a mis-read env var here does not fail a test, it strands a paid
  batch. No other trigger (no `#if DEBUG`, no bundle sniffing). The function is **pure in its inputs**, which
  is what lets the fail-closed direction be checked by handing it each bad reading directly rather than by
  mutating the environment of a running app.
  `BatchJournalPathContract` (driver section 16) adds **17 $0 checks** (`test-batch-resume.sh` 241 → 258, ALL
  PASS): the fail-closed table (9 near-miss flag values, then 11 unusable override roots — two independent
  loops, 20 resolutions, not a cross product), then — behind a guard that makes them REFUSE to run unless the
  live path really is redirected — save/read/delete all landing in the redirected directory, the DEFAULT
  deleter removing a real journal file, a confirmed Stop with the real deleter installed removing it, an
  unconfirmed one keeping it and warning, and no outcome touching `pending_run.json`. Non-vacuity measured
  with **eight mutants**: the shipped gap verbatim (deleter → `{ }`) reddens 2 where it previously reddened 0;
  a `!= nil` flag gate 1; dropping the absolute-path guard 1; an un-seamed `deletePendingRun()` in `cancel()`
  1; a resolver that ignores the override 3, including the refuse-to-run guard; a save that writes elsewhere
  4; dropping the real branch's `createDirectory` 1 and the override branch's 3.
  **The second reader's findings** (an independent adversarial pass, 17 raised) landed as a follow-up commit
  and are folded in above: the guard now runs from the TOP of the driver rather than from section 16 (the
  resolver fails closed *silently*, so a harness whose override did not validate would have pressed Stop 80+
  times against the operator's own state before section 16 noticed) and logs a loud warning when an override
  is requested and rejected; the guard resolves symlinks and rejects a parent of the real directory; the
  create-the-directory side effect is now proved on BOTH branches against scratch roots (a `FileManager`
  subclass answers the Application Support query, so the real branch is exercised end to end without
  `~/Library` being the subject) instead of asserted as a state that was already true; and six stale or wrong
  doc claims were corrected, including the `makeBatchJournalDeleter` doc still saying "a check may never run
  it" and the "banner refresh relies on it" justification for the directory — it is the `.atomic` write that
  needs the directory, not the refresh, which reads through `Data(contentsOf:)`.
  `cancel()`'s semantics are untouched (that is W16.bat3/bat5). Verified the owner's real
  `~/Library/Application Support/ArchiveProcessor/` holds neither journal and was not written at any point,
  including during the eight mutant runs. Side benefit: section 14's 80 sweep Stops now read an empty state
  directory, so the suite no longer slows in proportion to a large real interrupted run — which also made one
  check in section 15 reliably vacuous, filed as **W16.bat4-fu**.
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchJournalPathContract.swift, OCR/BatchCancelWiringContract.swift, OCR/BatchInterruptTailContract.swift, Capture/BatchResumeTestDriver.swift, scripts/test-batch-resume.sh | S | high | none
- [x] **W16.bat2-fu3 — fold in the three wiring checks a killed session's draft had and the shipped one
  does not [XS · LOW].** DONE 2026-08-01, this commit. Not a defect — a coverage delta found while cleaning up. The
  session that landed W16.bat2-fu's checkpoint 1/3 (`b4b871f`) was killed holding an untracked draft of
  `BatchCancelWiringContract`; the shipped file was written independently and is stronger where it counts
  (`clientTypeName`, the seams' defaults, the banner sentinel — the draft has none of those), but the draft
  covered three things the shipped one did not, all three now folded in (213 → 225 checks, ALL PASS):
  (1) `sweepEveryShape` — 80 Stops through the real `cancel()` over every provider × 0–3 acknowledged
  chunks × journal-present × each chunk refused in turn, each demanding an EXACT outcome. Not a port of the
  draft's sweep: that one asserted only internal consistency (satisfiable by a cancel path that confirms
  nothing, ever), and its chunk-ID invariant `attempted == derivedChunkIds` was wrong as written — it
  fails for every shape whose provider rule declines to attempt (multi-chunk Anthropic/Mistral, OpenAI),
  which the killed session never got to run. Here each trial states the expected attempt list and
  confirmation independently, and with-journal trials give the batch decoy IDs the journal never
  acknowledged, so no shape may fall back to them. (2) A multi-chunk single-job-provider Stop: 3 chunks through an
  Anthropic/Mistral batch attempts nothing, keeps the journal, and warns — while still asking for the
  canceller and the deleter, so the check stays about the wiring. (3) The legacy (`lifecycleVersion ==
  nil`) journal driven through `cancel()`: its batch ID is cancelled, never its non-authoritative stored
  chunk list. Non-vacuity measured by mutating production five ways: `cancel()` ignoring the journal
  (14 fails), a single-job provider cancelling the first of several (12), a vacuous empty-list Gemini
  success (7), the no-batch-path provider reporting confirmed (6 — caught by the sweep alone at the
  wiring level), and the derivation reading `submittedChunkIds` past `effectiveChunkIds` (2). The
  adversarial review then found the legacy-journal check green under mutation 1 — it gave the journal and
  the live `BatchContext` the same batch ID, so `pendingBatch: nil` satisfied it; all three ID sources now
  disagree and it reddens. Same review: the 80 Stops each run a real `checkForPendingBatch()`, which
  decodes the operator's OWN manifests, so `test-batch-resume.sh`'s 60s report wait (fine at the measured
  4s on an empty machine) could time out on a large interrupted run — i.e. fail exactly when there is a
  live paid batch. Raised to 300s and the dependency written down; it goes away with W16.bat2-fu2. A red
  in the sweep now names the first bad shape (`Anthropic/1 chunk/journal/none refused`) instead of a bare
  boolean. The preserved draft folder is deleted.
  | files: OCR/BatchCancelWiringContract.swift, scripts/test-batch-resume.sh, ArchiveProcessor/TESTING.md | XS | low | none
- [x] **W16.bat4 — after an interrupted FIRST run, the Resume control the message names never appears [S · LOW].**
  DONE 2026-08-01 `1515773` + `819494d` + this commit. Was: every `batchPollInterrupted` message tells the
  operator the batch was kept so they can resume it; on a **resume** that was true (the site called
  `cleanupTempFiles()` + `checkForPendingBatch()`), but on a **first** run the interrupt was
  `isProcessing = false; return` with neither call. `pendingBatchInfo` — the only thing the "Pending Batch /
  Resume Batch" box (`Views/OCRView.swift:319-336`) renders from — is written only inside
  `checkForPendingBatch()`, so the button the message named did not exist until the operator pressed Start and
  was refused, and the PDF-input temp JPEGs leaked. The two tails are now ONE method,
  `finishInterruptedBatchPoll()` (`+Pipeline.swift:796`), called by both sites and by nothing else, so they
  cannot drift again. Reaching the first-run site through it also covers `performBatchOCR`'s three earlier
  interrupted exits (journal-save failure, a submission stopped part-way, a journal/ID disagreement), which
  previously left a dead `activeBatch`/`activePendingBatch` behind and leaked the same temp files. It deletes
  no journal and touches no output — a paid server-side job may still be running.
  `BatchInterruptTailContract` (driver section 15) adds **16 $0 checks** (`test-batch-resume.sh` 225 → 241),
  non-vacuity measured with **four neuters**, each reddening exactly its own checks — including the shipped
  bug itself (drop `checkForPendingBatch()` → 5 red). Scoped in its header: it pins the TAIL, not its two call
  sites (driving either needs a real paid submission or the un-redirectable journal path — W16.bat2-fu2);
  what keeps them aligned meanwhile is structural, each being a bare `finishInterruptedBatchPoll(); return`.
  | files: OCR/OCRProcessor+Pipeline.swift | S | low | none
- [x] **W16.bat3 — Stop during a paid batch poll DELETED the recovery journal, while the UI said it was kept
  [XS fix · HIGH].** DONE 2026-08-02 `53e43e2` + this commit. Owner-authorized 2026-08-01 (grant now marked
  discharged in `OWNER_AUTHORIZATIONS.md`). Was: `cancel()` deletes the journal **only** when every
  server-side cancellation was confirmed, and otherwise keeps it and says *"the paid-batch journal was kept
  for recovery"* — but the poll unwinding at the same time hit `guard !Task.isCancelled else { return }` in
  `pollBatchUntilComplete` and returned **silently**, so `batchPollInterrupted` stayed false and BOTH callers
  deleted the journal anyway: the first run through `performBatchOCR`'s tail, and a resume through
  `resumeBatch` (whose own `guard !Task.isCancelled` sits *below* the delete). Pressing Stop mid-poll could
  strand a paid, still-live server-side batch with no local record, and tell the operator the opposite. Both
  guards now set the flag. All four readers of it were traced first: the change is deletion-**reducing** on
  every path and adds a delete to none — the keep-on-doubt rule the grant made binding. Also extracted
  `performBatchOCR`'s inline tail to `retirePaidBatchJournalIfPollCompleted()` — same condition, statements
  and order — purely so that direction could be *driven* against a real journal file rather than read; the
  surrounding function needs a paid submission to reach. **`BatchPollCancelContract`** (driver section 17)
  adds **7 $0 checks** (`test-batch-resume.sh` 258 → 265): both cancellation exits report themselves
  interrupted (swept over `LLMProvider.allCases`; the in-the-wait one timed, to show the sleep was aborted
  rather than waited out), the first run's tail keeps an interrupted journal **and** still retires a
  completed one, and a whole cancelled `resumeBatch` leaves the real journal file on disk with the Resume
  control rendered. Discrimination **measured**: revert the two assignments and 4 of the 7 redden, including
  the journal file itself disappearing from disk. No network and no keys — both guards precede the
  `switch provider` — and the two checks that write at the shipped journal path sit behind the same
  `redirectIsInForce` verdict section 16 uses, so nothing here can reach the operator's own journal.
  Regression: `test-recovery.sh` 56/56 and `test-manifest-persistence.sh` 109/109 still ALL PASS. The
  adversarial review found no keep-on-doubt violation; three findings were folded in (an overclaimed
  discrimination in section 2, now stated as an honest limit; a hardcoded provider count; and section 3
  documented as pinning the tail's rule rather than being the regression check), and a fourth — a **fifth**
  interrupted exit in `performBatchOCR` that runs no tail at all — is filed as **W16.bat3-fu**. Unblocks
  **W16.bat6**, whose gate was this item *landing*.
  | files: OCR/OCRProcessor+OCR.swift, OCR/OCRProcessor+Pipeline.swift, OCR/BatchPollCancelContract.swift | XS | high | none
- [x] **W16.bat6 — the kept-journal warning could be overwritten by the cancelled run's own status message
  [S · LOW].** DONE 2026-08-02 `f5c9fe8` + this commit. From the W16.bat2-fu adversarial review;
  **pre-existing.** Gated on W16.bat3 deliberately — while that stood, the warning was *sometimes a lie* (the
  journal was deleted downstream anyway) and making a sometimes-lie more visible is the wrong fix order — and
  released by it landing. Was: `cancel()` cancels `processingTask` and then spawns the cancellation task that
  assigns *"the paid-batch journal was kept for recovery"*, while the run it just cancelled unwinds
  concurrently and writes `statusMessage` of its own — a status check still in flight when Stop landed
  resolves into `"Batch processing… n/m complete"` or `"Error checking batch… Retrying…"` on the way out. No
  order was guaranteed, so the one signal that a paid job may still be running server-side could be gone
  before the operator read it, with the journal on disk and nothing on screen pointing at it. **Fix:**
  `cancel()` keeps the run's task handle after dropping it, and the cancellation task awaits it before
  raising the warning — last by construction, not by luck. Only the *message* waits: the server-side
  cancellations still go out first (they stop paid work), and the Resume banner is still recomputed
  immediately — leaving it unrendered is precisely the W16.bat4 wedge — then recomputed again afterwards,
  since the unwinding run's tail may retire the journal. The wait cannot hang: that task is already cancelled
  and all seven continuations it can park on are resumed above it, so the only thing that can hold it open is
  an in-flight request running out its own `timeoutInterval` (30s status / 120s fetch). **Narrowing the
  window was rejected on the same reasoning the owner used for W16.bat5** — the clobbering write is by
  definition the one that comes back last, so a timeout on the wait would only shrink the race, not end it; a
  late warning beats a lost one. **3 new $0 checks** (`BatchPollCancelContract` section 5; `test-batch-resume`
  265 → 268), the only ones in the suite that press Stop with a **live `processingTask`** — which is exactly
  why `BatchCancelWiringContract` could prove the warning *assigned* and never *survived*. Discrimination
  **measured**: remove the await and 2 of the 3 redden. Honest limit, written into the section header: the
  window where a *real* poll writes after a Stop is inside a paid provider call (both cancellation guards sit
  above the `switch provider`), so the run is a stand-in — live, suspended when Stop lands, cancelled by the
  real `cancel()`, then writing one of the poll's own status lines on a **non-cancellable** timer so the
  losing order is certain rather than likely. Everything the fix touches is real. Adversarial review found
  one defect and it was fixed before shipping: the first draft moved `checkForPendingBatch()` behind the
  wait, which would have re-opened W16.bat4's unrendered-Resume-control wedge for as long as the unwind took.
  Also verified: no `cancel()` call site is inside `processingTask` (all five are view actions), so the await
  cannot self-deadlock, and every `Task.detached`/task-group child in the run path is awaited inline, so
  nothing outlives the run task to write afterwards. Regression: `test-recovery.sh` 56/56 and
  `test-manifest-persistence.sh` 109/109 still ALL PASS. Clean build, 0 new warnings.
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchPollCancelContract.swift | S | low | none
- [x] **W16.bat3-fu — `performBatchOCR`'s FIFTH interrupted exit ran no tail at all [S · MED].** DONE
  2026-08-02 `a2bb4b9` + this commit. From the W16.bat3 adversarial review; **pre-existing**. ⚠️ **The filing's
  stated scenario was WRONG, and the correction is part of the substance here.** It claimed
  `guard markBatchSubmissionComplete() else { return }` (`+OCR.swift`) "returns without setting
  `batchPollInterrupted`, without `isProcessing = false`" when the submission marker could not be
  persisted. Re-confirmed by symbol: it does set both. `markBatchSubmissionComplete()` delegates to
  `persistPendingBatchMutation`, whose `savePendingBatch`-failed branch already assigned `statusMessage`,
  `batchPollInterrupted = true`, `isProcessing = false` and `processingTask?.cancel()` — so that case
  reached `processFiles`'s `if batchPollInterrupted { finishInterruptedBatchPoll(); return }` all along. The
  reviewer read the guard as a plain bool and missed that the side effects live one call down.
  **The exit was nevertheless unguarded, for a different reason**: `persistPendingBatchMutation`'s *other*
  failure, `guard var candidate = activePendingBatch else { return false }`, returned with no flag, no
  message and no task cancellation — and `cancel()` nils `activePendingBatch` while a Gemini submit loop may
  still be running (the same window W16.bat5 is about), so a **Stop pressed mid-submit lands in exactly
  it**. That mattered because **nothing resets `batchPollInterrupted` at the start of a run** — the only
  `= false` in the app is inside `pollBatchUntilComplete`, which this exit never reaches — so the run's fate
  was decided by whatever the PREVIOUS run left in the flag. **Fix:** one named reporter,
  `reportInterruptedPaidBatch(_:)`, carrying the four statements the save-failure branch already ran; BOTH
  of `persistPendingBatchMutation`'s failure exits now route through it (so all three journal mutators —
  `markBatchSubmissionComplete`, `recordSubmittedBatchChunk`, `markBatchChunkConsumed` — report instead of
  returning a bare `false`), plus an explicit `batchPollInterrupted = true; isProcessing = false` in the
  fifth exit's own guard body so it cannot inherit a stale flag if a future edit adds a quiet third failure
  path. `cancel()` was NOT touched, and nothing about what gets deleted was changed — W16.bat5 was not
  started. **Keep-on-doubt verified, not assumed:** all four readers of `batchPollInterrupted` were traced
  first (`+OCR.swift`'s failure-sweep guard, `retirePaidBatchJournalIfPollCompleted`, `resumePendingBatch`,
  `processFiles`) and every one treats `true` as *keep the journal* — so the change is deletion-**reducing**
  on every path and adds a delete to none. **9 new $0 checks** (`BatchMutationReportContract`, driver
  section 18; `test-batch-resume` 268 → 277), pinning both directions: a failed mutation always reports, a
  HEALTHY one never does, and reporting removes nothing from disk. Discrimination **measured** on two
  mutants: restore the silent `return false` and 4 redden; make the reporter fire unconditionally and 1
  reddens. Honest limit, written into the contract header: the fifth exit itself needs a real paid
  submission to reach, so its explicit flag set is structural (a bare guard body), not driven — the same
  limit `BatchInterruptTailContract` records for the tail's two call sites. The stale "all four interrupted
  exits" comments in `finishInterruptedBatchPoll`, `processFiles` and `BatchInterruptTailContract` are
  corrected to five. Scratch only: the two contract sections that write a real journal sit behind the same
  `redirectIsInForce` verdict sections 16/17 use, and FAIL loudly rather than skip if it is not in force.
  Regression: `test-recovery.sh` and `test-manifest-persistence.sh` still ALL PASS. Clean build, 0 new
  warnings. **A new HIGH money-path finding came out of the adversarial pass and is FILED, not fixed:
  `W16.bat7`** — four *other* silent exits in `pollBatchUntilComplete` that delete the journal when results
  fail to persist. It is owner-gated (plan HOLD QUEUE), not a follow-up to this item.
  **SECOND READ, folded in same-day (third commit).** An independent adversarial agent returned after the
  first two commits had landed. It confirmed the change SOUND on all eight questions put to it — no new
  deletion on any path, the four flag readers are the complete set, the new `statusMessage` writes cannot
  race W16.bat6's kept-journal warning (every reporter call site is inside the run task, so all of them
  precede `await interruptedRun?.value`), and the Swift 6 isolation is correct — and found six issues, four
  of them defects in what had just shipped, fixed here rather than filed:
  **(1) MED, VACUITY — section 2's "the marker was persisted" check was self-fulfilling.**
  `PendingBatch.init` defaults `submissionComplete` to **`true`** and the fixture omitted it, so the
  assertion was already true before the mutator ran: neuter `markBatchSubmissionComplete`'s mutation closure
  to `{ _ in }` and both of its checks stayed green. The fixture now passes `submissionComplete: false`,
  with the reason written above it, and that mutant reddens 1. This is the one that mattered — a vacuous
  check on the money path is worse than none, because it reads as coverage.
  **(2) MED, NEW BEHAVIOUR — the reporter could cancel the WRONG run.** `processingTask?.cancel()` was
  reachable from the post-Stop exit, which is by construction the unwind: `cancel()` has already nil'd
  `processingTask`, and a confirmed cancellation deletes the journal `startProcessing` refuses on, so the
  operator can legitimately start a NEW run while this one is still resolving a 30–120s provider request.
  The stale run would then cancel the new run's task and reset its state underneath it.
  `reportInterruptedPaidBatch` now takes `cancelRun:` and the post-Stop exit passes `false`; a new section 2
  drives the reporter directly to pin BOTH directions (a LIVE run that cannot persist its journal is still
  cancelled — the submit loop must not keep spending after the app gives up). Neutering the cancel reddens 1.
  **(3) LOW, OVERCLAIM** — the header's "a mutator returning `false` has ALWAYS reported" was false:
  `recordSubmittedBatchChunk`'s input-validation guard still returns `false` silently (benign — both call
  sites throw into a catch that sets the flag). Now an explicit carve-out rather than quietly wrong.
  **(4) NIT** the skip message said two checks were skipped when four are; **(5) NIT** half of
  `leftTheRunAlone` was trivially true (it re-asserted a nil the fixture had just set) and is now a
  resume-banner sentinel, which catches a reporter that starts doing `finishInterruptedBatchPoll()`'s job.
  Checks 277 → 279, still ALL PASS, and the item's original two mutants still redden 4 and 1.
  **(6)** Its last point corrected **W16.bat7**'s scope rather than this item — that filing is revised
  HIGH → MED, because this change closed its dominant trigger. One further finding of its own is filed as
  **W16.bat3-fu2** (after a Stop, the submission-failure message is doubly wrong).
  | files: OCR/OCRProcessor+OCR.swift, OCR/OCRProcessor+Pipeline.swift, OCR/BatchMutationReportContract.swift, OCR/BatchInterruptTailContract.swift, Capture/BatchResumeTestDriver.swift | S | med | none
- [x] **W16.bat5 — Stop mid-submit could delete the journal while a later Gemini chunk was already paid for
  [S · HIGH · money].** DONE 2026-08-02, this commit. Owner-authorized 2026-08-01 **with the fix direction
  chosen by him** (grant now marked discharged in `OWNER_AUTHORIZATIONS.md`). Was: `cancel()` snapshots the
  batch's chunk IDs once, nils `activePendingBatch`, and its cancellation task deletes the recovery journal
  if **every** chunk in that snapshot confirms. A Gemini submit creates its server-side jobs one at a time,
  so a chunk created *after* the snapshot is already billed, its ID is journaled nowhere (the nil
  `activePendingBatch` makes `recordSubmittedBatchChunk` fail), and the journal — the only local trace of
  the run — is deleted on top of it. **Pre-existing**; found by the W16.bat2 adversarial review.
  **Fix — the in-flight guard the owner specified, not the re-read he rejected.** The invariant is *a submit
  is in flight ⇒ the journal survives*, and the flag bracketing the submit loop already existed: the
  journal's own `submissionComplete`, written `false` before the first provider create request and flipped
  true by `markBatchSubmissionComplete()` after the last. A new pure predicate
  `batchSubmissionIsInFlight(_:)` reads it; `cancel()` evaluates it **synchronously, before dropping
  `activePendingBatch`**, and hands the answer to `performServerBatchCancellation`, which now keeps the
  journal on a fully confirmed cancellation whenever a submission was in flight. Reusing the durable flag
  rather than adding a process-local bool is deliberate: there is no new set/clear pair for a later edit to
  forget, and it cannot fall out of sync with the submission it describes. Reading it at Stop time (not in
  the cancellation task) is what makes it a rule and not another race — by the time that task runs the
  submit has aborted and a late read would answer "finished" and delete. `submissionInFlight` is a
  **non-defaulted** parameter, so no future caller can omit it. The known chunks are still cancelled — the
  guard keeps the journal, not the money — and the operator gets a **distinct** message
  (`batchCancellationSubmissionInFlightMessage`): "we stopped everything we knew of, and there may be more"
  is not "we could not stop it". **Deletion-reducing only, and deliberately conservative:** a journal whose
  submission never completed reads as in-flight for the rest of its life (including across a resume), so a
  few Stops that used to delete now keep. That is the intended reading — an unfinished submission means the
  set of paid jobs is unknown, so confirming the known ones proves nothing about the rest — and the cost is
  one press of the existing Resume/Dismiss banner's Dismiss (`OCRView.swift:331`), which every unconfirmed
  Stop already required. `confirmed && !journalDeleted` is now a reachable outcome, documented as such on
  `BatchCancellationOutcome` so no reader mistakes `confirmed` for "the file is gone". **20 new $0 checks**
  (`test-batch-resume.sh` 277 → 297): the predicate against literals, a named mid-submit Stop in both the
  rule (`BatchCancelContract`) and the wiring (`BatchCancelWiringContract`), and the in-flight dimension
  folded into **both** sweeps rather than sampled — the rule sweep 132 → **264** trials (8 real deletions,
  every one in the finished-submission half) and the wiring sweep 80 → **120** Stops (10 real deletions,
  110 real keeps). Discrimination **measured** on two mutants: hard-code `submissionInFlight: false` at the
  `cancel()` call site — the fix reduced to a silent no-op — and **7** redden, all in the wiring half, the
  sweep naming the exact shape (`Anthropic/1 chunk/journal mid-submit/none refused`); kill the rule's
  branch and **15** redden across both halves. Every named check has a non-vacuity twin: the same Stop with
  `submissionComplete` true still deletes. Scratch only — no check here touches the shipped journal path
  (both contracts stub the deleter and delete a temp fixture), no network, no keys, no cent. Regression:
  `test-recovery.sh` 56/56 and `test-manifest-persistence.sh` 109/109 still ALL PASS. Clean build, 0 new
  warnings. **The adversarial pass confirmed the guard sound on all six questions put to it** — no path
  where a submit is genuinely in flight and the predicate says otherwise (the Gemini submit loop is
  strictly sequential, nothing detached, and `activePendingBatch` is assigned one line before `activeBatch`
  with no suspension between, so `cancel()` can never see a live batch without its journal); a resumed
  batch never creates a new chunk, so the guard cannot be evaded through resume; no production reader of
  `.confirmed`/`.journalDeleted` at all; and not the rejected direction, because `cancel()` is non-`async`
  so the read and the decision are one uninterrupted MainActor turn. It also verified no wedge: a kept
  journal stays self-consistent, renders the banner, and is escapable by **both** Dismiss and a Resume that
  terminates (a server-cancelled chunk is a *completed* provider state). **Three findings were fixed here
  rather than filed.** (1) MED — the operator message was factually WRONG in two reachable shapes: a Stop
  during a RESUMED batch whose original submission never completed (resume is GET-only, so nothing is being
  submitted and nothing is created after the Stop), and a submit that finished but whose marker write
  failed. It now states the unfinished *record* rather than a time — the same class of defect the repo
  already tracks as W16.bat3-fu2. (2) `confirmed`'s own doc still asserted the strong reading this change
  invalidates, one line above the ⚠️ warning about it. (3) The predicate is a **superset** of "a create is
  happening right now" and the doc denied it; the breadth is correct and is now written down, along with
  the Anthropic/Mistral case where the keep is uniformity rather than safety. **One residual is FILED, not
  fixed: `W16.bat5-fu`** — the journal this now keeps still does not list the chunk paid for after the
  snapshot, because `cancel()` has nil'd `activePendingBatch` by the time that chunk's callback runs.
  Inherent to the direction the owner chose, out of scope for this grant, and owner-gated on the same
  precedent as W16.bat7.
  | files: OCR/OCRProcessor+Pipeline.swift, OCR/BatchCancelContract.swift, OCR/BatchCancelWiringContract.swift | S | high | none
- **Split out as its own LOW entry (tracked in `ArchiveProcessor/KNOWN_ISSUES.md`, NOT queued):** *lost-create
  reconciliation* — if a provider accepts a create POST and the response is lost, the app records the ambiguity
  honestly but cannot list the provider's batches to re-adopt the orphan. Cost is one batch's spend possibly paid
  twice. Building auto-adoption needs **live paid API calls** against each provider's list endpoint (outside the
  daemon's envelope) for a failure mode **never observed here**; the non-idempotent retry policy already stops the
  app from creating the duplicate itself. Ship the operator doc note (in W16.bat1) instead; build only if a
  lost-create event is ever actually observed. ✅ **The doc note shipped with W16.bat1** (`ArchiveProcessor/README.md`
  §"Batch Processing → If a batch submission reports an uncertain outcome"): it quotes the exact in-app message,
  says do **not** press Resume before checking the provider's own console, links all three consoles, and separates
  this from the benign *"stopped after N server jobs"* message. The reconciliation itself stays unbuilt by decision.
- [x] **W16.bat5-fu — the journal `W16.bat5` keeps now lists the chunk paid for after the snapshot too
  [S · MED · money].** DONE 2026-08-03, this commit (checkpoint `bf8365e`). ✅ Owner-authorized 2026-08-02
  with the fix direction chosen by him: **let a post-Stop chunk ID still reach the journal.** The residual of
  the direction he chose for `W16.bat5`, not a defect in it — `cancel()` had nil'd `activePendingBatch` by
  the time a late `onJobCreated` ran, so `recordSubmittedBatchChunk` hit `persistPendingBatchMutation`'s
  missing-journal guard, reported the interruption and returned `false` with the ID written **nowhere**; the
  operator was warned and sent to the provider console for a paid job the app could neither cancel nor
  collect. **Fix:** `cancel()` now records a `ClosedPaidBatchJournalAddress` — identity only (`submittedAt` +
  `runFingerprint`), deliberately **not** a snapshot that could be written back — immediately before it nils
  `activePendingBatch`, and a late `recordSubmittedBatchChunk` re-reads the file and appends its ID through
  the production writer (so the comma-joined mirror and the lifecycle fingerprint are recomputed as the live
  path recomputes them). **Both halves are load-bearing:** the ID lands in the list `resumeBatch` polls, AND
  the mutator still returns `false`, so the Gemini callback still throws and the submit loop still stops
  creating paid jobs — a Stop that recorded the ID and then kept spending would be worse than the bug. Four
  refusals keep it ADDITIVE (the grant's ⛔): a live journal in memory (the normal persist path owns the
  file); no file on disk (a confirmed cancellation deletes it, and re-creating it would resurrect a Resume
  banner and lock `startProcessing` out); a journal whose identity is not this batch's (after a delete the
  operator may have started another run — a stranger's ID would have its poll fetch another run's pages);
  and a legacy pre-lifecycle journal, whose IDs are read from the comma-joined `batchId` so an append there
  would be written and never read back. ⛔ **Stop stays instant** — nothing added waits, the load+save is one
  uninterrupted MainActor turn (so the cancellation task's own delete cannot land between them), and the
  quiesce-before-nil variant the owner rejected is not present; the constraint is **measured**, not argued.
  Tier-2, scratch only: new `BatchClosedJournalAppendContract` (driver §22, 20 checks) drives the real
  `cancel()` with both cancel-path seams stubbed and then the real mutator against a real journal at the
  redirected path — **360 checks ALL PASS**, clean build, 0 new warnings. **Non-vacuity measured on nine
  mutants**, each killed by the check it targets: no-append (pre-fix) → 4 FAIL incl. the regression check;
  no identity check → foreign-journal; overwrite-instead-of-append → 3 FAIL; resurrect a deleted journal →
  creates-none; `return true` → stops-spending; drop the legacy guard → legacy; write behind a live journal →
  live-journal; synthesize an address from disk → no-address; hand-rolled write bypassing the writer → 2 FAIL.
  **The adversarial pass found one real gap, fixed here rather than filed:** the checks proved the ID was *in
  the file* but not that Resume would *offer* the file — `checkForPendingBatch()` runs every journal through
  `pendingBatchIsSelfConsistent`, three of whose clauses an append can break, so a plausible hand-rolled
  write would have produced a journal the app then refuses (mutant 9 confirms). Section 5 now pins the app's
  own verdict. It also caught **two checks passing for the wrong reason** — the legacy and live-journal
  fixtures were refused at the missing-file/identity guard before reaching the guard they name (measured:
  deleting those guards left them green) — both fixtures now share the stopped batch's identity and put a
  matching journal on disk, and the header records the trap. `ArchiveProcessor/README.md` §"If a batch
  submission reports an uncertain outcome" updated: a Stop mid-submit now normally lands in the benign
  "Resume can pick the batch up" bullet.
  | files: OCR/OCRProcessor.swift, OCR/OCRProcessor+Pipeline.swift, OCR/OCRProcessor+OCR.swift, OCR/BatchClosedJournalAppendContract.swift, Capture/BatchResumeTestDriver.swift, README.md | S | med | **AUTHORIZED 2026-08-02 — discharged**
- [x] **W16.bat4-fu — one interrupt-tail banner check went reliably vacuous when the journal path became
  redirectable [XS · LOW].** DONE 2026-08-02, this commit. From the W16.bat2-fu2 adversarial review.
  `BatchInterruptTailContract`'s "the recomputed banners are what `checkForPendingBatch()` alone produces"
  compared a tailed processor's two banners against a fresh one's — but since the redirect both sides read the
  harness's **empty** state directory, so it was permanently `nil == nil && nil == nil`. It still caught a tail
  that assigned a placeholder of its own; it no longer distinguished a correct banner from an empty one.
  (Before the redirect it was meaningful exactly when the operator happened to have a manifest on disk — i.e.
  never on purpose.) **Fix — give the read something to find.** The comparison moved out of
  `theResumeControlAppears` into its own gated section, `theRecomputedBannersAreARealRead`, which writes a real
  self-consistent `pending_batch.json` (through the PRODUCTION `savePendingBatch`, so the lifecycle fingerprint
  is stamped) and `pending_run.json` at the SHIPPED URLs first. Two hazards the first draft would have walked
  into and did not: `runFingerprint` is load-bearing — `fingerprintVersion` defaults to **2**, whose
  self-consistency arm rejects a manifest with no stored identity outright, so an unstamped fixture renders the
  *torn/tampered* banner instead of the healthy one (this is what the first run of the new check actually
  caught) — and it is computed from the shipped `runFingerprint(…)` with the arm's own arguments rather than
  typed out. **3 new $0 checks** (`test-batch-resume.sh` 297 → 299 net, one check having moved): the banners
  carry the fixture's own details (fragments built from the fixture's fields, and the label carries the actual
  banner text on a red so a stale fixture cannot read as a broken tail); the comparison itself, now guarded by
  `!= nil` on both sides so it can never decay to `nil == nil` again; and — newly assertable, closing half of
  this file's own scope note — **neither durable journal at the SHIPPED path is removed by the tail**, which is
  what a `deletePendingBatch()` added "to tidy up" would do, stranding a paid job. **Money-path safety:**
  writing at the shipped path is gated on the driver's existing `redirectIsInForce` verdict (same gate as
  sections 16–18), a refused run FAILs three named checks rather than silently skipping them, and both files
  are restored byte-for-byte (or removed again) on the way out so sections 16–18 find the directory as they
  left it. Verified after every run that `~/Library/Application Support/ArchiveProcessor/` holds neither
  journal and was never written. **Discrimination measured on four mutants:** the tail assigns a placeholder →
  1 red (the value the old check did carry, preserved); the tail calls `deletePendingBatch()` → 2 reds *in this
  section* where it previously caught **nothing**; the fixture removed before the read, i.e. the exact
  pre-fix empty-directory state → **3 reds**, which is the regression proof that the check can no longer be
  vacuous; and the original W16.bat4 bug (no `checkForPendingBatch()` in the tail) → 6 reds, confirming the
  primary regression checks survived the restructure. Regression: manifest-persistence 109/0, merge-safety
  15/0, tagwarn 74/0; clean Debug build, 0 new warnings. No production change — the only non-comment edit
  outside the contract is the driver passing it the redirect verdict it already computes.
  | files: OCR/BatchInterruptTailContract.swift, Capture/BatchResumeTestDriver.swift | XS | low | none


## Wave 19 — Notes date-mirror + Quality facet (MERGES/replaces Priority) (owner-reviewed 2026-07-18)

- [x] **W19.q1 — SPEC: the Quality facet + Notes-as-date-emitter.** DONE `06fabcc`, **merge revision** 2026-07-18
  — `SPEC/tag-format.md` now defines Quality as the single rating facet that supersedes Priority (Priority row →
  RETIRED + read-alias `P8`–`P10`→`Q1`–`Q3`, `P7`→unrated; `Q3`=old `P10`), records the companions as `Q` emitters
  + the phone↔Mac protocol as a SHARED HOTSPOT, and keeps the Notes date-projection row. Source of truth for q2–q7. | Tier-2 (SPEC) | S


## Notes test hardening (from the 2026-07-29 health-gate RED)

- [x] **W23.flake1 — de-flake `NoteBodyEditorModelTests.supersededLoadIgnored` (it RED'd the health gate).**
  The 2026-07-29 19:10 periodic gate went **RED on Notes** (708 passed / **1 failed**) and then **GREEN on the
  daemon's retry against the identical commit `baa970a` with a clean tree** — same code, different result, i.e.
  nondeterminism, not a regression. Cause: the test raced the two selections with `async let first = m.select(a)`
  / `async let second = m.select(b)`, but **Swift does not specify which child task starts first.** When B started
  first the model did the *correct* thing — B loaded, then A superseded it as the genuinely newest selection and
  won — so the assertions (`loadedID == b`) failed spuriously with
  `Expectation failed: (m.loadedID → …) == (b → …)`. **`NoteBodyEditorModel` was never at fault; the supersede
  guard (monotonic `loadGeneration` re-checked after each `await`) is correct and is unchanged by this item.**
  Fix (test-only): order the race deterministically — start A's slow `select` in a `Task`, spin on
  `Recorder.loadCount` (bumped at the top of `load` *before* its sleep) until A is parked mid-load with
  generation 1 captured, and only then `await m.select(b)`; assert `loadCount == 1` so a never-set-up race fails
  loudly instead of vacuously passing. Also **added `slowUnsupersededLoadStillWins`**, which pins the mirror
  ordering the old test hit by accident (a slow load that nothing supersedes must still win) — so the generation
  guard is now proven to drop *superseded* loads only, never merely late ones. Net: the hazard keeps its coverage
  and gains the complement. Verified: `NoteBodyEditorModelTests` **30/30 consecutive** runs green; full
  `ArchiveNotesTests` bundle green (710 tests, was 709); test bundle builds with **0 new warnings**. Rarity is why
  it surfaced only now — pre-fix, the single test passed **25/25** in isolation and the full bundle **4/4**, so
  the gate's retry-once is what caught it. Tier-2 not triggered (no product code touched, no write path changed).
  ⚠️ **Follow-up left open on purpose:** `NoteBodyEditorModel.flushPending`'s doc comment justifies keeping
  `select`'s flush sequence *inline* because "the extra async frame ... perturbs the actor scheduling its
  superseded-load race relies on" — that rationale was resting on the flaky test and is now stale. Whether
  `select` should call `flushPending()` instead of duplicating the sequence is a real (small) Tier-2 refactor
  decision on a note-body write path, so it is **not** bundled here.
  | files: ArchiveNotes/macOS/Tests/ArchiveNotesTests/NoteBodyEditorModelTests.swift | S | low | none | done


## W21 — GUI lane generalization + small hygiene (owner-reviewed 2026-07-28)

- [x] **W21.screen — the daemon must never draw on the owner's screen [M]** — **DONE 2026-07-30** (owner
  reported the daemon running a GUI test on their display mid-morning). Root cause was **not** a rogue GUI
  command: both unit bundles are **app-hosted** (`TEST_HOST = the .app`), so the routine
  `xcodebuild test -only-testing:<App>Tests` the daemon runs on nearly every session **launched the real app**
  and parked a window on the owner's screen — measured from the health gate's `.xcresult`: **Reader 2m52s,
  Notes 49s**, every session and every gate. The guardrails all aimed elsewhere, and two asserted the
  opposite ("plain unit tests … no VM, no window"). Four layers shipped:
  1. **Source fix** — ArchiveCore `ArchiveTestHost`: under `XCTestConfigurationFilePath` the app sets
     `activationPolicy(.prohibited)` and every auto-opening `Window` renders `HiddenWindowStub` instead of its
     real content (the branch lives in the `ViewBuilder`, because `SceneBuilder` has no `buildEither`). Pinned
     by `TestHostWindowSuppressionTests` in **both** suites. Side effect: with no UI to build, the Reader unit
     suite went **172s → ~2s**.
  2. **Enforcement** — `.claude/hooks/no-host-gui.sh` (PreToolUse/Bash, live when `ARCHIVE_UNATTENDED=1`, which
     the daemon now exports) hard-DENIES host UITest runs, `launch.sh`/`gui-drive*`/`capture-window.sh`/
     `cliclick`/`osascript`, a windowed Android emulator, and the iOS Simulator — each denial naming the VM
     route. Interactive sessions unaffected. Harness: `ops/autonomous/tests/prove-no-host-gui.sh` (24 cases).
  3. **Honesty** — the GUI-VM gate had been reporting `✓ gui-vm` for a lane that ran **zero** tests since
     2026-07-28: `tart ip --wait` returns on *networking*, but `tart exec` needs the Tart Guest Agent's vsock
     socket, which comes up later, so every exec failed and the gate fail-opened with `exit 0`. Fixed both
     halves — poll `tart exec true` until the agent answers, and exit **3 = SKIPPED** so `health-gate.sh`
     prints `⊘ … SKIPPED — <reason>` and `— but NOT VERIFIED:` instead of a checkmark.
  4. **Coverage** — `gui-vm-gate.sh` generalized to a per-app table and now runs **Reader + Notes** UITests in
     the VM (`AUTONOMOUS_GUI_VM_APPS`), builds each app's fixture in the guest, mounts the gitignored fixture
     corpus as its own `corpus:` share (so it works from a worktree), and wipes the guest Notes container
     before each run (the `organization.json` INDEX-DB caveat).
  5. **Second escape, same morning — the wrapper-script hole.** With all of the above shipped, a daemon
     session still put `ArchiveNotesUITests` on the owner's screen by running `./ArchiveNotes/test-smoke.sh`:
     the hook matches the Bash **command string**, and that string contains no `xcodebuild` and no
     `-only-testing`, while the script's own whole-scheme `xcodebuild test` includes the UITest bundle. The
     repo's own loop step 2 ("run the touched app's smoke test") pointed straight at it. Closed with two
     layers a string matcher can't provide: both `test-smoke.sh` scripts now run **only the unit bundle**
     under `ARCHIVE_UNATTENDED=1` (so the documented command is *correct*, not just blocked), and
     `ops/autonomous/bin/xcodebuild` — a **PATH shim** the daemon prepends — refuses any `test` action
     without `-only-testing:` at any nesting depth. Hook pattern added too, as the fast third layer.
  7. **Generalization pass across the whole suite (2026-07-30).** Audit of every app + script, not just the
     two touched: the Processor's `scripts/test-smoke.sh` **launches the app with `open` and drives it with
     `osascript`** and had no unattended guard; the **health gate runs in the daemon LOOP**, where no hook
     applies and the session env is out of scope, so `AUTONOMOUS_GATE_OCR=1` would have opened the Processor
     on the owner's screen with nothing in the way; and the PATH shim covered **`xcodebuild` only**, leaving
     the wrapper hole open for every other mechanism. Fixed: `ops/autonomous/bin/` is now one shim per
     screen-reaching binary (`xcodebuild`/`open`/`osascript`/`cliclick`/`emulator`), the gate declares
     `ARCHIVE_UNATTENDED=1`, and the Processor smoke skips its launch step unattended. Clean by comparison:
     `android-ui-drive.sh` already boots the emulator `-no-window`, and all three `launch.sh` are hook-matched.
     A FORWARD tripwire in `prove-vm-lane.sh` (48 checks) now fails any app whose `project.yml` declares an
     app-hosted unit-test bundle without adopting `ArchiveTestHost` — verified to actually fire against a
     synthetic app, so the Processor is covered the day it gains a test target.
  6. **Adversarial audit of the whole lane** (2026-07-30) — 14 findings raised, 5 survived refutation, all
     fixed here: the warn tier had reintroduced the silent green (a reproducibly-failing suite exited 0 and
     printed `✓ gui-vm` with the failure list discarded → now **exit 4 = WARN**, rendered as `⚠ KNOWN
     FAILURES` with the test names, and detail kept in `gui-vm-<app>-LAST-FAILURE.log`); the fixture was
     built only when absent although the suite **mutates** it (→ rebuilt every run; this alone was two of
     the "Notes failures"); no lock around a single shared VM (→ `tart_lock_*`, and the VM is only stopped
     by whoever booted it); plus the runner's two. New harness `ops/autonomous/tests/prove-vm-lane.sh` (31
     checks) pins the exit-code→owner-text mapping, the lock, the shim and the smoke-script guards.
- [x] **W21.vmgui-path — `vm-gui-runner.sh` blames a missing VM when `tart` is merely off PATH [XS · repeat
  cost].** ✅ **DONE 2026-07-31** (this commit, owner's Morning Review walkthrough). Fixed **in
  `ops/gui/tart-lib.sh`**, not in the runner, because that is where the split caused it: the gate carried its
  own `export PATH=/opt/homebrew/bin:$PATH` (`gui-vm-gate.sh:35`) and the runner did not, so the *interactive*
  entry point every doc points a session at was the only one that could be lied to — the second instance of
  the exact duplication `tart-lib.sh` was created to end. The lib now (a) prepends the first
  `$TART_SEARCH_DIRS` entry that actually holds an executable `tart`, only when PATH lacks one, and (b)
  exports `tart_require`, which reports *"tart is NOT INSTALLED or not on PATH — this is not the same as the
  VM being missing"* with the dirs searched and the PATH it saw, and deliberately makes **no claim about the
  VM** (it cannot run `tart list` to find out). Both call sites now separate the two: the runner dies with
  *"tart is installed, but VM '…' does not exist"* only when tart really is present, and the gate SKIPs with
  two distinct reasons. `TART_SEARCH_DIRS` is one list feeding both the search and the message, so the
  message cannot claim to have looked somewhere it did not. **Proved, not assumed:** `bash -n` on all three
  scripts; under `env -i PATH=/usr/bin:/bin` the lib still resolves `/opt/homebrew/bin/tart` and
  `tart_require` returns 0; with `TART_SEARCH_DIRS=/nope/a /nope/b` it returns 1 and prints the
  not-installed text with the searched dirs echoed back. No VM boot needed for either check.
  Previous text: `ensure_vm()` did `tart list 2>/dev/null | … || die "VM 'archive-gui-runner' not found — create it
  first"`, so in a plain non-interactive shell (no `/opt/homebrew/bin` on PATH) it reports the VM as absent
  while the VM is present and healthy. **This has now cost three daemon sessions** (W23.m14, W23.m15, W23.l4 —
  each logged it to Morning Review, one lost a whole lane run), which is why it is a queue item and not a
  fourth note. **Fix:** resolve `tart` by absolute path (or prepend `/opt/homebrew/bin` inside the script), and
  split the two failures in the message — "tart not found on PATH" vs "VM not created (ops/gui/README.md §3)".
  A misleading message here is expensive in a specific way: a session that believes it defers a GUI check to
  the owner that it could have run itself. Same treatment for any sibling `tart` call in `ops/gui/tart-lib.sh`.
  | files: ops/gui/vm-gui-runner.sh, ops/gui/tart-lib.sh | XS | low | none
- [x] **W23.status1 — `daemon.sh status` blamed an empty queue for what was a usage cap [XS · misreport].**
  ✅ **DONE 2026-07-31** (this commit, owner's Morning Review walkthrough). For an hour that morning both
  status renderers said *"running, BACKING OFF (idle 3375s — sessions finding no actionable work)"* while
  every session since 06:35 had been **refused with a 429** (five-hour cap, reset 07:30) and died in ~5
  seconds, with `next-queue-item.sh` offering ~20 actionable items throughout. The 429 was sitting in
  `$STATE/last-session.log` the whole time; neither renderer read it. **The two states demand opposite owner
  actions** — "the queue is drained, add work or stop the daemon" vs "it is throttled and resumes by itself"
  — so this is a misreport, not a wording nit; it is the same family as the `last-gate.log` trap in memory
  `health-gate-red-retry-once`. **Fix:** new `ops/autonomous/run-state-lib.sh` owns the question, sourced by
  BOTH `daemon.sh` and `status-digest.sh` (writing the check twice is how the tart-PATH trap survived three
  sessions — see W21.vmgui-path, fixed the same day). Keyed on the **terminal** `"api_error_status":429`, not
  on a `rate_limit_event`, so a session that was warned, recovered and did work is not slandered as
  throttled; `resetsAt` distinguishes *"resets 09:21"* from *"already reset 07:30 — next attempt should get
  through"*. Reporting only — the BACKOFF **behaviour** is already correct for a cap, so no control flow
  changed. Both call sites degrade to the old wording if the lib is absent, which is the real window while
  the PRIMARY checkout has not yet merged (memory `arm-installs-from-primary-checkout`). **Proved:** `bash -n`
  ×3; the detector returns throttled for the real 06:35 log and NOT for the real aborted 07:58 log, a
  synthetic future reset renders "resets HH:MM", a warned-but-successful session and a missing file both
  return not-throttled; then end-to-end through the real `status-digest.sh` with a stubbed `pgrep`, printing
  THROTTLED and BACKING OFF from the two real logs respectively.
  | files: ops/autonomous/run-state-lib.sh (new), daemon.sh, status-digest.sh | Tier-2 | XS


## Suite doc hygiene (owner / small) — 2026-07-16

- [x] **Archive Notes `00-overview.md` — RESOLVED 2026-07-29 (owner): KEEP IT PERMANENTLY as the Notes interface
  spec. This item is CLOSED — do not re-open it as a doc-hygiene task.** `00-overview.md` is deliberately exempt
  from the "delete a shipped `execution-plans/` plan" convention: that convention targets *stale* plans, and this
  file is not stale — it is the live, load-bearing interface contract for Archive Notes, cited **65 times across 38
  tracked files** (mostly source and test comments), which `ArchiveNotes/CLAUDE.md` now states explicitly. Deleting
  or relocating it would mean rewiring 65 references inside shipped code for zero functional gain. Left in place at
  its current path by owner decision; it was NOT promoted to `SPEC/` (that would make every future edit hold-queue
  and owner-gated — an ongoing tax on a Notes-internal document). Evidence for the decision below.
  - **History.** Originally "fold §16 into `CLAUDE.md`, delete the plan" [S]. The 2026-07-18 review found that
    under-scoped and re-estimated it as "§2/§5/§6/§16, ~190 lines, 8+ citation sites". On **2026-07-29** the owner
    picked that fuller scope — but a `git grep` census then showed **that estimate is also wrong, by a lot.**
  - **Measured reality (2026-07-29, `git grep`):** the file is cited **65 times across 38 tracked files**, spanning
    **31 distinct sections** — §2, §3.1, §3.2, §3.3, §3.4, §3.6, §3.7, §5, §6, §7, §8.2, §8.3, §8.4, §9, §10, §13,
    §15.1, §15.3, §15.4, §15.5, §16, §16.1, §16.3, §D.1–§D.6, plus D2/D9. Citations are **not** doc-to-doc: most are
    source and test comments (`NotesModel.swift`, `MarkdownBridge.swift`, `FrontMatterCodec.swift`, `ZoteroClient.swift`,
    `NotesGUITests.swift`, `DurableLinkE2ETests.swift`, `e2e-durable-links.sh`, `packages/ArchiveCore` parity tests…),
    and it is also cited by `POTENTIAL_FEATURES.md`, `09-gap-closure.md` and `devonthink-import.md`.
    Note `§2` is **not** cited by `ArchiveNotes/CLAUDE.md` at all (that claim was wrong) — it is cited from
    `POTENTIAL_FEATURES.md` and `SUITE_TODO.md` instead.
  - **The repo already treats it as a spec, not a lingering plan:** this very file says it is "**RETAINED** as the
    authoritative interface contract" (L96) and cites `00-overview.md §2` for the locked D1–D10 decisions (L1101).
  - **RECOMMENDATION: keep it permanently and close this item.** The "delete a shipped execution plan" convention
    exists to stop *stale* plans lingering; this one is not stale — it is the live interface contract for Notes and
    is load-bearing in 38 files. Deleting it means rewiring 65 citations across source, tests, scripts and three
    other docs, for no functional gain and a real risk of breaking references. If kept, the right small tidy is to
    **rename/relocate it out of `execution-plans/`** (e.g. `ArchiveNotes/INTERFACE-CONTRACT.md`) so its status is
    obvious and the doc convention is honoured — that is a ~1-line-per-citation path update, still 38 files.
  - **Decide one:** (a) keep permanently, close this item, optionally note in `ArchiveNotes/CLAUDE.md` that
    `00-overview.md` IS the interface spec [recommended]; (b) keep the content but relocate it out of
    `execution-plans/` and update all 65 citations [M–L, mechanical]; (c) genuinely delete it — relocate all 31
    cited sections into `ArchiveNotes/CLAUDE.md` and rewire 65 citations [L, and `CLAUDE.md` becomes very large];
    (d) promote to `SPEC/` — ⚠️ this makes it a cross-app contract and therefore **hold-queue** for the daemon
    thereafter, which is a real ongoing cost for a Notes-internal document.
- **Worktree hygiene (standing rule, not a to-do).** The 4 stray `suite-wt-2026071[45]-…` worktrees this note
  used to list are **gone** (cleaned 2026-07-16) — don't go looking for them. Standing rules: remove your own
  worktree once your work is pushed, and **never touch a worktree you didn't create.** In particular **IGNORE the
  Codex worktree** — `~/Documents/GPT/archive-suite-processor-fixes` (branch `wt/codex-processor-bugfixes-*`) is
  a different agent's and routinely holds uncommitted WIP: do not clean it, remove it, salvage it, or surface it
  to the owner as a stray. Leave it entirely alone (owner instruction 2026-07-16; also in `AGENTS.md`).


## Owner GUI-pass follow-ups — 2026-07-16 (from the interactive Reader + Processor GUI review)

- [x] **Guided key setup for Anthropic (Processor).** The onboarding wizard's `onboardable` list is
  `[.gemini, .mistral, .openai]` — Anthropic has only a manual key field. Add `ProviderKeySpec.anthropic`
  (console.anthropic.com deep links, `sk-ant-` precheck, cost/privacy notes) so Anthropic gets the same guided flow.
  **Verify:** drive the wizard with `ops/gui/capture-window.sh` + `cliclick` and read the shot — the visual half is
  no longer owner-gated (TCC granted). | files: Models/ProviderKeySpec.swift (+ `onboardable`) | S | low | none
  — ✅ shipped: `ProviderKeySpec.anthropic` added (mirrors the `.openai` spec — console.anthropic.com deep
  links for keys/billing/privacy, `sk-ant-` precheck, honest no-free-tier cost/privacy/card notes; URLs +
  wording `// VERIFY`) and prepended to `onboardable` → `[.anthropic, .gemini, .mistral, .openai]` (enum order,
  Anthropic is the lead provider). The item under-scoped its file list: the spec's `validate` closure needs a
  validator, so **`KeyValidator.validateAnthropic`** was also added (cheap `GET /v1/models` with
  `x-api-key`+`anthropic-version: 2023-06-01` — matching the app's Anthropic OCR clients; 200 works / 401·403
  invalidKey / 429 rateLimited / 5xx providerBusy; like OpenAI, /v1/models 200s even for an unfunded account →
  live smoke surfaces that). Keychain account = `LLMProvider.anthropic.rawValue` ("Anthropic"), so the wizard
  writes the same slot the app reads. The wizard is fully generic (the only provider-specific branch,
  `geminiRegionWarning`, returns nil for Anthropic — same as OpenAI). Additive + opt-in; no default-provider
  change. Build clean, 0 new warnings; Tier-1 self-review. **GUI visual (wizard "Set up (guided)…" → Anthropic
  step) → Morning Review** (GUI off this run).
- [x] **OpenAI LLM rotation detection (Processor).** `.openai` is wired to LOCAL Vision rotation only
  (`LLMRotationDetector.swift:72` + `CostEstimator.rotationModelCost` return nil — defensive, like Mistral/gateway).
  OpenAI is a capable vision model, so wire `.openai` into the LLM candidate-compare rotation path + add its
  `rotationModelCost` arm, matching Anthropic/Gemini (keep local Vision as the free default; Mistral genuinely can't
  → leave nil). | files: OCR/LLMRotationDetector.swift, Models/CostEstimator.swift, OCR/OCRProcessor+OCR.swift | M | low | none
  — ✅ shipped: `.openai` wired into the LLM candidate-compare rotation path — extended the `LLMRotationDetector`
  provider guard + added `askOpenAI` (OpenAI vision chat: `image_url` data URLs, Bearer auth,
  `choices[0].message.content` parse; endpoint via `OpenAICompatibleClient.openAIBaseURL`) on a new
  **non-reasoning** `cheapOpenAIModel = gpt-5.4-mini` (deterministic `temperature: 0` + `max_tokens: 8`; a
  reasoning model would reject `temperature` and could burn the tiny budget on hidden reasoning). Added the
  `CostEstimator.rotationModelCost` `.openai` arm `(0.75, 4.50)` + a tiling-accurate per-candidate token estimate
  (765), so the cost estimate now matches the runtime path. Local Vision stays the free default; Mistral/gateway
  still nil; any call failure falls back to local Vision. **`OCRProcessor+OCR.swift` needed no change** —
  `detectRotation` already passes `provider` through generically (the item over-scoped its file list, like
  W13.oai-1). Additive + opt-in; default provider unchanged. Build clean, 0 new warnings; Tier-1 self-review.
  **Live-key OpenAI rotation smoke (does gpt-5.4-mini pick the upright candidate?) + final model-ID/pricing
  confirm → keyed/owner tail → Morning Review.**
- [x] **Auto-route multi-page-PDF drops to re-OCR; retire the mode toggle (Processor) — owner-clarified 2026-07-16.**
  A dropped multi-page PDF should just run the re-OCR flow (render each page → LLM-OCR → interleaved image/OCR-text
  PDF) automatically — **no text-layer heuristic.** Owner's rule: `preOCRedInput` exists only to send input through
  the **tagging pipeline** (segment + tag), which is **not relevant to a multi-page PDF** (an assembled document, not
  a page stream to segment). So: multi-page PDF dropped → auto re-OCR; keep `preOCRedInput` as the separate
  tagging-pipeline path (single-page/image input); retire the manual "Re-OCR multi-page PDF" Settings toggle.
  **Tier-2** (PDF output). **Verify:** a render guard on the interleaved image/OCR-text PDF output (the 2-page-SPEC
  surface `DocumentRenderGuardTests` already guards from the Reader side) + `ops/gui/` for the drop-zone / toggle
  removal. | files: Views/OCRView.swift, OCR/OCRProcessor+Pipeline.swift | M | med | none
  — ✅ shipped: new `PDFToImageConverter.isMultiPagePDF` (ext + `PDFDocument.pageCount > 1`) drives
  `autoReOCR = !preOCRedInput && files.contains(where:)` in `OCRProcessor.startProcessing`, replacing the retired
  `reOCRMultiPagePDF` toggle — a dropped multi-page PDF now auto-routes to `performMultiPagePDFReOCR` (the transform
  itself is unchanged), while images/single-page PDFs stay on the standard path and `preOCRedInput` stays the
  deliberate tagging-pipeline opt-in (wins when set). Presence-based so a multi-page PDF is never silently truncated
  to its first page by the image path; output-only, so file-safety holds. Removed the Settings toggle + its
  `@AppStorage`/`DefaultsKeys`/`ProcessingProfileStore` entry; drop zone now accepts images **and** PDFs (label
  "Drop images or PDFs here") and the Tagging panel greys out with an explanation when a multi-page PDF is dropped;
  `preOCRedInput` help text explains the automatic re-OCR. Build clean 0 new warnings; **Tier-2 $0 functional test
  20/20 PASS** (`test-multipage-reocr.sh` — added 9 auto-route/detection assertions incl. the file-safety
  no-overwrite invariant). GUI visual (drop-zone label, toggle gone, Tagging grey-out) + a live multi-page-PDF
  re-OCR run → Morning Review (GUI off this run).
- [x] **Reader tag-filter → token field (selected tags INSIDE the box) [BUG-3 pane shift] — SHIPPED `b5a5a01`,
  owner-verified 2026-07-16 ("no longer pushes the left margin, all is good").** Selected subject filters used to
  render as separate buttons beside the "Add tag filter…" combo box, so each chip's width tipped the content column
  past the window and the root `HStack` re-centered, dragging the file table left. Two container attempts failed
  (a capped horizontal `ScrollView` reserved its max eagerly → overflowed on the FIRST chip; a wrapping
  `FlowLayout` got squeezed to ~one chip wide and piled vertically). Fix: new `Views/SubjectFilterTokenField.swift`
  — an `NSTokenField` whose tokens ARE the filters, bounded (220 pt), single-line, horizontally scrolling, with LOW
  horizontal compression resistance, so adding filters adds **zero** width to the bar → shift fixed by
  construction, and tags live in the box as the owner expected. Replaced/deleted the `TagFilterField` combo box
  (its only call site). Build clean; Reader units 194/195 (the 1 failure is the pre-existing env-only
  `DeepLinkTests.testRevealAndSelectNoRoot`). | files: Views/SubjectFilterTokenField.swift (new),
  Views/NavigationWindowView.swift, Views/TagFilterField.swift (deleted) | done
- **Processing History view — KEEP (owner-confirmed 2026-07-16).** The Tools-tab history view (W12-cost, promoted
  from POTENTIAL_FEATURES 2026-07-15; records actual run cost + a run log, writes only its own store) stays. No action.
- [x] **Visual-render test tooling — the pixels XCUITest can't see (NEW 2026-07-17).** XCUITest only reads the
  accessibility tree (element exists/hittable); it is blind to whether a PDF/scan actually *drew*. Added two
  layers: **(1) headless pixel guards** — `RenderProbe.swift` renders a SwiftUI view (`ImageRenderer`) or a PDF
  page (ArchiveCore `PDFThumbnailer`) to real pixels and asserts on them (`assertRendersNonBlank`,
  `nonWhiteFraction`); `DocumentRenderGuardTests.swift` guards the **2-page PDF SPEC** (page 0 scan / page 1 OCR)
  + a negative "blank page IS flagged" test; runs in the unit bundle with **no launch / no TCC prompt** → health-
  gate-safe. Reference-image diffs via **swift-snapshot-testing** (`SnapshotTests.swift`, new SPM dep). Rendered
  PNGs are logged as `ARTIFACT <name>: <path>` + attached to the .xcresult so a session can `Read` them.
  **(2) live sighted loop** — `ops/gui/capture-window.sh` grabs a running window's on-screen pixels (needs GUI-on)
  to pair with `cliclick`. Installed `imagemagick` for image ops. Reader units 205/206 pass (the 1 failure is the
  known env-only `DeepLinkTests.testRevealAndSelectNoRoot`). Pre-push adversarial review (workflow) fixed 3 issues
  (OCR fixture ink margin vs font-smoothing, uniform grey/black blank detection, AppleScript arg injection in the
  capture script). Considered Appium mac2 → **rejected** (same XCUITest substrate, so same a11y-tree blindness +
  extra TCC surface). | files: ArchiveReader/macOS/Tests/
  ArchiveReaderTests/{RenderProbe,DocumentRenderGuardTests,SnapshotTests}.swift, ArchiveReader/macOS/project.yml,
  ops/gui/{capture-window.sh,README.md}, AGENTS.md | done
- **DROPPED — Live Capture output-folder default** ("forget about this", owner 2026-07-16). The Downloads-if-unset
  default stays; the picker already lets the operator change it. Not an open question.
- **iOS is ON HOLD — read §Project focus before listing anything iOS.** The iOS Drive-relay OAuth client was
  surfaced to the owner in error: iOS *and* the Google-Drive relay are BOTH on-hold/maintain-only. Anything in
  `ArchiveCaptureiOS/` or the Drive path is out of scope until un-held; don't re-list it.
- [x] **Notes: extract a shared numeric sort-date combiner in ArchiveCore [LOW].** `Item.sortDate`
  (`ArchiveNotes/Store/Item.swift`) re-implements the shared `*10_000/*100` formula instead of reusing
  `ArchiveCore.DocumentTags.sortDate` (ArchiveCore exposes no `(year,month,day,decade)→Int?` combiner for Notes'
  `date:String?`+`datePrecision` input). Drift is already caught by a value-parity test
  (`ItemSortDateTests.testItemSortDateMatchesArchiveCoreSharedFormula`), and sort order is display-only (never
  written to a corpus → no file-safety stakes) — so this is a **low-priority** de-dup, below the W9 Notes
  gap-closure. Tier-1. | files: packages/ArchiveCore (new combiner), ArchiveNotes Store/Item.swift | S | low | none
  — ✅ shipped (2 commits): new `DocumentTags.sortDateKey(year:month:day:decade:)` in ArchiveCore is now the
  single source of truth for the SPEC sort formula (`year*10_000 + month*100 + day`; decade→`decade*10_000`;
  year wins over decade; absent month/day = 0; nil when undated). `DocumentTags.sortDate` (Reader) and
  `Item.sortDate` (Notes — parses `date`+precision, then defers the arithmetic) both call it, so the key can
  never drift between apps. Behavior-identical (the parity table + malformed-input nil cases preserved). +5
  ArchiveCore combiner tests; the Notes parity tripwire + its (now-done) comment updated. Verified across all
  three apps: ArchiveCore `swift test` 100 green, ArchiveNotes 520 unit tests green (13/13 ItemSortDateTests),
  Reader + Processor test bundles compile clean (no new warnings). Tier-1 (display-only).
- **CLOSED — `sessionComplete()` dead protocol surface: WON'T DO, PARKED (owner 2026-07-16).** ~30 lines of
  unreachable code in both companions' `SegmentTransport`/`MacClient`/`DriveRelayTransport`/`FileRelayTransport`
  (nothing calls it; the Mac's `/session/complete` route stays as a harmless no-op for older phones). Removing it
  would mean editing the *frozen* `RelayObjectFormat` wire contract (`encodeSessionComplete` +
  `sessionCompleteMatchesGolden`) and the on-hold Drive path for zero functional gain. **Do not re-raise** unless
  the Drive milestone is un-held AND `RelayObjectFormat` is already being edited for another reason.


## Archive Notes — NEW APP (SHIPPED W0–W8, 2026-07; `execution-plans/archive-notes/00-overview.md` retained)

- [x] **W0** **ArchiveCore extraction + Reader/Processor migration (FIRST)** — create `packages/ArchiveCore`, move
  the shared tag/PDF/date contract (facet parser + `sortDate` + read + the audited **write** path + Processor
  vocabulary/formatting + `PDFTextExtractor`/`PDFFormatStatus` + new `RootMarker`/`DurableLink` + `ArchiveSuite`
  recognition) out of both shipping apps and migrate them onto it; behavior-preserving, parity-gated, one audited
  write seam; adds the SPEC delta — `00a-archivecore-refactor.md` — **Tier-2** (TagWriter + both apps + SPEC)
  (S0 `f050d88` → S5 `cd7ff4f` → S6 `b90800f`)
- [x] **W1** scaffold + app skeleton **depending on the W0 ArchiveCore** — `01-scaffolding-and-core.md` — Tier-2 (scaffold)
  (S1 `7cddf60` → S2 `254fd73` → S3 `91c3c45` → S4 `220b582` → S5 docs — **partial**: app-local
  `README.md`/`AGENTS.md`/`SMOKE_TEST.md` were not actually written at S5; they shipped later under **W9 Phase A**
  `56360f7` (2026-07-18). The SPEC `ArchiveSuite` marker prose section (A4) is still pending — see
  `archive-notes/09-gap-closure.md`.)
- [x] **W2** store + front-matter I/O + virtual folders/replication + FTS5 index — `02-storage-model-and-index.md` — Tier-2 (writers)
  (S1 `64eaa9c` → S2 `02201f0` → S3 `2404852` → S4 `afd06c7` → S5 org graph + organization.json)
- [x] **W3** rich-text/Markdown editor (WYSIWYG + raw toggle, inline images) — `03-rich-text-markdown-editor.md` — Tier-1
  (S1 `0db7f61` → S2 `16e0f43` → S3 `1f740b3` → S4 `2261b1f` → S5 `78a9fb5` → S6 perf+cache+tests)
- [x] **W4** source blocks + page thumbnails + Reader URL scheme/reveal + durable links — `04-sources-and-cross-app-linking.md` — Tier-2 (Reader deep-link)
  (S1 `0b7b89d` → S2 `8a7012c` → S3 `1e81b71` → S4 `f477f3a` → S5 `15c690c` → S6 `0ddf88e` → S7 reveal+preview)
- [x] **W5** Zotero metadata / citations / chips — `05-zotero-integration.md` — Tier-1
  (S1 `3704c6a` → S2 `2dac700` → S3 `97547c1` → S4 `f420346` → S5 settings + degrade polish)
- [x] **W6** viewers + search/filter/sort + replication UI + templates + dates/quality — `06-viewers-search-replication.md` — Tier-2 (delete path)
  (S1 `27d3952` → S2 `70bfd1e` → S3 `c37f175` → S4 `92f84f4` → S5 `3d46c0d` → S6 `598d2f2` → S7 dates & quality UI)
- [x] **W7** extracts (snapshot + provenance, blocks→notes, jump-to-source) — `07-extracts.md` — Tier-1
  (S1 `f5efe60` → S2 `71ca1db` → S3 `50920ce` → S4 `c8c93ee` → S5 `328bff3` → S6 app-quit/window-close autosave flush)
- [x] **W8** tests + XCUITest/cliclick GUI harness (scratch corpus) — `08-testing-and-gui-verification.md` — Tier-1/2
  (S1 `0f164ed` → S2 `6ef2244` → S3 `3aa27e2` → S4 `6f22159` → S5 `2a412c9` → S6 `6ce10a6` →
  S7 GUI-harness scaffold `98a4afc`–`0e7472c` → S8 per-wave GUI checks `f79e279`–`267ca8d` +
  S8b probe-queryability + owner-eye README → S9 durable-link E2E `17a2d27`/`7d2dcb8` + `GUI_SAFETY.md`)
  — **W8 COMPLETE (GUI-on):** full `ArchiveNotesUITests` suite (G0–G11 + Smoke) **13/13 TEST EXECUTE SUCCEEDED**;
  the `an.status.indexReady` probe is now XCUITest-queryable (G0); owner-eye checks (G2/G6/G11 + chip clicks)
  documented in `ArchiveNotes/scripts/GUI-HARNESS.md`. **Completes Archive Notes (Wave 11 / W0–W8).**


## P0 — Finish the Suite publish (network back)

- [x] Push merged history: `main` + `suite-v1.0.0` pushed to `origin` (0 diverged). ✅ 2026-07-06
- [x] Publish release: `suite-v1.0.0` LIVE with `ArchiveSuite-1.0.0.dmg` (4.48 MB) attached. ✅
- [x] Verify online: release published, asset `uploaded`; `origin/main` == locally build-verified tree. ✅
- [x] **Phase F DONE** — redirect banner pushed to the old `archiveprocessor` README; repo **archived** (read-only, `isArchived=true`). ✅ 2026-07-06


## P1 — Quick local wins (S, low-risk, no network)

- [x] Cite `SPEC/tag-format.md` as the shared-contract source of truth from BOTH per-app `CLAUDE.md`. ✅
- [x] Reconcile Reader `CLAUDE.md` prose to SPEC (doc-only; code already correct): page-2 line verbatim/any-ext/may-be-absent; Year 3–4 digits; BC note clarified; Box/Folder/OCR-Failed subjects noted. ✅
- [x] Regression test: `Box`/`Folder`/`OCR Failed` classify as plain subjects (SPEC #3) — added; **110 tests green**. ✅
- [x] Close stale checkbox: near-term-UI item **E3** confirmed shipped & ticked. ✅
- [x] Processor: "Import tag vocabulary from CSV" — added `Import from CSV…` button + file drop target on the vocabulary editor (`SettingsView.swift`; NSOpenPanel + newline/comma parse, de-dupe). macOS build green, no new warnings. ✅
- [x] **Android `targetSdk` 34→36 — DONE 2026-07-08** (builds clean + Android-16 emulator smoke PASSED). Toolchain: installed `platforms;android-36` + `build-tools;36.0.0`; AGP 8.6.1→8.9.1; Gradle 8.9→8.11.1; `compileSdk`/`targetSdk` 34→36; `:app:assembleDebug` **BUILD SUCCESSFUL** (JDK 21). **On-device smoke on the `ap_test36` (API-36 / Android 16) emulator PASSED:** app launches, both connect screens render with correct system-bar insets (no edge-to-edge clipping — screenshots checked), full capture flow drove (pair → 2× shutter → End segment → Skip → Box marker), **camera opened** (CameraService connect), and the phone→Mac protocol ran against a stub (`/ping`, 20× `/phone/status` heartbeat, 3× `/photo`, `/segment/complete`) — **no crash, no foreground-service/permission FATAL, 0 FATAL EXCEPTION**. *(Nice-to-have before Play submission: a final pass on a physical Android 15/16 device — emulator ≈ device but not identical.)* | files: ArchiveCapture/ | done
- [x] Reconcile Bonjour service-name mismatch — iOS now advertises `_archivecap._tcp` (matches the Mac) in both `ArchiveCaptureiOS/project.yml` + generated `Info.plist`; iOS project regenerates clean. ✅


## P2 — Reader features (no network; local build/test)

- [x] Non-standard-PDF **detection layer** — `Core/PDFFormatStatus.swift` (standard/unreadable/noTextLayer; page count is NOT a defect signal — merged >2-page PDFs are legit); persisted in the v2 content index. **117 tests green, lint clean.** ✅
- [x] Surface it — filter-bar "N need attention" toggle (`needsAttentionOnly` filter), health-popover row, per-row ⚠ badge. ✅
- [x] Viewer banner for image-only docs ("no OCR text layer") in the document window — build green. ✅
- [x] Tag near-duplicate detection — `Core/TagSimilarity.swift` (union-find + length-scaled Levenshtein) + `SimilarTagsSheet` review UI (Merge drives the existing audited rename). 130 tests green, lint clean. ✅
- [x] Duplicate-filename disambiguation — `Core/DuplicateNames.swift` + a dimmed containing-folder subtitle for rows sharing a base name. 135 tests green, lint clean. ✅
- ~~Side-by-side compare of two selected documents~~ — **dropped (owner: not doing this), 2026-07-06.**


## P2 — Reader performance

- [x] **Parallelize + batch the content-index build** *(Part A — build speed)* — bounded parallel
  `withTaskGroup` extraction + `upsertBatch` + WAL/`synchronous=NORMAL` + `existingMTimes()` +
  `performMaintenance`. 185 tests green. Tier-2 APPROVE. | done
- [x] **Ranked (bm25) search + search-during-index refresh** *(Parts B+C)* — bm25 relevance-ranked
  search (SQL `ORDER BY bm25`, column weights name=10/class=5/body=1, ordered `[String]` return,
  `ftsRank` map, `.relevance` auto-sort, lifecycle + persistence coercion) + auto-refresh active FTS
  query on index pass completion. 186 tests green. Tier-2 APPROVE. | done
- [x] **Prune the content index** — gated cache eviction: `!isGathering && !files.isEmpty` +
  two-emission absence confirmation + component-boundary root scope + batched deletes. Its own pass
  (`pruneIfSettled`), not folded into `startIndexing`. Root-switch resets pending-prune state.
  Corpus-wide counts now correct at source (the `among:`-scoped workaround stays as defense-in-depth).
  191 tests green (5 new). Tier-2 APPROVE (7/7 vectors). | done


## Owner-requested batch (2026-07-09) — Processor output + Reader UX/viewer

- [x] **Multi-column OCR output layout** — `textColumns` setting (1/2/3, default 1) in Settings +
  ProcessingProfiles; body text on page 2 flows into N CoreText columns (header stays single-column,
  full-width). Threaded through OCRProcessor, SessionProcessingConfig, LiveCaptureProcessor (Codable-safe
  with `decodeIfPresent` fallback). Build clean 0 new warnings. Tier-2 APPROVE (7/7 vectors). 7 synthetic
  tests green. GUI-verify deferred: verify on a real multi-column newspaper scan → Morning Review. | done
- [x] **Multi-page PDF → per-page LLM OCR → single alternating image/OCR-text PDF** _(owner-requested 2026-07-15; SHIPPED — new "Re-OCR multi-page PDF" Process-Files mode)_
  — a NEW Process-Files mode: accept an existing **multi-page PDF**, render EACH page to an image, send each
  page-image to the LLM for OCR (re-OCR the page images — distinct from the existing `preOCRedInput` mode, which
  only extracts the embedded text layer), and output ONE PDF whose pages **alternate image, OCR-text, image,
  OCR-text, …** (each source page → its image page + a selectable OCR-text page). **Mostly assembles from
  existing primitives:** `PDFGenerator.mergeDocumentPDFs` already interleaves image1,text1,image2,text2,…;
  `OCRProcessor.performOCRCall` is already per-single-image; `PDFGenerator.generate` builds the per-page
  image+text unit. **New bits:** a "render ALL pages" variant of `PDFToImageConverter` (today hard-codes
  `page(at: 0)`); a pipeline branch in `OCRProcessor.startProcessing` / `convertPDFInputs` that fans one input
  PDF into N page-jobs then reuses generate+merge; a mode toggle beside `preOCRedInput` (+ a `DefaultsKeys` entry)
  in `OCRView.swift`. **Tier-2** (PDF-writing output — adversarial review + scratch-copy functional test, NEVER
  the real corpus). SPEC: add a short note to `SPEC/tag-format.md` §2-page structure (the interleaved shape
  already matches multi-page-document output + is covered by the "consumers must not hard-assume 2 pages" clause,
  so it's a coordinated Processor+Reader+SPEC clarification, not a format break). |
  files (verify at impl): OCR/PDFToImageConverter.swift, OCR/PDFGenerator.swift (generate + mergeDocumentPDFs),
  OCR/OCRProcessor+OCR.swift (performOCRCall, convertPDFInputs), OCR/OCRProcessor+Pipeline.swift (startProcessing),
  Views/OCRView.swift (intake + mode toggle), SPEC/tag-format.md | M | med | none
  — **DONE:** `DefaultsKeys.reOCRMultiPagePDF` + `ProcessingProfileStore`; `PDFToImageConverter.renderAllPages`
  (fail-loud, no partial set); `OCRProcessor.performMultiPagePDFReOCR` (render all pages → per-page OCR via
  `performOCRCall` → `PDFGenerator.generate` per page → `mergeDocumentPDFs` into ONE alternating image/OCR-text
  PDF), branched in `startProcessing` BEFORE `preOCRedInput`; a pure transform (no Finder tags — output never
  overwrites the input via `uniqueOutputURL`). Settings toggle (mutually exclusive with pre-OCRed; disables
  batch + separate-image export), Process-Files "Drop PDFs here" intake + PDF accept-gate + grayed Tagging box.
  SPEC §2-page-structure interleaved-variant note added. **Tier-2:** adversarial self-review + `$0`/key-free
  functional test `scripts/test-multipage-reocr.sh` (`MultiPageReOCRTestDriver`, 11/11 PASS incl. the
  input-overwrite guard); merge-safety regression still green; build clean, 0 new warnings. GUI visual check
  (toggle render / drop-zone flip) deferred → Morning Review (launch-time Keychain prompt blocks it unattended).
- [x] **Shared provider text-completion client** — **ALREADY SHIPPED `f1d2263` (suite-v1.2.0), before the
  2026-07-15 promotion re-listed it.** `OCR/LLMTextClient.swift` is the shared text-completion client;
  `TagGenerator` + `CollectionSegmenter` both delegate to it, each keeping its own `maxTokens`/timeout so request
  bodies stay byte-identical (the Mistral-signature drift was reconciled deliberately, not blind-merged).
  Verified in-tree 2026-07-16 (file present; both callers reference it). Promoted-in-error 2026-07-15 (`1ee659c`) —
  the POTENTIAL_FEATURES source entry was stale.
  | files: Tagging/TagGenerator.swift, Tagging/CollectionSegmenter.swift, OCR/LLMTextClient.swift | done
- [x] **Live Capture output-folder picker** — **ALREADY SHIPPED `782dfdd` (suite-v1.2.0), before the 2026-07-15
  promotion re-listed it.** LiveCaptureView has the picker (`chooseOutputFolder()` + NSOpenPanel), a "Choose…"
  button, the current-destination "Output folder" row, a `?` HelpButton, and gray-out in Stage-for-later mode —
  unified on the SAME `DefaultsKeys.outputDirectory` as Process Files (one source of truth). Verified in-tree
  2026-07-16. Promoted-in-error 2026-07-15 (`1ee659c`). **Residual (owner):** the owner's promoted wish said the
  default should be "not Downloads"; the shipped default is Downloads-if-unset (visible + changeable via the
  picker). Whether to change the default (and to what — last-used vs a dedicated folder) is an owner call →
  Morning Review. | files: Views/LiveCaptureView.swift | done
- [x] **Cost tracking + processing history** _(promoted 2026-07-15; SHIPPED 2026-07-16)_ — persist each run's **actual**
  cost plus a run log (timestamp, provider/model, file count, results/failures) and surface a simple history view.
  `CostEstimator` already does the per-model math for *estimates*; this records **actuals** and accumulates them.
  Writes only its own store (Application Support / UserDefaults) — **never** the corpus. **Tier-1**.
  | files: Models/CostEstimator.swift, Models/DefaultsKeys.swift, Views/ToolsView.swift (or a new history view) | M | low | none
  — **SHIPPED:** `Models/ProcessingHistory.swift` — `ProcessingRun` + in-memory `RunHistorySnapshot` (params captured at
  run start; cost = the SAME `CostEstimator` math the pre-run pane shows, applied to what ACTUALLY ran — no provider
  returns per-call token usage) + bounded (200) `ProcessingHistoryStore` (JSON in UserDefaults, never the corpus).
  `OCRProcessor` records at EVERY genuine completion tail (startProcessing + resumeRun pre-OCRed/standard + resumeBatch;
  resume snapshots rebuilt from the persisted manifest + live rotation/scale); cancel/interrupt paths never record.
  `Views/ProcessingHistoryView.swift` — a Tools-tab sheet (per-run provider·model/mode/counts/cost, summary totals,
  confirm-gated Clear; cost footnoted as an estimate, not billed). **Tier-1** verified: build clean, 0 new warnings +
  `$0`/no-key/no-GUI headless self-test `scripts/test-processing-history.sh` (`ProcessingHistoryTestDriver`, 19/19 PASS,
  against a THROWAWAY UserDefaults suite — never the operator's real history). Visual GUI check deferred (launch-time
  Keychain prompt blocks the Processor GUI unattended) → Morning Review.
- [x] **Global keyboard shortcuts + dark-mode pass** _(promoted 2026-07-15; re-scoped 2026-07-16; VERIFIED 2026-07-16)_ —
  Tier-1 audit; **no code change needed** (both sub-items already correct in-tree — churning clean code would be worse).
  **(a) Shortcut coverage — complete & correct:** `Views/ProcessingCommands.swift` exposes the two main-window
  commands (⌘R Start Processing, ⌘⌥P Cycle Provider) as a menu-bar `CommandMenu` = the single source (key
  equivalents shown; routes via `NotificationCenter` → MainActor observers with a `TextEditingGuard` so a shortcut
  never steals a keystroke). Every OTHER `.keyboardShortcut` in the app is a `.defaultAction`/`.cancelAction`/⌘Return
  **scoped to a modal sheet** (correctly NOT global menu commands) — matches the Reader's "menu bar = single source"
  convention. **(b) Dark-mode — static audit clean:** all chrome uses adaptive `Color(nsColor: .controlBackgroundColor
  / .windowBackgroundColor / .textBackgroundColor)`; text uses `.primary`/`.secondary`/`.tertiary` + adaptive accents;
  `white`/`black` literals appear ONLY for document/paper rendering (thumbnail/PDF-output/OCR-test canvases — must
  stay), modal scrims (`black.opacity(…)` — intentional dimming), and glyphs/text on dark scrims or saturated colored
  badges; the one AppKit token field sets `drawsBackground = false` (the adaptive pattern). No custom `Color` palette/
  extension, no named-image chrome (`Image(systemName:)` only), no forced `.preferredColorScheme` / `NSApp.appearance`
  / `window.backgroundColor` override. **Human visual dark-mode spot-check deferred → Morning Review** (the Processor
  GUI can't launch unattended — blocking login-Keychain prompt; no Processor XCUITest harness). | files (audited):
  Views/* (all), Views/ProcessingCommands.swift | S | low | none | done
- [x] **Incremental processing (skip already-processed files)** _(promoted 2026-07-15; SHIPPED 2026-07-16)_ —
  re-running a directory now processes only new/changed files instead of redoing everything (matters at 150k scale).
  Skip key = the owner-specified one: an existing `<output>/<base>.pdf` whose mtime is no older than the source.
  **Fail safe: when in doubt, PROCESS** — never silently skip a file that needed processing. **Tier-2** (a wrong
  skip = silently missing output). | files: OCR/OCRProcessor+Pipeline.swift, Views/OCRView.swift | M | med | none
  — **DONE:** new pure `OCR/IncrementalSkip.swift` (`partition(inputs:outputDirectory:)`) is the safety-critical
  decision core; skips a source ONLY when its base name is unique among inputs, the candidate `<out>/<base>.pdf`
  is a distinct file (not the source itself), exists as a regular file, both mtimes are readable, and source
  mtime ≤ output mtime — every ambiguity falls through to PROCESS. Opt-in toggle `DefaultsKeys.skipAlreadyProcessed`
  (default OFF, Settings ▸ Input & Processing; also a `ProcessingProfile` key). Filtered at the top of
  `startProcessing` and confined to plain per-file output (skipped for Live Capture pre-grouped handoffs,
  collection-organized, and merged runs, where an output can't be attributed to one source — a safe no-op there);
  the skipped count is surfaced in the completion status, and an all-skipped run finishes with a clear
  "nothing to do". **Tier-2 verified** (no-key Processor): headless `$0` `scripts/test-incremental-skip.sh`
  (`IncrementalSkipTestDriver`, INCREMENTAL_SKIP_TEST=1) — **13/13 PASS** across every fail-safe branch,
  mktemp-isolated (never the corpus) — plus adversarial diff review + build clean, 0 new warnings. GUI visual
  check (toggle + status line) deferred → Morning Review (Processor GUI launch = blocking login-Keychain prompt).
- [x] **Remove the phone "Finish" button** _(owner decision 2026-07-15 — "get rid of it"; premise found STALE —
  already done, reconciled 2026-07-16 `W12-finish-button`)_ — the phone's **Finish**
  (`CaptureViewModel.finishSession()` → `MacClient.sessionComplete()` → `POST /session/complete`) is near-useless
  and actively misleading: the Mac handler (`CaptureServer.swift` ~L242) only sets a status string and returns OK —
  it does **not** start finalize, so the operator must still click **Finish session** on the Mac. **End segment**
  stays the phone's only "done" action; the Mac's Finish session stays the finalize trigger. Remove the button +
  its call from **both** companions (keep them in sync). **Leave the Mac's `/session/complete` route in place** (a
  harmless no-op) so an older/unupdated companion still works — do NOT change the protocol in the same pass.
  | files: ArchiveCapture/ui/CaptureScreen.kt + capture/CaptureViewModel.kt,
  ArchiveCaptureiOS/UI/CaptureScreen.swift + Capture/CaptureViewModel.swift | S | low | none
  — **ALREADY DONE (stale premise, like recent-years/de-dup).** The phone **Finish button + its `finishSession()`→
  `sessionComplete()` UI call are already gone from BOTH companions** — removed in `ce55511` ("Live capture: End
  segment is the only 'done' action"). Verified in-tree 2026-07-16: neither `CaptureScreen.swift` nor
  `CaptureScreen.kt` has a Finish button (both only expose **End segment** = `finishDocumentSegment()` →
  `segmentComplete(...)`, the segment signal — NOT `sessionComplete`); a full-tree grep finds **zero callers of
  `sessionComplete()`** in either companion's UI/Capture/Net; both UIs even carry a "there is no separate Finish"
  comment. The Mac's `POST /session/complete` route is intact (`CaptureServer.swift:284`), as the item requires.
  So the actionable scope (remove the button + its UI call, keep the Mac route) is fully satisfied — no code change.
  **Residual (OUT OF SCOPE this pass → Morning Review):** `sessionComplete()` survives as **dead protocol surface**
  in the Net/ transport layer (the `SegmentTransport` protocol + `MacClient`/`DriveRelayTransport`/`FileRelayTransport`
  impls, both companions). Removing it would touch the **frozen** `RelayObjectFormat` wire contract
  (`encodeSessionComplete` + the `sessionCompleteMatchesGolden` test) and the maintain-only cloud path, i.e. it
  **"changes the protocol"** — which the item explicitly forbids "in the same pass." Left as an optional future
  protocol-cleanup pass (owner-gated). Doc-only reconciliation (Tier-1, no build needed — tree == `a624ccf`).
- [x] **Cap recent years at 5 (both companions)** _(owner decision 2026-07-15; SHIPPED 2026-07-16)_ — both
  companions now cap the recent-years quick-chip list at **5** (was 6): iOS `Array(ys.prefix(5))`
  (`CaptureViewModel.noteYear`) + comment; Android `.take(5)` (`Prefs.noteYear`) + `max 5` doc comment. Kept in
  sync. Migration-safe (a previously-stored 6th year is truncated on the next `noteYear`; it is only a UI
  convenience list — no tag/corpus write, so Tier-1). **Verified:** iOS `xcodebuild` **BUILD SUCCEEDED** + Android
  `./gradlew :app:assembleDebug` **BUILD SUCCESSFUL**, no new warnings; no unit test asserts the cap. Visual
  chip-count check (needs seeding ≥6 recent years then opening the tag sheet on device/emulator — an
  E2E-harness-level drive, disproportionate for a one-line display cap) → Morning Review.
  | files: ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift (recentYears), ArchiveCapture/.../data/Prefs.kt (recentYears) | S | low | none
- [x] **Adjustable + collapsible side panels** — `PanelDivider` (drag-to-resize, 140–350 / 160–400
  clamped, `@AppStorage`-persisted widths); sidebar + tag cloud toggle via toolbar buttons + View menu
  shortcuts ⌥⌘S / ⌥⌘T; animated expand/collapse. 191 tests green, 0 warnings. | done
- [x] **Add/remove columns in the file list** — right-click the column header → checkmark menu to
  show/hide any column (except File name); visibility persisted via UserDefaults. `ColumnPickerHeaderView`
  subclass + `AppSettings.hiddenColumns`. |
  files: Views/AppKitTableView.swift, Core/AppSettings.swift | done
- [x] **Make tags editable in the file list _again_** — `TagTokenCellView` (NSTokenField in NSTableCellView)
  replaces the plain-text tags cell; edit-start base snapshot + freeze-during-edit + WYSIWYG commit on blur,
  all routing through `commitSubjectEdit` → `TagWriter`. Tier-2 APPROVE (6/6 vectors). 191 tests green,
  0 warnings. GUI write-verify deferred (screen locked). | done
- [x] **No dates in the tag cloud** — exclude Year/Month/Day **and decade** facets; show subjects only
  (facet classification already exists in `DocumentTags`). | files: Views/NavigationWindowView.swift
  (tag-cloud panel), Core/DocumentTags.swift | S | low | done
- [x] **Remove date tags from the tag filter search** — months/years/decades must not appear as
  suggestions/targets in the tag filter field. | files: Views/TagFilterField.swift, Core/DocumentTags.swift | S | low | done
- [x] **Logarithmic tag-cloud sizing** — size by `log(count)` (or similar) so a 1000-count outlier doesn't
  crush the 2/10/20/100/1000 gradient into uniformly tiny text. | files: Views/NavigationWindowView.swift | S | low | done
- [x] **Wrap (not clip) file tags in the list** — `usesAutomaticRowHeights` + multi-line `NSTokenField`
  (`wraps = true`, top/bottom constraints). Build clean, 191 tests green. GUI-verify deferred (screen
  locked). | files: Views/AppKitTableView.swift | S | low | done
- [x] **Decade tags ("1970s", "1980s")** _(plan: `execution-plans/decades-date-facet.md`)_ — SHIPPED.
  SPEC + Reader parse/sort/display/topicalTags + write-path safety (year supersedes decade) +
  Processor Year-field help text. 12 new unit tests (182 total green). Tier-2 APPROVE. Defaults
  applied for the 4 open questions (italic=yes, no Reader decade editor, no hard validator, cloud/filter
  exclusion structural). Plan deleted. | done
- [x] **Incremental (as-you-type) OCR search** — debounced 150ms Combine pipeline on `$fullTextQuery`
  triggers `runFullTextSearch()` as-you-type; FTS5 MATCH + bm25 is indexed and fast at scale; existing
  `ftsGeneration` token handles superseded queries. `.onSubmit` removed (debounce handles it); clear
  button still calls explicitly for instant feedback. 191 tests green, 0 new warnings.
  | files: Views/NavigationWindowView.swift, Views/NavigationModel.swift | done
- [x] **In-viewer find, scoped to the open PDF(s)** _(owner-requested 2026-07-14)_ — ⌘F find bar over the
  open PDF(s): highlights ALL matches (yellow), next/prev navigation (⌘G / ⇧⌘G, wrapping) with a global
  "N of M" count, and searches ACROSS every open document (both panes = page 0 + page 1) — not the corpus
  FTS. New `Core/DocumentFind.swift`: pure `FindNavigator` (reading-order match list + wrap cursor) +
  `DocumentFindScanner` (per-pane match counts via `PDFDocument.findString`). `PDFPaneController` grows
  find-highlight state reapplied on every view rebuild (mirrors the persisted-zoom pattern), so highlights
  survive page cycling; cross-document jumps set the pane target then change `index` so the rebuild applies
  it with no timing race. 10 new unit tests (`DocumentFindTests`, incl. a synthesized text-PDF scanner
  check); build clean 0 new warnings. Read-only → Tier-1. Live GUI drive (highlight render / scroll /
  next-prev / cross-doc jump) → Morning Review (GUI off). | files: Core/DocumentFind.swift,
  Views/DocumentViewerModel.swift, Views/PDFPaneView.swift, Views/DocumentWindowView.swift,
  ArchiveReaderCommands.swift | M | low | done
- [x] **Full-text search snippet previews (keyword-in-context)** _(promoted from POTENTIAL_FEATURES 2026-07-15;
  SHIPPED 2026-07-16 — `80725d3` core, `d797ea8` UI)_ —
  show a `snippet()`-style **keyword-in-context** excerpt for each search hit (the matched OCR text with the query
  term highlighted) so results are scannable without opening each doc. FTS5 has `snippet()` **built in** and the
  content index **already stores the OCR `body`**, so this is a **search-UI addition, not an indexing change** —
  it layers on the shipped bm25 relevance ranking (and is distinct from the in-viewer find above: this is the
  corpus/library search). Read-only, no writes → **Tier-1**. Was deferred out of the `index-parallelization` plan
  (owner, 2026-07-09), which shipped ranking but explicitly not previews. | files (verify at impl):
  Search/ContentIndex.swift, Views/NavigationModel.swift, Views/NavigationWindowView.swift | M | low | none
  — **DONE:** `ContentIndex.searchRanked(query,snippetLimit)` returns every bm25-ordered match path (unchanged
  filtering surface) **plus** bounded FTS5 `snippet()` KWIC previews for the top hits — `snippet()` reads each
  doc body, so a `path IN (…)` filter caps the work at the top N rather than every match at 150k scale (an
  `ORDER BY bm25 … LIMIT` would still evaluate `snippet()` for every scanned row). New pure `Search/SearchSnippet.swift`
  (STX/ETX marker vocabulary shared by the SQL builder + the UI; robust segment parser). `NavigationModel` stores
  per-path snippets (`ftsSnippets`, cleared at every reset site) + `searchSnippet(for:)`; the AppKit list name cell
  grows to a dimmed 2nd keyword-in-context line for a hit (matched terms bold + faint adaptive-yellow wash) via the
  existing `usesAutomaticRowHeights`. **Tier-1** verified: 15 new unit tests (`SearchSnippetTests` + `ContentIndexTests`)
  green; build clean, no new warnings; **GUI-verified** by a new fixture XCUITest (`testOCRSearchShowsKeywordInContextSnippet`,
  **TEST SUCCEEDED**) that OCR-searches a body-only term ("California", in 9/11 fixture bodies, in no filename) and
  asserts the snippet line renders end-to-end. (Pre-existing env-only unit failure `DeepLinkTests.testRevealAndSelectNoRoot`
  — owner's real `archiveRootBookmark` in the shared unit-target UserDefaults — is unrelated → Morning Review.)
- [x] **Drop the top-bar Sort button; sort via column headers** — removed the toolbar Sort menu; primary
  sort via native column-header click (already wired via `sortDescriptorPrototype`); right-click header →
  secondary sort (asc/desc) + remove-secondary + reset-to-default via `ColumnPickerHeaderView`. Dead
  SwiftUI-Table sort code removed (`ArchiveFileComparator`, `sortComparators`, `applyTableSort`). 191 tests
  green, 0 warnings. | done
- [x] **Smart folders behave like a scoped root** — selecting a saved search enters a base scope; user
  filters layer on top; Clear returns to the base set, not the whole root. Sidebar shows a durable
  highlight. Scope persists across relaunch. `LibraryFilter.effective` merge for Save/summary. 170 tests
  green. Tier-2 APPROVE. | done
- [x] **Single-page PDF with an embedded text layer → show its text as plain text (right pane)** — in both
  the document viewer and the navigator Preview, when a PDF has selectable text but no OCR page-2, extract
  the text layer via `embeddedText` and render it as selectable plain text in the right pane. Build clean,
  191 tests green. GUI-verify deferred (screen locked). | done
- [x] **Preview gets its own default zoom** — independent of the document viewer's persisted zoom; default
  to **full page** until the user changes it; on open, **focus the image pane** so keyboard zoom works
  immediately. `PDFPaneController(persists: false)` in preview mode; focus via async dispatch on appear.
  Build clean, 191 tests green. GUI-verify deferred (screen locked). | done
- [x] **⌘0 = "fit full page" everywhere zoom applies** — `.focusedObject(model)` on PreviewSheet
  publishes the viewer model so the existing Document menu ⌘0 (Fit Page) + zoom shortcuts reach the
  preview. Build clean, 191 tests green. GUI-verify: Document menu confirmed; preview-specific test
  deferred (scratch corpus not Spotlight-indexed). | done
- [x] **View non-PDFs (e.g. JPG) in the viewer** — tagged non-PDF images (JPG/PNG/TIFF/HEIC/BMP/GIF)
  now open in viewer + preview via PDFPage(image:) wrapping in DocumentViewerModel.loadCurrent().
  Build clean, 191 tests green. GUI-verify deferred (scratch corpus not Spotlight-indexed). | done


## Owner-requested (2026-07-10) — Reader

- [x] **Exclude a subfolder (inside the root) from indexing _and_ display** — a Settings control to
  name one or more folders under the current root that the Reader should treat as out of scope: their
  files are neither shown in the library nor added to the content index. UI lives in the Reader's
  **Settings** scene (`ArchiveReaderApp.swift:30` — add an "Excluded folders" section / list; a folder
  picker scoped under root that appends rows, each removable). Persist the exclusions (path prefixes,
  and/or security-scoped bookmarks like `RootFolderStore`) via `AppSettings`/a small store. **Apply at
  BOTH gates so "not indexed" and "not shown" actually hold:** (1) _display_ — filter files whose path is
  under an excluded prefix in `NavigationModel.libraryDidChange`/`recompute` (discovery is Spotlight-wide
  by tag in `ArchiveLibrary`, so match on path prefix, not search scope); (2) _index_ — skip excluded
  paths in `ContentIndexer.startIndexing`, **and prune already-indexed rows** under a newly-excluded
  folder (reuse the gated-prune path so search stops matching them; growth stays bounded). Reversible:
  un-excluding re-includes + re-indexes on the next library change. Edge cases: exclusion must be a
  descendant of root; overlapping/nested exclusions dedupe to the outermost; an excluded folder that
  later disappears is a no-op. Mostly build+unit verifiable (path-prefix filter, prune-on-exclude);
  GUI-verify the Settings list + that excluded rows vanish from the list and OCR search. **Not Tier-2**
  (no tag/corpus writes — read/index-side only). | files: `ArchiveReaderApp.swift` (Settings scene),
  new `Search/ExcludedFoldersStore.swift` (or `Core/AppSettings.swift`), `Views/NavigationModel.swift`,
  `Search/ContentIndexer.swift`, `Search/ArchiveLibrary.swift` | M | low


## Deferred from the 2026-07-09/10 autonomous run → queued for next autonomous run

- [x] **Prefix-match as-you-type OCR search** _(W10.1)_ — `ftsMatchExpression` appends `*` to the last token
  (>2 chars) for FTS5 prefix queries ("news" → "newspaper"). Min-length gate skips wildcard for ≤2-char tokens.
  3 new tests (196 total green), 0 warnings.
- [x] **Reader perf (deferred W6.2/W6.5)** _(W8.1)_ — (a) `displayedByID` rebuild gated by `displayedGeneration` counter (skips O(N) dict rebuild on unrelated `updateNSView` calls); (b) `tagCloud` cached + invalidated in `recompute()`. 193 tests green, 0 warnings.
- [x] **Processor OCR throughput (deferred W6.5 — M3–M5). Tier-2** _(W8.2)_ — M3 `handleOCRResult` PDF gen →
  `Task.detached(.utility)`; M4 `processBatchResults` rotation → bounded-concurrent `withTaskGroup`; M5
  Anthropic batch submit → incremental JSON serialization (1-image peak vs all-images). Tier-2 APPROVE
  (18 attack vectors). Build clean 0 warnings. | files: `OCR/OCRProcessor+OCR.swift`, `OCR/BatchOCR.swift` | M | low
- [x] **Processor OCR LOW cleanup (W6.4 L1–L4)** — L1 Gemini `cancelBatch` apiKey → `urlComponentEncoded`; L2
  preserve `errorCode` across 4 OCRResult re-creations; L3 documented `nonisolated(unsafe) static var` concurrency
  contract (write-once-per-run on MainActor, happens-before child tasks); L4 cache previous JPEG in Anthropic +
  Gemini batch loops. Build clean 0 warnings. | files: `OCR/BatchOCR.swift`, `OCR/OCRProcessor+ReviewFlows.swift`,
  `OCR/OCRProcessor.swift` | S | low
- [x] **Reader GUI test harness (XCUITest)** — W7.1–W7.5 shipped (target + accessibilityIdentifiers + fixture-root override + make-gui-fixture.sh + suite). **W7.6 (fixup) — all 14 tests now EXECUTE and PASS** (were 13/14 skipping): fixed the sandbox↔Spotlight fixture load (DEBUG off-Spotlight directory enumeration, since NSMetadataQuery returns nothing for a temporary-exception path), UITest↔owner shared-UserDefaults isolation (no view-state restore/persist in test mode — was inheriting the owner's live filter AND clobbering their settings), the tag-cloud element-type query + row/header click hittability, and marked the UI-test classes `@MainActor` (test-target warnings 171→32). PDFView content panes aren't XCUITest-queryable (framework limit) — asserted via observable chrome instead. | L | med


## P2 — Processor (KI#3 done; rest bucketed by how it can be verified)

- [x] KNOWN_ISSUES #3: zoomed-image scroll monitor no longer swallows scroll app-wide — scoped to the image via a hit-test-transparent probe (`ZoomableImageView.swift`); SwiftUI drag/pinch intact, no OCR/output logic touched. Build clean. ✅  ← GUI-verify (zoom a page >100%, confirm the filmstrip scrolls).
- [x] **[A1 — SHIPPED; owner-gated live-verify remains]** **Owner-requested (2026-07-07): bring the Live Capture Processing pane up to the Process Files "Files" pane's level of detail — on shared central code.** Today the Processing pane in Live Capture is too sparse: when a document **fails OCR the user gets no reason**, and there's **no way to (re)process just one or two files**. It should show the same per-file detail as the Process Files "Files" pane (status, OCR text/error reason, per-file actions) and offer the same **granular fallback/retry options** (retry a single file, change model/rotation and re-run, etc.). The pane likely needs to be **larger** to fit this. **DRY — don't invent it twice:** factor the Process Files file-list + row + per-file action UI into a **shared component** so both the Process Files pane and the Live Capture Processing pane render from one central source, rather than two parallel implementations. Mostly build-verifiable; verify the failure/retry paths in a live run. **Tier-2** if it touches the finalize/retry write path. | files: Views/OCRView.swift (+OCRView+*), Views/LiveCaptureView.swift, Capture/LiveCaptureProcessor.swift, new shared row/pane component | L | med
  - **Progress (2026-07-07, A1 design `.maintenance/A1-shared-pane-design.md` steps 1–9):** SHIPPED — shared `Views/Shared/{ProcessableItem,ProcessableItemRow,ProcessableItemListView,ModelChoiceView}.swift`; Files pane adopts it (`FileItem` adapter, identical render); Live pane fully adopts it (`SegmentItem` adapter, reasons + per-item retry / retry-with-model / rotate-&-re-run / view-text / reveal + grown scrollable box); `LiveCaptureProcessor.retryFailed(groupIds:override:)` generalized (G1 = all-failed footer); failure taxonomy un-conflated (`succeededNoText` for filed image-only docs — labeling only, deletion path untouched); `OCRProcessor.retryOne(...)` extracted. Builds clean, no new warnings. **Files pane inline-disclosure action UI shipped** (overnight, commit `d068a99`): tap-to-expand rows surface retry / retry-with-model / rotate-&-re-run / view-text / reclassify via `OCRProcessor.retryOne(...)` + `ModelChoiceSheet` + `FileTextViewerSheet`; review-mode keyboard/tap gestures preserved (expand only outside review mode). `.fileAsImageOnly` not surfaced (auto-files via `succeededNoText`). **REMAINING:** live-run GUI verification of the new reasons/retry paths (owner-gated).
- [x] **shipped `f1d2263`, suite-v1.2.0** — Behavior-preserving de-dups (audit `wf_4373722d-e70`): shared text-completion client; small cluster (`highestLeadingNumber`, `monthTag`, `acceptedImageExtensions`, `GatewayConfig.fromDefaults`, `liveProcessingMode`); reconcile iOS(5)/Android(6) recent-years cap. **Correction 2026-07-18:** the **finalize/organize move helper** and the **box/folder color-retag** unification were listed here but `f1d2263`'s own commit body **DEFERRED both** (Tier-2, not provably identical — the `trashOrRemove`+`filedGroupIds` vs `fm.removeItem` paths differ, and 3 drifted color-retag copies remain in `OCRProcessor+ReviewFlows.swift`). They are **still open** and live in `ArchiveProcessor/POTENTIAL_FEATURES.md` → *Maintainability / refactor backlog*. | M | low
- [x] **shipped `b1fc5d4`, suite-v1.2.0** — No-API local features: processing profiles/presets + main-window global shortcuts (start / switch provider). | Views/SettingsView.swift, Views/OCRView.swift, new store | M | low
- [x] **shipped `782dfdd`, suite-v1.2.0** — Output-folder picker in the Live Capture pane (+`?` help + gray-out); unify with Process Files `outputDirectory`. **Tier-2** (output path) — add the picker + wire the EXISTING setting; don't change write/move logic. | M | low
- [x] **shipped `d2de49d`, suite-v1.2.0 (owner live-verified pairing).** **Remove the Mac Transport picker — auto-run both receivers.** The phone already chooses its transport at pairing (Wired/Wi-Fi/Cloud), so the Mac-side lan/cloud setting is redundant + a footgun (left on Cloud, Wi-Fi pairing silently dies, and vice-versa — hit live 2026-07-07). Instead: the Mac always runs the LAN `CaptureServer`, and *also* runs the Drive relay watcher automatically whenever it's signed into Google + a session is active (sign-in = the enablement, not a mode). Drop the Transport picker from `SettingsView` (keep the "Sign in to Google Drive" config); emit ONE combined pairing QR (host/port/token + relay token) so any phone-side choice works from a single scan; show dual status (Listening + Watching Drive). Gate the Drive poll to active sessions to save quota. **Tier-2** (Capture/Net/Views) — worktree + adversarial review; verify LAN via the android-ui-test-harness + the cloud path with a paired phone. | Capture/CaptureSession.swift, Views/SettingsView.swift, Views/LiveCaptureView.swift | M | low
- [x] Connectivity UX — **superseded/shipped** by the cloud-transport integration (legible Wi-Fi failure + reachability preflight landed; USB + Drive relay is now the direction). ✅
- [x] **shipped `338dc1b`, suite-v1.2.0 (B2)** — Keep OCR/progress live while the per-segment tag card is open (looks hung today). | Views/LiveCaptureView.swift | S
- [x] Tag card: when the Spotlight tag index is still building, present UI saying so instead of silently-empty autocomplete. ✅ `SystemTagsProvider.isReady` (false until first gather) → SegmentTagCard shows a spinner + "building tag suggestions…" that clears when the query finishes. | Views/LiveCaptureView.swift (SegmentTagCard), Tagging/SystemTagsProvider.swift
- [x] After rotation review, if finalize/processing is still running, show a throbber so the gap before collection naming doesn't look hung. ✅ LiveCaptureView overlay: "Finishing — processing segments…" shown while `isFinalizing && no sheet` (the regen gap; gated off during the finalize move which has its own spinner). View-only — no Capture/ change needed. | Views/LiveCaptureView.swift
- [x] **shipped `6ea268a`, suite-v1.2.0 (B4)** — Re-pair coordination: auto re-show QR on phone re-pair; split "listening" vs "connected"; verify USBBridge re-runs `adb reverse`. | Net/, Views/LiveCaptureView.swift, companions | M
- [x] **shipped `6ea268a`, suite-v1.2.0 (B5; residual `resolvedGroupIds` resurface tracked as B9 in KNOWN_ISSUES)** — Streaming residuals (mostly shipped in the cloud-transport work — Finish drain-gate + phone queue-depth + "End segment = the only done action" landed): finish/verify any remainder — `needsResend` for P10/reclassify in-flight, `completedDocGroups` persistence across Mac restart. | Capture/LiveCaptureProcessor.swift, companions | M
- [x] **shipped `7aace39` + audit fix, suite-v1.2.0 (see KNOWN_ISSUES ✅ FIXED)** — KNOWN_ISSUES #2: merged multi-page docs leave exported originals loose — thread per-page image URLs into `organizeOutput`. **Tier-2 file-move**; needs a live pipeline run. | OCR/CollectionSegmenter.swift, Capture/LiveCaptureProcessor.swift | M
- [x] **Owner-gated: live Google Drive end-to-end test — DONE 2026-07-07.** Android phone→Drive→Mac verified end-to-end (sign-in, single photo, multi-page segment + Mac tag card, Box/Folder markers, Finish; photo durable in the Mac session + backup folder). Fixes landed: `DriveError` legibility + `DriveAuth.init` whitespace-trim; console setup (Desktop client for Mac, Android client + SHA-1 + **Custom URI scheme enabled** for the phone) captured in the Processor CLAUDE.md Live Capture section. ✅
- [x] **iOS Drive-relay on-device OAuth — implemented.** `DriveAuth.swift` (`ASWebAuthenticationSession` + PKCE, `drive.file` scope, thread-safe `TokenStore` for `DriveClient`'s blocking token provider); `CaptureViewModel` gains `TransportMode` (.lan/.drive) + auto-selects Drive when QR has a relay token and user is signed in (falls back on LAN-unreachable too); `ConnectScreen` gains a "Sign in to Google Drive" section. `project.yml` registers the reversed-client-ID URL scheme. **Placeholder client ID** — needs a real iOS OAuth client in GCP project YOUR_GCP_PROJECT (bundle ID `com.archiveprocessor.capture.ios`, "Custom URI scheme" enabled). iOS build clean, no new warnings. On-device testing deferred → `ArchiveProcessor/POTENTIAL_FEATURES.md`. | ArchiveCaptureiOS | M


## P3 — Suite structural

- [x] Processor Implementation Map added to `ArchiveProcessor/CLAUDE.md` — 2026-07-07. ✅
- [x] De-nest the `App/App` folders → `App/macOS/`. Both apps build (0 warnings), 161 Reader tests green, DMG verified. ✅


## Flagged — need the owner present / GUI / a scratch-corpus write

- [x] **Headless GUI-test lane for the daemon — Tart macOS VM (BUILT 2026-07-28).** macOS has no `Xvfb`, so host GUI tests hijack the one console `WindowServer` (the screen); a **Tart** `macos-tahoe-xcode:26.3` VM (macOS 26 + Xcode 26.3, matches host) gives its own virtual display so XCUITest **and** a sighted pixel loop run entirely off the physical monitor. Shipped `ops/gui/vm-gui-runner.sh` + `ops/gui/README.md` §3: **resumable** image pull (skopeo → local `crane` registry → `tart clone`; a network drop costs ≤512 MB vs the non-resumable `tart pull`), VM `archive-gui-runner`, an **XCUITest lane** (Reader UITests build + run + drive the app in-VM — proven, 10/15 pass), and a **VNC sighted lane** (`--vnc-experimental` virtual display; `vncdotool` grabs the framebuffer + injects input from the host — off-screen, and bypasses guest TCC). Also fixed `make-gui-fixture.sh` (was broken since the `c07c98c` corpus slim removed the consecutive `00002–00010` it required → now takes the first 10 real PDFs + honors `AR_FIXTURE_SRC`). **Follow-ups — both DONE 2026-07-28:** (1) ✅ window-scoped the 5 toolbar UITests via a `toolbarButton(_:)` helper in `FixtureUITestCase` (scope to the "Archive Reader" window + prefer the hittable match) → **full Reader UITest suite is 15/15 green in the VM** (was 10/15). (2) ✅ wired into the periodic health gate as a **fail-open** step — `ops/autonomous/gui-vm-gate.sh` + a hook in `health-gate.sh`, **ON by default (owner enabled 2026-07-28; `AUTONOMOUS_GUI_VM=0` disables)**: missing-VM/boot/timeout → skip (never parks; inert where no VM), REDs only on a reproducible `** TEST FAILED **` (retry-once). On-by-default also raised `GATE_MAXRUN`→50 min (absorbs the ~15–20 min VM step; else a slow cold run could false-park), added a fixture-absent WARN, and updated session guidance (CLAUDE.md loop step 2 + resume-prompt STEP 3.5) so sessions verify view/interaction changes in the VM **screen-free, regardless of gui-mode**. **Item-picking gate RELAXED / `gui-mode` RETIRED (2026-07-28, owner-directed):** GUI items now run + verify OFF-screen in the VM by default (no gate); Live-Capture E2E runs on the Android **emulator** (unattended — the harness is "emulator only, never a physical phone"), so the daemon needs **no capability flags at all**. `gui-mode` + its `daemon.sh gui`/taskport/UI-automation machinery is DELETED from `daemon.sh`, the resume-prompt (STEP 1/2/3.5), the daemon work-fingerprint, `prove-daemon.sh`, and `next-queue-item.sh`; owner-interaction/hardware work is simply not daemon work (→ Morning Review / hold-queue). Model: unattended-by-definition, so flags key off machine capability (there are none left needed), never owner presence. prove-daemon 72/72; taskport confirmed already-secure (nothing stranded). | files: FixtureUITestCase/NavigationUITests/ViewerUITests, ops/autonomous/{gui-vm-gate,health-gate,archive-suite-autonomous,resume-prompt,daemon.sh,next-queue-item,tests/prove-daemon}, ops/gui/{vm-gui-runner,README}, CLAUDE.md, ArchiveReader/scripts/make-gui-fixture.sh | done
- [x] **GUI-verified 2026-07-08 (owner-driven, on the AR-Smoke scratch corpus, checked at the on-disk xattr level):** Reader inline tag-editor commit — Return-commit ✓, blur-commit of a completed token ✓. Found the half-typed-fragment case *dropped* the word (the documented no-lost-tag safety) yet left a misleading phantom chip; owner chose **WYSIWYG** instead, so `SubjectTokenField` now commits the field's tokens on blur (typed text sticks). Adds route through `TagWriter` (no tag loss); Tier-2 APPROVE. | files: Views/SubjectTokenField.swift | done
- [x] **Perf-checked the nav Table 2026-07-08 (owner-driven GUI, 40k synthetic scratch corpus): the SwiftUI `Table` JANKS at scale.** Scroll stutters; filter-box *keystrokes* lag + can beachball (per keystroke it re-filters 40k AND re-diffs the whole Table on the main thread); sort is slow. Discovery/load of 40k was fine — it's the Table view layer. At the ~150k production target this would be worse. → spawned the follow-up below.
- [x] **Reader: swap the nav SwiftUI `Table` → AppKit `NSTableView`** — `AppKitTableView.swift` (`NSViewRepresentable` wrapping `NSScrollView`+`NSTableView` with `NSTableViewDiffableDataSource`): virtualized rows + cell reuse (fixes scroll); incremental snapshot apply (fixes sort); debounced `filterSearchText` (150 ms, fixes the typing beachball). `ContextMenuTableView` subclass for right-click menu; `ContextMenuActions` trampoline bridges NSMenu items to `NavigationModel`. Model + `TagWriter` untouched (no data-safety surface). Build clean, 161 tests green. **Full GUI re-verify deferred → Morning Review (owner-gated).** ✅
- [x] Remove stray `InlineTest` tag on the SCRATCH corpus — **N/A: scratch corpus (`AR-Smoke/Batch-A/00001`) no longer exists on disk** (directory empty, file cleaned up). No action needed. ✅


## Processor/Capture — WS11 paced re-review findings (2026-07-18, autonomous)

- [x] **W3.cap-r3-fu10 [MED · reachability decision] — ✅ DONE 2026-08-04** (`0ee6179` code + Test 21 §3b +
  four measured mutants; this commit, trackers). **The question: is the "Finishing — processing segments…"
  throbber meant to BLOCK input, or only to explain the wait?** Its scrim was
  `Color.black.opacity(0.2).ignoresSafeArea()` in an `.overlay` with no `.allowsHitTesting(false)`, and a
  `Color` is hit-testable — so it blocked every click in the Live Capture panel as a SIDE EFFECT of being
  drawn, with nothing saying whether that was meant. That ambiguity is what let `W3.cap-r3-fu7` reason from
  this overlay in both directions and get it backwards once.
  **DECIDED: frozen, not live** — which is also what the prior session recommended to the owner in Morning
  Review, so this implements the recommendation rather than pre-empting a live choice. Three grounds: the
  overlay stands in for the sheet that is not up yet and a sheet is modal, so freezing keeps the whole
  `isFinalizing` window uniform instead of half-modal; every mutating affordance under it is a hazard in this
  window (fu7's retry, fu11's Clear, fu3's remove-photo, and Finish which is already `.disabled`); and it is
  not a lock-out, since the mode Picker is a sibling in `ContentView.mainContent`'s VStack, outside the frame
  the overlay is sized to.
  **Expressed in code, not only in prose.** `.frame(maxWidth:maxHeight:)` + `.contentShape(Rectangle())` make
  the whole overlay one hit target — the `.frame` is load-bearing, because `Color` is the only greedy view in
  that ZStack and `.contentShape` alone would shrink to the throbber card if someone removed it. The predicate
  is extracted as `LiveCaptureProcessor.isFinishingScrimUp` (it had been restated in four places, one of them
  a hand-copied driver assertion that could have kept passing while the view drifted), and the throbber now
  carries `accessibilityIdentifier("live.finishing-throbber")` so `W21.vmgui-d` can wait on the window and
  assert a button behind it is not `isHittable`.
  **⚠️ The item's own suggested conclusion was too coarse and is NOT what shipped.** It said "blocking →
  re-label fu7's gates belt-and-braces". They split three ways, and only one leg is spare: to the MOUSE the
  retry buttons are covered twice; to the KEYBOARD and to VOICEOVER only `.disabled` covers them, because a
  hit-test scrim is neither a focus ring nor an AX barrier; and on the deferred `modelChoiceTarget` Apply only
  `retryFailed`'s guard covers them, because a presented sheet floats ABOVE the overlay. Recorded at the
  overlay, at `retryFailed`, at the bulk button, at `SegmentItem.actions(for:finalizing:)` and in
  `ArchiveProcessor/CLAUDE.md`.
  **Knock-on severity calls, which is why this was MED despite changing no behaviour on its own.**
  `W3.cap-r3-fu11` (ungated Clear) is **re-graded MED → LOW**: `clearSessionState()` has exactly one
  production caller, that button, with no keyboard shortcut and no menu route, and it sits under the scrim —
  so no mouse path survives. fu7's mutants **P6/P7 stay 0 RED and now provably so**: a click-driven XCUITest
  cannot kill a `.disabled` on a control whose clicks the scrim already eats, so `W21.vmgui-d` must drive the
  KEYBOARD for those — recorded in the driver so the lane writes the right test instead of reading a clicking
  one's 0 RED as coverage.
  **Test.** Driver Test 21 §3b measures the COVERAGE half — the scrim is up for exactly the exposed window,
  and down when idle, under either sheet, and after the window closes. The two sheet states are reached by
  ASSIGNMENT and restored on the same MainActor turn (deliberately not through the real `finalize(_:)`, which
  moves files and would make a cosmetic mutant's kill depend on the harness's env for file safety); the check
  asserts the restore. `test-recovery.sh` 156 → **157 checks ALL PASS**; build clean, no new warnings.
  **4 mutants measured: S1 1 RED** (`!showFinalizeSheet` dropped), **S2 1 RED** (`!showRotationReview`
  dropped — a SPECIFICATION kill; no path reaches that state today), **S3 1 RED** (property forced `false`),
  **S4 2 RED** (forced `true` — predicted 1, measured 2, the second being the post-window sample). **S5/S6**
  (`.contentShape` deleted; the overlay's `if` deleted) are **0 RED BY CONSTRUCTION** — hit-testing and
  rendering are invisible to a headless driver, which is the point rather than a gap.
  **ADVERSARIAL (independent pass, opus, read-only) — seven findings, all folded in before the code shipped.**
  It confirmed the invalidation, sheet-float, escape-hatch, sole-caller and non-vacuity claims, and refuted or
  narrowed six others: (1) "nothing under the scrim is worth reaching" was FALSE — `SegmentItem.actions`
  deliberately KEEPS `.viewText`/`.revealFiles` while finalizing and driver check 7 asserts it, so freezing
  takes two read-only affordances with it, now stated as accepted collateral; (2) the overlay sits over an
  AppKit-backed `HSplitView`, the case where the SwiftUI hit-test story is least certain, so the DECISION
  (normative) is now separated from what was OBSERVED (nothing), with the split divider named for the lane;
  (3) "`.contentShape` survives removing the `Color`" was false — the `.frame` makes it true; (4)
  "`finishSession` refuses to raise `showRotationReview` while finalizing" was false, that function has no
  such guard, and the real argument (through `requestFinish` and `pendingFinish`) is now written out; (5) this
  change's own 33-line insertion broke two line citations inside the very comment that warns a mis-cited line
  caused a real analytical error — fixed, plus a third inherited from the tracker; (6) "Full Keyboard Access"
  is the wrong name for the macOS 14+ setting ("Keyboard navigation", off by default) and the keyboard/AX legs
  are reasoned not measured — both now labelled, since inferring reachability without observing it is the
  exact error this item exists to correct; (7) the predicate excludes two of the view's FIVE sheets, so "no
  sheet over the panel" was wrong as a rule statement. One residual filed: **`W3.cap-r3-fu10-fu1`** — the
  window is modal to the pointer only; making it modal to focus + AX interacts with the VM lane's own test, so
  it is `(blocked-on: W21.vmgui-d)`.

- [x] **W3.cap-r3-fu11 [LOW · data · re-graded MED → LOW by fu10] — ✅ DONE 2026-08-04** (`fb833ea` fix;
  `c903bb8` Test 22; this commit, five mutants + the adversarial pass + trackers). The Captured pane's Clear
  button was `session.clear(); liveProc.clearSessionState()` — **two calls and no gate**, live in the exact
  window `W3.cap-r3-fu7` closed for the retry, and strictly more destructive there: `session.clear()` Trashes
  the source photos the detached `writeSegmentFiles` is still reading, and the state reset empties
  `staged`/`retained` under the loop about to `staged.firstIndex` them, so the regeneration's `guard let idx`
  finds nothing, its partially-rewritten `_processed` files are orphaned and the sources are in the Trash.
  Recoverable (Trash, per the Recovery Core Directive) — which is why LOW, not a data-loss item.
  **The fix is ONE DOOR with ONE GUARD**, the shape `fu5` (one exit from `finalizedGroups`) and `fu6` (one
  labeller) converged on: new `LiveCaptureProcessor.clearSession()` = `guard !isFinalizing` → `session.clear()`
  → `clearSessionState()`, and `clearSessionState()` is now **`private`** so that is the only way in. The view
  calls it and carries `.disabled(liveProc.isFinalizing)`.
  ⚠️ **Why the guard could not live on the button**, which is the part worth carrying forward: not (only) the
  deferred-callback argument `retryFailed` makes, but **ATOMICITY**. A refusal that splits the pair produces an
  outcome worse than either half — sources in the Trash while `staged` still lists the segments pointing at
  them — so the two have to refuse together, which a two-statement button action cannot promise. Reachability
  is the *second*, independent reason: `fu10` settled that the scrim eats the pointer, so what the view's
  `.disabled` actually defends is the keyboard/VoiceOver route (`W3.cap-r3-fu10-fu1`), not the mouse.
  **SCOPED to `isFinalizing`**, deliberately not widened to `requestFinish`'s triple — same call `retryFailed`
  made: those states put a modal sheet over the panel and clearing from under an unconfirmed collection sheet
  is a legitimate abort with no write in flight. Mutant M4 is 1 RED on that, so the WIDTH is tested, not
  merely preferred.
  **Driver Test 22, six checks, all driven for real** (real ingest → OCR stub → real `writeSegmentFiles` →
  real `finishSession()` → real rotation review → real `applyRotationReviewAndFinalize`), scratch-only, $0.
  Check 4 is deliberately COMPOUND — sources on disk, sources in the pane, `staged`, `finalizedGroups`,
  `retained`, output files — because a check per half would pass on a single-sided guard.
  **NON-VACUITY measured on FIVE mutants, one-to-one:** M1 the guard deleted (the shipped defect) → **2 RED**
  (4, 5); M2 `session.clear()` hoisted above the guard → **2 RED** (4, 5); M3 the mirror, `clearSessionState()`
  hoisted above it → **2 RED** (4, 5 — predicted as 1 and recorded as measured: emptying `staged` alone
  strands the regeneration, so the state half is not the harmless side of the split); M4 widened to the triple
  → **1 RED** (6, the width); M5 the view's `.disabled` deleted → **0 RED**, unavoidably (a SwiftUI modifier is
  invisible to a headless driver — same limit as fu7's P6/P7, and it needs a **keyboard-driven** XCUITest in
  `W21.vmgui-d`, not a clicking one, since the scrim already eats clicks).
  **This CLOSES the `staged`-implies-`finalized` enumeration** at `applyRotationReviewAndFinalize`: all three
  entrants (`retryFailed`, `finalize`, `clearSessionState`) now refuse, where before only two did and the
  argument rested on MainActor synchronicity alone. That comment, and the scrim's hazard list in the view, are
  corrected — `removePhoto` (`W3.cap-r3-fu3`) is now the only one of the four still relying on the overlay.
  **The adversarial pass's finding, recorded at `clearSession()` rather than filed:** gating Clear is not the
  same decision as gating a retry, because **Clear is the operator's escape hatch** — a stuck `isFinalizing`
  makes a retry annoying but strands the session. Checked rather than assumed: the flag is set in exactly two
  places and both clear it immediately after their single `await` with no branch, `throw` or early `return`
  between, and neither `writeSegmentFiles` nor `executePlans` is throwing, so there is no reachable stick.
  What would create one — an early `return` added into either of those two gaps — is named in the comment.
  **⚠️ An ops fact the mutant pass turned up, which fed back into `W21.recovery-timeout`:** the ALL-PASS suite
  runs in 15 s but M1 and M3 take **81 s and 79 s**, past `test-recovery.sh`'s 60 s wait — so a real
  regression of this guard prints "timed out", not a FAIL. The first mutant pass duly misread M1's missing
  report as 0 RED. The failing case is systematically slower than the passing one, so that wait is calibrated
  against the wrong run; `W21.recovery-timeout` now carries the numbers. (A second self-inflicted lesson from
  the same pass, for whoever writes the next one: the harness reverted mutants with `git checkout -- .`, which
  also reverted the *uncommitted* test it was measuring, yielding two more bogus 0-REDs. Commit the test
  first, then revert per-file.) | Capture/Views | Tier-2

- [x] **W3.notes-passage-paste-at-caret — typing or pasting next to a provenance chip silently DROPPED the text and multiplied the block header — ✅ DONE 2026-08-05** (this commit).
  **Root cause, measured.** `.noteBlockSource` / `.noteImageRelPath` describe ONE attachment character each —
  identities, not styling. AppKit seeds `typingAttributes` from the character before the caret, or AT the caret
  when there is none (offset 0), then `insertText` merges them into every inserted run lacking the key; it
  strips `.attachment` and knows nothing about these two. So a caret adjacent to a chip stamped that chip's
  `SourceAnchorBox` over everything inserted — and `MarkdownBridge.serialize`'s chip test asks only "does this
  position carry `.noteBlockSource`?", never "is this THE attachment character?", so it minted one
  `<!-- block: … -->` header per stamped character and swallowed each one's text.
  **Measured:** pasting a 62-char passage at caret 0 → 62 headers, all bodies empty, **zero** `](assets/…)`
  refs, the imported bytes on disk with nothing pointing at them (the mirror of the W14.3 bug `testG13`
  guards). With no paste at all: typing one plain character at offset 0 before a chip emitted TWO headers and
  DROPPED the character; before an inline image it duplicated the asset ref and dropped the character. Silent
  data loss in ordinary editing. After: 2 headers, 1 asset ref, G13 41.7 s green, G4 17.6 s green, full lane
  notes 15/15 + reader 16/16.
  **Fixed in `EditorTextView.typingAttributes`'s setter** — the one point AppKit sets them — not in the
  serializer and not as an offset-0 special case: this keeps the TEXT STORAGE correct (which
  `NotePassageSource.blockRanges` depends on, since it enumerates `.noteBlockSource` RUNS to split the copy
  path) and covers every insertion site plus plain typing at once. `.noteBlockKind` / `.noteInlineCode` are
  deliberately not stripped — they legitimately continue while typing.
  ⚠️ **How it stayed hidden:** `setEditorSelection` never cleared its input field, so `setEditorSelection(0,0)`
  silently failed and left the previous whole-body selection in place — G13 had been exercising only
  replace-whole-selection, never the ordinary caret paste, for its entire existence. Fixing the helper is what
  exposed this. Residual, filed not fixed: `W3.notes-chip-header-needs-a-line-break`.
  | ArchiveNotes/Editor | Tier-2

- [x] **W21.vmgui-g13 — the seams that could not say why they did nothing — ✅ DONE 2026-08-05** (this commit).
  Filed as a "reproducible" RED, regraded to a flake when it passed four runs in a row, and finally resolved as
  a REAL bug once the lane it ran in was fixed (`W21.vmgui-g14-leak`) — the failure then moved to the
  `.md`-reference assertion and reproduced on both attempts. Its two original failures came from the one gate
  run whose notes lane was broken; the genuine defect it was pointing at is
  `W3.notes-passage-paste-at-caret`, now fixed.
  **What shipped here** is the diagnosability, and it is why the cause was findable at all: `handlePassagePaste`
  and `copyPassageIfNote` each reported through a `Bool` their DEBUG seams threw away with `_ =`, so a declined
  paste and a paste that imported nothing were the SAME observation, and the test asserted only that the
  button was clickable. Both seams now return a diagnosis — the outcome, which of the guards declined, and
  `imgs=`, the count of image bytes actually on the pasteboard, without which an `ok` outcome is a dead end
  (`ExtractBuilder` `continue`s past a nil import and still returns non-empty markdown, so a paste that
  imports ZERO files reports success). G13 also now asserts the paste RAN, and that the SOURCE note gained no
  second asset — the check that separates "declined" from "imported into the wrong item" — placed BEFORE the
  assertion that fails, because `continueAfterFailure = false` aborts on the first one. Same defect class as
  `W16.bat7`: a caller reading a handler's silence as success. | ArchiveNotes/Editor + Tests | Tier-2

- [x] **W21.vmgui-g14-leak — nothing ever guaranteed ONE window, so the Notes GUI lane was passing by luck — ✅ DONE 2026-08-04** (this commit).
  ⚠️ **Filed with the wrong mechanism and corrected here.** It was filed as "G14 leaks a window, cascading six
  false failures". The leak was a SYMPTOM. What was actually true: `ArchiveNotesApp` declares TWO
  auto-opening `Window` scenes, BOTH render `NotesBrowserView`, so `an.status.indexReady` / `an.editor.text` /
  the toolbar ids exist TWICE whenever the Extracts window is open — and almost every check queried UNSCOPED,
  so those queries threw "Multiple matching elements" and blamed whatever test ran next.
  `closeExtractsWindow` was called only at the END of G12/G14, never in setUp, so the suite depended on the app
  CONTAINER remembering "Extracts closed" from an earlier run. A fresh container — which `notes:prerun`
  creates — inverts that, and `notes:prerun`'s `rm -rf` was fire-and-forget, so a silently-failed wipe is what
  had been keeping the suite green. **Measured, testG0 ALONE, container wiped:**
  `windows=2 titles=["Archive Notes","Extracts"] indexReadyMatches=2`, and
  `extracts: seen=true closeBtn=true hittable=false closed=false` — the close button EXISTS but is NOT
  HITTABLE, because the second scene launches occluded BEHIND the main window. That is why two attempts at
  raising the timeout changed nothing: occlusion, not timing.
  **Fixed three ways, in order of how much weight each carries.** (1) LOAD-BEARING — a `mainWindow` scoping
  root, with the shared helpers (`editor`, `indexReadyProbe`, `rawToggle`, `selectItem`, the seam clicks,
  `lastOpenedURL`, `an.toolbar.new`) and the `scope ?? app!` defaults re-rooted to it. A window-scoped query
  resolves to one element or none, never two, so correctness no longer depends on window COUNT and a future
  leak cannot break a later test. Menus stay app-rooted (`app.menuBars`/`app.menuItems`/`activate`/`typeKey`)
  — a blanket rewrite would break the suite. (2) HYGIENE — setUp closes the Extracts window, raising it via
  Window ▸ Extracts first so the button is not occluded. (3) The prerun's wipe is CHECKED and warns, because
  fresh-vs-inherited container are different tests. **Result: notes 15/15, reader 16/16, three consecutive
  green lanes — and G14 went 1101.600 s → 37.1 s, so its 18-minute outlier was the two-window state too, not a
  separate problem.** Residual risk filed as `W21.vmgui-winsize-writeback`. | ArchiveNotes/Tests + ops | Tier-2

- [x] **W21.vmgui-flakereport — the flake guard retried, learned the answer, and then threw it away — ✅ DONE 2026-08-04** (this commit).
  `gui-vm-gate.sh`'s `show_failures()` looped BOTH attempts and `sort -u`'d them, printing the union directly
  beneath "RED — reproducible UITest failure in: <app>". The APP-level guard was always right (it clears an app
  only when the whole retry is green), but at the TEST level the union discarded the retry's answer, so a test
  that failed once and PASSED on retry appeared as evidence for a reproducible failure, indistinguishable from
  one that failed twice. Found the expensive way during the owner's 2026-08-04 gate run: the notes lane
  reported `testG13…` **and** `testG5…` as the reproducible failure, and the per-attempt logs showed G5 failing
  at 46.250 s and then **passing on retry at 18.154 s**. The summary sent a reader to investigate a bug that
  was not there — the mirror image of this file's own rule that a gate saying ✓ for work it did not do is worse
  than no gate. `show_failures()` now partitions: REPRODUCIBLE (failed both attempts — what the RED is about),
  FLAKED (failed attempt 1, passed on retry — explicitly "do not chase these"), and FLAKED THE OTHER WAY
  (passed first, failed on retry — named rather than hidden, since it means the suite is order/timing
  sensitive). When attempt 2 ran no tests it says so and shows attempt 1 unpartitioned rather than inventing a
  distinction. Evidence is still preserved in full — both per-attempt log paths are printed. Verified by
  running the shipped functions against the two REAL attempt logs from the failing run: G13 → REPRODUCIBLE,
  G5 → FLAKED. The two findings it disentangled are filed as `W21.vmgui-g13` and `W21.vmgui-g5-flake`.
  | ops/autonomous | Tier-2

- [x] **W3.cap-r3-fu12 [LOW · behaviour decision] — ✅ DONE 2026-08-04** (`5180d03` the decision + the gate;
  `5148086` Test 25; `ed8c429` round-1 mutants; `776fa73` the adversarial pass and the four fixes it forced;
  this commit, trackers). An emptied Captured pane hid **Finish** and **Clear** even while the session held
  unfiled staged segments: the header cluster was gated on `!session.photos.isEmpty`, `liveProc.staged` is
  independent of it, so deleting every received page with the per-thumbnail ✕ left segments already OCR'd,
  tagged and written to `_processed/` with nothing to file them and nothing to abandon them. The pane just said
  "Waiting for photos…"; recovery existed (shoot one more photo) but nothing said so.
  **THE DECISION, since it was filed as one rather than as a bug: offer the SAME two controls.** Finish, because
  the OCR behind those segments is already BOUGHT and filing them is the only way the operator sees it —
  stranding paid work behind an undiscoverable gesture is the money-path harm. Clear, because abandoning is the
  other half of the same choice and an operator who cannot abandon is stuck. Gated on a new model property
  `hasUnfiledWork` (`!statuses.isEmpty || pendingFinish`) rather than a view predicate, for the reason
  `isFinishingScrimUp` was named on the model: a headless driver can read a model property and cannot read a
  `View`. `statuses` rather than `staged` is the WIDER spelling on purpose and it is measured (M2), covering a
  segment that failed to file and an orphaned in-flight row as well. Both header arms compose the same extracted
  `clearButton`/`liveFinishControls` — no tailored copy, because fu9-fu1's own comment warns that a copy-paste
  is how one of two renderers drifts. It also un-stranded a case the item never named: a PARTLY-failed finish
  left its failed groups behind the green "Session complete" summary with no way to re-Finish or discard them.
  🔺 **THE ADVERSARIAL PASS FOUND THAT v1 SHIPPED A PRIMARY BUTTON THAT DID NOTHING** — the same class as
  fu9-fu1's ("an affordance that hides in the state you need it") turned inside out: this one was *present* and
  inert. `finishSession` guards `!staged.isEmpty` while `pendingFinish` is cleared one level above it, so with a
  roster of nothing but an orphaned row (✕ the last page of a document still in OCR) a press armed the flag,
  spawned a watchdog Task, lowered the flag and returned — no sheet, no status line, no state change, one
  orphaned Task per press. Its sharpest point was that **Test 25's own check 7 CREATED that state and asserted
  `hasUnfiledWork`**, i.e. blessed drawing the cluster there without ever pressing the button. Fixed with a
  second, narrower property `canFinish` (`!staged.isEmpty || !session.groups.isEmpty`, the second disjunct
  preserving the documented "Finish also recovers an un-ended segment" case) ADDED to the button's `.disabled`
  rather than replacing its terms — money path, and a derived-equivalence argument is not worth one `||`.
  Three more fixes from the same pass. **A false FILE-SAFETY claim:** the section said an explicit
  `chosenExisting` means `finalize` "can never consult `currentOutputDirectory`" — it evaluates that
  unconditionally one line after its guard, and check 4 reaches `beginFinalize`, which *enumerates* it on disk.
  Nothing writes outside `tmp` (read-only enumeration, plus `test-recovery.sh` exports `LIVECAPTURE_TESTOUT`),
  but the mechanism was mis-located, so the comment was telling the next author that `finalize` protects them;
  it now names both real guards and carries a ⛔ on the "drive the real sheet's drafts" refactor that would file
  into the operator's real output folder. **A wrong reachability bound:** "(0 left)" was claimed reachable for
  ≤1.5 s via the per-item-sheet grace; it is the **5 s** watchdog tick, via the ordinary ✕ gesture, because
  `removePhoto` neither clears the flag nor re-enters the gate — which is what turned "not worth a third message
  branch" into worth one. **A performance regression:** `processingCount` rebuilt `session.groups` (a computed
  property that builds a dictionary and sorts twice) once per status row, read from a SwiftUI body that
  re-evaluates on every arriving photo; hoisted to one group-id Set. Plus `clearButton` got a `.help`, since it
  was the only button in the cluster without one and sits beside "Cancel finish", which costs nothing.
  Comment corrections: "can never resolve" softened (a re-paired phone re-uploads, so the group can return —
  the predicate is live, the phrasing was not); M4 is **not** "the pre-fu12 spelling" (it now strips the finish
  hold too, a combination that never shipped); check 3 admits it discriminates nothing about `hasUnfiledWork`,
  its first term being implied by its second.
  Driver **180 → 188 checks, ALL PASS, 0 FAIL, ~18 s** (`W21.recovery-timeout` headroom intact); six key-free
  Capture/finalize drivers green alongside (manifest-persistence 109, merge-safety 15, segment-json 30,
  multipage-reocr 29, filerelay 10/10, output-file-safety 18). Seven mutants BUILT and RUN against the final
  baseline: **M1 0 / M2 2 / M3 2 / M4 2 / M5 2 / M6 0 / M7 1 RED**. Three predictions were wrong and are
  recorded as measured rather than quietly fixed (M2 predicted 0, M3 predicted 1, M5's second RED is a
  pre-existing check). M6 records that `hasUnfiledWork`'s `pendingFinish` disjunct is **unreachable dead code**,
  kept only so this gate cannot delete fu9-fu1's escape — "belt-and-braces, unmeasured, argued" is its honest
  status. M1's 0 RED is the same priced view→model gap fu9/fu9-fu1 recorded: nothing headless reads a `View`, so
  `live.clear` / `live.finish` identifiers were added for `W21.vmgui-d` to press.
  Two residuals filed rather than guessed at: **`W3.cap-r3-fu12-fu1`** (Clear here has no count and no
  confirmation, and wipes `finalizeSummary` — the only record of what a partly-failed finish did not file) and
  **`W3.cap-r3-fu12-fu2`** (with Review rotation ON, Finish from a ✕-emptied pane reviews pages whose sources
  are in the Trash and discards every correction silently; pre-existing, promoted from two-step to one tap by
  this arm). | Capture/Views | Tier-2

- [x] **W3.cap-r3-fu9-fu1 [LOW · ops/UX] — ✅ DONE 2026-08-04** (`124652f` the button + the guard; `f311f75`
  Test 24 + round-1 mutants; `483dc8a` the adversarial pass and the fix it forced; this commit, trackers).
  `LiveCaptureProcessor.cancelPendingFinish()` was correct code with **no caller in the shipped UI** — its only
  caller was `ManifestPersistenceTestDriver` — so the only way out of a pending Finish was **Clear**, which
  Trashes every source photo of the session. Now wired to a "Cancel finish" button in the pending-finish row,
  beside the message that already explains what the finish is waiting for. Cancelling un-arms the wait and
  nothing else: no OCR cancelled, no `staged`/`retained` dropped, no file touched, and `requestFinish`'s
  `completeAllOpenDocGroups()` recovery deliberately NOT rewound (there is no supported undo — that rollback
  fires only when the manifest write failed). `guard pendingFinish` so a cancel with nothing armed cannot
  narrate a finish that was not happening.
  🔺 **THE ADVERSARIAL PASS SENT THE FIX BACK, and the lesson has the same shape as fu9's: an escape hatch
  nested inside the predicate that hides the thing it is an escape FROM closes nothing.** All three skeptics
  converged on it independently — v1 put the button inside `if !session.photos.isEmpty`, the very gate all
  three of its own new comments cited as the reason Clear was inadequate. The state is reachable and is now
  MEASURED rather than argued (check 7): arm a Finish held by a still-heartbeating phone, delete the received
  pages with the ✕, and `pendingFinish` survives — `CaptureSession.removePhoto` neither clears it nor re-enters
  `proceedToFinishIfReady` — with the entire control cluster unrendered and nothing on screen saying a finish
  is pending. Not self-healing either: `phonePendingActive`'s 20 s staleness clock starts only once the phone
  goes quiet, so the 5 s watchdog re-holds. Fixed by extracting `pendingFinishRow` and rendering it in TWO
  places, the second an `else if liveProc.pendingFinish` arm for the emptied pane. Row only — what else an
  empty pane with live staged segments should offer is filed as **`W3.cap-r3-fu12`**.
  The pass also corrected four claims, none behavioural: the four-holds enumeration OVERSTATED the fix (a
  finish held by a tag card or a live per-item sheet is held *by a modal over the panel the button lives in*,
  so the button is unpressable there and dismissing the sheet is itself the exit — and Clear was never
  reachable there either; the button serves the in-flight-OCR and phone-drain holds, which are the two that
  can persist indefinitely with nothing on screen to resolve); the `guard` was written as if it made the status
  write safe, when a cancel with a finish armed can still overwrite the late-page "kept in the Backup Folder"
  notice (kept the write — every arriving photo already overwrites that line, so it is not a new class of loss
  — and said so instead of implying otherwise); the `completeAllOpenDocGroups` citation was backwards; and,
  pre-existing but leaned on by the new comment, `isFinishingScrimUp`'s note claimed `finishSession` has two
  callers including `requestFinish` when it has one (the conclusion it supports — `pendingFinish ∧
  isFinalizing` unreachable, so the omitted `.disabled` is right — was independently re-traced and holds).
  Two test weaknesses fixed and re-measured: check 5's 0.5 s negative window discriminated NOTHING (`.staged`
  and `proceedToFinishIfReady` are set in one MainActor turn, so the sample was already after the named event,
  and the only deferred resumers — the 1.6 s grace hop and the 5 s watchdog — sat outside the window), so it is
  gone and the section now has no wall-clock waits at all (`W21.recovery-timeout`); and check 6 asserted a
  LEVEL, which under M3 was green for exactly the wrong reason (`requestFinish` no-ops against an
  already-raised review) — now a false→true transition, and M3 went 3 RED → 5 RED.
  Driver 172 → 180, ALL PASS. Mutants, all built and run: M1 (button deleted — the shipped defect) 0 RED, the
  priced view→model gap (`W21.vmgui-d`); M2 (guard deleted) 1 RED; M3 5 RED; M4 (cancel widened to cancel
  `pageTasks`) 1 RED — but only after check 3 gained a task-handle term, since the stub OCR ignores
  cancellation and the obvious "did it still stage?" assertion measured 0 RED; M5/M6 not run, with reasons
  recorded. Build clean, 0 Swift warnings; manifest-persistence driver (the method's pre-existing caller)
  ALL PASS. | Capture/Views | Tier-2

- [x] **W3.cap-r3-fu9 [LOW · SUSPECTED → closed by construction · presentation] — ✅ DONE 2026-08-04**
  (`7fd8cbb` first fix; `db38627` Test 23 + round-1 mutants; this commit, the adversarial pass + the fix it
  forced + trackers). `LiveCaptureView` attaches FIVE `.sheet` modifiers to one view, and the item asked
  whether a per-item sheet already on screen can SUPPRESS the rotation-review sheet — which if true skips the
  operator's review silently and then DEADLOCKS Finish for the rest of the session (`requestFinish` guards
  `!showRotationReview`, the only writers that clear it are the invisible sheet's own buttons, and
  `clearSessionState` does not clear it either), leaving paid, staged output nobody can file.
  ⚠️ **THE PREMISE WAS NOT VERIFIED, and the fix does not need it to be.** A headless driver cannot see sheet
  presentation at all and the Processor has no VM GUI lane yet (`W21.vmgui-d`), so rather than guess, the three
  things SwiftUI might do with two concurrent presentations were enumerated — and every one is a real failure:
  **suppressed** = the item's own hazard; **queued** = the deferred Apply's `retryFailed` nils `retained[gid]`
  first, so the review that then appears describes a segment being re-OCR'd and `applyRotationReviewAndFinalize`
  silently DROPS its rotation edits (the item's second leg); **stacked** = dismissing the review drops the
  operator back onto a still-presented model sheet whose Apply now lands inside `isFinalizing`, the one entry
  `fu7`'s guard is the whole defence for. So the STATE was made unreachable instead of the behaviour predicted.
  **THE FIX is one term in one guard plus a grace window.** `proceedToFinishIfReady` refuses to START the
  finish while either per-item sheet is up — the same class as the `pendingTagGroup` term already beside it (a
  modal the operator has open, which the finish must not walk into) — and `perItemSheetUp` stays true for
  `perItemSheetGrace` (1.5 s) after the last target clears. Placement is load-bearing: `pendingFinish` is
  cleared on the line before `finishSession()`, so the same refusal one level in would DISCARD the finish.
  🔺 **THE GRACE IS THERE BECAUSE THE ADVERSARIAL PASS BROKE THE FIRST VERSION**, and this is the part worth
  carrying forward: **a cleared target is not the sheet leaving the screen.** `.sheet(item:)`, and the sheet's
  own Apply/Cancel/Dismiss, write nil while AppKit is still animating the sheet OUT (~0.2–0.4 s). v1 advanced
  the finish one MainActor turn after that write — microseconds — so it raised the review DURING the outgoing
  sheet's teardown and turned the concurrent-presentation state into the ORDINARY path rather than the rare
  race the item was filed for, with the worst of the three outcomes (a dropped presentation is unrecoverable:
  Finish dead for the session, and Clear no escape). Two of three reviewers found it independently. The grace
  is deliberately a bounded OVER-hold rather than an `.onDisappear` signal from the view: releasing early
  re-opens an unrecoverable hazard, holding long costs seconds and expires by itself, and a view-fed signal
  could leak and hold forever.
  **Reachability needs no click:** `finishSession` is the only writer of `showRotationReview`, and
  `proceedToFinishIfReady`'s callers are background events (a segment staging, a phone heartbeat, a 5 s
  watchdog). The operator presses Finish while the phone is still draining, opens "Rotate & re-run" while
  waiting, and the drain completing raises the review under their open sheet.
  **The two targets moved out of `LiveCaptureView`'s `@State` onto `LiveCaptureProcessor`** — the guard must
  see them, and a second published copy would be the two-records-one-fact shape `fu1`/`fu6` were filed for.
  `clearSessionState` now resets them too, since a survivor would hold the NEXT session's Finish.
  **Test 23 (9 checks)** drives the REAL `requestFinish` (Tests 21/22 could call `finishSession()` directly;
  this cannot, because the background entrant is the point), in the operator-reachable order the first draft
  got wrong — the tag card is modal, so it is resolved BEFORE a per-item sheet can be opened. Check 4 asserts
  every other term of the guard independently false, so the hold is attributable to the sheet alone; check 6
  asserts the grace as a PAIR (up across the teardown, down after it), since either half alone is satisfiable
  by a mistake. Mutants, all built and run to a written report on a 150 s wait (baseline 172 checks, 0 RED, 0 Swift
  warnings): M1 the guard term deleted → **1 RED** (check 4); **M2 the grace deleted, i.e. v1 → 1 RED**
  (check 6), the kill for the defect the pass found; M3 the delayed hop shortened back to one turn →
  **0 RED**, which is the right answer and the measurement that says the protection lives in the grace and
  not in the hop; M4 the guard moved into `finishSession` → **3 RED** (checks 4, 7, 8). M5 (the view→model
  leg) is buildable and would be 0 RED — not run, and priced as a gap for `W21.vmgui-d`.
  ⚠️ **What this does NOT cover, priced rather than implied.** The VIEW→model leg is UNCOVERED: an earlier
  draft called it "compile-enforced" because the view's `@State` was deleted, and the adversarial pass built
  the counterexample (re-adding a `@State` target and repointing the sheet compiles cleanly, leaves
  `perItemSheetUp` permanently false, and makes the guard a silent no-op with 0 RED anywhere) — so it is
  `W21.vmgui-d`'s to close, and M5 records the cost. Nothing here observes the 5 s watchdog either; an earlier
  draft waited 5.5 s to "cover a tick", which is unbacked (a tick that never armed is indistinguishable from
  one that fired and was held), so that wait was cut to 0.75 s and the claim withdrawn.
  **Knock-ons recorded rather than left implicit:** `fu7`'s deferred-Apply entry is no longer reachable in
  production, so that guard is defence-in-depth now and its SILENT-refusal cost is not live (its DONE entry and
  `retryFailed`'s comment both say so); Test 21's check 8, which flagged itself as coupled to a fu9 fix that
  "refuses during the sheet states", stands unchanged because this fix holds the FINISH instead — discharged,
  not pending. One residual filed: **`W3.cap-r3-fu9-fu1`** — `cancelPendingFinish()` has no caller in the
  shipped UI, so a pending finish's only operator escape is the Clear button, which Trashes the sources; the
  guard's comment claimed otherwise until the pass caught it. | Capture/Views | Tier-2

- [x] **W3.cap-r3-fu7 [LOW · latent · race] — ✅ DONE 2026-08-04** (`765897b` fix + Test 21; `68160b0` five
  mutants; this commit, trackers + the adversarial pass). The item's own suggestion was the cheap one and it
  was right, but not sufficient on its own. `applyRotationReviewAndFinalize` sets `isFinalizing` and then
  writes each changed segment from a DETACHED task, and that is the ONE finish state with no sheet over the
  Live Capture panel — `LiveCaptureView:48` shows a throbber for exactly `isFinalizing && !showFinalizeSheet
  && !showRotationReview`. So both the bulk "Retry N failed" button and each expanded row's per-item retry
  were live in a window where a retry deletes the segment's staged output, releases it, drops `retained` and
  re-ingests every page — **buying its OCR a second time** — while the regeneration's write is in flight and
  about to `staged[idx] = fresh` over whatever the re-run appended.
  **Three edits, and the FIRST is the one that holds.** `retryFailed` gained `guard !isFinalizing`; the bulk
  button gained `.disabled(liveProc.isFinalizing)` (the same gate as Clear, `:405`); and
  `SegmentItem.actions(for:finalizing:)` withholds `.retry`/`.retryWithModel`/`.changeRotation` while
  finalizing, keeping the read-only `.viewText`/`.revealFiles`. The model layer is where the refusal has to
  live, because it is the one place all three entries converge and one of them is **deferred**: the
  `modelChoiceTarget` sheet captures a group when it opens and calls back on Apply, so no enabled-ness computed
  when the button was drawn can speak for the moment the retry actually runs. The two view edits exist so the
  operator is not offered what would be refused — with the accepted limit stated at the guard, that the
  deferred Apply is the one path where the refusal is silent.
  **The item's open question — "does the per-item menu need the same gate?" — is answered YES, and MEASURED.**
  Mutant P2 (the guard weakened to bulk-only, `!(isFinalizing && groupIds == nil)`) reads exactly as red as no
  guard at all, because the per-item entry reaches the same `retryFailed` and spends the same money, and the
  expanded row is on screen in precisely the exposed window. `finalizing` takes no default value, so a third
  call site cannot inherit "not finalizing" silently; Test 17's existing call site now says `finalizing: false`
  explicitly, which is what its own leg means.
  **The refusal is deliberately NARROW, and the narrowness is itself tested.** It covers `isFinalizing` only —
  not `requestFinish`'s `!showFinalizeSheet, !showRotationReview` triple — because those two put a modal sheet
  over the panel, so its retry affordances are unreachable in them. Mutant P5 (widening the guard to the
  triple) is 1 RED on check 8, which pins that the intended window did not become a ban. What the widening
  would have papered over is filed instead as **`W3.cap-r3-fu9`**: whether an already-open per-item sheet can
  suppress the rotation-review sheet, which if true is a worse bug than this one (the review is skipped and
  `requestFinish`'s own guard then deadlocks Finish) and wants a presentation-layer fix, not a silent refusal
  inside a money path. **fu9 shipped 2026-08-04 and settled it the other way round:** the presentation question
  is still unobserved, but the finish flow no longer STARTS while a per-item sheet is up, so the
  concurrent-presentation state is unreachable — which also makes THIS item's deferred-Apply entry unreachable
  in production. P5's narrowness therefore still holds, and this guard is now defence-in-depth rather than the
  sole defence on that path.
  **Test 21 (8 checks) drives the real window with no gate object.** `isFinalizing = true` is set
  synchronously before the `Task`, and everything that closes the window again runs on the MainActor after an
  await on the detached write — so a retry issued on the same MainActor turn is genuinely inside the window
  with the write genuinely running on another thread; check 3 asserts that state rather than trusting it. What
  is measured is the refusal and its money consequence, not the record overwrite itself: which of the two
  orderings you get is an artifact of scheduling, whereas the double spend is order-independent and the refusal
  forecloses every ordering. Check 8 pins that the refusal is a WINDOW and not a ban — once `beginFinalize` has
  raised the collection sheet the same retry works again and buys the pages back, which is the recovery
  affordance the operator depends on. 5 mutants: **P1 3 RED** (the shipped defect; its third is a consequence,
  checks 4 and 5 are what name it), **P2 3 RED**, **P3 1 RED**, **P4 1 RED**, **P5 1 RED**, plus **P6/P7 0 RED**
  (added by the adversarial pass — see below). `test-recovery.sh` 148 → **156 checks ALL PASS**, 13.6 s; build
  clean, no new warnings; 5 adjacent $0 drivers green (`test-manifest-persistence`, `test-merge-safety`,
  `test-output-file-safety`, `test-processfiles-tagwarn`, `test-collection-organize`; `test-drive-live` skipped,
  it needs a Drive token).
  **ADVERSARIAL (independent pass, opus/xhigh, read-only) — nine findings, and it changed what this item
  CLAIMS more than what it does.** The guard itself came back sound: correctly placed (after the mode check,
  before every mutation, so a refusal is total — no half-cleared `groupOCROverride`/`statuses`/`pageTasks`/
  manifest), complete over the window (`isFinalizing` has exactly four writes, and both `true→false`
  transitions are synchronous with the code that raises the next sheet, so there is no trailing gap), with no
  legitimate caller silenced and no other UI path to `retryFailed` (the row's actions are inline `Button`s, not
  a stale-snapshot `NSMenu`; the Files pane routes elsewhere entirely). What it demolished was the record:
  1. **The reachability premise was backwards, and the item cited the blocker as the evidence.** fu7's filing —
     and this commit's own first drafts — said the panel was "on screen and CLICKABLE" in the window, citing
     `LiveCaptureView:48`'s throbber. That throbber's scrim is `Color.black.opacity(0.2).ignoresSafeArea()` in
     an `.overlay` with **no** `.allowsHitTesting(false)`, and a `Color` is hit-testable — so it most likely
     swallowed every click in the panel, meaning neither button was ever pressable there. Confirmed on the code
     (and against this repo's own deliberate uses of the modifier both ways); the hit-test outcome itself needs
     the VM lane. Consequence: the two view-layer edits are defence-in-depth, P1/P2's RED measured an entry the
     UI could not take, and the guard's live value is the deferred sheet Apply. Filed as **`W3.cap-r3-fu10`**,
     which now decides this item's true severity; corrected at the guard, in the SHIP ORDER note and in
     `ArchiveProcessor/CLAUDE.md`.
  2. **The "same gate as Clear (`:405`)" citation was wrong** — `:405` is the **Finish session** button. Clear
     is `:363` and carries **no gate at all**, and in this window it is worse than the retry: it Trashes the
     sources the detached write is reading and empties `staged`/`retained` under the loop about to index them.
     Filed as **`W3.cap-r3-fu11`**, not absorbed here (gating a delete path is its own Tier-2 decision).
  3. **Test 21's write was never "in flight."** `LiveCaptureProcessor` is `@MainActor`, so
     `applyRotationReviewAndFinalize`'s `Task { … }` is MainActor-isolated and cannot start until the MainActor
     yields — which the section never does before check 5 — so the inner `Task.detached` is not even created.
     What the section proves is a FLAG-STATE refusal, not a simultaneous race. That is still the property the
     fix turns on, but the stronger claim is now removed from the comment, the check label and this entry.
  4. **Two of the three edits are unmeasured above the pure-function line.** Check 7 exercises
     `SegmentItem.actions(for:finalizing:)` directly, so nothing proved the view passes the real flag in.
     Measured rather than argued: **P6** (`let finalizing = false` in `segmentItems`) and **P7** (deleting the
     bulk button's `.disabled`) are both **0 RED**, recorded as limits — a SwiftUI modifier is invisible to a
     headless driver, so closing them is VM-lane work alongside fu9/fu10.
  5. **Check 8 measures the guard's WIDTH, not the operator's affordance,** and couples this section to fu9: it
     retries while `showFinalizeSheet` is up (a state no button is pressable in), and because it asserts that
     retry SUCCEEDS, a fu9 fix that refuses during the sheet states turns it RED and must rewrite it. Both facts
     are now stated at the check. The pass also found the *reason* fu9 might want that refusal: a deferred Apply
     during `showRotationReview` nils `retained[gid]`, so the regeneration silently drops that group's rotation
     edits — operator work lost with no money involved. Folded into fu9.
  6. **`gate`'s stated completeness property was false** for `.succeeded` and `default`, which returned literals
     bypassing it — exactly the "gated in one place and forgotten in the other" failure the comment claimed was
     impossible. Fixed: every branch routes through `gate` (no-ops today, and that is the point).
  7. **The silent-refusal limit was underpriced.** `onApply` clears `modelChoiceTarget` unconditionally, so a
     refused Apply discards the operator's provider, model, thinking level, rotation AND freshly typed API key —
     not "a second press". Corrected at the guard, with the right fix named (keep the sheet open, don't widen).
  8. **The edited fu6 cross-reference over-credited the new guard's neighbours** — `finalize` already guarded
     `!isFinalizing`, so `clearSessionState` is the *only* remaining entrant to that argument, and it is the one
     still ungated in the UI (fu11). Corrected in place.
  9. **P1's arithmetic was wrong** — check 4 issues two retries and the second re-buys as well, so the mutant
     spends four extra calls, not two. Corrected in the mutant block.
  Findings 6 and 7 and the corrections to 1, 2, 3, 8, 9 ship in this commit; 1, 2 and 5's second leg ship as
  fu10/fu11 and a fu9 amendment; 4 ships as two recorded 0-RED mutants. Nothing the pass found required
  reverting or reshaping the guard.
- [x] **W3.cap-r3-fu6 [LOW · bookkeeping] — ✅ DONE 2026-08-04** (`61fc680` fix; `b2ff7d1` test + mutants;
  this commit, the adversarial pass's corrections + trackers). The item's own recommendation was the right
  one: extract the taxonomy so there is ONE labeller. `finalizeSegment`'s A1 branch is now
  `labelStagedRecord(_:type:outcome:results:)`, and both writers of a staged record go through it — the first
  write, and `applyRotationReviewAndFinalize`'s regeneration, which replaced the record WHOLESALE and left
  the old label sitting on the new bytes. Both directions the item named are closed and both are now driven:
  forward, a segment that failed `.noOutput` for a transient write error and regenerates cleanly stops being
  counted failed, so the collection sheet no longer warns "N segment(s) failed to process and are NOT
  filed — Retry them before finalizing" about a segment that is fine (that warning is the money half: obeying
  it hits `retryFailed`, which deletes the freshly regenerated output and re-buys the OCR, and unlike the fu5
  chain it needs no special shape — the segment is still staged, so the retry always lands); backward, a
  `.staged` segment whose regeneration produces nothing stops wearing a success label over an empty record
  that `executePlans` then skipped silently, and is now `.failed`/`.noOutput` and offered for retry, which is
  the only way it is recoverable.
  **The item's ⚠️ was wrong, and checking rather than approximating is the point.** It warned that
  `anyText`/`firstError` are unavailable on the regeneration path (`RetainedSegment.texts`, not `OCRResult`s)
  and said not to approximate `anyText` without checking how `texts` represents a text-less page. They ARE
  available, exactly: `RetainedSegment.pages` is `[PageWork]` and `PageWork.result` IS the page's `OCRResult`,
  so the regeneration passes the same values `finalizeSegment` awaited — a rotation edit rebuilds `OCRResult`
  preserving `text`/`errorMessage`/`errorCode` (now via `OCRResult.with`, the shared seam, rather than a
  hand-retyped five-field init — the re-type is how `errorCode` was once dropped, W9.1), and `PageWork` is
  Codable so they survive a manifest resume. `texts` would have been wrong for exactly the reason the item
  suspected: it maps a nil text to `""`, conflating "OCR returned nothing" with "OCR returned an empty
  string" — the one distinction `.succeededNoText` exists to draw. So no deliberate decision about what the
  regeneration leg passes was needed; the answer was that it passes the real thing.
  **This CHANGES a fu5 measurement, which is recorded rather than quietly inherited.** fu5's mutant M1 (the
  `finalize` call site back to a bare `finalizedGroups.remove`) read 2 RED; as of this fix it reads **0 RED**.
  Not a regression in Test 19 — fu6 removed the reachability M1 needed. The regeneration re-derives the
  label, so the group leaves `failedGroupIds` at check 4 instead of at the finalize, and no other path can
  put a filable record in the failed set: `markFailed` is the only writer that inserts, it fires only for
  `.noOutput` (no PDFs) or `.incompleteOutput` (`pagesComplete == false`), and `executePlans` skips both. Read
  as "the defect fu5 fixed can no longer be CONSTRUCTED", NOT "fu5 was unnecessary" — it was real and
  shipped. `releaseFinalizedGroup`'s pairing is kept (right on its own merits, and the invariant is
  load-bearing for `retryFailed`'s cancel-loop latency argument) and its live coverage is now fu5's M2, 9 RED
  in Test 17. Recorded in three places so the next reader cannot mistake it: the M1 line, the `finalize` call
  site, and Test 19 check 5's note.
  **Verification.** Driver Test 19 check 4 FLIPPED — it existed to PIN the stale label and said so — and now
  asserts the SPECIFIC label the taxonomy owes the regenerated record (`.succeededPlaceholderImage`, no
  reason line) plus `failedGroupIds == ["V2"]`, so a fix that reconciled the sets by blanket-clearing them
  would still be caught. New **Test 20** drives the backward half for real: a two-page merged document stages
  cleanly, the staging dir stops accepting writes, the operator straightens a page, the regeneration produces
  nothing. `mergeDocuments: true` is load-bearing there — regeneration writes each page back to the SAME
  path, so with per-page PDFs still on disk a failed write is masked by the previous run's file; the
  successful first write merges and deletes them, so the targets are genuinely absent (asserted, since the
  section is vacuous otherwise). Real decodable JPEG bytes, so the segment reaches the plain `.staged` label
  the item names. 4 mutants: **N1** (the regeneration's label call deleted) **3 RED** — Test 19 check 4 plus
  Test 20 checks 5 and 6, the shipped defect in both directions; **N2** (label from `texts`) 0 RED, an honest
  limit — nothing stages a document whose OCR returns an EMPTY STRING rather than nil, the only separating
  input, and building one needs a per-page stub instead of the driver's single shared one; **N3** (label from
  `retained` re-read instead of the `regenInputs` snapshot) 0 RED and expected to be, since nothing mutates
  `retained` while the detached write runs — the snapshot is defensive, not covered; **M1** re-measured as
  above. `test-recovery.sh` **148 checks ALL PASS**; six adjacent headless $0 drivers green unchanged
  (manifest-persistence, merge-safety, multipage-reocr, output-file-safety, collection-organize,
  processfiles-tagwarn) — the extraction moved the first-write branch verbatim and those are what would
  notice otherwise. Build clean, no new warnings. No migration written because there is nothing to migrate.
  **The adversarial pass proved the new invariant risk and found two residuals.** The regeneration can now
  `markFailed`, which INSERTS into `failedGroupIds` — so it had to be shown that the group is still in
  `finalizedGroups` there, or fu5's subset would break on the very path fu5 was about. It is, and
  structurally: every exit from `finalizedGroups` also drops the group from `staged`
  (`retryFailed`/`clearSessionState`/`finalize` each do both, synchronously with no await between), and the
  new label sits behind the existing `guard let idx = staged.firstIndex(...)`. Two residuals filed, both
  PRE-EXISTING and neither introduced here: **`W3.cap-r3-fu7`** (the "Retry N failed" button is not disabled
  during the regeneration, so a click inside that window races `staged[idx] = fresh`) and
  **`W3.cap-r3-fu8`** (the manifest-resume path is a THIRD labeller, hardcoding `phase: .staged`).
  Deliberately NOT folded in: fu8 would newly put resumed segments into the retry set, a money-path
  behaviour change that wants its own gate. Leaves `-fu3`, `-fu4`, `-fu7`, `-fu8` open.

- [x] **W3.cap-r3-fu5 [LOW · bookkeeping · contingent] — ✅ DONE 2026-08-03** (`2d15fae` fix; `f091ea2` test +
  mutants; this commit, trackers). The item asked for a DECISION — clear `failedGroupIds` at finalize, or
  assert the invariant somewhere it can be seen to hold — and the answer was neither exactly: make it
  **structural**. `finalizedGroups` now has exactly two exits — `releaseFinalizedGroup(_:)` per group and
  `releaseAllFinalizedGroups()` for Clear — and both clear `failedGroupIds` with it, so
  `failedGroupIds ⊆ finalizedGroups` rests on that rather than on every future caller remembering to pair
  two removals. Same move `W3.cap-r4` made on the duplicated collection key: remove the way to drift rather
  than sync the copies. ⚠️ The **first version claimed a SOLE exit and was wrong** — `clearSessionState` had
  its own unguarded pair of `removeAll`s, i.e. the identical hazard one line apart; the adversarial pass
  caught the claim and the second helper is the answer to it. "By construction" is also scoped honestly in
  the code now: the set is a bare `private var`, so `.subtract`/`.filter`/whole-set assignment would bypass
  both helpers with no compiler help, and `retryFailed`'s synchronous release + async re-arm leaves a gap a
  suspended `finalizeSegment` could `markFailed` into — unreachable today for the same reason its cancel
  loop is a no-op, which is a circularity the comment names rather than hides.
  **The filed premise held, and the chain is narrower than "seven writers" suggested.** `markFailed` is the
  sole INSERT and runs inside `finalizeSegment` after the group is already finalized, so the subset can only
  break on a REMOVAL — and there are exactly three (`retryFailed`, `clearSessionState`, `finalize`), of which
  only `finalize` dropped the finalized entry alone. The reachability the item called contingent was
  **reproduced**: a `.noOutput` segment is appended to `staged`+`retained` before the label branch,
  `finishSession` enumerates `retained.values` with no filter, and a rotation-review regeneration replaces
  the staged record wholesale — so a transient write error that clears makes the record filable while the
  group is still counted failed. What the leftover entry cost: `finalize` drops the status ROW one line
  above, so the operator got a "Retry 1 failed" button with nothing under it — plus the collection sheet's
  "N segment(s) failed … NOT filed" warning — aimed at a document already in the collection. **The money
  claim needed narrowing and the adversarial pass is what narrowed it:** usually pressing that button costs
  nothing, because `clearFiled` retires the filed sources, `session.groups` is derived from `photos`, and
  `retryFailed`'s `else { failedGroupIds.remove(gid) }` guard self-clears the phantom on first press. It is
  expensive only when the filed record carries `placeholderSources` — the source is deliberately withheld,
  the group survives, and the retry really does re-ingest and re-buy the OCR. That sub-case IS reachable in
  this exact chain (regeneration does not re-derive the label, so a group can be failed AND filed-with-a-
  placeholder at once), and Test 19 turns out to build precisely it — now pinned by its own check.
  New driver **Test 19** (`test-recovery.sh` **134 → 142**) builds that state for real rather than asserting
  it: a staging dir chmod'd `0555` is the transient write error, then the REAL Finish → rotation review →
  finalize path. TWO groups fail and only V1 is rotated, so V2 is a segment still genuinely failed when the
  batch files V1. "Review rotation" is set and restored around the single synchronous call that reads it, so
  the operator's own toggle is never left flipped. **Four mutants measured:** M1 the pre-fix
  `finalizedGroups.remove(gid)` → **2 red**, both here · M2 `releaseFinalizedGroup` clearing only
  `failedGroupIds` → **9 red** (1 here, 8 in Test 17, which needs the same removal) · M3
  `failedGroupIds.removeAll()` → **1 red**, and only because of V2 · M4 `releaseAllFinalizedGroups` dropping
  its `failedGroupIds.removeAll()` → **0 red**, recorded as an honest limit and NOT fixed: nothing here
  drives Clear, so the pairing at that exit is convention in a way it is not at the per-group one, and
  covering it needs a Clear-path section of its own. **Two predictions were wrong and the
  measurement corrected them:** M2 was expected to be 1 red (it is 9, and — because Test 17's stalled settles
  push the run past the harness's 60 s wait while the report is written only at the END — under
  `test-recovery.sh` as shipped it reads as a bare TIMEOUT with no PASS/FAIL lines at all, which independently
  corroborates `W21.recovery-timeout`: the GREEN suite is **14 s wall-clock measured here** (142 checks, so
  46 s of headroom), but a mutant that strands ~8 bounded 10 s settles needs >60 s and the all-or-nothing
  report turns that into silence rather than into the 9 REDs it actually has — 240 s was enough); and M3 was
  expected to be caught by Test 18 (Test 18's scope check is
  about `pageTasks`, not this set — **a first draft with a single group let M3 through the whole suite**, and
  the sibling group was added for it). Test 19 also renames its own "the document really filed" premise,
  which collided with Test 17's identically-worded check while the mutants were being read.
  **Honest scope:** this makes the SETS consistent. It does NOT fix the stale LABEL on a regenerated record —
  check 4 deliberately pins that as present behaviour — which is filed as **`W3.cap-r3-fu6`** and carries the
  reachable-through-the-UI money consequence (the false "N failed" warning invites a retry that deletes the
  regenerated output and re-buys the OCR). It also does not touch `-fu4`'s "a filed group loses its late-page
  cover"; what it removes is the bulk retry that used to be racing that re-upload.
  **Tier-2: an independent adversarial pass** (separate context, told to refute) found **no path on which
  the shipped code behaves wrongly** — it independently re-derived the sole-INSERT claim, confirmed the three
  suspension points between `finalizedGroups.insert` and `markFailed` are all guarded with no `await` left
  before the label branch, could not construct a filed group that should still read as failed (`executePlans`
  skips `pagesComplete == false` and requires `pdfExpected > 0`, and the two `succeeded*` labels already
  leave the set), found no reader that depended on a filed group staying failed, and confirmed the mutant
  arithmetic. Verdict **SHIP WITH FIX** — the fixes were to CLAIMS, and both shipped here: (a) "sole exit"
  was false, `clearSessionState` was a second unguarded pair → `releaseAllFinalizedGroups` added and the
  wording scoped; (b) "`retryFailed` would re-buy the OCR" was false in the ordinary case → narrowed to the
  placeholder sub-case, in code and here. It also raised four LOWs, all accepted-and-recorded rather than
  fixed: the async re-arm gap in `retryFailed`, the absence of any compiler barrier to a third exit, the two
  `UserDefaults` residuals in Test 19 (a kill inside the window leaves the toggle ON; `object(forKey:)` reads
  through the domain search list, so a global-domain value would be restored into the app domain), and the
  extra `@Published` emissions from `Set.remove` on already-absent groups — that last one **declined
  deliberately**: SwiftUI coalesces them inside the synchronous block, so no render differs, and a `contains`
  guard would obscure a two-line invariant helper for no observable gain. Its finding that Test 19 only ever
  builds the PLACEHOLDER shape was checked and is true — so rather than change the fixture, the section now
  pins that shape explicitly, which is what makes the narrowed money claim measured instead of argued.
  `test-recovery.sh` ALL PASS 142; manifest-persistence 109, multipage-reocr 29, merge-safety 15,
  segment-json 30, filerelay 10/10 all green; build clean, no new warnings. The paid smoke test was NOT run:
  it makes real Gemini/Mistral OCR calls and this change touches no request shape, matching how `-fu1`/`-fu2`
  were verified. No migration written because there is nothing to migrate. Leaves `-fu3`, `-fu4`, `-fu6` open.

- [x] **W3.cap-r3-fu2 [LOW · latent] — ✅ DONE 2026-08-03** (`3fdeb00` fix; `71cc4e6` test; this commit,
  mutants + trackers). `retryFailed` dropped every page's `pageTasks` entry without cancelling it — the exact
  mutant (M2) `cap-r3` was measured against, sitting in production 130 lines above that fix. **Shipped as the
  no-op the item asked for, and the commit says so** rather than implying a live leak was closed. The
  latency was re-derived here rather than taken on trust, and it holds on every route: `finalizeSegment`
  awaits every page and clears these same entries (its `// free memory` loop) BEFORE `markFailed` inserts the
  group into `failedGroupIds`, which is the bulk button's whole input; the only two writers of
  `failedGroupIds` are `markFailed` and `retryFailed`'s own removal; the per-item menu offers a retry only for
  `.failed`/`.succeededNoText`/`.succeededPlaceholderImage`, never for `.processing`, which is what
  `.ocr`/`.tagging` render as; and a page arriving for such a group afterwards cannot start a call either,
  because `finalize` drops only FILED groups out of `finalizedGroups`, so a failed group keeps its late-page
  cover for the whole session. What the fix buys is the **invariant**, now whole across every path that frees
  an entry: no `pageTasks` entry leaves the map without its call being cancelled first — so the next edit that
  makes a retry reachable mid-flight cannot inherit the paid leak by construction. Stated with the qualifier
  the adversarial pass insisted on: no entry leaves `pageTasks` with a **running** call behind it —
  `finalizeSegment`'s own clear drops without cancelling and is right to, because it runs after every one of
  those pages was awaited.
  New driver **Test 18** (`test-recovery.sh` **127 → 133**) parks three pages on the $0 stub's gate — two of
  the group to be retried, one of another group — and calls the REAL `retryFailed`; the gate is what stops
  every check being vacuous (a finished Task cannot be shown to have been cancelled), and
  `_recoveryTestOCRTasks` is the only vantage that tells a genuine `cancel()` from a silent drop. It enters
  through the API and its header says so, because the UI cannot reach it — and check 2 **pins BOTH legs of
  that gate**: the per-item menu (mapping the live mid-OCR status through the real
  `SegmentItem.state(for:)`/`actions(for:)` and requiring it to be empty) and `failedGroupIds`, the bulk
  button's whole input. The second leg was added by the adversarial pass, which pointed out that pinning only
  the menu left the fragile half unpinned. **Four mutants measured:** M1 the pre-fix drop-without-cancel →
  **1 red**, the fix's own check alone · M2 a wholesale `for t in pageTasks.values { t.cancel() }` ahead of
  the same per-group drop → **1 red**, the scope check alone · M3 the cancel moved BELOW the re-ingest →
  **2 red** · M4 the cancel without the `= nil` → the fresh-call check red and then **nothing further at
  all**, the harness killing the run at 60 s. M4 is **recorded as observed (×3) and not explained**: by the
  clock the bounded 10 s settle should have let the staging check report FAIL with ~20 s to spare (the green
  suite takes ~28 s), so that state stops making progress for a reason this pass did not diagnose; it is not
  a crash (the app is alive when SIGTERMed). **Honest limit, in the section header too:** the output check (6)
  is a guard against over-reach, not a second catcher — the $0 stub is cancellation-blind by design, so an
  after-the-re-ingest cancel shows up in check 5, and no measured mutant reddens check 6 alone.
  **Tier-2: an independent adversarial pass** (separate context, told to refute) confirmed the unreachability
  on every route it tried and found no path on which the shipped code behaves wrongly — but it corrected the
  fix's own commentary twice, and both corrections shipped: (a) the claim that a cancel here would be no worse
  than the drop even if it became reachable is **wrong for the one page finalize is parked on** — finalize
  dereferenced that Task before suspending, so the drop costs it nothing and only the cancel destroys it
  (exactly what Test 17 scenario 5 measures); the comment now says the right future fix is refusing the retry
  while `finalizedGroups.contains(gid)`, not copying `photoRemoved`'s carve-out — which would also leave
  `retryFailed`'s own `finalizedGroups.remove` + `segmentResolved` free to start a SECOND `finalizeSegment`
  that double-appends to `staged`; and (b) the symmetry claim needed the "running" qualifier above. It also
  filed the residual **`W3.cap-r3-fu5`** — the `failedGroupIds ⊆ finalizedGroups` invariant that this item's
  own latency argument leans on is maintained by nothing.
  `test-recovery.sh` ALL PASS 134 (×5 runs across the pass's changes); manifest-persistence 109,
  multipage-reocr 29, merge-safety, segment-json and filerelay 10/10 all green; build clean, no new warnings.
  No migration written because there is nothing to migrate. Leaves `-fu3`, `-fu4` and `-fu5` open.

- [x] **W3.cap-r3-fu1 [MED] — ✅ DONE 2026-08-03** (`1a84d1c` fix; `54981e0` test; this commit, mutants +
  trackers). The filed premise held on all three paths. `photoIngested`'s W3.cap-r2 started-once guard read a
  SECOND record of its own — a `startedPages: Set<PageKey>` inserted beside the OCR Task — and that copy
  outlived the work it was guarding wherever the Task was freed without it: `finalizeSegment` clears
  `pageTasks` for the pages it staged, `finalize`'s reclaim branch emptied the set WHOLESALE while its
  straggler / partial branches emptied nothing at all (all three of them dropping the filed group from
  `finalizedGroups` first), and `photoRemoved`'s mid-finalize carve-out keeps the key on purpose. So the guard
  came to mean "this page once had a call" instead of "this page has one", and it sits ABOVE the late-page
  branch: a page the phone re-sent after its group finalized returned there — no call, no warning — and once
  the group had been filed a later finalize read the empty entry as "OCR not started" and staged a silently
  text-less archival document.
  **Fixed at the second of the two seams the finding named** — gate on presence-of-task, `pageTasks[key] ==
  nil` — and the second record is **DELETED**, the same shape as `cap-r4` (one reader, nothing left to drift)
  rather than a hand-sync between two sets. Presence-of-Task is strictly stronger than started-ness for a
  page's whole pre-finalize life, because a COMPLETED Task stays in the map until finalize clears it: `cap-r2`'s
  dropped-ack dedup is unchanged, and the mid-finalize carve-out still de-duplicates a re-arrival instead of
  letting it overwrite the entry finalize is suspended on. Two behaviour deltas, both toward the operator: a
  page re-sent for a still-staged group now reaches the "a late page arrived" message it could never reach, and
  a page re-sent after its group was filed buys the OCR it needs instead of being archived text-less (one page
  of spend, versus a text-less document — the same trade `cap-r3` recorded). One incidental fix: the reclaim
  branch's wholesale reset also disarmed pages still mid-OCR in groups the batch never planned, so a
  dropped-ack re-upload of one could buy its call twice.
  **The finding's ⚠️ was half right, and the correction matters for the next reader.** It warned that retiring
  the key inside the carve-out would let a re-arrival "overwrite `pageTasks[key]` and double-buy" — measured
  (M2), it does NOT double-buy: `finalizedGroups` still holds the group mid-finalize, so the re-arrival returns
  at the late-page branch before any assignment. What that naive fix actually costs is a **mislabel plus a lost
  paid page** — the operator is told a "late page arrived" for a page that IS being read, and finalize then
  reads `nil` for it, so the segment keeps ONE of the two pages of OCR they paid for. Same verdict on the fix,
  different reason; the money claim was over-stated.
  Tier-2: adversarial self-review traced every `pageTasks` mutation, every `finalizeSegment` exit, and every
  `finalizedGroups` insert/remove, confirming there is no state where a nil entry coexists with a live consumer
  outside `finalizedGroups` — i.e. the invariant is exactly "a page may buy a call iff no Task exists for it
  and its group is not currently finalized". `retryFailed`'s missing `cancel()` was deliberately left alone
  (that is `-fu2`). **4 mutants measured, all killed:** M1 the pre-fix two-record design (the original bug)
  **8 red**, incl. the no-warning and the one-page-of-text checks · M2 the naive carve-out retirement **4 red**
  (2 of `cap-r3`'s + the new mislabel + the lost page) · M3 the guard removed outright **5 red**, incl.
  `cap-r2`'s own dedup check, so the guard is still doing its original job · M4 the reclaim branch resetting
  the record wholesale **2 red**, exactly scenario 4 and nothing else. New Test 17 in the recovery driver: 14
  checks over the four states a page can re-arrive in (staged · filed · mid-finalize · post-reclaim), each
  driven through the REAL `ingest` → `finalizeSegment` → `finalize` path with the $0 stub, so what they count
  is what the operator would be charged; the harm is measured on the record finalize wrote, not on the guard.
  `test-recovery.sh` **ALL PASS, 113 → 127**. Build clean, no new warnings. (The Processor scheme has no test
  action, so these headless drivers ARE its smoke test.) Residual filed from this pass: **`W3.cap-r3-fu4`** —
  after Finish the app forgets a groupId was ever filed, so a late re-upload opens a second document for it
  instead of being told it cannot join.

- [x] **W3.cap-r3 [LOW → money] — ✅ DONE 2026-08-03** (`5c3938e` fix; `c510af2` + `1ddc083` test + mutants;
  `72b2e1c` the adversarial pass's fix; this commit, trackers). **The last of the six WS11 Capture findings —
  this section is now closed.** The filed premise held: `removePhoto` / `removePhotoIfSafe` dropped a photo
  out of `session.photos` and sent its source to the Trash without telling `liveProcessor` anything, so the
  OCR call bought for that page on arrival ran to completion — billed, for a page nobody will ever read — with
  its `Task` and result stranded in `pageTasks` under a key nothing looks up again. No other path drops a
  single page's entry (`finalizeSegment` clears only the segment it just staged, `retryFailed` only the group
  being re-run, `clearSessionState` only a whole-session Clear), so both the spend and the entry leaked.
  New `photoRemoved(_:)` trigger, symmetric with `photoIngested(_:)`: cancel the page's task, drop it from
  `pageTasks`, retire its `startedPages` key — called from both removal paths BEFORE the source is trashed.
  Two deliberate decisions, both the kind a later reader would "simplify" away and both now pinned by a test:
  it is a **NO-OP while the segment is mid-finalize** (from `finalizedGroups.insert` until finalize clears the
  entry itself, finalize IS the consumer — it snapshotted the group before its awaits and is about to read
  this page's result into the segment's text, so cancelling would discard paid output rather than save any),
  and **`startedPages` is retired with the task** (as `retryFailed` already does) because a page with no task
  must be free to buy a new call if it ever arrives again — leaving W3.cap-r2's started-once guard armed over
  an absent task would save nothing and file the page as "OCR not started", a silently text-less archival
  document, which is the worse failure.
  **What the cancel actually saves, scoped honestly** (the adversarial pass showed the first wording was too
  strong): `NetworkSession` honours cancellation at four points, so a call still queued behind the 5-slot
  `RequestLimiter` — the common state in a capture burst — or parked in 429 backoff is never sent and the
  whole charge is saved; a call the provider has already ACCEPTED may be billed anyway, exactly as the
  no-repeat-after-timeout rule already assumes. Cancelling there still frees a slot for a page that WILL be
  read and never costs more. The strongest money case is the reclassify path, where the new group has already
  re-bought the same image, so the old copy's call was pure waste.
  Tier-2: **two independent adversarial passes** (correctness/concurrency and money/test-adequacy lenses),
  both of which traced every `finalizedGroups` mutation and every `finalizeSegment` exit and confirmed the
  carve-out cannot strand an entry, that `pageTasks` has exactly one production consumer, that both
  `X-Replaces` callers do skip `rg == groupId`, and that no fourth removal path bypasses the trigger. One
  pass found a REAL defect introduced by checkpoint 1 — the delete cancelled by `(groupId, seq)` and removed
  from the list by `CapturedPhoto.id`, a fresh UUID minted per VALUE that `ingest`'s idempotent re-upload
  replaces. A stale SwiftUI row value therefore cancelled the LIVE page's call while `removeAll` removed
  nothing, leaving a page in the session with no task and its source trashed → filed as "OCR not started"
  over a placeholder image. Pre-fix that window kept the text, so the divergence WIDENED the harm; `72b2e1c`
  puts both halves on `(groupId, seq)` (the identity `PageKey`, the manifest and the relay SPEC already use,
  and the one `removePhotoIfSafe` always used), making an absent key a whole no-op. **7 mutants measured**:
  M1 `photoRemoved` → no-op (the original bug) 8 red · M2 drop only `cancel()`, keep the bookkeeping 3 red ·
  M3 drop `startedPages.remove` 3 red · M4 drop the `!finalizedGroups` guard 3 red · M5 drop the
  `removePhotoIfSafe` call site 2 red · M6 the checkpoint-1 form (cancel by key, remove by id) 2 red · M7 the
  plausible WRONG fix (agree on `id`, so a stale value silently does nothing) 1 red — M7 is what earns the
  second new check, since agreeing on `id` leaves nothing broken behind and only "the delete lands" reds.
  M4 originally red only ONE check, resting on a mechanism assertion with no consequence, so scenario 5 was
  added — a two-page segment parked on its FIRST page with the SECOND deleted, where an unconditional cancel
  really does cost the operator a paid page of retained text. `test-recovery.sh` **ALL PASS, 89 → 113**;
  adjacent suites on the same build: `test-manifest-persistence.sh` ALL PASS (109), `test-network-session.sh`
  ALL PASS, `test-filerelay.sh` PASS 10/10 including `reclassify-chain(A3)`, which drives the very
  `removePhotoIfSafe` path this hooks. Build clean, no new warnings. (The Processor scheme has no test action,
  so these headless drivers ARE its smoke test.)
  **One deliberate, bounded trade, recorded rather than filed:** deleting a page whose OCR had already
  COMPLETED and then re-delivering the same `(groupId, seq)` now buys a second call, where pre-fix the cached
  result was reused for free. It is one call, and it buys correct output for a page that IS in the session —
  the alternative (keeping the entry) is what files a text-less page. Residuals the passes found in
  PRE-EXISTING code are queued as `W3.cap-r3-fu1` (`startedPages` outliving its task on three paths),
  `-fu2` (`retryFailed`'s uncancelled drop, latent) and `-fu3` (`removePhoto` has no `isFinalized` guard).

- [x] **W3.cap-r4 [MED · misfile] — ✅ DONE 2026-08-02** (`d719e3f` fix; this commit, test + trackers).
  The filed premise held exactly. `backfillCollections` corrects an out-of-order Box's document in the live
  map `groupCollectionKey` **and** in the visible `staged[]` record, but `RetainedSegment` carried a THIRD
  copy of the same fact, taken at finalize and never touched again. `applyRotationReviewAndFinalize`
  regenerates each straightened segment from those retained inputs and **replaces** the staged record with the
  result — so the pre-correction key was written straight back over the corrected one and the document was
  filed into the previous collection. The trigger is the operator's last action before the move (straighten a
  page in the end-of-session rotation review), and nothing on screen says the collection changed back.
  **Fix:** the retained copy is **deleted, not synchronised.** The collection was never a write input —
  `writeSegmentFiles` only carries it into the record it returns — so there is now exactly one reader,
  `liveCollectionKey(for:)` (live map, falling back to the staged record, which `loadStagingManifest` re-seeds
  the map from on resume). With no second copy there is nothing left to drift, and the next correction site
  someone adds cannot recreate this bug. Regeneration additionally **re-reads** the key on the way into
  `staged`, AFTER its detached write rather than before it — the same last-possible-moment discipline
  `finalizeSegment` adopted in `cap-r5`, because that write suspends too and a late Box can re-pin a segment
  while it runs. No migration written **because there is nothing to migrate** (owner, 2026-08-01); an older
  manifest still decodes, its now-unread `collectionKey` ignored by the keyed container.
  **Tier-2:** recovery driver Test 16 — the mirror of Test 15 — 7 new $0 checks driven through the real
  ingest → backfill → rotation-review path, ending on what the operator actually sees next (the naming
  sheet's drafts group the document with its own Box, not the previous one). **Mutation-verified against the
  real pre-fix code**, not a hand-written mutant: `git checkout 1f43498 -- LiveCaptureProcessor.swift` reddens
  exactly the two W3.cap-r4 assertions and nothing else, Test 15 included. The test needed one non-obvious
  isolation step, and it is load-bearing: `CaptureSession.init` adopts the newest backup session that still
  holds unprocessed photos (crash recovery), so the first draft of Test 16 inherited Test 15's groups —
  **including its boxes, whose capture order then decided this test's answer** — and passed before it had done
  anything. It now clears session-named folders under the throwaway test root first.
  **Adversarial review** (independent Opus pass over the diff) confirmed no production defect across the
  writer/clearer walk, the Codable removal and the actor isolation, and **reproduced a real flake it did
  find**: Test 16's drafts assertion raced the out-of-order Box's own `finalizeSegment`, which `ingest` only
  enqueues — 1 red in 10 runs under CPU load, a false red while the product invariant passed. Fixed with a
  settle, as was the same pre-existing race in `cap-r5`'s Test 15. Verified 6/6 ALL PASS under 8-way CPU load.
  `test-recovery.sh` ALL PASS (82 → 89 checks); collection-organize / manifest-persistence (109 checks, the
  manifest round-trip that matters most here) / merge-safety / multipage-reocr / segment-json /
  output-file-safety ALL PASS; build clean, no new warnings. As with `cap-r5`/`cap-r2`, the Processor's
  `scripts/test-smoke.sh` was NOT run — its de-nesting paths are stale (`W21.smoke`, still open).
  **Closes the collection-correction path for good** — `cap-r5` fixed the record being written, this fixes the
  record already written — and **unblocks `W17.stg1`**, which touches the same `RetainedSegment`.
- [x] **W3.cap-r5 [MED · misfile] — ✅ DONE 2026-08-02** (`d67b9cb` fix+test; this commit, trackers).
  Premise re-confirmed by reading the path rather than the filed line numbers. `finalizeSegment` inserts the
  group into `finalizedGroups` and reads `groupCollectionKey[groupId]` into a **local** — both before any
  await — and then suspends, for seconds, at the per-page OCR awaits, the LLM tagging call and the off-main
  file write. `backfillCollections`' first loop skipped every group in `finalizedGroups`, and its second loop
  could only repair segments already in `staged`. So for the whole span between those two states the document
  was reachable from **neither** loop: a Box delivered out of relay order in that window could not re-pin it,
  and the pages were staged — and later filed — into the PREVIOUS collection. Not a lost file, but an
  irreplaceable document in a folder nobody would think to look in.
  **Fix (two halves, both load-bearing):** (a) `backfillCollections` now skips only groups already in
  `staged` — the loop below owns those, records and all — so the in-flight group is corrected like any other;
  (b) `finalizeSegment` binds the key it RECORDS after its last await (`filedCollectionKey`) instead of at the
  pin. (b) is safe precisely because the key is metadata about *where* the segment is filed and never an input
  to the bytes or the paths: staging is one flat per-session `_processed/` dir, collection folders only
  materialise at `executePlans`, and `writeSegmentFiles` merely carries the key into the record it returns.
  There is no await between the re-read and the two assignments, so it is also the LAST point a correction can
  land. Both readers get it: `staged[].collectionKey` (end-of-session collection grouping) and
  `retained[].collectionKey` (rotation-review regeneration). Folder markers ride the same path as documents,
  which matches what the staged loop already did; a Box is still its own collection and is never re-pinned.
  **Tier-2:** recovery driver Test 15, 6 new $0 checks driven through the REAL ingest → finalize path. The
  window is the whole defect, so the test **holds it open** rather than hoping a sleep lands inside it: a new
  one-shot `_recoveryTestOCRGate` parks the stub OCR the segment is awaiting, and the check that the document
  is genuinely finalized-but-not-yet-staged runs BEFORE the Box is delivered, so the test cannot pass by
  accidentally exercising the already-working staged path. It asserts both record copies (a fix that corrected
  `staged` and left `retained` stale would pass on the first alone) and both ordering guards. Costs $0 and
  touches no network: `taggingMode: .human` keeps the document off the LLM (`computeTags` only calls it in
  `.automatic`) and a box/folder short-circuits to a colour tag inside `TagGenerator`.
  **Mutation-verified** on two mutants, one per half: restoring the `finalizedGroups` guard reddens the same
  2 checks, and recording the pinned key instead of the re-read one reddens the same 2. `test-recovery.sh`
  ALL PASS (76 → 82 checks); collection-organize / manifest-persistence / merge-safety / multipage-reocr /
  segment-json / output-file-safety ALL PASS; build clean, no new warnings. As with `cap-r2`, the Processor's
  `scripts/test-smoke.sh` was NOT run — its de-nesting paths are stale (`W21.smoke`, still open) — and the new
  driver block stays fail-closed behind the existing `ARCHIVEPROC_TEST_BACKUP_ROOT` isolation check.
  **Residual, deliberately NOT fixed here:** the mirror-image case where the Box arrives *after* the segment is
  staged, so the correction reaches `staged` but not `retained` and the rotation review reverts it. That is
  `W3.cap-r4`, the next item, and it is what closes this path for good.
- [x] **W3.cap-r2 [MED · money] — ✅ DONE 2026-08-02** (`96f223b` fix+test; this commit, trackers).
  Premise re-confirmed by reading the path, not the filed line numbers (they had drifted): `CapturedPhoto.id`
  is `let id = UUID()`, minted per VALUE (`CaptureModels.swift:23`), while `CaptureSession.ingest`'s
  idempotent-replace path does `photos[existing] = photo` for a matching `(groupId, seq)` — a REPLACEMENT, so
  a new value, so a new id. `photoIngested`'s `!startedPhotoIds.contains(photo.id)` therefore saw a brand-new
  page on a phone auto-retry after a dropped ack and started a **second paid OCR call**, orphaning the first
  Task under a key nothing would read again.
  **Fix:** one `PageKey(groupId, seq)` keying `pageTasks` + `startedPages` (renamed from `startedPhotoIds`).
  That pair is not a new convention — it is the identity `ingest` already de-duplicates on AND the identity
  the JPEG's own filename encodes (`%05d-<groupId>.jpg`), so two byte-distinct pages could never have
  coexisted under one key anyway; the processor simply stops disagreeing with the session about what "the
  same page" means. Money direction is strictly REDUCING — the change can only remove a paid call, never add
  one — and the worst case if it over-matched is reusing an OCR result for the same page, never deleting a
  file. Three side effects of the guard now catching the retry, all corrections: no more false "a late page
  arrived for an already-finished document" alarm on a duplicate of a page that IS in that document; a stale
  Box re-upload no longer resets `currentCollectionKey` (which could misfile later docs); and no redundant
  second `finalizeSegment` Task for a re-uploaded Box/Folder marker.
  **Tier-2:** recovery driver Test 14, 8 new $0 checks driven through the REAL `ingest`, with a canned
  stand-in for the paid call (`_recoveryTestOCRStub`) so what the test counts is what the operator would be
  billed. It asserts both ingests were genuinely ACCEPTED before asserting the count (no passing on nothing);
  that the first call's result is still reachable through the REPLACEMENT photo the way `finalizeSegment`
  reaches it — a fix that de-duplicated but stranded the Task would finalize the page as "OCR not started"
  and file it image-only; and that distinct pages/groups still each get their own call. **Mutation-verified**
  on two mutants: putting the ephemeral id back in the key reddens 3 checks, dropping `seq` from it reddens 2.
  `test-recovery.sh` ALL PASS (68 → 76 checks); manifest-persistence / multipage-reocr / merge-safety /
  collection-organize ALL PASS; build clean, no new warnings. **The Processor's `scripts/test-smoke.sh` was
  NOT run** — its de-nesting paths are stale (`W21.smoke`, still open), so it fails before it builds. File
  safety: the driver arms its session with `_recoveryTestBeginLive`, deliberately NOT `beginLiveSession` →
  `activate`, whose `pruneLegacyStaging` resolves orphans against `backupRoot` — redirected under test — and
  would therefore judge the operator's real legacy staging dirs orphaned and delete them; the block stays
  fail-closed behind the existing `ARCHIVEPROC_TEST_BACKUP_ROOT` check.
- [x] **W3.cap-r6 [LOW · data-loss] — ✅ DONE 2026-08-02** (`905722d` fix+test; this commit, trackers).
  `finalize()`'s allFiled branch trashed the whole `stagingDir` after the `executePlans` move await. Premise
  re-confirmed by reading the path, not the line number (it had drifted from :996 to :1097): `plans` is
  snapshotted synchronously in `finalize`, the await runs off the MainActor for as long as the moves take,
  and `finalizeSegment`'s post-await continuation can resume inside that window — appending to `staged` and
  writing fresh output into the same `stagingDir` without ever being in `plans`. `outcome.allFiled` reports
  only on the planned segments, so it stayed true, and the straggler's output was trashed along with the
  batch it missed, leaving a `staged` entry pointing into the Trash.
  **Fix:** a pure `stagingSafeToReclaim(allPlannedFiled:segmentsStillStaged:)` beside `sourcesSafeToRetire`,
  asked AFTER the filed segments are dropped from `staged`. Every staged segment's outputs live in that one
  directory, so any survivor — a straggler, or a segment the finalize sheet never planned — means it still
  holds files that exist nowhere else. A survivor now keeps the directory, persists the REDUCED manifest (the
  straggler's own `persistManifest` still listed the now-filed segments), leaves the session live instead of
  resetting it, and tells the operator to Finish again. The failure direction is a kept directory, never a
  deleted one. No behaviour change to the partial branch or to the empty-staging reclaim.
  **Tier-2:** recovery driver Test 13, 12 new $0 checks — the decision alone; the WIRING through the REAL
  `finalize`, with the straggler injected in the same MainActor turn as the call so the interleaving is exact
  rather than timing-dependent; and the happy-path reclaim it must not break. **Mutation-verified:** reverting
  the gate to the pre-fix `allPlannedFiled` fails 5 of them (the directory is trashed, the straggler's PDF is
  gone from disk, the manifest lies, the operator is not told) — so the test genuinely catches the bug.
  `test-recovery.sh` ALL PASS (68 checks); build clean, no new warnings. File safety: the wiring test builds
  a real `CaptureSession`, so it FAILS CLOSED unless `ARCHIVEPROC_TEST_BACKUP_ROOT` is set; every draft pins
  `chosenExisting` to a scratch folder so `currentOutputDirectory`'s real-Settings fallback can never
  contribute a path; and `test-recovery.sh` now also exports `LIVECAPTURE_TESTOUT` as a second belt.
- [x] **W3.cap-r1 [MED · tag/PDF SPEC] — ✅ DONE (this commit), BOTH FIXES IN ONE COMMIT as required.**
  Premise re-confirmed by symbol first: three `_ = try? MacOSTagger.applyTags(...)` sites remained (line
  numbers had drifted to 666/673/699). Both now go through one new `LiveCaptureProcessor.tagStagedArtifact`
  seam that passes the app's own `jsonTags.colorTag` with `colorIsAuthoritative` fixed `true` — so this path
  can never again infer a Finder colour from a subject string — and returns whether the write landed. A
  refusal is recorded on the new `StagedSegment.untaggedOutputs` (optional ⇒ legacy manifests unchanged) and
  `finalize` warns per filed artifact. Per the 2026-07-18 owner decision the file **still counts as filed**;
  only the silence is fixed. Merge drops its deleted constituents from the record so the warning never names
  a file that no longer exists. Tier-2: `test-recovery.sh` Test 12 (11 new checks) covers colour authority,
  the box-colour regression, a real `uchg`-refused write, the wiring onto the segment, and the merge path —
  56/56 ALL PASS, and **both halves proven non-vacuous** by neutering each in turn (colour → 1 RED, discarded
  result → 2 RED, everything else GREEN). `test-merge-safety.sh` + `test-output-file-safety.sh` re-run clean.
  Build clean, 0 new warnings. Unblocks **W23.m5**, which reuses this exact mechanism for the 9 Process Files
  sites. Original entry: `LiveCaptureProcessor.swift:640/647/673` — **(a) the SPEC subject-collision:** the live path writes tags via the raw `[String]` `MacOSTagger.applyTags` overload (no `colorIsAuthoritative`), so a document segment whose subject is literally "Red"/"Purple" is promoted to a Finder color label (Red=6/Purple=3) → the Reader mis-parses it as a box/folder photo. KNOWN_ISSUES #5's fix (derive authoritative color from classification) was applied to the batch merge path but **never to the live streaming path**. *(Premise manually confirmed: raw overload at all 3 call sites.)* **(b) tag-write failures are silently swallowed** (found by the 2026-07-18 review; was NOT in any KNOWN_ISSUES entry): all three sites are `_ = try? MacOSTagger.applyTags(...)`, so a PDF can land byte-perfect, count as **filed**, and have its **source photo trashed** while carrying no subject/date/priority tags at all — in the Reader that file is then invisible to tag-driven triage. **This is the only way today's "filed" verdict can be wrong without the operator ever knowing.** Owner decision 2026-07-18: record a per-artifact `tagsApplied` and **warn in the finalize summary**, but the file still counts as filed — the bytes are safe and retagging is possible, so withholding "filed" (and thus retaining the source) over-corrects. ⚠️ **THESE MUST BE ONE COMMIT.** (a) changes *which* overload is called; (b) changes *whether the result is discarded* — both rewrite the same three lines, so landing them separately means the second silently reverts part of the first. | Capture | Tier-2

## P3 — Suite structural

- [x] **SUITE.consolidate — one item list, and a doc set where every split has a stated reason.** DONE
  2026-08-01 (`08fa6ed`, `92f0667`, `3483627`, `ec967aa`, `3c00f46`, and this commit). Owner-directed, executed
  interactively with the daemon down. Driven by one morning producing the same defect three times — a stale
  `W21.vmgui-path` checkbox, a six-grants-stale tag list in `resume-prompt.txt`, a prove script false-failing 4
  runs in 6 — every one *a secondary copy drifting from the truth*.
  **Audit:** each document was tested against five criteria (tooling binds its path / distinct lifecycle /
  audience / durability / mutability), per the owner's instruction to check there was "actually a reason and
  not just path determinacy". Most splits survived with the reason now written down — `AGENTS.md` on audience
  (non-Claude agents that never read `CLAUDE.md`), `REVIEW.md` on load pattern, the per-app `CLAUDE.md` files on
  the token-efficiency directive. Four did not.
  **Shipped:** `check-tracker-sync.sh`, WARN-only on every health gate, which also reports untracked actionable
  work (25 assertions); the dead 139K `ARCHIVE_NOTES_PROGRESS.md` retired to `old/`; GUI verification
  de-duplicated to one canonical home in `AGENTS.md`; 160 completed entries moved here out of `SUITE_TODO`
  (3,580 → 1,189 lines); and the plan's 36 open WORK QUEUE entries collapsed to one-liners, removing 208 lines
  of duplicated prose and the dual-write tax on every item edit.
  **NOT done, deliberately:** replacing the plan's checkboxes with bare tag references. Tried and reverted — it
  dropped `(blocked-on: …)` clauses that live only in the plan, flipping `W16.bat6` and `W21.vmgui` from
  `blocked` to `ok`, and W16.bat6 going actionable before W16.bat3 would have inverted a fix order the owner had
  confirmed that morning. The guard already makes that class of drift loud, which was the actual goal. The
  reasoning sits at the code site (`next-queue-item.sh` §2b) and in the plan's WORK QUEUE header, so a future
  attempt starts from it — deliberately NOT left as a lingering execution plan.
