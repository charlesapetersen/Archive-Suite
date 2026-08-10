# Known Issues & Gotchas

Running log of quirks, risks, and things verified/unverified. Keep current.

## ✅ FIXED (`W26.previewzoom`) — the preview sheet's zoom/fit shortcuts did nothing; `⌘0` never reached it

**Found 2026-08-09** by `W26.docs-fu1`, the item that finally ran a GUI check deferred since the feature
shipped; **fixed 2026-08-10.** It was a *shipped claim that was false*, not a regression: `SUITE_TODO_DONE.md`
recorded **"⌘0 = fit full page everywhere zoom applies"** and **"on open, focus the image pane so keyboard
zoom works immediately"**, and neither held in the preview sheet (`Space` / `⌘Y`). The full **document window
was always fine** — only the sheet was affected.

**What was measured in the VM** (`ArchiveReaderUITests.testFitPageCommandReachesThePreviewSheet`; screenshots
in `~/.tart-mirror/vm-artifacts/shots-reader/`):
- Document ▸ `Fit Page` was disabled from the list (correct — nothing to fit) and **stayed disabled while the
  preview sheet was open**, so `ArchiveReaderCommands`' `@FocusedObject var doc` was nil and `.disabled(doc == nil)`
  killed `Fit Page`, `Zoom In`, `Zoom Out` and the pane-focus commands alike.
- In pixels the sheet's image pane was **byte-identical** before and after `⌘↑`×3 and again after `⌘0` (three
  screenshots, two blobs — the result bundle deduplicated the identical pair). Nothing zoomed; nothing refit.

**Cause:** `PreviewSheet` published with `.focusedObject(model)`, which applies only while the modified
subtree holds SwiftUI keyboard focus — and the pane is an AppKit `PDFView` behind `NSViewRepresentable`, which
never gives SwiftUI that focus. It was the app's only `.focusedObject`; `NavigationWindowView` and
`DocumentWindowView` both use `.focusedSceneObject`, and their Document-menu commands always worked.

🔺 **THE ONE-TOKEN FIX THAT SUGGESTS IS HALF OF IT, AND THE OTHER HALF IS THE PART WORTH REMEMBERING: a
focused-SCENE value is NOT retracted when the view that set it is torn down.** Switching the sheet to
`.focusedSceneObject(model)` made `Fit Page` correctly ENABLED with the sheet open, and left it **enabled
after the sheet was dismissed** — a live command over a dead preview model, and with it the Document menu's
⌘C / ⌘⇧C shadowing the Selection menu's own bindings in the nav window. Not a test artifact:
`documentMenuItem` re-opens the Document menu on every call, so every read is a fresh AppKit validation.
**A destroyed view cannot publish `nil`**, so scene-scoped publication has to be owned by something that
outlives what it publishes.

**Shipped shape:** `PreviewSheet` publishes nothing and reports its model up through a `@Binding`
(`published`, set in `onAppear`, cleared in `onDisappear`); `NavigationWindowView` holds it in `@State` and
publishes `publishedPreviewViewer`, which is `nil` unless `model.showingPreview` — belt-and-braces, because
`onDisappear` is not guaranteed on every teardown path but the sheet cannot be on screen with its own
`isPresented` binding false. The model stays a fresh `@StateObject` **per presentation** on purpose:
`PDFPaneController` carries `savedScale` forward by design (DV-2), so one shared long-lived instance would
have made a re-opened preview restore the last zoom instead of fit-full-page — falsifying the *"Preview gets
its own default zoom"* behaviour while fixing this one.

**The 241 s stall recorded against this issue was the bug**, not a separate mystery: with `⌘0` bound to
nothing the app never went idle. After the fix, from the test's own timing prints, `⌘↑`×3 = **0.4 s** and
`⌘0` = **0.1 s**.

**How it is now proven** — the inverse of the deduplication that proved the bug. Three shots bracket
`fit → ⌘↑×3 → ⌘0`: shot 2 differs from shot 1, and shot 3 is **byte-identical to shot 1** (MD5
`29e26af3…`), so the zoom happened *and* `⌘0` refit exactly back to the default rather than merely changing
something. VM lane 19 tests / 0 failures.

**Residual, tracked as `W26.previewzoom-fu1`:** publishing the model necessarily enables *every*
`.disabled(doc == nil)` item in the Document menu while the preview is up, and `Find…` / `Find Next` /
`Find Previous` have no find bar there to drive.

## ✅ FIXED (`W26.fsev-fu2`) — a folder that would not open left the list spinning "Scanning…" for ever

**Found 2026-08-06** by `W26.fsev-fu1`, which bounded the *stream*'s `open(2)` and measured that the *walk*'s
own probe had no bound at all. `CorpusWalker.canonicalRoot` (`rootIsOpenable` when this was written; renamed
by `W26.symroot`, which also made it resolve a symlinked root) calls `opendir(3)` on the same root, on its
dedicated `Thread`; under an unanswered TCC prompt, a stalled network/cloud mount or a disconnected volume it
does not return, the pass never reaches `finish`, and `LibraryPhase` stays `.firstScan(done: 0, seen: 0)` —
which `LibraryEmptyState` reads as `.scanning`. So the status bar was honest about live updates while the
list beneath it blanked behind a spinner that would never stop.

**Fixed 2026-08-06 (`5b4a8c8` → completion commit).** A pass that has examined **zero** files after
`scanStallTimeout` (5 s) publishes `.degraded(.scanStalled)` — *"Archive folder has not answered"*. It is a
**reported** deadline, not a cancellation, because a thread blocked in `opendir` cannot be interrupted: the
walk keeps running and supersedes the verdict if it returns, and so does the first file it sees. The verdict
grants nothing — `.degraded` is not settled, so no content-index pruning and no authoritative absence.

⚠️ **The thread is still stuck.** Nothing here makes an unopenable root openable, or reclaims the thread and
security scope that a stalled walk holds for the life of the process. What changed is that the app says so
and stays usable. If you are diagnosing a Reader that reports this, the problem is the volume or the
permission prompt, not the app.

## ✅ FIXED (`W26.fsev-fu1`) — the app could hang at launch, with no window, starting the FSEvents stream

**Found 2026-08-06** while shipping `W26.vocab-fu1`, from a stack sample rather than a reading. A Reader
unit run sat for 9+ minutes at **0% CPU** in:

```
NavigationModel.init() → ArchiveLibrary.start(scope:) :186 → startWatcher :465
  → CorpusWatcher.start() :256 (FSEventStreamCreate) → open(2)   ← main thread
```

`FSEventStreamCreate` opens the watched root, and it was called synchronously on the main thread during
`NavigationModel` construction. On local disk that is microseconds and invisible. Under an unanswerable TCC
prompt, a stalled network/cloud mount, or a disconnected volume the `open` does not return and **the app
never draws** — no window, no message, nothing to cancel. Everything else in this subsystem was already off
the main thread (the launch walk has a dedicated `Thread`, the stream runs on its own queue); the stream's
*creation* was the last synchronous step.

**Fixed 2026-08-06 (`a4aced6` → completion commit).** The start runs on a dedicated `Thread`, and
`W26.fsev`'s ordering guarantee is preserved by inverting *who waits*: the launch **walk** is deferred behind
the start instead of the main thread waiting on the open. A 2-second deadline bounds that deferral — an
unopenable root now draws a window, lists whatever it can read, and says *"Archive folder is not
responding"* (`DiscoveryFailure.liveUpdatesStalled`) instead of stalling silently. A stream that returns late
is still adopted and pays for the interval it missed with exactly one catch-up pass. Full entry, including
the three non-obvious decisions and the mutation results, in `SUITE_TODO_DONE.md` §Wave 26.

✅ **The walk's own `opendir` now has a deadline too** — see the `W26.fsev-fu2` entry above. Its probe still
blocks; the difference is that the list stops claiming to be scanning and says the folder has not answered.

**Practical consequence for testing — UNCHANGED, still skip it.** The long-known `DeepLinkTests` environment
artifact (`testRevealAndSelectNoRoot` picks up the owner's real persisted `archiveRootBookmark`) presented as
a **hang of the entire `ArchiveReaderTests` bundle** through this code path. The main-thread half of that is
gone by construction, but whether the bundle still hangs is **not verified**: confirming it means provoking a
TCC prompt on the owner's physical screen, which an unattended session may not do — and `CorpusWalker`'s
`opendir` can still block on the same root (`W26.fsev-fu2` bounded the *report*, not the syscall), which
leaves a test that waits on the library waiting. Keep running the unit lane with
`-skip-testing:ArchiveReaderTests/DeepLinkTests`. Proper isolation of the test itself is
`W20.deeplink-isolation`.

## ✅ FIXED (`W26.walk2`) — Release discovery was Spotlight-only and could blame an unreadable index on files

**Found 2026-08-04.** The owner pointed the Reader at a folder of 1,849 correctly-tagged PDFs on a volume
whose Spotlight index was dead, and the app said *"No Read/Unread-tagged PDFs were found in this folder."*
Root cause: `ArchiveLibrary` discovers only through `NSMetadataQuery`, and the one filesystem walk that
exists (`loadFixtureSynchronously`) is `#if DEBUG` — **compiled out of Release entirely**. There is no
fallback to fail over to, and `NavigationWindowView.swift:174-176` states the empty result as a fact about
the corpus rather than about what the app could see.

**Engine shipped 2026-08-05 (`W26.walk1`: `b3efb16` → `025d126`).** `ArchiveCore.CorpusWalker` is the
deterministic replacement — read-only, and its result distinguishes *has tags* / *verified none* /
**could not read** (`unreadable`, `directoryErrors`, `isClean`), which no layer of the old stack could.
`ArchiveReaderTests/LibraryDiscoveryTests` pins that it returns exactly what the shipped loader returns on a
readable tree, and that it diverges on exactly one thing: an unreadable file, which the loader drops in
silence while still reporting a settled library.

**Fixed 2026-08-05 (`W26.walk2`: `f1c0d2f` → `b88d20a` → `6f5d6ad` → completion commit).** Release now uses
that walker; all `NSMetadataQuery`/`NSMetadataItem` discovery and the Spotlight-lag `PendingWrite` subsystem
are deleted. `LibraryPhase` is the single health gate: only a clean, root-stable `.settled` pass may treat an
absence as real, prune content-index rows, or claim that no files carry Read/Unread tags. That last sentence
must quote how many regular files were examined. A degraded pass keeps every unseen prior row, including
descendants of a directory the enumerator could not enter, and cannot consume a deep link's not-found retry
budget. `W26.fsev` now supplies live FSEvents; File ▸ Rescan Archive Folder (⌘⌥R) remains the explicit
recovery control.

**Non-vacuous GUI proof:** the Tart VM's fixture builder timed out with **0/11 files Spotlight-indexed**, yet
Reader rendered all 11 tagged files and its existing 16 UI tests passed. A separate UI test over one genuinely
untagged sandbox file verified the rendered denominator. The incident no longer has an app-side workaround
because it no longer depends on Spotlight discovery.

## ✅ FIXED (`W26.fsev`) — external Finder/Processor changes were invisible until a manual rescan

**Fixed 2026-08-05 (completion commit).** `CorpusWatcher` now starts a FileEvents + MarkSelf + WatchRoot
FSEvents stream before the launch walk, on a serial dispatch queue, and holds an additional security scope
for exactly the stream lifetime. Each asynchronous exact/subtree read holds its own balanced operation scope
and is cancelled on root replacement. Every retained event is re-statted and re-read through
`ArchiveCore.CorpusWalker.inspect`; semantic item flags are never trusted. Exact paths update in place,
`MustScanSubDirs` replaces only its subtree, stream/drop sentinels force a root pass, and
RootChanged/mount/unmount re-resolve the saved bookmark before restarting. Hidden files, package
descendants, directory symlink targets, and the measured `.sb-XXXXXXXX-XXXXXX` atomic-save sibling stay
outside the walk's universe.

The app persists no event ID: each launch walks once and watches `SinceNow`. A volume whose stream cannot
start shows *"Live archive updates unavailable"* instead of going quietly stale; activation retries it and,
if still unavailable and the last clean settle is over five minutes old, re-walks. Recovering a stream also
forces one catch-up walk because `SinceNow` cannot replay its outage. There is no periodic timer. Root passes
are bounded to one active + one queued with a minimum interval, and queued recovery never exposes a false
settled/pruning window.

**Adversarial corrections before ship (11 across two passes):** dropped/history sentinels are interpreted
before path containment; RootChanged wins over unioned drop/history flags; an old-root callback is
generation-rejected; live work cannot outlive its security scope or root generation; a live read has the same
newer-verified-write precedence as a full walk while still accepting freshly read content metadata;
directory→file replacement clears phantom descendants; directory symlinks never expand the watched tree; a
queued root pass never briefly publishes settled; a recovered `SinceNow` stream gets a catch-up walk; and a
failed `FSEventStreamStart` does not call the start-only `Stop` API. The real APFS test changes Finder tags
from a separate `/usr/bin/xattr` process and uses `FSEventStreamFlushSync` to prove delivery without
Spotlight. Final self-review also made a newer serialized live read retire converged verified-write ordering
guards, so a long-running healthy library cannot retain every Reader edit forever. All filesystem fixtures are
temporary scratch trees; the real corpus was neither read nor written.

## ✅ FIXED (`W26.idx`) — launch blocked on a full walk, and persisted rows could amplify stale writes

The owned filesystem walk made discovery truthful, but a large root still showed no rows until the pass
finished. `W26.idx` adds a separate disposable system-SQLite discovery cache keyed by byte-exact root path +
marker GUID + file path. It restores tracked rows immediately as visibly revalidating, then compares fresh
`stat(2)` fingerprints and re-reads tags for every new, changed or unverified path. The tuple includes ctime,
because a Finder tag edit need not change mtime. Scan provenance prevents an interrupted/denied pass from
claiming currency or deleting unseen rows after relaunch; canceled corpus-scale DB work yields every 500 rows.

The cache does not gain write authority. Every cache-provenance row is re-inspected before a bulk or inline
mutation derives a target/delta, and the corpus rename primitive re-reads under coordination and requires the
old token still to exist. Out-of-root/canonical-lookalike paths are rejected byte-exactly. Dataless rows never
reach the PDF-open boundary; stale content-index rows are removed without materialising the file. Regression
tests cover warm correction after an app-closed tag change, mixed valid/stale selections, conditional rename,
root/commit races, partial SQLite state, canonical Unicode spellings and no-download extraction policy. The
index and saved-selection shape are new v1 state: there is deliberately no migration or compatibility path.

## ✅ FIXED (W26.deny) — `TagWriter` could DESTROY tags on a file whose xattrs are unreadable-but-writable

**Found 2026-08-04** while auditing Spotlight removal; **independent of Spotlight** and of that wave.

**Fixed 2026-08-05** — `2956f3c` (the read primitive) → `ad86cce` (the write path). Affects
`packages/ArchiveCore` — filed here because Reader tag safety is documented here. The finding is kept below
in full, followed by *what shipped*, because two of the prescriptions written into it were measured wrong.

`TagWrite.swift:252-261` states *"§2/§3 fresh read inside coordination; a read FAILURE aborts (never treated
as empty)"* and then does:

```swift
let rv = try writeURL.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
before = rv.tagNames ?? []          // ← breaks the promise directly above
```

**The `catch` never fires in the dangerous case.** Measured: `resourceValues` throws `NSCocoaErrorDomain/257`
for parent-directory denial and for an ACL denying `read`/`readattr`/`readextattr` — both already safe — but
for **a file that is itself unreadable with a traversable parent it SUCCEEDS with `tagNames == nil`**. So
`before = []`, `transform([], nil)` computes a delta against nothing, and `:271` commits it.

**Reproduced twice on scratch files** (tags `["Unread","Subj","P9"]`, then a "mark Read"):

| Setup | read | write | result |
|---|---|---|---|
| `mode 0o200` (write-only) | no throw, `before=[]` | **SUCCEEDED** | `["Read"]` — **`Subj`/`P9` destroyed** |
| ACL `deny readextattr`, perms `0644` | no throw, `before=[]` | **SUCCEEDED** | `["Read"]` — **destroyed** |
| `mode 0o000` | no throw, `before=[]` | fails (−5000) | tags survive, but `before`/inverse is `[]` → **undo corrupt** |

Violates the Core Directive (*"MUST NOT mangle, drop, or lose any tag unintentionally"*).

**Exposure on the real corpus: ZERO — measured, not assumed.** Read-only scan of all **123,028** files under
`~/Desktop/Google Drive/Archival Photos`: `owner lacks read bit: 0`, `getxattr EACCES: 0`. (51 files match
"nil tags yet `_kMDItemUserTags` present"; inspected samples decode to a literal **empty array** at
`-rw-r--r--` — benign residue of removed tags, not denial.) So **latent, not an active fire** — but modes and
ACLs arrive from network copies, restores and archive extractions, and the corpus is irreplaceable.

⚠️ **Testing gotcha that already caused one wrong conclusion here:** `URL.resourceValues` **caches on the
backing `NSURL`**, so a probe that reuses a `URL` value returns a stale answer and the test passes while
asserting nothing. Build a fresh `URL` per probe, or use `stat(2)`/`getxattr`. See *@Published willSet
timing* below and the `url-resourcevalues-caches` note (W23.m11-fu) for the same class of trap.

### What shipped (2026-08-05)

**`TagXattr.inspect`** (`packages/ArchiveCore/.../Tags/TagReading.swift`) is the new shared primitive that
answers *absent* / *readable-but-empty* / *unreadable* by asking the filesystem directly:
`getxattr(path, "com.apple.metadata:_kMDItemUserTags", …)`, where **only `ENOATTR` (93) confirms absence** —
`EACCES`, `EPERM`, `EIO`, `ENOTSUP`, `ENOENT` all mean *we could not look*. It runs **only on the
`tagNames == nil` branch**, so a tagged file costs nothing extra. Both call sites route through it:
`TagReading.read`, and `CoordinatedTagWriter`'s §2/§3 fresh read **and** its §8 post-write re-read (without
the latter, a write to an *empty* tag array would "verify" against a file nobody can read).

🔴 **Two prescriptions in the finding above are WRONG — do not follow them; they are corrected in
`execution-plans/despotlight.md` §4a.1 and §7a.3:**

1. **`access(R_OK)` is not a usable probe** (the finding's own later text says this; the "Fix" line said
   `access(R_OK)`/`getxattr`). An ACE denying only `readextattr` leaves the file *data* readable, so
   `access(R_OK)` returns 0 while the tags are unreadable.
2. **The probe must FOLLOW symlinks — NOT `XATTR_NOFOLLOW`.** Measured: `resourceValues` reports the
   **target's** tags through a symlink, so a `XATTR_NOFOLLOW` probe answers about the *link*, which has no
   attribute of its own, and returns `ENOATTR` — "confirmed no tags" — for a **denied target**. The same
   coercion, displaced one indirection.
3. **"a returned size of 0" is not the only honest empty.** Removing a file's tags leaves a **42-byte
   empty-array plist** behind, and macOS reports `tagNames == nil` for it. **51 of the owner's 123,302
   files** are in that state; treating a nonzero size as unreadable would have mis-flagged every one. The
   shipped rule: a readable attribute that decodes to an **empty array** is a confirmed "no tags"; a
   non-empty array macOS did not report as tags, a non-array plist, or undecodable bytes are all unreadable.

**Corpus census, read-only, 2026-08-05** — 123,302 regular files in 30.8 s, 0 walk errors: 21,311 `ENOATTR` ·
101,940 tagged · 51 empty-array residue · **0 denied** · 0 undecodable. Exposure was and is zero; this is a
guard against modes and ACLs arriving from network copies, restores and archive extractions.

**Known consequence, explained by `W26.notsup` (fixed 2026-08-05):** a volume with no xattr support (some
SMB/NFS mounts — *not* FAT/exFAT, where macOS emulates them) returns `ENOTSUP`, so every file there still
correctly reads as unreadable. Reader now surfaces *"Finder tags unavailable for N files"* and explains that
it cannot list or edit those files because their volume cannot represent Read/Unread tags; it recommends an
archive copy on a Finder-tag-capable volume such as APFS, followed by a rescan. Mixed-mount permission and
folder failures keep their own counts. Classification keys on ArchiveCore's exact ENOTSUP suffix, not a broad
substring that could be present in a filename. The safe read/write primitive is unchanged.

**Tests:** `ArchiveCoreTests/TagDenialTests` (20, scratch temp files only), non-vacuity measured on six
mutants — including reverting the coercion, which turns the write tests red by **succeeding**.

## ✅ FIXED (W23.l2) — a cancelled prune task could still defeat the two-emission absence gate

**2026-07-31.** `ContentIndexer.pruneIfSettled` cancels the prior prune task before starting a new one,
and that cancellation was doing more work than it can. **Cancellation is cooperative**: a task already
past its last `Task.isCancelled` check runs to completion, and `MainActor.run` is *not* cancellation-aware,
so its late hops execute too. The old code then read `pendingPrune` in one hop and wrote it in another,
with nothing tying either to the emission it belonged to.

**Re-confirmed empirically before anything changed** — the finding was inspection-only, and the first
probe *refuted itself*, which is the useful part. Replaying the pre-fix shape under the real concurrency
runtime, back-to-back emissions turned out to be **safe**: task A dies at its first cancellation check
because it hasn't started running when B cancels it. The race needs A genuinely mid-flight — which is the
real case, since `allPaths()` over a large index takes real time. With the probe parked past A's last
check, all four questions confirmed: A observed `Task.isCancelled == true` and ran its hops anyway; a
superseded A overwrote state a newer emission had just written; that stale stash then deleted a path
after only **one** current absence; and in the other interleaving A deleted a path the newest snapshot
said was **present**. Search results vanish until a reindex — the files themselves were never at risk
(the content index is an explicitly rebuildable cache).

**The fix is a prune epoch, and two halves of it are load-bearing:**
- `commitPruneDecision` does read-decide-write in **one main-actor hop**. A split read-then-write is the
  window a newer emission interleaved through, so a generation check alone would not have closed it.
- The row delete **re-checks the epoch** before running. Skipping a superseded delete costs only that the
  rows survive another two-emission cycle; deleting them wrongly costs search hits until a reindex.

Gotchas for whoever touches this next:
- **`resetPruneState` bumps the epoch, not just the task.** A root change invalidates the old root's
  absences; without the bump an in-flight task from that root re-stashes them over the cleared state.
- **The delete now happens AFTER the pending-state write** (it used to be before). That ordering is safe
  because `pendingPrune` is in-memory only: if the `try?`'d delete fails, the next emission re-stashes the
  absence and prunes a cycle later. Two end-to-end tests over a real scratch index pin the observable
  contract so the reordering can't drift.
- **`pruneDecision` is now a pure function here too**, mirroring `NotesIndexer`'s (this file is its
  fork) — which moves the "an empty snapshot can never wipe the index" guarantee inside the decision.
  `NavigationModel` already refuses to call with an empty set, so no reachable behaviour changed; the
  point is that the guarantee can no longer be lost to a future caller.
- **The race tests don't try to win a real race.** They drive the interleavings through the epoch seam
  (`beginPruneGeneration` / `commitPruneDecision`), and each one re-implements the pre-fix ungated logic
  against the same fixture and asserts it produced the harmful outcome — so a passing test can't be
  vacuous. `inFlightPruneTask` exists so an end-to-end test can await an emission instead of sleeping.

## ✅ FIXED (W23.m9) — a failed `ContentIndex.open()` poisoned search until restart, silently
**2026-07-30.** Two defects on the same path, both about silence.

**The half-open handle.** `sqlite3_open_v2` is *lazy*: it returns a live handle for a file it hasn't read.
So a corrupt or foreign `content-index-v2.sqlite3` opened with `SQLITE_OK` and died on the first PRAGMA
("file is not a database", rc=26 — confirmed by experiment before any code changed). `open()` threw with
`db` still non-nil, and since it short-circuits on `guard db == nil`, **every later `open()` returned
"success" without completing setup**: the index was poisoned for the life of the process, and since the bad
file is still there next launch, every launch after. `open()` is now all-or-nothing — the PRAGMA/schema half
runs inside a `do` whose `catch` calls the new `discardHandle()` and rethrows. `discardHandle()` uses
**`sqlite3_close_v2`, not `sqlite3_close`**: close_v2 never returns BUSY, so clearing `db` can't strand a
live connection holding the file lock. That mattered — under the neutered build the stranded handle kept the
`-shm` sidecar locked and even *replacing* the bad file failed.

**The silent finish.** `ContentIndexer.launch` opened with `try?` and wrote every batch with `try?`, then
finished like any other pass: a dead index produced a run that extracted every PDF in the library, threw all
of it away, cleared `progress`, and left an idle status bar. Search answered `[]` — indistinguishable from
"no matches" — and format health answered 0, i.e. "nothing needs attention". The driver now publishes a typed
`Failure` (`.unavailable(detail:)` / `.incomplete(rows:)`), mapped from a pass `Outcome` in one place
(`finish`), where `.ok` **clears** it so a transient corruption can't leave a permanent warning. The five
query paths go through `openForQuery()`, which records the failure rather than answering empty.
`NavigationModel.indexFailure` mirrors it; the status bar shows an amber line whose tooltip carries the
SQLite reason (`ar.status.indexFailure`).

Gotchas for whoever touches this next:
- **`pruneIfSettled`'s `try?` is deliberate.** A failed open there makes `allPaths()` empty, so the diff finds
  nothing absent and the prune deletes nothing — it degrades to a no-op. The asymmetry with the query paths is
  intentional and commented in place.
- **A failed open now STOPS the pass.** Continuing meant extracting 150k PDFs to discard them one batch at a
  time; the honest path is also the cheap one.
- **`.incomplete(rows:)` has no end-to-end test** and can't easily get one: post-fix a batch write can only
  fail at *runtime* (disk full, corruption after open), and there is no portable way to make SQLite fail a
  write on demand short of corrupting an open file (undefined behaviour). The outcome→state mapping is a pure
  function that IS tested; the count itself is `batch.count` at two flush sites, exact because `upsertBatch`
  rolls the whole batch back on any error.
- `ContentIndexer` gained an `init(url:)` seam (the app path is now `convenience init()`), which is how the
  failure paths are reachable without an Application Support file.

Tests: `ContentIndexRecoveryTests` (3), `ContentIndexerFailureTests` (7) — scratch garbage sqlite3 files under
the bundle temp dir; the `ArchiveFile` paths need not exist (an unreadable file is a legitimate row). Both
mechanisms proven non-vacuous by neutering. The same fix shipped in Notes the same day — see
`../ArchiveNotes/KNOWN_ISSUES.md`.

## `DeepLinkTests.testRevealAndSelectNoRoot` fails on a machine with a persisted archive root (environmental)
The unit-test host shares the `com.archivereader.app` UserDefaults domain, so if this machine has a persisted
`archiveRootBookmark` (e.g. left by a GUI/XCUITest session pointing at the `AR-GUI-Fixture`), `NavigationModel()`
resolves a root and the test's "No archive folder" assertion fails. It's **environmental, not a regression** —
the diff under test touches no NavigationModel/DeepLink/RootFolderStore code. The WS7 health gate
(`ops/autonomous/health-gate.sh`) therefore runs the Reader unit suite with
`-skip-testing:ArchiveReaderTests/DeepLinkTests/testRevealAndSelectNoRoot` so it doesn't false-park the
autonomous run. **Real fix (then drop the skip) — QUEUED 2026-07-18 as `W20.deeplink-isolation`:** isolate the
test's defaults (inject a volatile `UserDefaults(suiteName:)` with no bookmark), so it doesn't read the machine's
persisted archive root. ⚠️ Must NOT be "fixed" by stashing/removing the machine's real `archiveRootBookmark`
(that's the never-mutate-live-root hazard) — inject a throwaway defaults instead.

## GUI-pass regressions in the AppKit nav table + tag filter (2026-07-16 — owner GUI re-test)
An interactive GUI pass surfaced three display/interaction bugs in shipped Reader features. Two fixed, one deferred:
- **FTS snippet previews never rendered (FIXED).** The keyword-in-context excerpt line under a search hit was
  clipped: the AppKit name-column `NSTextField` (a `labelWithString:` field) stayed single-line
  (`usesSingleLineMode`/`wraps = false`), so the appended second line + `\n` never grew the row under
  `usesAutomaticRowHeights`. Fix: in the snippet branch, put the field into the same multi-line-capable state the
  tags cell (`TagTokenCellView`) uses, and reset it in the non-hit branch (cells are reused). `AppKitTableView.swift`.
- **Column-header click sort was dead (FIXED).** `sortDescriptorsDidChange` is an `NSTableViewDataSource`
  callback, but it was implemented on the `Coordinator` (only the table's *delegate*); the
  `NSTableViewDiffableDataSource` is the real `dataSource` and never forwarded it. Fix: a
  `SortableDiffableDataSource` subclass implements + forwards it — **and the method MUST be `@objc`**: an optional
  @objc-protocol method added on a *subclass* is not auto-exposed to the Obj-C runtime, so `respondsToSelector:`
  returned false and AppKit never called it (build was clean; only runtime/GUI surfaced it). `AppKitTableView.swift`.
- **Selected-tag filter chips shifted the file table left (FIXED `b5a5a01`, owner-verified 2026-07-16).** The chips
  rendered as separate buttons beside the "Add tag filter…" field in a single-row filter bar that already sits near
  the window width; each added chip's width tipped the content column past the window, so the root `HStack`
  re-centered and dragged the file table left.
  **Two container fixes failed — the instructive part:** a horizontal `ScrollView` capped at 260 pt *reserved* its
  max eagerly (a scroll viewport's width is the width proposed to it, independent of content), so it overflowed on
  the **first** chip — worse than the original; a wrapping `FlowLayout` then got compressed to ~one chip wide and
  piled the tags up vertically. Both attempts were tuning a container's width; the bug was that **any**
  content-sized chip row inflates a bar that has no slack.
  **Fix (by construction, not by tuning):** `Views/SubjectFilterTokenField.swift` — an `NSTokenField` whose tokens
  ARE the selected filters, bounded (220 pt), single-line, horizontally scrolling, with LOW horizontal compression
  resistance. Tags live *inside* the field, so adding a filter adds **zero** width to the bar and the column can't
  be pushed past the window. Replaced the `TagFilterField` combo box (deleted; that was its only call site).
  **Lesson:** when a layout bug is "container X inflates its parent", moving the content *inside* an
  already-bounded control beats resizing the container.

## Verified facts to rely on (2026-07-04)
- Writing `.tagNamesKey` while keeping the color-name token (`Red`/`Purple`) and **not** touching
  `.labelNumberKey` **preserved** `labelNumber` (tested on a Red-labeled scratch copy, local APFS).
  Still verify `labelNumber` after every write and restore on drift.
- `FileManager.setAttributes([.creationDate:])` accepts historical dates (1938, 1850) but **clamps
  below ~1677-09-21** (int64-ns-since-1970). → Do NOT use creation date as the chronological sort
  key; sort by a date derived from the tags (no range limit, medieval-safe).
- ~~Spotlight tag queries are fast (compound 3-facet over 6,941 files ≈ 0.38s) and scale.~~
  ⛔ **RETRACTED 2026-08-07 (`W26.docs`) — this "verified fact" is what the 2026-08-04 incident falsified,
  and it is exactly the kind of fact this section exists to be trusted on.** The 0.38 s was measured on a
  *healthy* index and says nothing about the failure mode that matters: a dead Data-volume index answers
  just as fast, with **zero rows**, and reports no error — 1,849 correctly-tagged PDFs became *"No
  Read/Unread-tagged PDFs were found in this folder."* Speed was never the risk; **unfalsifiable emptiness**
  was. Replacement fact, measured read-only 2026-08-04 on the real corpus: a single-threaded
  `FileManager.enumerator` walk of 123,028 files / 102,478 PDFs at depth 7 takes **10.15 s**, and it cannot
  be silently empty. Discovery is that walk now (`ArchiveCore.CorpusWalker`, `W26.walk1`/`walk2`).

## macOS tag/label coupling (verified 2026-07-05)
- A **`Red`/`Purple` tag token is inseparable from its Finder color label**: setting the token makes
  macOS auto-assign label 6/3, and there is no "Red subject with no label" state. So `TagWriter`'s
  color-clear removes the token matching the *actual* label (correct), and a document whose subject
  is literally "Red"/"Purple" will always appear color-labeled. Non-color subjects are unaffected.
- **Do not run overlapping `xcodebuild test` invocations** on the same scheme/DerivedData — the
  concurrent test processes contend on `NSFileCoordinator` and tag writes, ballooning runtimes
  (seen: a 0.07s suite took 448s under contention). Run one build/test at a time.

## Deferred hardening (from the 2026-07-05 code review)
- **Write-target identity re-verification (Safety §6, low severity) — FIXED 2026-07-17 (mechanism
  `838b456`+`d393ff3`, W14.2; armed at live call sites `1a7c6cb`+W14.2-fu).** The concern: a tag write
  applies to whatever file currently occupies the URL, so a Finder move/replace between discovery and the
  write could tag the wrong file. **Mechanism:** `CoordinatedTagWriter.write(_:expectedIdentity:)`
  + `FileIdentity` (backed by `fileResourceIdentifier`, compared via `isEqual:` — **never**
  `.documentIdentifierKey`, which mutates on read) re-verify the resolved URL's identity **inside the
  `NSFileCoordinator` block** and abort with `.identityMismatch` on a moved/replaced file; the Reader
  `TagWriter.apply`/`setReadState` adapter exposes an opt-in `expecting:` param (fully unit-tested on
  scratch copies). **Armed (W14.2-fu):** every `NavigationModel` write call site — `mark`, group/inline
  edits, corpus-wide rename, and undo — now captures the file's `FileIdentity` **lazily at edit time**
  (via `ArchiveFile.liveIdentity()`, never at bulk discovery — the original rationale was Spotlight's
  "no per-file I/O" fast path, which `W26.walk2` retired, but **lazy is still correct**: an identity
  captured at discovery would already be stale at edit time, and a stale identity is worse than a fresh
  one) and passes it through `expecting:`; undo re-verifies against the identity captured at the
  ORIGINAL edit, so a file swapped under its path between edit and undo is skipped rather than mis-tagged.
  The group/rename path uses the identity-carrying `TagWriter.apply(_:to:[(url,identity)])` batch overload.
  A `nil` identity (file with no resolvable id) transparently skips the check for that file. Guard active
  in production; failures surface as "could not update/edit" without altering any other file.

## @Published willSet timing (fixed 2026-07-05 — GUI-caught)
- A Combine subscription on a nested `@Published` (`library.$files`) fires in **willSet**, *before* the
  property commits. A synchronous sink that reads the stored property (`self.library.files`) inside
  `recompute()` therefore sees the **old** value — which made the nav list show **0 of N** after a
  load. Fix: `.receive(on: DispatchQueue.main)` before the sink so it runs after the value commits
  (or use the value the publisher delivers, not the stored property). **Do not** read a just-changed
  `@Published` back from `self` inside its own synchronous sink. Unit tests missed this; only running
  the GUI surfaced it (verified via `screencapture`).

## SwiftUI `Table` row-render skip via identity-only Equatable (fixed 2026-07-05 — GUI-caught)
- `ArchiveFile` conformed to `Equatable`/`Hashable` by **`url` only** (treating `==` as *identity*).
  SwiftUI's `Table` diffs elements by Equatable, so when a tag edit changed a row's *tags* but not its
  `url`, the Table judged the element "unchanged" and **skipped re-rendering the cell** — marking a
  file Read left the row visibly "Unread" even though the model was correct. This *masked* the separate
  Spotlight clobber (below): we never saw "Read" appear, so it looked like the write/optimistic update
  failed. Fix: **value-based `==`** (url + name + fileType + tags + contentModified) in
  `ArchiveFile.swift`; row *identity* for selection stays `id` = url.path; url-only `hash` remains valid
  (value-equal ⇒ same url ⇒ same hash). **Lesson:** for a type used as SwiftUI collection data, make
  `Equatable` reflect **displayed value**, not identity — identity belongs in `id`. Unit tests missed
  it; only the live GUI surfaced it (same lesson as the willSet gotcha above).

## Spotlight tag-index lag clobber (fixed 2026-07-05; obsolete subsystem removed by W26.walk2 2026-08-05)
- The 2026-07-05 fix overlaid `TagWriter`'s verified `.after` value while Spotlight re-emitted stale tags.
  It was necessary while `ArchiveLibrary` consumed `NSMetadataQuery`, but its 600-second TTL, convergence
  comparisons, and settle timer had no role once filesystem discovery shipped. `W26.walk2` deleted that
  `PendingWrite` subsystem and its 8-case test file. A smaller monotonic ordering guard now protects the
  distinct race that remains: if a walk started before a verified write, its later emission cannot replace
  the fresh `.after`/`.afterLabel`. All five write call sites still publish only the writer's verified re-read;
  no optimistic reconstruction, disk write, or extra disk read was introduced.

## Interleaved merged PDFs: pages 3+ were unviewable AND unfindable (W23.m2 — fixed 2026-07-30)
- Processor merges a multi-page document as `image1, text1, image2, text2, …` (`PDFGenerator.mergeDocumentPDFs`,
  and its "Re-OCR multi-page PDF" mode), and `SPEC/tag-format.md` §"Interleaved multi-page variant" states
  outright that **consumers must not hard-assume two pages**. Reader assumed exactly that in three places at
  once: `DocumentViewerModel.imagePage`/`textPage` were `page(at: 0)`/`page(at: 1)`, `next()`/`previous()`
  stepped **file URLs** rather than pages within a document, and `DocumentFindScanner` had a literal
  `default: break` discarding every match on page index ≥ 2. Net effect for any merged document with 2+ source
  pages: every scan after the first, and all of its OCR text, was unreachable at every affordance — no
  scrolling, no cycling, no find, no menu command — **even though the full-text index had already extracted it**,
  so search would lead you to a document whose matching page you then could not open.
- Fix: a **page-pair** model. New pure `Core/DocumentPagePairs` — pair `p` is PDF page `2p` (image) + `2p+1`
  (OCR text) — is the single home for that arithmetic, shared by the viewer and the find scanner so they
  cannot drift. `pairCount` rounds **up**, so a merge of a 2-page document and a bare scan doesn't lose the
  trailing scan. `DocumentViewerModel` publishes `pair`: cycling walks pairs then files (backwards lands on the
  previous document's **last** pair), `canGoNext`/`canGoPrevious` gate the buttons, `positionLabel` gains
  "· page 2 of 4" only when there IS more than one pair, and `DocumentFindScanner.pairMatchCounts` buckets
  every page so `FindNavigator` can address a match by `(doc, pair, pane)`.
- **Gotcha worth remembering:** both viewers must key their panes on `model.pageIdentity` (index + pair), not
  on the file index. `PDFPaneView.updateNSView`'s reuse fallback compares `page.string`, which is `nil` for
  both the old and the new **image** page — so without the pair in the `.id`, stepping to the next pair leaves
  the previous scan on screen. `PreviewSheet` had no `.id` at all, which was the same latent bug for document
  cycling there; it is keyed now too.
- Not a SPEC change: the SPEC already documented the interleaved variant and the no-2-page-assumption rule.
  This is Reader coming into conformance with it.
- ~~Still open (separate item)~~ **CLOSED by `W23.m4`** (below): the focused-pane page number, the command's
  unreachability from the document window, and reveal dropping the page are all fixed.

## Page-level durable links were broken at all three ends (W23.m4 — fixed 2026-07-30)
`archivereader://reveal?…&page=N` is the citation Notes stores for a quoted page (the reveal contract in
`execution-plans/archive-notes/00-overview.md` §8.3 requires the page be passed on). Three independent
defects meant the feature could not work at all — each fixed here, together, because fixing one alone still
leaves it broken:
- **You could not make one where you read.** `ArchiveReaderCommands` reached for the archive root + marker
  through `@FocusedObject NavigationModel` and disabled the command on `nav == nil`. A document window
  publishes only `.focusedSceneObject(model)` (its `DocumentViewerModel`) — there is no `NavigationModel` in
  that scene — so "Copy Archive Link to This Page" was **greyed out in the document window** and reachable
  only over the navigation window's preview sheet.
  Fix: `Core/ArchiveLinkTarget.swift` — the root + marker as one small `Sendable` value, published as a
  **focused value** by every window that shows a document, plus an app-level `ArchiveLinkContext`
  (`@StateObject` injected into both scenes) that carries it out of the navigation window. The nav model
  stays the single writer (`attach(linkContext:)` + a `rootStore.objectWillChange` sink), so a root switch or
  clear can never leave a document window citing the old archive. The command now needs only the focused
  viewer + that target.
- **It wrote the wrong page.** The page was `imagePageIndex(pair:) + 1` — the pair's **image** page — no
  matter which pane you were reading, so citing a passage of OCR text produced a link to the scan.
  Fix: `DocumentViewerModel.focusedPageNumber`, the 1-based PDF page of the **focused** pane, degrading to
  the pair's image page when that pane holds no page (a trailing text-less scan, or a failed load).
- **Reveal threw the page away.** `revealAndSelect` stored it in `pendingRevealPage`; the only other
  mentions **cleared** it. The link selected the row and stopped — no viewer, no page.
  Fix: `goToPDFPage(_:)` (the exact inverse of `focusedPageNumber`: page → pair + pane, clamped, a vanished
  text page degrading to its image page), an additive optional `DocumentSelection.initialPage`, and
  `openViewerRequest`/`openViewerSelection` — a counter+payload request in the shape of the existing
  `requestScroll`, since `openWindow` is an Environment action only a View holds. A link **without** a page
  still just selects and scrolls; that is unchanged.
- **Gotchas worth remembering:** (a) adding those two modifiers inline to `NavigationWindowView.body`
  overflowed the compiler's type-check budget ("unable to type-check this expression in reasonable time") —
  they live in one extracted `archivePageLinkBridge` modifier. (b) `make-gui-fixture.sh` now writes a
  `.archive-suite-root.json` with a FIXED GUID: with no marker at the fixture root there is no portable link
  identity, so every archive-link command stays disabled and the GUI lane could not test them at all.
  (c) `initialPage` is part of the `WindowGroup` value, so two links to different pages of one document open
  two windows (same page → the existing window is brought forward). That is the value-identity semantics of
  `openWindow(id:value:)`, and reasonable here: each cited page gets its own view.

## A root's identity could be a GUID the disk never had (W23.m6 + W23.l3 — fixed 2026-07-30)
Every durable archive link names the root's `.archive-suite-root.json` GUID, so a GUID that isn't on disk is a
link that can never resolve. `ArchiveCore/Links/RootMarker` handed one out three ways, and the Reader minted
from it without knowing:
- **Unreadable was reported as absent.** `read` mapped ENOENT *and every other read failure* (permissions, I/O)
  to `nil`. "Absent" is precisely the answer that licenses minting a replacement, so a transient read error on
  an **existing** marker invited `ensure` to write a new GUID over it — orphaning every link already copied
  from that root. Now: `nil` means absent and nothing else; unreadable throws the new `.unreadable`, malformed
  still throws `.malformed`, and `ensure` refuses to fall through to creation on either.
- **A failed write returned the in-memory marker anyway.** Indistinguishable from a durable one, but it is a
  different GUID after the next launch. On a read-only volume / no write permission / disk full, links copied
  during that session were born broken. Now `ensure` throws the (declared-but-never-used) `.readOnly`, carrying
  the marker as `provisional` so a caller can say *which* identity was lost without being able to mint from it.
  Same for a write that reports success but leaves nothing readable.
- **First-time creation was a check-then-write race (W23.l3).** The absence check sat *outside* the write
  coordination, so two processes could both see absence and both write; the loser returned a GUID the disk had
  already replaced. The re-check, write and confirmation now happen inside **one** write claim, and a racer that
  finds a winner adopts it. (Codex confirmed this by inspection only — the new concurrency fixture reproduces
  it: under the old ordering 8 racers get 8 different GUIDs with one on disk, 3 runs out of 3.)

Reader side: `RootFolderStore.rootMarker` is now derived from `Core/RootMarkerState.swift` and is **nil unless
the identity is durable** — one choke point, so `copyArchiveLinks`, the W23.m4 focused link target and
`revealAndSelect` all refuse together instead of each remembering to check. It also degrades **visibly**:
`RootMarkerDegradation` keeps the four distinguishable reasons and each says what is wrong and what would fix
it. Copying a link from a degraded root used to say "Choose an archive folder first." with a folder plainly
open; an incoming link used to be blamed for pointing at a different archive.

Gotcha: `ensure` needs an **uncoordinated** `decode` helper for the in-claim re-check — calling `read` there
would nest a second `NSFileCoordinator` inside an accessor block and deadlock.

Audited while here: Notes does **not** share the defect. `ArchiveNotes/Store/RootMarkerStore.ensureMarker` is a
separate (duplicated) implementation that throws `corruptRootMarker` when an existing file won't read or decode
and propagates its write failure — it never hands back an unpersisted GUID. It is uncoordinated, though, so the
W23.l3 race would apply to it if two Notes instances ever raced a first-time root; folding it onto
`RootMarker.ensure` is the obvious future cleanup.

## Reactive/eventual-consistency bugs found by adversarial review (fixed 2026-07-05)
A multi-agent hunt for this bug class (the willSet + clobber category) confirmed four more:
- **`extendSelectionToDocumentRun` selection race:** the `Task` mixed a *pre-await* `selected` snapshot
  with the *post-await* current `self.selection`, so a selection change during the `await` polluted it.
  Fix: snapshot the selection before the await and bail if it changed (the selection is the epoch).
- **`ContentIndexer` dropped live updates:** `guard !running` silently dropped any index request that
  arrived during a running pass (new/re-OCR'd files never indexed). Fix: coalescing `pending` + relaunch
  on finish (a tag-only update does not restart a huge initial index, since `needsIndex` skips it).
- **`ContentIndexer` uncancelled scope change:** the detached task was never cancelled (its
  `Task.isCancelled` check was dead code), so a stale-scope pass held the slot and the new root was
  never indexed. Fix: store + cancel the task on an empty-set (scope-clear) call, with a `generation`
  token so a superseded pass can't clobber newer progress/finish state.
- **⌘O orphaned the Preview sheet:** the Selection-menu ⌘O stayed enabled over the preview and opened
  the doc window without dismissing the sheet. Fix: `openSelection()` clears `showingPreview` first.

## Open risks / to verify
**Reviewed with the owner 2026-07-18** — every former entry here was grounded against current code; almost all
are now settled in code + tests. Kept as a short record:
- **SETTLED — Spotlight content indexing is not relied on.** Full-text search uses the Reader's own FTS5 index
  (`Search/ContentIndex.swift` + `ContentIndexer` + `PDFTextExtractor` over page-2 text), never
  `kMDItemTextContent` (0 code references). The old "re-check on-disk indexing" residual is moot.
- **SETTLED — `.documentIdentifierKey` is never requested** (it can assign/persist an identifier = a mutation).
  It appears only in "never request" comments; W14.2 identity re-verification uses `fileResourceIdentifier`
  (Safety §6). Enforced, not "to confirm."
- **SETTLED — tag-write coordination.** The shared `CoordinatedTagWriter` uses
  `NSFileCoordinator(.contentIndependentMetadataOnly)` (never `.forReplacing`), reads the array **inside** the
  coordinated block (TOCTOU), and verifies by re-read multiset. Covered by focused example tests
  (`TagWriterPrimitiveTests`/`TagWriterTests`). *(A generative property test was considered 2026-07-18 and
  declined as assurance-only — the path is deterministic + audited + green.)*
- **SETTLED — facet classification is display/sort/filter only, never drives a write.** `DocumentTags.parse`
  demotes shadowed collisions (a subject literally `1984`/`P7`/`Read`) back to subjects; `TagEditing` removes only
  the exact winning token. Regression-tested (incl. the `Read`-substring case).
- **SETTLED — segment features degrade when Classification is absent** (`DocumentRuns` returns a single item);
  the nav table is AppKit `NSTableView`; non-2-page / corrupt / non-PDF files degrade via `PDFFormatStatus` +
  render guards (page count is never a defect signal).
- **Low-pri, NOT queued (owner-reviewed 2026-07-18) — Unicode-on-write verification.** A scratch probe/guard for
  (a) macOS not trimming whitespace off a tag on write and (b) locking in that the verify treats NFC==NFD as
  equal. **The note's NFC/NFD "false-fail" fear is already neutralized** — Swift `String` comparison is
  canonical-equivalence-aware — so only the trim case is unpinned. Assurance-only, not a correctness gap; left
  as a soft backlog item.
- **QUEUED (owner-reviewed 2026-07-18) — the `DeepLinkTests` no-root flake real-fix** (top of this file) is now
  tracked as **`W20.deeplink-isolation`** in `SUITE_TODO.md`.

## Environment notes
- Xcode 26.3 / Swift 6.2 toolchain; XcodeGen 2.45.2 at `/opt/homebrew/bin/xcodegen`.
- GitHub CLI: use `/opt/homebrew/bin/gh` (bare `gh` is shadowed on this machine).
- The corpus lives in `Test files/Brown Gemini/` (150-PDF representative sample as of 2026-07-18, slimmed from ~6,941) and is gitignored — never modify it.
