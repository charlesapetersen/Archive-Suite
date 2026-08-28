# Known Issues (deferred)

Tracked bugs we've chosen to come back to later. Each entry has enough context to resume cold.

---

## ✅ FIXED (W28.cert-fu2): a normal Processor Debug build could not launch under the suite's self-signed certificate

**Found and fixed 2026-08-12.** The build succeeded, but dyld aborted before either the app
or its headless recovery driver reaches `main`: Xcode 16's `ArchiveProcessor.debug.dylib` and the launcher
were reported as having different Team IDs. The local self-signed identity has no Team ID, while the hardened
runtime still enforced library validation. Consequently the documented clean-Debug `launch.sh`,
`test-smoke.sh`, and recovery-driver paths were not executable.

The target now sets `ENABLE_DEBUG_DYLIB: NO` in **Debug only**, making Xcode link the app body into the
ordinary executable that was already signed and accepted. Processor has no app-hosted XCTest target or
SwiftUI previews, so it needs neither the split dylib nor Reader/Notes' explicit
`disable-library-validation` entitlement. Xcode does inject `get-task-allow` into Debug automatically.

The signed-product audit found that Xcode also injected `get-task-allow` into Release despite its absence
from the shared entitlements map. The Release target now sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`:
hardened runtime and the explicitly declared network/file entitlements remain, while the signature contains
neither debugger entitlement.

## ✅ FIXED (W21.e2e-fu1): the phone↔Mac Tier-2 harness could not reach pairing

**Found 2026-08-12 while verifying W3.cap-r3-fu8; fixed 2026-08-13.** The script now resolves the real
`macOS` XcodeGen directory. API-36 keyboard dismissal checks WindowManager's actual IME window, sends Back
only while it is visible, and waits for it to disappear; the old `KEYCODE_ESCAPE` path was mutation-proven
to leave Gboard over `Connect`.

The first complete pairing attempt exposed W16.lan2's stale READY credential (tracked separately below).
Until that source seam is corrected (`W21.e2e-fu2`, Tier-2 — not owner-gated since 2026-08-13), the harness reads the persisted high-entropy LAN token used
by `CaptureServer`, never logs or screenshots it, redacts the stale relay code from READY/Mac-log artifacts,
and makes the entire run directory owner-private. Both raw backup and finalized output now stay under the
per-run `/tmp` root. The exact current harness completed all three emulator→Mac fixtures through OCR and
finalize, with every unique token + year and every required phone screenshot present.

## ⚠️ OPEN (W21.e2e-fu2): the test-only LAN READY line publishes the cloud-relay credential

**Found 2026-08-13 while running W21.e2e-fu1.** W16.lan2 correctly split the six-character Drive relay
`token` from the 32-character `lanToken` authenticated by `CaptureServer`, but
`CaptureSession.serverDidStart` still writes `token` in its `LIVECAPTURE_READY` line. A phone that pairs
with that advertised value reaches the Mac and gets HTTP 401; the E2E screenshot and UI diagnostic both
confirmed the mismatch before any photo or paid OCR call.

The scripts-only W21.e2e-fu1 workaround reads the persisted `LiveCaptureLANToken` used by the running
server. The source seam should still be corrected so its LAN READY contract is truthful, while
`relayReceiverDidStart` keeps publishing the relay token. That change lives in `Capture/` and is therefore
parked for a named owner authorization; do not fold it into an unrelated harness edit.

## ✅ FIXED (W3.cap-r3-fu8): manifest resume no longer disguises a failed segment as staged

**Fixed 2026-08-12.** The current staging manifest persists both each staged record and its retained per-page
OCR inputs, but resume rebuilt every status row as `.staged`. A `.noOutput` or `.incompleteOutput` record was
still correctly refused by finalization—so its source remained recoverable—but it returned after a crash with
a success label, outside `failedGroupIds`, and with no retry action.

Resume now sends a current record through the same `labelStagedRecord` classifier as first-write and rotation-
regeneration paths. Failed records return failed and retryable; relaunch itself starts no OCR, so replacement
spend remains an explicit operator decision. Retained pages also restore the true page count used by the row
and retry-cost sheet (artifact counts are zero for no output and one for a merged multi-page PDF). A legacy or
damaged record without matching retained inputs deliberately keeps the prior `.staged` fallback: guessing with
an empty result list could call a complete text-bearing document image-only. Finalize/deletion decisions are
unchanged and still key only off on-disk filing plus completeness.

## ✅ FIXED (W25.modelsync-fu): the retry sheets opened on the wrong model — and one on the wrong provider

**Found 2026-08-02** (adversarial review of W25.modelsync; pre-existing, not introduced by it). **Fixed
2026-08-03** — see `SUITE_TODO_DONE.md` → *Owner-reported bugs (2026-08-02)*.

**Three defects, not the one filed.** The unfiled one was worst: `OCRRetrySheet` hardcoded `.gemini` +
`geminiModels[0]` with nothing ever overwriting them, so a failed **Anthropic / OpenAI / Mistral** run
offered to retry on *Gemini* at that family's cheapest model, with the Gemini Keychain key loaded to
match. Separately, `ModelChoiceSheet.init` seeded `initialProvider.models.first`, and
`ModelChoiceView`'s in-sheet provider switch set `newProvider.models[0]`.

**The fix.** Both sheets take `initialModel` from the caller and guard `initialModel.provider ==
initialProvider`, so a mismatched pair can't send one provider's model id to another's endpoint. The
in-sheet switch reads `ModelSelectionStore.savedModel(for:)`.

**Two invariants worth keeping.** (1) A retry choice is **never** written back to `ModelSelectionStore` —
it is a one-off, and must not change what the next full run uses; both sheets keep independent `@State`.
(2) **Live Capture seeds from `session.config`, not the app-wide selection**, because
`CaptureSession.activateProcessingIfNeeded` locks the session config at start so mid-session Settings
changes cannot affect a running session. Don't "simplify" either sheet into reading the store directly:
only the caller knows which notion of "current model" applies.

**Still broken in every retry path — see W25.retry-backend below.** These sheets pick a *native* provider
model and load `KeychainHelper.load(account: provider.rawValue)`, which is wrong in gateway / Local Agent
mode. Fixing the seed did not fix that, and the seed fix makes one branch of it *cost more*.

---

## ⚠️ OPEN (W25.retry-backend): in gateway / Local Agent mode the retry sheets are decorative, and Live Capture's retry silently bills a metered API

**Found 2026-08-03** (adversarial review of W25.modelsync-fu). **Pre-existing mechanism; needs an owner
decision, so not fixed with the seed.** Three faces of one defect — the retry UIs assume the direct
provider path, but a run can be on a gateway or the Local Agent CLI.

1. **Process Files retry ignores the picker entirely.** `retryOne` and the modal retry loop pass
   `gatewayConfig: currentGateway, localAgent: currentLocalAgent`, and `performOCRCall`'s backend
   precedence is **localAgent → gateway → provider** (`OCR/OCRProcessor+OCR.swift`), so the chosen
   `provider`/`model` are never read. In gateway mode the sheet seeds a native model, prints a cost
   estimate for it, and the status line even says *"Retrying 3 files with Anthropic Claude Opus 4.6…"* —
   while the call goes to the gateway's `modelID`, i.e. **the same model that just failed**, at the
   gateway's price. Money spent re-running the identical failing config, with the UI naming a model that
   is never contacted.
2. **Live Capture retry does the opposite — it *drops* the backend.** `LiveCaptureProcessor.retryFailed`
   passes `gateway: ov == nil ? config.gateway : nil, localAgent: ov == nil ? config.localAgent : nil`, so
   any override forces the **direct metered API**. On a Local Agent session (subscription auth, $0/page) a
   6-page segment retry becomes 6 real billed calls. ⚠️ **W25.modelsync-fu made this branch dearer**: the
   sheet now seeds the session's *selected* model instead of the family's cheapest, so the same accidental
   click costs more. That is an argument for fixing this soon, not for reverting the seed — the old
   cheap-but-wrong default was not a safety feature.
3. **A gateway-only operator cannot retry at all.** Both sheets load the *provider-named* Keychain account,
   never `"Gateway"`, and Retry is `.disabled(apiKey.isEmpty)` — so with no native key the button is dead
   and the only option is "Continue Without Retrying".

**Owner decision needed** (this is why it is filed, not fixed): should a retry (a) reproduce the run's
backend and drop the provider/model picker to a gateway-model / CLI-model field, (b) keep the picker as a
deliberate *escape hatch* to the direct API — in which case it must say so and show the price, since that
is a $0 → metered jump for Local Agent — or (c) offer both, explicitly labelled? Until that is decided,
any comment claiming the picker and the call agree is false.

**Related, same review, smaller (`W25.retry-estimate`):** both retry estimates call `CostEstimator.estimate`
without `rotationMode:` or `imageScale:` (so `.off` / `1.0`), while `retryOne` runs `detectRotation` with the
run's real rotation mode — an LLM rotation mode makes extra paid calls per file that the quote omits.

---

## ✅ FIXED (W25.modelsync): a model change in Settings did not reach the Process Files estimate — or the run

**Found 2026-08-02** (owner-reported). **Fixed 2026-08-02** — see `SUITE_TODO_DONE.md` → *Owner-reported
bugs (2026-08-02)* for the full write-up and the four adversarial-review follow-on fixes.

**What was wrong.** The per-provider selected model (`selectedModelId_<provider>`) is the only processing
setting that cannot be `@AppStorage` — the property wrapper needs a fixed key, and this one varies by
provider — so `OCRView`, `SettingsView` and `ToolsView` each mirrored it into a plain `@State` seeded once
in `init()`, and `ModelSelectionStore`'s bare `UserDefaults.set` notified nobody. The Settings cost pane
read its own `@State` and updated; the main window did not. Because `startProcessing` passes that same
stale value, **a run launched from the main window called the previous model** — real money at the wrong
price, with the estimate faithfully describing the stale run.

**The fix.** `ModelSelectionStore` is now a `@MainActor ObservableObject`; all three views read it live.
`@MainActor` (not `@unchecked Sendable`) is deliberate: the cached ids are exactly the state a stray
background write would corrupt into a wrong paid model, so the compiler enforces it.

**Watch for:** anything that writes `selectedModelId_<provider>` with `UserDefaults.set` directly instead
of `ModelSelectionStore.saveModel(_:for:)` re-introduces the staleness for every observer.

---

## ✅ FIXED (W23.m5 + W23.h5-fu): Process Files reported tags as applied after discarding the write failure

**Found 2026-07-29** (owner-commissioned Codex full-suite review, confirmed finding). **Fixed
2026-07-31** — `ff792a9` + `088df94` + `4cf1fb7` + the trackers commit. The Process Files sibling of
W3.cap-r1 (below): the same `_ = try? MacOSTagger.applyTags(…)` on the ordinary OCR pipeline instead of
the live streaming one.

**What was wrong.** Every tag write in Process Files was its own `try?`. It swallowed each xattr /
coordination / verification / permission / filesystem failure, and the run then populated
`jobs[].appliedTags` and reported the file as processed as though the output were tagged. The PDF is
byte-perfect either way — what an untagged output costs is FINDABILITY: the Reader's tag-driven triage
silently omits it, so the operator learns about it the day a tag search comes back short. Folded in:
**W23.h5-fu**, the same silence one layer down — `PDFGenerator.generate` reports whether the image page
holds the real scan or the deliberate placeholder, and all five Process Files call sites were discarding
that too.

**The fix.** One seam, `OCRProcessor.writeOutputTags`, serves all 13 sites (`+Tagging` ×6, `+OCR` ×2,
`+Pipeline` ×1 — the 9 filed — plus 4 in `+ReviewFlows` that are the same defect; leaving those unrouted
would have made the new summary trustworthy and wrong). It returns whether the write landed. The run
records the verdict, and the "Done. N succeeded, M failed." status line + the batch log name the
affected files. Deliberately W3.cap-r1's mechanism, not a second warning channel.

Four decisions worth keeping:

- **The file still counts as processed** — the owner's 2026-07-18 decision, unchanged. Tags are
  re-derivable; withholding "done" over metadata would help nobody. Only the silence was the bug.
- **The record is keyed by the INPUT file, not the output.** `CollectionSegmenter.organizeOutput` MOVES
  *and RENUMBERS* every output (`00003 Box 12.pdf`) as the last step of a run, so an output name or URL
  recorded during tagging names a file that no longer exists by the time the summary is written. The
  input name never changes and is what the operator recognizes.
- **Self-healing, but only on a real attempt.** A later successful re-write (rotation regen, review
  retry) CLEARS the entry. A step that attempts no write does not: a post-run `retryOne` regenerates the
  PDF and — outside copy-source — does not re-tag it, so treating "no attempt" as success would have
  silently cleared a warning about a file that is still untagged.
- **Merge keeps it honest.** One merged PDF now covers every page, so its successful tag write resolves
  each page's earlier failure; the placeholder warning stays against the photo whose page is still a
  placeholder inside the merged PDF — the page an operator would actually re-shoot.

**Guard:** `scripts/test-processfiles-tagwarn.sh` (`ProcessFilesTagWarningTestDriver`,
`PROCESSFILES_TAGWARN_TEST=1`) — 79 $0 checks, no OCR/network/GUI, synthetic files in a temp dir.
`chflags uchg` makes the tagger genuinely fail; a real production site (`applyBoxFolderLabelTags`) proves
the WIRING and that fixing the permission clears the warning; merge, the summary copy and the h5-fu
placeholder path are all driven end to end. Proven non-vacuous by six neuters, each turning exactly the
expected checks RED.

**The colour half — also FIXED now (W23.m5-fu, 2026-07-31, `5342d2b` + the trackers commit).** The two
read-append-rewrite sites (`applyCaptureQualityTags`, `exportOriginalImages`) re-applied tags as a raw
`[String]`, so `MacOSTagger`'s Red/Purple DETECTION ran over names read back off disk: a document whose
**subject** tag is literally "Red" was stamped with Finder label 6 — and the Reader reads a red label as
a **box** photo. Both sites now pass the colour explicitly, derived from the page's classification by
`OCRProcessor.authoritativeColor(for:)` (`forJob:` coalesces `job.classification ??
job.result?.classification`, since a failed re-OCR can blank the result's copy). That is the same rule
`TagGenerator`, `applyBoxFolderLabelTags`, `performDocumentMerging` and the review flows already follow,
so a rewrite reproduces the label the FRESH write intended. Note the fix is **not** simply
`colorIsAuthoritative: true`: with no colour to pass, that strips the label off every genuine box/folder
PDF — a dedicated neuter holds that line. Copy-source mode was never affected (verbatim names, label
untouched). 12 of the guard checks cover this, driving both real production functions.

**Quality persistence + the phone boundary — FIXED (W19.q5, 2026-08-27; the commit whose
subject begins `feat(processor): preserve Quality`).** A normal re-tag used to treat `Q1`–`Q3` as unknown
subjects and discard them, the Live Capture post-pass wrote its old `P7`–`P10` spellings back to Finder,
and a merge replaced its first component with generated `appliedTags` that might not include a user-set
Quality. The audited `MacOSTagger` transform now treats every shared rating spelling as one explicit
intent: an incoming `Q` wins, a phone `P8`–`P10` maps to its one canonical `Q`, and `P7` explicitly
clears the facet. With no incoming rating it preserves the current rating while re-tagging, canonicalizing
any retained `P` on that ordinary write; it never invents a rating from OCR. No-tagging is a true
no-op at the phone boundary. Copy-source still
copies existing source tags verbatim, but its phone-boundary input is canonicalized before that pass-through
can create a fresh P. The merge reads the
retired first component's actual rating before it replaces it when generated tags supplied none, and the
image mirror carries the PDF's `Q` unchanged. `test-processfiles-tagwarn.sh` drives fresh re-tag, P7 clear,
merge and image-mirror cases on disk; `test-recovery.sh` drives the real phone `P10` → staged-`Q3`
path. Live Capture canonicalizes the same boundary before individual PDFs, image mirrors and a merged PDF,
including verbatim-mode writes; P7 clears there too, while No tagging bypasses that boundary completely.
Current retained records require and retain their explicit tagging mode and unread policy, so a rotation
replay cannot adopt a later Settings choice; older retained-policy records are unsupported. There is no bulk
corpus rewrite: P remains an accepted phone input until W19.q7 changes the wire field.

**The reclassification half — also FIXED now (W23.m5-fu2, 2026-07-31, `7a0043c` + the trackers commit).**
The sentence above says the review flows "already follow" the classification rule. They did — but only by
*appending* "Red"/"Purple" to the array and letting detection find it, and they cleared the way first with
`removeAll { $0 == "Red" || $0 == "Purple" || $0 == "Box" || $0 == "Folder" }`. Matching the literal word
is what made the label look right: a document whose genuine **subject** is one of those words lost it from
the file and from `jobs[].appliedTags` the moment anyone reclassified the page, and it never came back —
tag LOSS, the mirror image of the misfile above. All **three** sites (`applyReviewEdits`,
`updateClassification`, `applyDocumentReviewEdits`) now go through `OCRProcessor.reclassifiedTags(_:from:to:)`,
which takes back exactly one occurrence of each word the app added for the OLD classification
(`structureTag(for:)` + `authoritativeColor(for:)`) and adds one of each for the new one, in the fresh
`GeneratedTags` shape. The two halves are ONE fix: once a subject "Red" can survive the strip, raw-array
detection would promote it straight back to the box label, so every site now also passes
`colorIsAuthoritative: true` with the classification's colour. The OLD classification is read through
`taggedClassification(of:)`, which coalesces `job.classification ?? job.result?.classification` — reading
one field alone would strand the app's own "Box"/"Red" on a page that is no longer a box. Copy-source mode
keeps its verbatim pass-through and untouched label. 27 of the guard checks cover this, §8b driving all
three real production functions against real files on disk; three dedicated neuters hold each half.

---

## ✅ FIXED (W3.cap-r1): Live Capture invented Finder colours, and threw away failed tag writes

**Found 2026-07-18** (adversarial Capture review; the colour half is the never-applied other side of #5
below). **Premise re-confirmed by symbol on 2026-07-31** before a line changed — all three
`_ = try? MacOSTagger.applyTags(...)` sites were still there in `writeSegmentFiles`, at 666/673/699 (the
recorded 640/647/673 had drifted with W16.cfg\*).

**The defect — two of them, on the same three lines.**

1. **The colour was inferred from the text.** The live path passed a raw `[String]`, and that overload
   *detects* "Red"/"Purple" anywhere in the array. So a document whose subject genuinely is "Red" (the Red
   Scare, the Red Cross) was promoted to Finder label 6 — and lost "Red" from its tag list, since detection
   also removes it. Downstream the Reader reads a red label as a **box** photo, so an ordinary document was
   mis-parsed as archival structure. #5's fix (take the colour from the classification, not the words) was
   applied to the batch merge path in 2026-07 and never to the live streaming path.
2. **The write result was discarded.** `try?` swallowed every xattr / coordination / identity / permission
   failure, and the segment was then staged, finalized and reported as tagged. A PDF could land byte-perfect,
   count as **filed**, have its **source photo trashed**, and carry no subject/date/priority tags at all —
   invisible to every tag-driven search in the Reader. This was the only way the "filed" verdict could be
   silently wrong.

**The fix.** One seam, `LiveCaptureProcessor.tagStagedArtifact`, used by all three sites:

- The app assigns exactly one colour (Red = box, Purple = folder, none = document), so `jsonTags.colorTag`
  is passed explicitly and `colorIsAuthoritative` is **fixed `true`** in the helper rather than left to the
  caller — this seam no longer has a code path that can guess.
- The helper returns whether the write landed; a refusal is recorded on the new
  `StagedSegment.untaggedOutputs` and `finalize` warns, naming how many filed files carry no tags and what
  to do. Optional field ⇒ a legacy staging manifest decodes and behaves exactly as before.
- **The file still counts as filed** — the owner's 2026-07-18 decision. Bytes are safe and retagging is
  possible, so withholding "filed" would strand the source photo over recoverable metadata. Only the silence
  was a bug. (Contrast W23.h5, where the *image* is missing and the photo genuinely must be kept.)
- Merge removes its about-to-be-deleted constituent PDFs from the record before tagging the merged output,
  so the warning never counts an artifact that no longer exists.

**Both had to ship together** (and did): (1) changes *which* overload is called and (2) changes *whether the
result is discarded*, on the same three lines — landing them apart would have silently reverted half of the
first.

**Verification** (Tier-2; scratch only — synthetic files in a temp dir, never a corpus): `test-recovery.sh`
Test 12 adds 11 checks — a subject tag of "Red" stays a searchable tag and takes no label; a box segment
still gets label 6 with "Red" exactly once; a successful staging records nothing and its tags are read back
off disk; a `chflags uchg` artifact makes the tagger genuinely fail and that verdict is both returned and
threaded onto the segment; and the merge path tags the merged file with no stale record. 56/56 ALL PASS.
Non-vacuity proven by neutering each half: colour → 1 RED, discarded result → 2 RED, all others GREEN.
`test-merge-safety.sh` and `test-output-file-safety.sh` re-run clean.

**Not widened (deliberate).** The **nine** equivalent `try?` sites in Process Files
(`OCRProcessor+{Tagging,OCR,Pipeline}`) are out of scope here and stay queued as **W23.m5**, which reuses
this mechanism rather than inventing a second one; **W23.h5-fu** (Process Files can't read the placeholder
signal either) folds into m5 for the same reason.

---

## ✅ FIXED (W23.m8): the phone's crash-durable session save couldn't tell you it hadn't saved

**Found 2026-07-29** (owner-commissioned Codex full-suite review; premise re-confirmed by symbol on
2026-07-30 against `996a58b` before a line was changed — `SessionStore.save` still returned `Unit`).

**The defect.** `ManifestFileWriter.replace` already computed whether the new session snapshot reached
disk, but `SessionStore.save` returned `Unit`: it discarded that Boolean and wrapped everything in a
blanket `catch { }`. Nothing above it could tell a published snapshot from a lost one.

The cost lands on the NEXT launch, not the failed write. `CaptureViewModel`'s recovery sweep re-adopts
every `img_*` on disk the restored session doesn't mention, into a fresh **default Document group** —
correct when `session.json` merely lagged, a fabrication when the last publish never landed. Against a
stale manifest those files were tracked; what died with the write is the record of *what they are*. So a
page shot into a classified box/folder segment came back as an untagged Document page and the auto-retry
loop sent it to the Mac, which filed it into the archive under a classification nobody chose. Group
boundaries, priority/date/tags, replacement provenance and segment-completion state went the same way,
and pages the stale manifest *did* list came back with stale metadata.

**The fix.** Three layers, because knowing in-process isn't enough when the loss lands after a restart:

1. **Propagate.** `save` returns whether *this* snapshot is durable, while keeping the no-crash contract
   the blanket catch existed for — a persistence hiccup still can't take down the capture flow, it just
   can't be mistaken for success. The one writer coroutine reports a change of state to
   `CaptureViewModel.sessionNotSaved` (its own UI line, not the status line, which the next capture
   overwrites); conflation makes it self-correcting, since a later snapshot that lands clears it.
2. **Make staleness durable.** A `session.stale` flag is created **before** a snapshot is written and
   removed only once that write is confirmed — set-before-write, not set-on-failure, because a kill
   *during* a publish leaves the same older manifest and must read the same way. `manifestIsStale()` is
   exposed separately from `Restored` because the worst case is a **first-ever** publish failure, where
   `load()` returns null and the photos on disk are exactly the ones the sweep would adopt as untracked.
   `clear()` drops the flag with the manifest. The view model reads it as the first statement of `init` —
   `resumeUploads()` reaches `setState` → `persist()`, and the first successful save clears it.
3. **Don't let the adoption lie.** Against a stale manifest the sweep adopts pages `needsReview = true`
   (persisted). They are **kept** — an archival photo can't be re-taken, so they stay visible, counted as
   un-sent in the heartbeat, and delete-confirmed — but `isSendable` refuses them at `enqueueUpload`, the
   single choke point every send passes through. A "Review" action opens the ordinary tag sheet on that
   segment; applying (or deliberately skipping) tags is the only thing that releases them.

Also fixed en route: `File.createTempFile` sat **outside** `ManifestFileWriter.replace`'s `try`, so an
unwritable parent threw straight past the function whose Boolean is now the caller's only evidence.

**Not widened (deliberate).** `finalizeSegment` now rotates the current group only when the segment it
finalized *is* the current one — every pre-existing caller does, but a held recovery segment is reviewed
while a restored in-progress segment is still open. The flag is durable against process death (the stated
failure), not against power loss: no unfsynced directory entry is.

**Verification.** 24 headless JVM checks over real scratch temp dirs (no device, no emulator, no corpus),
all five mechanisms proven non-vacuous by neutering — pre-fix `save` always reporting success → 11 RED;
adoption ignoring staleness → 3 RED; set-on-failure instead of set-before-write → 1 RED; `clear()` keeping
the flag → 2 RED; `createTempFile` back outside the `try` → 1 RED. 56/56 pass restored. Not covered: the
Compose banner and the view model's own wiring lines — the app has no instrumentation-test target
(`androidTest`), so those are compiler- and inspection-level only.

`ArchiveCapture/.../data/{SessionStore,ManifestFileWriter}.kt`, `capture/{CaptureModels,CaptureViewModel}.kt`,
`ui/CaptureScreen.kt`.

---

## ✅ FIXED (W23.m7): the Mac tag card acted on a Save/Skip it had not proved was durable

**Found 2026-07-29** (owner-commissioned Codex full-suite review; premise re-confirmed by symbol on
2026-07-30 against `5cc8616` before a line was changed — both halves were live).

**The defect.** `CaptureSession.applyMacTags` / `skipMacTags` did two things in the wrong order and
checked neither:

1. `_ = writeManifest()` — the `Bool` was discarded at both sites, so a failed manifest replacement was
   indistinguishable from a successful one. The card vanishes the instant `resolvedGroupIds` gains the
   group (it is *derived* from that set), so the operator saw a completed action, and the UI had no
   failure channel at all.
2. `liveProcessor.segmentResolved(groupId:)` was called **before** the write. That is the step that bakes
   `macTags` into staged output.

Together: a failed write plus a crash reloads the **old unresolved** state. Stage-for-later loses the
operator's decision outright; in live mode the artifact has already been produced from tags the recovered
state doesn't have, and the segment is re-prompted — recovered state inconsistent with output on disk.

**FIXED.** Both functions now stage the decision, write, and on failure restore `macTags` (nil restores
"never tagged") and `resolvedGroupIds`, set the status message and return `false`. `writeManifest` writes
`.atomic`, so a failed write leaves the previous manifest byte-intact — which is exactly why rolling memory
back restores agreement with disk rather than papering over a divergence. The card therefore stays up with
everything typed still in it (that lives in the view's own `@State`, not in `macTags`), and the operator can
retry. Live processing is notified through one new choke point, `notifySegmentResolved`, reached only after
the write succeeds. One shared string, `CaptureSession.tagDecisionNotDurableMessage`, drives both the
session status line and a new inline red row in `SegmentTagCard`, so the two can't drift.

Two smaller things fell out of it: the headless auto-skip loop (`headlessResolvePendingTags`) would have
spun forever on a card that now rolls its own resolve back, so it stops on a refusal (the finalize autopilot
re-enters it, so a transient failure is still retried); and `LiveCaptureTestDriver` now logs a refused
resolve instead of letting the E2E time out later with an unexplained "staged 0/N".

**Verified** (Tier-2, scratch only — `ARCHIVEPROC_TEST_BACKUP_ROOT` + synthetic pages; no corpus, no OCR,
no network, no GUI, $0): 18 new checks in `ManifestPersistenceTestDriver` covering refusal, roll-back, the
card staying up, the operator message, and a fresh `CaptureSession()` restore agreeing with memory after
*both* the refusal and the retry — plus the ordering, asserted by a notification hook that reads the real
`manifest.json` from inside the notification. Non-vacuous per half: restoring the old call order → 5 RED,
swallowing the write failure → 10 RED, both neuters reverted. 86/86 ALL PASS, plus `test-recovery.sh`
45/45, `test-network-session.sh` 7/7, `test-filerelay.sh` 10/10. Build clean, 0 new warnings.

**Not widened (deliberate).** `removePhoto`, `removePhotoIfSafe`, `clear` and `clearFiled` still discard
their `writeManifest` result. They trash photos, and restore skips any manifest entry whose file is absent,
so a lost write there degrades to a stale-but-harmless manifest rather than a decision the app already acted
on. If that ever needs closing it is a separate item, not a re-open of this one.

`Capture/CaptureSession.swift`, `Views/LiveCaptureView.swift`,
`Capture/{ManifestPersistenceTestDriver,LiveCaptureTestDriver}.swift`.

---

## ✅ FIXED (W23.m1): re-pairing left an upload owned by the OLD Mac, and the phone deleted its copy on that Mac's ack

**Found 2026-07-29** (owner-commissioned Codex full-suite review; premise re-confirmed by symbol on
2026-07-30 against `b31aa03` before a line was changed).

**The defect.** Android `CaptureViewModel` had no notion of *which* Mac owned a send:
1. `enqueueUpload` captures `val c = client` for the life of the coroutine (3 POST attempts).
2. `disconnect()` cleared `prefs` / `endpoint` / `client` but cancelled **no** `uploadJobs`, cancelled no
   `segmentJobs`, and invalidated **no** `inFlightUploads` entry.
3. So after re-pairing, `resumeUploads()` → `enqueueUpload(item)` hit `inFlightUploads.add(item.id)` →
   `false` (the id was still held by the dead send) and **returned immediately: the newly paired Mac was
   never sent the page**, while the orphaned coroutine kept uploading through its captured old client.
4. If that old Mac was still reachable and acknowledged, the handler ran unconditionally: `UPLOADED`,
   `sentCount += 1`, and `delay(650); removeConfirmed(item)` → **the phone's copy was deleted** although the
   Mac now paired had never received it. Not classified as data loss (the old Mac does hold a durable copy)
   but a silent destination mismatch that contradicts the Capture requirement that disconnected items
   re-upload to the **new** endpoint.
5. The same hole existed for the segment-completion signal: `trySendSegmentComplete` dropped a group from
   `endedSegments` on any `ok`, so an old-Mac ack meant the new Mac never heard about the document at all.

**The fix — endpoint identity is now generational.** New pure, JVM-testable layer in `CaptureModels.kt`:
- `PairingGeneration` — a monotonic token rotated by every pair **and** unpair (`retirePreviousPairing()`,
  called from `disconnect()`, `connect()`'s success branch and `connectCloud()`), which also cancels every
  outstanding upload/segment job. Cancelling is best-effort by nature (a blocking POST already on the wire
  runs to completion), which is exactly why the *generation check*, not the cancel, is what makes this safe.
- `OutstandingSends<K>` — the in-flight guard, now generation-stamped. `claim` still refuses a second send
  for a key **even across a re-pair**, preserving W23.h4's invariant that only one coroutine ever holds a
  photo file (the delete path's cancel-and-join depends on it). `release` frees only the caller's own claim,
  so a retired send unwinding can never free the live endpoint's guard.
- `sendAck(ok, tokenIsCurrent)` — the ownership rule in ONE place, shared by both kinds of send so they
  cannot drift. Staleness deliberately outranks success: an `ok` from a Mac we are no longer paired with is
  `REQUEUE_STALE`, never `CONFIRM` — because `CONFIRM` is what marks a page uploaded and therefore
  deletable. The upload handler bails out before `setState(UPLOADED)` (so a crash in that window can't
  persist a false confirmation either), and its `finally` returns the page to the queue via
  `markSendableAgain` (`PENDING`, resend marker cleared, heartbeat re-counted) for the endpoint paired now.

**No behaviour change when nothing re-pairs:** with the generation constant, `claim`/`release` are exactly
the old `add`/`remove` and `sendAck` always yields the old CONFIRM/RETRY decision.

**Regression:** `CapturePairingGenerationTest`, 8 cases (scratch only — one JVM temp file; the tests cannot
see a corpus, a session, a Mac or the gallery), including a coroutine driver that runs the shipped objects
through the real misroute sequence (upload on the wire → re-pair → old Mac acks) and asserts the phone copy
survives, the page returns to `PENDING`, and the **new** Mac then receives it. Proven **non-vacuous** by
neutering: dropping the staleness arm of `sendAck` turns 4 of the 8 RED, the driver test among them.
Android suite **33/33** (was 25); `assembleDebug` + `testDebugUnitTest` BUILD SUCCESSFUL, **0 warnings**.
No device or emulator was needed or used.

**Two things deliberately left alone.** (a) The **iOS twin is PARKED** per §Project focus — verified still
present by symbol (`ArchiveCaptureiOS/.../Capture/CaptureViewModel.swift`: `disconnect()` nils
`endpoint`/`client` without touching the `inFlightUploads` set or any upload task), recorded here rather
than fixed. (b) The status **heartbeat** (`sendStatusReport` → conflated `statusChannel`) can still deliver
one queued count to the Mac we just unpaired from; it is display-only on the Mac, carries no page bytes and
licenses no deletion, so it is outside this fix. **Inherent, not a bug:** re-pairing part-way through a
document leaves the already-confirmed pages on the old Mac and sends the rest to the new one — the phone's
guarantee is that no page is destroyed without the Mac that is *currently* paired confirming it, and the
old Mac's still-open group is closed by its own "Finish session" backstop.

---

## ✅ FIXED (W23.h5): a placeholder-only PDF counted as archived, and finalize then retired the source photo

**Found 2026-07-29** (owner-commissioned Codex full-suite review; premise re-confirmed verbatim by symbol
before fixing, then measured again on 2026-07-30 against `ee9cadf`).

**The defect.** When `PDFGenerator.makeImagePage` can't decode/embed a source image, `generate` inserts
`makePlaceholderImagePage(…)` and **returns normally**. That substitution is deliberate and stays — it keeps
the 2-page archival contract and `PDFTextExtractor`'s `pageCount >= 2` heuristic valid. The bug was that it
was **indistinguishable from success**: `generate` returned `Void`, so the only signal any caller had was
"did it throw / does the file exist". Live Capture's `writeSegmentFiles` checked exactly that
(`fm.fileExists(atPath: stagedPDF.path)`), so a scan-less PDF was recorded in `pdfURLs`, counted toward
`pagesComplete`, reached the destination, landed in `executePlans`' `filedGroupIds` — and `finalize` then
put the corresponding raw capture in the Trash via `session.clearFiled`. Net effect: an apparently filed
archival document containing **no image**, with the only copy of that image retired. Output-content
validity was never established anywhere in the chain.

**The fix** (per the owner's constraint: keep the placeholder, still count the file as filed, never retire
the source — the same "warn, don't withhold-filing" shape as W3.cap-r1's `tagsApplied`):
- `PDFGenerator.generate` now returns `ImagePageOutcome` (`.embedded` / `.placeholder`), `@discardableResult`
  so the five Process Files call sites are untouched (their `try?` swallowing is the separate item W23.m5).
- `writeSegmentFiles` records the affected **source URLs** on the new `StagedSegment.placeholderSources`.
  A `nil` outcome — `generate` threw yet still left a file on disk — is treated as placeholder: unknown
  resolves toward keeping the photo.
- `finalize` runs its deletion set through the new pure `LiveCaptureProcessor.sourcesSafeToRetire(...)`,
  which AND-s the existing filed gate with the new one. Withholding is **per page**: a sibling page that
  embedded fine is still retired, so one unreadable page doesn't strand a whole session's photos.
- Operator surface (it was silent before): new `SegmentStatus.Phase.succeededPlaceholderImage`
  ("Filed (scan MISSING)") → new amber `ItemState.succeededPlaceholderImage` with a row explanation and
  retry/rotate actions, plus a finalize-summary warning naming how many photos were kept and why.
- Backward compatible: `placeholderSources` is optional, so a legacy staging manifest behaves exactly as
  before. The rotation-review regeneration path replaces the whole `StagedSegment`, so the flag self-heals
  when a retry succeeds and re-arms if it fails. ⚠️ The *record* always self-healed there; the **row
  describing it did not** until `W3.cap-r3-fu6` (`61fc680`, 2026-08-04) sent both writers through one
  `labelStagedRecord`. Before that, a regeneration could leave a `.failed` label on a record that now files
  (the sheet then warning about it, inviting a retry that re-buys the OCR) or a success label on one that
  now holds nothing.

**Regression:** `LiveCaptureRecoveryTestDriver` Tests 9–11 via `scripts/test-recovery.sh` ($0, no OCR,
no network, no GUI, synthetic temp files) — detection, the pure retirement gate, and the wiring between
them end-to-end. **45/45 ALL PASS.** Both halves were proven **non-vacuous** by neutering them in turn:
disabling the gate turns 5 cases RED, disabling the detection turns 2 RED (the no-placeholder / unfiled /
legacy regression cases correctly stay GREEN in both runs). `test-merge-safety.sh` and
`test-output-file-safety.sh` also re-run clean.

---

## ✅ FIXED (W23.h4): Android deleted an un-uploaded capture with no confirmation and no upload-job cancel

**Found 2026-07-29** (owner-commissioned Codex full-suite review; premise re-confirmed by symbol before
fixing). The Android twin of the iOS bug closed on 2026-07-09 (further down this file) — the iOS fix was
never ported, so `ArchiveCapture` still had no guard at all. `CaptureViewModel.deleteItem(id)` ran
`runCatching { items[i].file.delete() }; items.removeAt(i)` unconditionally, on the third tap of the
thumbnail select → arm → delete gesture. Two independent losses:
1. **No confirmation.** A `PENDING`/`UPLOADING`/`FAILED` page exists ONLY on the phone, and an archival
   photo can't be re-taken — one mistimed tap destroyed it silently.
2. **No upload-job cancel.** The delete never touched `uploadJobs`. The upload coroutine opens the file
   itself (`item.file.readBytes()` inside its own `withContext(Dispatchers.IO)`), so a delete that won that
   race left `readBytes()` returning null → `ok=false` → **no Mac copy could ever exist**, and the `FAILED`
   state write landed on an item already removed from the model, so nothing surfaced the loss.

**Fixed** in three parts, with the policy pulled into pure `CaptureModels.kt` seams so it is provable on the
JVM with no device:
- **Confirm.** `requiresDeleteConfirmation(item)` — true unless the Mac has confirmed the bytes AND no
  metadata resend is outstanding. Deliberately the SAME predicate `pendingReportCount` uses (it now
  delegates to it), so "the Mac still needs this" and "losing this loses it forever" cannot drift apart.
  An already-uploaded page still deletes on the third tap; anything else opens an `AlertDialog`.
- **Cancel-and-join.** `retireCapture(uploadJob, file, retire)` `cancelAndJoin`s the item's upload BEFORE
  the bytes go away, so the upload either completed or unwound while the file was still readable. The
  `uploadJobs[id]` read and the `cancel()` happen in one main-thread turn (`viewModelScope` is
  `Main.immediate`), so nothing can enqueue a replacement job into the gap.
- **Recoverable retire.** The dialog's primary action is "Save to gallery & delete": the photo is copied to
  Pictures/Archive Capture via the existing `PhoneBackup`, and the local file is removed ONLY once that copy
  is confirmed written. A failed copy returns `KEPT_RETIRE_FAILED`, **keeps the photo**, and re-queues it
  (its upload had been cancelled). "Delete permanently" remains available for a genuinely bad shot.

Regression coverage: `CaptureDeletePolicyTest` (8 JVM cases, scratch temp files only). The cancel-and-join
case is proven non-vacuous — swapping `cancelAndJoin()` for a bare `cancel()` turns it RED. Full Android
unit suite 25/25; `assembleDebug` + `testDebugUnitTest` clean, 0 warnings.
(`capture/{CaptureModels,CaptureViewModel}.kt`, `ui/CaptureScreen.kt`.)

**Not covered here:** W23.m1 (re-pairing leaves an upload owned by the OLD Mac) is a separate finding on the
same file and stays open.

---

## ✅ FIXED (W23.h1): launch-time `pruneEmptySessions` hard-deleted the relay dir + any unrecognized content under the visible backup root

**Found 2026-07-29** (owner-commissioned Codex full-suite review; re-verified against `62a10d1` — worse than
reported). `CaptureSession.pruneEmptySessions(under:)`, called unconditionally from `init()` **before**
recovery, treated **every** child directory of `~/Pictures/Archive Processor Live Capture/` as a spent
session and `try? fm.removeItem(at: folder)`-**recursively hard-deleted** any that lacked a top-level `.jpg`
or a `_processed/{pdf,jpg,jpeg,json}` output. Three concrete data-loss paths:
1. **The relay object store is a direct child of the pruned root** (`_relay/<token>/…`, `relayDir(token:)`),
   with no top-level `.jpg` and no `_processed` → it read as "empty" and **every pending relay object was
   hard-deleted on the next launch** — exactly the crash-recovery case the Drive/USB relay exists to survive.
2. **HEIC-/`.jpeg`-only sessions** were deleted (the top-level check accepted only `jpg`, though `_processed`
   accepted `jpeg`), losing recoverable source photos.
3. It **bypassed the Recovery Core Directive's `trashOrRemove`** (Finder → Put Back), so a wrong call was
   unrecoverable.

**Fixed** — prune is now conservative *by construction* (deletes strictly less, never more):
`isReclaimableEmptySession(_:relayBases:fm:)` reclaims a folder only when it is (a) POSITIVELY a session (the
launch-created ISO-8601 session-id name shape, `isSessionIdName`), (b) NOT the relay store (default `_relay`
or a `LIVECAPTURE_RELAYDIR`/`liveRelayDir` override), (c) free of any recoverable capture data (no top-level
source image in {jpg,jpeg,png,tif,tiff,heic,heif}, no `_processed/` output), and (d) free of any
**unrecognized** content (any file that isn't spent session metadata → the folder is KEPT). Every reclaim now
routes through `trashOrRemove` (the Trash, never `removeItem`). Regression coverage:
`LiveCaptureRecoveryTestDriver` Test 8 (`scripts/test-recovery.sh`, $0/no-OCR/no-GUI) asserts the relay dir +
its pending object, HEIC-/`.jpeg`-/`.jpg`-only sessions, `_processed`-output sessions, unknown-content
folders and non-session (operator) folders all survive, while a spent manifest-only session and a
genuinely-empty session are reclaimed **to the Trash**.

---

## ⚠️ OPEN (routing) / ✅ FIXED (silence): a mixed drop containing a multi-page PDF discards every non-PDF file

**Found the hard way 2026-07-29** — the owner dropped two `.jpg` files alongside one 3-page PDF. The PDF
processed correctly; **both images produced no output at all** and the UI reported **"No OCR text"**, which
blames the model for something it never saw.

**Root cause (confirmed by code trace, a headless repro, and the app's own `processingHistory`).** The
multi-page re-OCR route is chosen **per RUN, not per file**:
`OCRProcessor+Pipeline.swift:1607` — `let autoReOCR = !preOCRedInput && files.contains(where:
PDFToImageConverter.isMultiPagePDF)` — and line 1634 then passes the **unfiltered** `files` array to
`performMultiPagePDFReOCR`. So ONE multi-page PDF anywhere in a drop sends every sibling into a PDF-only
transform. There, `PDFToImageConverter.renderAllPages` opens with `PDFDocument(url:)`, which is nil for a
JPEG, and the guard at `OCRProcessor+OCR.swift:250` marks the job `.failed` and `continue`s — **before** any
output is written. Evidence it was the route and nothing about the files: the same grayscale, em-dash-named
JPEG succeeded **alone** in the same output folder with the same backend; the failing run is recorded as
`modeLabel:"Re-OCR PDF", fileCount:3, succeeded:1, failed:2`; and the 13:25 output carries **no** tag xattr
(the re-OCR route skips tagging) while the later single-file outputs do. Ruled out: grayscale, the em dash,
image decode, write permissions, `PDFError.writeFailed`, and the `claude` CLI (it read the grayscale file
perfectly). Mixed drops are reachable and unwarned — `Views/OCRView.swift:948-951` accepts PDFs and images
into one `droppedFiles` array, and `droppedHasMultiPagePDF` only greys out the tagging controls.

**The design intended this but its safety net never worked.** `Pipeline.swift:1604-1606` says "a non-PDF
sibling in the same run fails render loudly." It did not: the guard left `jobs[index].result` nil, and
`OCRView+FileRowView.swift:99` mapped `.failed` + nil `errorMessage` to `.ocrEmpty` — literally **"No OCR
text"**. The true reason existed only as a `statusMessage` overwritten by the next iteration, plus an
`os_log` that returns nothing via `log show`. The `.txt` batch log would have said so, but `writeLogFile`
is **opt-in and defaults to OFF** (`DefaultsKeys.writeLogFile`).

**FIXED (this commit) — the silence, not the routing.** A skipped sibling now carries a precise reason
(`errorCode: "not_a_pdf_in_reocr_run"`) naming the multi-page-PDF routing and telling the operator to re-run
images separately; the two PDF-write failure sites likewise set `"pdf_write_failed"` instead of nothing; the
row label now uses the pre-existing-but-unused `FailureKind.noOutput` ("No output produced") so `.ocrEmpty`
means only what it says; and the always-visible completion line appends an explicit ⚠️ count of non-PDF files
not processed. Pinned by 9 checks in `MultiPageReOCRTestDriver` §4 — **proven non-vacuous** (disabling the
fix fails exactly the three reason-related checks and no others).

**STILL OPEN — the routing itself.** A mixed drop still processes only the PDFs. The real fix is per-file
dispatch (partition `files` into the multi-page PDFs and the rest, run both in one pass), which requires
decoupling `performMultiPagePDFReOCR`'s positional index from `jobs` (it relies on `files.enumerated()`
matching `jobs = files.map { OCRJob(sourceURL: $0) }`, `Pipeline.swift:1597`) and inverting the assertion at
`MultiPageReOCRTestDriver.swift:107-108`, which currently pins the whole-run behaviour. **It also needs an
owner decision:** tagging is disabled whenever a multi-page PDF is present (`OCRView.swift:30`, `:375`), so a
partitioned run has two tagging semantics — either re-enable the picker as "applies to images only", or force
`.none` for the image subset and say so. Queued in `SUITE_TODO.md` as `W22.mixed-batch`.

**Workaround until then:** process multi-page PDFs in their own run. You will now be told plainly when a run
skips images instead of losing them silently.

---

## CLOSED (owner decision 2026-07-18): one recoverable filesystem-transaction service + operator recovery UI

**Do NOT build the shared engine or the Recovery screen. Do NOT re-promote this.**

### ⚠️ The original text below is FICTION in one important respect — read this first
It is written in the **past tense about machinery that was never built.** It claims Live Capture finalization
"freezes exact content hashes" and commits a "receipt." Verified 2026-07-18: **`grep -rn "sha256|SHA256|CryptoKit"`
across `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/` returns ZERO hits**, and there is **no receipt
anywhere in the finalize path.** Anyone reading the original paragraph would believe Live Capture hashes content
and writes receipts. It does not. The paragraph is retained below only as the historical proposal.

### Why it is closed
1. **The guarantees it wants already exist by other means.** The finalize deletion gate keys off
   `outcome.filedGroupIds` — an **on-disk fact**, not a promise (`LiveCaptureProcessor.swift:983-986`, with the
   Recovery Core Directive comment directly above it); every deletion is a Trash move (`trashOrRemove`); staging
   is co-located in the **visible** backup folder; `OutputFileSafety.relocateArtifactSet` already **is** a real
   copy-verify-install-then-delete transaction; and `PendingBatch` v1 already **is** a versioned, SHA-256
   fingerprinted, fail-closed journal.
2. **Its stated blocker shipped.** "the still-unfixed ArchiveCore metadata-read contract" is satisfied —
   `ArchiveCore/Tags/TagReading.swift` provides the tri-state `TagReadResult` (confirmed-empty vs unreadable),
   and `readTags` throws rather than coercing a read failure to `[]`.
3. **Consolidation would raise risk, not lower it.** Replacing three understood, separately-regression-tested
   mechanisms with one unproven abstraction — in the subsystem that already caused a real data-loss incident
   (2026-07-07) — buys no additional guarantee. The verification plan below even concedes it needs contract tests
   proving each path's *existing* guarantees survive: the same guarantees, differently spelled.
4. **Finder is already the recovery surface**, via the Backup Folder button (`LiveCaptureView.swift:139-148`), and
   it works in the one case a bundled screen cannot — when the app won't launch. **`Abandon` would add a
   destructive affordance to a subsystem whose entire design is that no destructive affordance exists.**
5. **A queued ten-line fix closes the actual hole.** `W3.cap-r6` — `finalize()`'s `allFiled` branch trashes the
   whole `stagingDir` after the `executePlans` await, so a straggler finalizing *during* that await loses its
   output. That is the one genuine recoverability gap this entry gestures at.

### What WAS promoted instead (see `SUITE_TODO.md` §"Known-issues work — Wave 17")
- **`W17.stg1`** — version + fingerprint + fail-closed the staging manifest. `StagingManifest`
  (`LiveCaptureProcessor.swift:709-719`) is the only one of the three durable-state records that is unversioned
  and unverified, and `loadStagingManifest` (:190-242) **fails silent-open**: both decodes fail, `restored` stays
  empty, and the operator sees an empty Processing pane while `_processed/` holds orphaned output. Corrupt
  manifests get renamed + bannered, never auto-deleted.
- **`W17.det1`** — stranded-session **detection logic only**, no UI.
- **Tag-write failures folded into `W3.cap-r1`** — ✅ **SHIPPED 2026-07-31** (see the FIXED entry at the top of this
  file). A real finding this entry did NOT contain: all three live-path tag writes were
  `_ = try? MacOSTagger.applyTags(...)`, so a file could be trashed-at-source while its output carried **no tags at
  all** and was invisible to Reader triage. Fixed as specified — record the failure, warn in the finalize summary,
  still counts as filed — in the same commit as r1's colour-overload fix, as required.

**Original proposal (historical — see the fiction warning above):**

Live Capture finalization now has a purpose-built durable transaction: it freezes exact content hashes and
destinations, records exact source-photo identities, admits only complete/hashable groups, pauses capture,
and commits destination → capture manifest → receipt → staging manifest before retiring recovery state.
Other Processor paths still implement their own multi-artifact ordering, and Live Capture's journal remains
an internal file with automatic retry/fail-closed messages rather than an operator-visible recovery tool.
The content hash also proves file bytes, not Finder tag/label metadata; proving those correctly depends on
the trustworthy tri-state tag reader tracked in the ArchiveCore review.

Build one reusable `RecoverableArtifactTransaction` component rather than growing more path-specific
journals. Give it explicit persisted states (`planned → destinationsVerified → sourceManifestCommitted →
stagingRetired`), versioned migrations, exact artifact/source identities, required metadata fingerprints,
atomic destination-side temporary copies, directory durability where supported, and bounded background
verification. Integrate Process Files organization/merge, paid-batch materialization, and Live Capture only
after contract tests prove the shared primitive preserves each path's current recovery guarantees.

Add a Recovery screen that lists interrupted transactions with human-readable source/destination paths and
offers Validate, Retry, Reveal, Export report, and a deliberately guarded Abandon action. Abandon must never
overwrite or delete an unverified destination, must retain irreplaceable raw sources, and must explain which
derived staging files will remain or move to Trash. An invalid/tampered journal should remain inspectable;
it must not silently block capture forever or be auto-deleted.

Verification plan:

1. Crash/fault-inject before and after every state transition, file copy, hash/metadata read, manifest save,
   receipt save, and container retirement; prove replay is idempotent and numbering never changes.
2. Exercise partial multi-group success, missing requested PDF/JPG/JSON, destination races, external-volume
   disconnect/reconnect, legacy staging roots, source replacement, late stragglers, and terminal receipts.
   Preflight directory-sync/metadata capabilities before accepting a plan; classify unsupported SMB,
   cloud-backed, and removable volumes explicitly so a durable journal cannot become permanently
   unreplayable merely because that filesystem does not implement APFS-style directory `fsync`.
3. Verify content plus required Finder tags/color label on APFS and on volumes that cannot preserve them;
   unsupported metadata must be an explicit policy/result, never silently treated as verified.
4. Stress thousands of large artifacts while proving hashing/copying never blocks the main actor and intake
   stays quiescent only for the owning transaction.
5. Test every Recovery-screen action against corrupt, unknown-version, partially committed, and already-
   completed journals; require an exportable audit report before any manual abandon.
6. Migrate one workflow at a time and run its old regression suite plus cross-workflow concurrency tests
   before deleting that workflow's specialized journal.

Deferred because the reviewed Live Capture bug needs a narrow, auditable checkpoint now, while a shared
transaction engine and recovery UI would span all Processor pipelines and the still-unfixed ArchiveCore
metadata-read contract. Review the state model and Abandon semantics with the owner before implementation.

---

## CLOSED (owner decision 2026-07-18): immutable, versioned Live Capture inputs from receipt through cleanup

**Do NOT build the generation-record model, the companion-persisted photo UUID wire migration, or the conflict/
reconciliation UI. Do NOT re-promote this.**

### ⚠️ The original text below is FICTION in one important respect — read this first
Like its sibling entry above, it is written in the **past tense about work that was never done.** It claims "the
narrow safety fix preserves a changed re-upload instead of overwriting an existing `(groupId, seq)` path" and that
"staged generations carry a content proof captured before OCR and rechecked through output generation/
finalization." Verified 2026-07-18: **`CaptureSession.ingest` still does `try? FileManager.default.removeItem(at: finalURL)`
followed by `moveItem` (`CaptureSession.swift:505-507`)** — it overwrites — and **there is no content hash
anywhere in `Capture/`** (zero `sha256`/`CryptoKit` hits). Neither the non-overwriting fix nor the content proof
exists. Retained below only as the historical proposal.

### Why it is closed
1. **The central hazard is unreachable from our own companions.** It requires two **byte-distinct** uploads
   claiming one `(groupId, seq)`. But `groupId` is a fresh random `"g" + UUID().prefix(8)` minted per segment
   (`CaptureViewModel.swift:97`), `seq` is a durably-persisted monotonic counter, an ordinary retry re-POSTs the
   **same immutable file**, and a reclassify mints a **new** groupId. **No such collision has ever been recorded
   in this project** — so the conflict/reconciliation UI is speculative, and it is the most expensive part of the
   proposal (it needs owner design input precisely because an adoption mistake binds results to the wrong photo).
2. **A cheaper fix delivered the stable-identity pillar — and has now SHIPPED.** `W3.cap-r2` (`96f223b`,
   2026-08-02) re-keyed `pageTasks` + `startedPages` (was `startedPhotoIds`) on a `PageKey(groupId, seq)`
   — `startedPages` itself was retired by `W3.cap-r3-fu1` (`1a84d1c`), which made `pageTasks` the sole
   started-once record once the duplicate was shown to go stale on three paths —
   instead of the ephemeral `CapturedPhoto.id` (`CaptureModels.swift:23`), which `ingest` re-mints on the
   replace path. That closed the real, **money-costing** bug — a phone auto-retry after a dropped ack
   bypassed the dedup guard and triggered a **duplicate paid OCR call** — with **no** persisted generation
   record, **no** manifest migration, and **no** three-app protocol review.
3. **The wire-contract cost is disproportionate.** Companion-persisted photo UUIDs would change the capture
   protocol across macOS + iOS + Android and all four transports (LAN, USB, file relay, Drive), requiring the
   emulator E2E gate and a physical iPhone to verify — for a failure mode that cannot currently occur (#1).
4. **The Recovery Core Directive already bounds the blast radius:** deletion keys off outputs confirmed on disk
   (`filedGroupIds`), all deletions go to the Trash, and both raw sources and processed output persist in the
   visible backup folder until finalize confirms the destination.

### What WAS promoted instead (see `SUITE_TODO.md` §"Known-issues work — Wave 17")
Nothing from this entry directly. Its legitimate residue is covered by **`W3.cap-r2`** (stable `(groupId, seq)`
keying — **shipped 2026-08-02 `96f223b`**) and **`W17.stg1`** (versioning + integrity + fail-closed on the
staging manifest, still open). The
per-source **content hash** was considered and **deliberately dropped** by owner decision: it is defensible as
*corruption detection* (truncated write, partial Drive download, an externally edited JPEG) but it is **not**
same-key collision defense, and the collision it was meant to defend cannot occur (#1). Revisit only if a
byte-distinct same-key upload is ever actually observed.

**Original proposal (historical — see the fiction warning above):**

The narrow safety fix preserves a changed re-upload instead of overwriting an existing `(groupId, seq)`
path, and current staged generations carry a content proof captured before OCR and rechecked through output
generation/finalization. The underlying model still treats a mutable filename as the capture's primary
identity, however. Deferred/replacement generations share a logical phone key, crash recovery reconstructs
them from filenames plus manifest entries, and there is no operator-facing conflict queue explaining why
two byte-distinct uploads claimed the same key.

Replace mutable raw paths with immutable capture-generation records. Give every receipt a stable generation
UUID, sender key `(device/session/group/seq)`, content hash, durable storage URL, byte count, received time,
and explicit relationship (`original`, `exact retry`, `supersedes`, or `conflict`). Store raw bytes under a
content-addressed or generation-addressed filename that is never overwritten. OCR, page work, staged-output
manifests, rotation regeneration, and finalization journals must reference that generation ID plus hash—not
re-read identity from the sender-key path at Finish.

Add a conflict/reconciliation UI for byte-distinct uploads that reuse a sender key. It should show both
generations, allow Reveal/compare, and offer Keep both, Treat newest as replacement, or discard-to-Trash
only with an explicit choice. Companion clients should eventually generate and persist their own immutable
photo UUID so ordinary retries never rely solely on `(group, seq)`; roll this out compatibly across macOS,
iOS, Android, LAN, USB, and Drive relay transports.

Verification plan:

1. Exercise `A receipt → OCR(A) → same-key B`, replacement during OCR/tagging/PDF generation, and a crash at
   every boundary; prove no artifact can bind A's OCR/tags to B's image or authorize deleting B.
2. Retry identical bytes before/after restart over every transport and prove exactly one generation/receipt;
   send different bytes under the same key and prove both remain durable without blocking Finish drain.
3. Commit A while B is deferred and another group is omitted/failed; prove A clears once, B immediately
   re-arms as new work, and stale completion/tag state cannot suppress its card or finalization.
4. Corrupt or remove generation metadata while leaving raw bytes; fail closed, surface recovery UI, and
   never infer destructive authority from a filename alone.
5. Migrate legacy manifests conservatively: hash/import each existing raw file as a new immutable generation,
   keep ambiguous duplicates, and require review before any legacy staged output may clear a source.
6. Stress thousands of large captures while source hashing/version checks stay off the main actor and prove
   storage deduplication cannot merge metadata or delete a generation still referenced by a transaction.

Deferred because this changes the capture protocol and persistence model across three apps and all receiver
transports. Review the generation identity, supersession semantics, and conflict UI with the owner before
changing the wire contract; retain the narrow fail-closed implementation until that migration is proven.

---

## PROMOTED → Wave 15: lossless Finder-tag undo must preserve duplicate occurrences [MEDIUM — shared contract]

**No longer deferred (owner review 2026-07-18).** Promoted to `SUITE_TODO.md` §"Known-issues work — Wave 15"
as **W15.tu0–tu4**, bundled with the ArchiveNotes W8-S2 concurrent-write race (same `CoordinatedTagWriter`
choke-point). The three questions this entry left open are now **decided**: restore semantics =
**occurrence-only** (correct token *count*; order is not guaranteed, since macOS reorders on write and the
SPEC already compares as a multiset); a concurrent unrelated edit between edit and undo must still **survive**
(keep today's Safety-Protocol §9 reconcile-against-fresh-read behavior); and undo stays **in-memory** — no
persisted/versioned undo records, so `TagDelta` needs no `Codable` (the §12 audit ledger remains unbuilt and
is a separate future item). **Also verified during that review:** macOS *does* persist duplicate tag strings
(scratch probe round-tripped `["A","A","B"]` through both `setResourceValue(.tagNamesKey)` and raw `setxattr`),
so this is real, not theoretical; forward writes and color-label undo are **already** lossless — only the
inverse/undo drops occurrences, and closing it needs both a multiplicity-aware inverse **and** a
multiplicity-aware apply (the apply path today refuses to re-add an already-present token). Original analysis
below.

Finder metadata can contain duplicate tag strings, but ArchiveCore's current inverse calculation uses
`Set` subtraction and `TagDelta` intentionally applies ordinary edits with set-like semantics. Replacing
one subtraction expression would therefore not make undo lossless: `['A', 'A'] → ['A']` still cannot be
represented by the existing inverse type. Normalizing duplicates away would silently mutate raw Finder
metadata and conflicts with the suite's lossless-write goal.

Introduce a separate exact-occurrence undo delta (ordered multiplicity plus color-label state) while keeping
ordinary user edits set-like. Route both through one bounded reconcile/verification layer, migrate undo
consumers only after ArchiveNotes' concurrent shared-Core work is clear, and version any persisted undo
records. Review with the owner before choosing between exact order restoration and occurrence-only
restoration if unrelated concurrent tag edits occurred.

Verification plan:

1. Cover duplicate additions/removals, exact inverse round trips, tag order, and color-label restoration.
2. Inject unrelated concurrent tag additions between edit and undo; prove they survive reconciliation.
3. Fault after each metadata write/read and require either a verified result or structured partial state.
4. Exercise Processor, Reader, and Notes callers against the same fixtures before changing the public
   `TagDelta` contract or deleting compatibility adapters.

Deferred because this is a real shared-contract revision, not a safe local bug patch, and ArchiveNotes is
currently being changed by another autonomous run.

---

## RESOLVED (2026-08-01) → Wave 16: replace process-global processing settings with per-run dependencies [was MEDIUM-LOW]

✅ **FIXED — W16.cfg1…cfg6 all shipped; the six `nonisolated(unsafe)` statics no longer exist.**
`OCRProcessor`'s `rotationModeForRun`, `standardImageMB`, `ocrWorkerCount`, `pdfImageMB`, `textColumns` and
`exportedImageMB`, and the `loadStandardImageMB()` that loaded them, were deleted by **W16.cfg6** (2026-08-01).
Every run/resume/retry/review/tag/export/merge consumer takes its values from an injected
`SessionProcessingConfig`; `targetDimensionScale` and `performOCRCall` now take their run values as **required**
parameters, so completeness is compiler-enforced rather than review-enforced. Where an optional config remains,
the terminal fallback is `SessionProcessingConfig.runSizing()` / `defaultRotationMode()` — pure, lazily
evaluated, Keychain-free UserDefaults reads that can return a *current* value but never a *stale* one.

**The residual risk this entry stayed open for is now unrepresentable, not merely unlikely:** no test driver can
leave a run-config global mutated, because there is no such global to mutate. The text below about drivers
poking `rotationModeForRun`/`standardImageMB`/`pdfImageMB`/`textColumns` describes the pre-cfg6 code and is kept
only as the historical rationale. **`MacOSTagger.stampUnread` — a *different* global, and the last one — is gone
too, deleted 2026-08-01 by W16.cfg6-fu** along with the `OCRProcessor.taggingMode` `didSet` that armed it. It had
already been lock-backed (`5b58da8`) and unread by production since W16.cfg4 made `stampUnread:` a required
per-call parameter at all 13 sites; what remained was three test drivers poking it, and they now assert the
injected per-call value instead. The concurrent-runs + Thread-Sanitizer stress driver from the verification plan
stays deferred (needs live keys or an owner-approved stub OCR backend).

**One gap the "single run config" framing hid, closed 2026-08-01 by W16.cfg6-fu2:** `fromDefaults()` — the
builder **Live Capture** snapshots — clamped `pdfImageMB`/`exportedImageMB` with looser inline closures than
`runSizing()`, so an out-of-range setting reached a live capture unclamped (21 MB stayed 21; `+.infinity`
passed straight through, since `inf > 0`) while Process Files clamped the same number. All five sizing values
now come from `runSizing()` on every defaults read. Scope that honestly: it is **one clamp per defaults read**,
not one clamp in the app.

**The writer side closed 2026-08-01 by W16.cfg6-fu3.** `SessionProcessingConfig.Bounds` is now the single
declaration of the three ranges (0.5…20 MB, 1…12 workers, 1…4 columns), read by the clamp helpers, the
Settings steppers, `PDFGenerator`, `schedulingWorkerCount` and the fail-closed resume validator alike; and
`normalizeSizingDefaults(_:)` writes the five defaults back as exactly what `runSizing()` resolves, on every
Settings change and after a profile is applied. So a sizing setting can no longer be *stored or displayed*
out of range — the unbounded text field, the raw cost quote, the low-only ETA clamp and the unvalidated
processing profile are all bounded. Two residues, both deliberate: the MB fields render to one decimal, so a
stored 19.96 still displays as `20` (under 0.05 MB, left alone); and the columns `Picker` offers 1/2/3 while
`Bounds` admits 4, so the validator stays slightly *looser* than what the UI can produce (harmless —
`PDFGenerator` renders 4 fine, and looser is the safe direction for a resume validator).

*Historical record below.* Promoted to `SUITE_TODO.md` §"Known-issues
work — Wave 16" as **W16.cfg1–cfg6**. **Owner decision: extend `SessionProcessingConfig` to be the single run
config** (it already carries 5 of the 6 values; `ocrWorkerCount` is the only gap) and have
`PendingRunRuntimeConfig` wrap it — **do NOT introduce a third type.** This is a consolidation job, not the
greenfield build the original text implies.

**W16.cfg1 DONE 2026-07-29:** `SessionProcessingConfig` is explicitly `Sendable` and now captures
`ocrWorkerCount` in `fromDefaults()` with the existing 1…12 clamp/fallback of 4. A separate, then-unused
`fromProcessFilesRunStart()` builder captures the complete existing normalization (worker
count, all three finite 0.5…20 image sizes, and 1…4 text columns) for W16.cfg2/3 without changing Live Capture
behavior in this checkpoint. Scratch-only volatile-defaults coverage pins the returned configs' worker
wiring/bounds and complete Process Files normalization.

**W16.cfg2 DONE 2026-07-29 (this commit):** fresh Process Files runs now capture that normalized config once
and thread it through OCR sizing/scheduling, batch result materialization, every automatic/interactive retry,
and PDF generation. The instance retains the same snapshot for post-run per-item retries; an adversarial review
caught and closed the initial gap there. Non-batch manifests record the exact config values that were actually
used. Resume continues through explicit nil/static fallbacks until cfg5, preserving schema and legacy behavior.
Scratch config/manifest, multi-page PDF, and batch/non-batch resume regressions passed with a clean Debug build.

**W16.cfg3 DONE 2026-07-29 (this commit):** the same snapshot now reaches every late review/output consumer:
rotation and manual PDF regeneration, review-driven reclassification tag writes, automatic/manual tagging,
priority layering, sized-original export, and merged-PDF tag transfer. Fresh and pre-OCRed paths inject it
explicitly; retained post-run UI actions resolve the active snapshot; resume keeps the old nil fallback until
cfg5. The Process Files snapshot takes its exact tagging/merge/export policy from the configured controller, preserving
headless `.none`/`.copySource` behavior and every explicit non-stamping copy-source write. Debug build plus
scratch manifest/config, merge-safety, and batch/non-batch resume regressions passed; Tier-2 adversarial review
found and closed the remaining live decision gates, then approved. The remaining work is cfg5 (construct/store
config on resume) and cfg6 (delete the fallback statics).

**W16.cfg5 DONE 2026-07-29 (this commit):** every modern or legacy resume now constructs, stores, and threads a
non-nil `SessionProcessingConfig`; the six resume-time global assignments and the fresh-run static fan-out are
gone. Modern runs replay the validated persisted snapshot. Legacy run/batch records retain current-default
fallback behavior, including the exact 1%…100% image-scale clamp, while persisted identity/output policy wins
where available. Fresh OCR, retry, paid-batch materialization, pre-OCRed resume, and standalone Tools diagnostics
all receive rotation/size explicitly. The manifest schema and validator did not change. Debug build and all
targeted scratch regressions passed; adversarial review caught and closed the remaining call-path/default-edge
gaps. Only cfg6 remains: remove the now-production-unused fallback statics and compatibility parameters/drivers.

**Two claims below are STALE — corrected here so they aren't re-derived:**
- *"`MacOSTagger` retains a global fallback for older call sites"* — **there is no global.** It stopped being
  `nonisolated(unsafe)` at `5b58da8` (`OSAllocatedUnfairLock`-backed), stopped being *read* at W16.cfg4 (which
  made `stampUnread:` a required parameter at all 13 sites, so no site takes an implicit default), and was
  deleted outright by **W16.cfg6-fu** on 2026-08-01. `MacOSTagger` now holds no state.
- *"let persisted recovery records own a versioned copy"* — **already shipped.** `PendingRunRuntimeConfig`
  (`OCRProcessor.swift:403`) is schema-versioned, manifest-attached, structurally validated independent of the
  fingerprint (`+Pipeline.swift:204-233`), and round-trip tested (`BatchResumeTestDriver.swift:304-426`).

**Why it is not HIGH:** the headline scenario — a Process Files run mutating an in-flight Live Capture's
settings — is **already impossible**; Live Capture is fully injected and reads/writes zero globals. The count of
six `nonisolated(unsafe)` statics IS still accurate (`OCRProcessor.swift:70/73/76/79/82/85`). The residual risk
that justifies the work: the env-gated headless **test drivers mutate these globals directly**, so a driver run
(or a crash that skips its `defer` restore) alongside real work yields wrong image size, wrong column count, or a
missing/extra `Unread` tag — non-zero because the daemon runs smoke tests unattended. It becomes genuinely HIGH
only if background processing, a second processor instance, or a share extension is ever added.

⚠️ **Hazard recorded for W16.cfg4:** several **copy-source** `applyTags` sites are correct today only because the
global happens to be `false`. A mechanical "pass the run's `taggingMode`" edit would silently start stamping
`Unread` on copy-source output — a SPEC-visible tag regression on irreplaceable files. Audit each site
individually. Original analysis below.

## Original text: replace process-global processing settings with immutable per-run dependencies

The immediate Live Capture overlap bug is fixed: Live Capture now carries its locked rotation, image-size,
and unread-tag policy through the OCR and file-writing calls instead of reading or mutating Process Files'
globals. Process Files itself still stores six run settings in `nonisolated(unsafe)` static variables, and
`MacOSTagger` retains a global fallback for older call sites. Its current single-run UI gate makes ordinary
Process Files use safe, but the representation remains fragile for future background work, tests, app
extensions, or a second entry point.

Replace the remaining globals with one immutable, `Sendable` `ProcessingRunConfig` created at every run
boundary. Pass it through OCR scheduling, retries, review/regeneration, PDF/image generation, tagging,
batch resume, and Live Capture. Let persisted recovery records own a versioned copy of the same type rather
than translating between manifest fields and mutable globals. Remove `nonisolated(unsafe)` configuration
entirely; keep only genuinely process-wide synchronized services (for example rate-limit accounting).

Verification plan:

1. Run Process Files and Live Capture concurrently with opposite rotation, image-size, worker-count,
   PDF/export-size, column, and unread-tag settings; prove each output matches only its own snapshot.
2. Suspend both modes at OCR, retry, tagging review, rotation review, and PDF regeneration boundaries,
   mutate Settings, then prove neither run changes behavior.
3. Crash and resume standard, batch, pre-OCRed, re-OCR, and Live Capture runs; compare the restored config
   byte-for-byte with the original and verify legacy recovery manifests still decode safely.
4. Add Thread Sanitizer/stress coverage that interleaves two programmatic processors and Live Capture,
   with no data races and no cross-run output/tag contamination.
5. Delete the static fallback fields and make compile-time configuration injection mandatory at every
   processing call site.

Deferred because completing it touches the whole Processor pipeline and recovery schema. The narrow fix
removes the actual cross-mode corruption path without forcing a high-risk pipeline rewrite into this bug
checkpoint.

---

## ✅ FIXED (2026-07-17): Process Files could change an in-flight Live Capture run's settings [HIGH]

**FIXED:** Live Capture no longer writes or reads Process Files' mutable rotation, standard-image-size, or
unread-tag globals. Its locked `SessionProcessingConfig` now carries those values explicitly into every
detached OCR task and staged/rotation-regenerated output write; the unread policy is also persisted with
retained staging state for crash recovery. Process Files can therefore start or resume while a capture
session is open without changing that session's rotation detection, request image scale, or Finder tags.
The key-free manifest regression activates Live Capture under conflicting globals and proves its explicit
size and tag policies win. (2026-07-17)

---

## LOW — typed BatchProvider refactor + provider contract fixtures (was: "unify paid-batch providers", MEDIUM)

**Downgraded + retitled (owner review 2026-07-18); the protocol rewrite is CLOSED, the tests are promoted** to
`SUITE_TODO.md` §"Known-issues work — Wave 16" as **W16.bat1** (provider contract fixtures) and **W16.bat2**
(cancel-path coverage).

**This entry was substantially STALE — three of its four headline risks are already closed AND regression-tested:**
- *"forget a persistence transition"* → `persistPendingBatchMutation` mutates a copy, writes atomically, and
  publishes in memory **only** if the disk write succeeded; on failure it halts the run rather than running ahead
  of its journal (`+Pipeline.swift:593-613`, transitions at :616/:626/:633).
- *"mishandle partial submission"* → partial submission is a **first-class journaled state**
  (`submissionComplete`, `OCRProcessor.swift:298`; guard `+Pipeline.swift:408`), regression-tested at
  `BatchResumeTestDriver.swift:476-486`.
- *"delete recovery state before cancellation is confirmed"* → `cancel()` deletes the journal **only** when every
  server cancellation is confirmed — and since W16.bat2 that rule lives in one testable seam,
  `performServerBatchCancellation` (`+Pipeline.swift:1565`), regression-tested by `BatchCancelContract`.
- *"keep a migration decoder for existing `pending_batch.json`"* → **already shipped** (`OCRProcessor.swift:344-372`).

*"Gemini returns multiple job IDs as a comma-separated string"* is **half stale**: the joined string survives as a
**derived compatibility mirror**, but the authoritative representation is the ordered `submittedChunkIds` array
(`OCRProcessor.swift:292`, `:380`), and self-consistency *forbids* a comma inside any individual ID
(`+Pipeline.swift:403`), so the join is provably lossless. Gemini's per-chunk IDs reach the journal via the
`onJobCreated` hook (`BatchOCR.swift:265-271`), not by parsing the joined string.

**Still true:** the three clients remain stringly-typed behind three `switch provider` blocks (`+OCR.swift:525`,
`+OCR.swift:630`, `+Pipeline.swift:1445`). **Owner decision: do NOT build the full `BatchProvider` protocol
rewrite** — it would touch the only code path that spends real money to remove risks that are already gone.
Revisit only when OpenAI batch (Phase 4) is actually implemented; the defensive `case .openai` arms
(`+OCR.swift:551-555`, `:740-743`, `+Pipeline.swift:1463-1464`) are where that work will land.

**The genuinely unmet gap — CLOSED 2026-08-01 (W16.bat1):** verification-plan item 5, provider contract
fixtures. `GeminiBatchClient.checkStatus` parsed **six alternative JSON shapes** with **zero tests**, so a
provider response-shape change would silently have marked an entire paid batch as failed. Each client's parse
bodies were lifted verbatim into pure seams (`parseStatusBody` / `parseResultsJSONL`, plus internal
`parseInlinedResponses` / `parseSingleResponse` / `parseBatchErrorBody`) and `BatchParseContract` now drives
literal Anthropic/Gemini/Mistral bodies through them — **81 checks, $0, no network, no keys**, riding
`scripts/test-batch-resume.sh` (144 checks total). All six result-file spellings are covered individually plus
their resolution order; both state envelopes and both inline envelopes with their precedence; blockReason /
RECITATION; entry-level errors; the `'0'` → `'file-0'` normalization; empty and malformed result sets; and the
rule that one unreadable JSONL line never costs the other paid pages. Non-vacuity measured with 7 neuters.
**Only verification-plan item 5 is closed** — items 1–4 were already covered (above), and the protocol rewrite
stays CLOSED by owner decision.

**Residual W16.bat1-fu — CLOSED 2026-08-01.** The fixtures' one live finding: an empty `inlinedResponses`
container shadowed the result-file fallback, so a SUCCEEDED Gemini chunk could be marked *consumed* in the
journal with zero pages. Both halves of that decision are now pure and pinned instead of inline in the poll —
`GeminiBatchClient.resultsSource(for:)` ranks the retrieval arms (an empty inline container, and a blank or
whitespace-only result-file name, are *not* sources), and `chunkOutcome(resultCount:emptyObservations:limit:)`
judges the **raw** provider results, which is the only place it can be judged: `processBatchResults` returns
`true` on an empty set deliberately, so that a resumed chunk whose pages already persisted is not
re-materialized. A finished chunk that produced nothing is re-read for ~2–4 minutes, then reported empty —
**never consumed, and never allowed to block the batch**: the run completes, the completion sweep gives its
unmaterialized files an explicit `no_result` failure the retry pass can act on, and the pages that did arrive
finish normally. 17 more $0 checks (`scripts/test-batch-resume.sh` → 161 total), non-vacuity measured with 4
neuters.

The first attempt at that fix halted the poll and kept the batch for resume instead, which the adversarial
review correctly rejected: the observation count was poll-local, so no number of resumes ever converted an
empty chunk to failed, and one anomalous chunk could block a run **permanently** — including the case where
every page was already on disk and only a long-expired result file was missing. Worth remembering when
touching this path: *"don't consume it"* and *"don't let it finish"* are not the same requirement, and only
the first one is a safety property. That review also surfaced two **pre-existing** defects, queued as
**W16.bat3** (Stop mid-poll deletes the paid journal while the UI says it was kept) and
**W16.bat4** (the Resume control is never surfaced after an interrupted first run). **Both are now closed —
see below.**

**W16.bat3 — CLOSED 2026-08-02** (`53e43e2` + this commit). The first of those two, and the one that cost
money. `cancel()` deletes the paid-batch journal **only** when every server-side cancellation was confirmed;
otherwise it keeps it and tells the operator *"the paid-batch journal was kept for recovery."* But the poll
task unwinding alongside it hit `guard !Task.isCancelled else { return }` in `pollBatchUntilComplete` and
returned **silently** — `batchPollInterrupted` stayed false, and both callers read that flag to decide the
journal's fate, so the first run's tail (`performBatchOCR`) and a resume (`resumeBatch`, whose own
cancellation guard sits *below* its delete) removed it anyway. Pressing Stop mid-poll could therefore strand
a paid, still-live server-side batch with no local record at all, while the UI said the opposite. Both
guards now set the flag, which is deletion-**reducing** on every path — all four readers were traced, and no
path gains a delete it did not have (keep-on-doubt: a stale journal costs a dismissed prompt, a deleted one
costs the batch). `performBatchOCR`'s inline tail also became
`retirePaidBatchJournalIfPollCompleted()` — identical condition, statements and order — so that direction
can be driven against a real journal file instead of read. **7 new $0 checks**
(`BatchPollCancelContract`, driver section 17; `test-batch-resume.sh` 258 → 265), with the discrimination
measured: reverting the two assignments reddens 4 of them, including the journal file disappearing from
disk during a whole cancelled `resumeBatch`. What it still does not pin is the first run's own call into the
poll — reaching that needs a real paid submission — so that seam is held by structure, exactly as W16.bat4's
call sites are. One adjacent defect the review surfaced is **open**: `performBatchOCR` has a *fifth*
interrupted exit (`markBatchSubmissionComplete()` failing) that runs no tail at all → `SUITE_TODO.md`
**W16.bat3-fu**.

**W16.bat6 — CLOSED 2026-08-02** (this commit). W16.bat3 made *"the paid-batch journal was kept for
recovery"* true; this makes it legible. `cancel()` raised that sentence from a task that raced the run it had
just cancelled, and the run writes `statusMessage` too — a status check still in flight when Stop landed
resolves into `"Batch processing… n/m complete"` or `"Error checking batch… Retrying…"` on the way out.
Whichever wrote last won, so the operator's only signal that a paid job may still be running server-side
could be gone before they read it, with the journal on disk and nothing on screen pointing at it.
`cancel()` now keeps the run's task handle after dropping it and awaits it before raising the warning: last
by construction rather than by luck. Deliberately *only* the message waits — the server-side cancellations
go out first (they stop paid work) and the Resume banner is still recomputed immediately (leaving it
unrendered is the W16.bat4 wedge), then again afterwards in case the unwinding run changed what is on disk.
The wait cannot hang: that task is already cancelled and all seven continuations it can park on are resumed
above it, so the only thing that can hold it open is an in-flight request running out its own
`timeoutInterval` — and a late warning beats a lost one, where merely *narrowing* the window would not, the
clobbering write being by definition the one that returns last. **3 new $0 checks**
(`BatchPollCancelContract` section 5; `test-batch-resume.sh` 265 → 268), and they are the only ones in the
suite that press Stop with a **live `processingTask`** — which is exactly why `BatchCancelWiringContract`
could prove the warning *assigned* but never *survived*. Discrimination measured: remove the await and 2 of
the 3 redden. The stand-in run is honest about its limits (the window where a *real* poll writes after a
Stop is inside a paid provider call, so it cannot be reached for free); what is real is the whole ordering
seam — the real `cancel()`, the real cancellation task, the real `statusMessage`.

**W16.bat4 — CLOSED 2026-08-01** (`1515773` + `819494d` + this commit). The second of those two. Every
`batchPollInterrupted` message tells the operator the paid batch was kept *so they can resume it*, and the
"Pending Batch / Resume Batch" box (`Views/OCRView.swift:319`) renders only from `pendingBatchInfo`, which is
written only inside `checkForPendingBatch()`. The resume path called it; the first-run path ended its
interruption with `isProcessing = false` and nothing else. So the operator was told to press a button that was
not on screen — they had to press Start, be refused, and only then see it — and the run's PDF→JPEG temp files
stayed behind. The two tails are now one method, `finishInterruptedBatchPoll()` (`+Pipeline.swift:796`),
called by both sites and by nothing else. Routing the first-run site through it also covers `performBatchOCR`'s
three earlier interrupted exits — a journal-save failure, a submission that stopped part-way, a journal/ID
disagreement — which each left a dead `activeBatch`/`activePendingBatch` behind and leaked the same temp files.
The tail deletes no journal and touches no output: a paid server-side job may still be running, and the journal
is the only way back to it. 16 $0 checks (`BatchInterruptTailContract`, driver section 15;
`scripts/test-batch-resume.sh` 225 → 241), non-vacuity measured with four neuters — dropping
`checkForPendingBatch()`, which is exactly the shipped bug, reddens five. What it does **not** pin is the two
call sites themselves: driving either needs a real paid submission. That gap is held closed structurally
instead — each site is now a bare `finishInterruptedBatchPoll(); return`, with no second copy of the tail to
drift. (This paragraph also used to cite the un-redirectable Application Support path as a blocker; that half
is gone — see **W16.bat2-fu2** below.)

**W16.bat2-fu2 — CLOSED 2026-08-01** (`5424054` + this commit). The paid-batch journal's location was
computed inline in `pendingBatchURL`/`pendingRunURL` and could not be moved, which cost two things at once.
The **default journal deleter's body** — `{ OCRProcessor.deletePendingBatch() }`, the one line on the money
path that actually removes `pending_batch.json` — could only be verified by reading it, because every check
in sections 13–15 replaces that seam and running the real one would have deleted the operator's own journal:
mutating the body to `{ }` left all 241 checks green. And the reverse hazard: had anyone bolted an *un-seamed*
deletion into the cancel block, *running `test-batch-resume.sh`* would have destroyed a live journal.
Both journals now resolve through `OCRProcessor.pendingStateDirectory(testFlag:overrideRoot:)`, which honours
`ARCHIVEPROC_TEST_STATE_ROOT` **only** when `BATCHRESUME_TEST` reads exactly `"1"` **and** the override names
a usable absolute directory — unset, empty, whitespace, `"0"`, `"true"`, `"1 "`, relative, `~`-relative, a
path naming a file, or one that cannot be created all resolve to the REAL path, because a mis-read variable
here does not fail a test, it strands a paid batch. There is deliberately no other trigger (no `#if DEBUG`, no
bundle sniffing), and the function is pure in its inputs so the fail-closed direction is checked by handing it
each bad reading directly. 17 $0 checks (`BatchJournalPathContract`, driver section 16; `test-batch-resume.sh`
241 → 258), non-vacuity measured with **eight mutants**: neutering the default deleter to `{ }` — the shipped
gap verbatim — reddens 2 where it previously reddened none; a `!= nil` flag gate reddens 1; dropping the
absolute-path guard reddens 1; an un-seamed `deletePendingRun()` in `cancel()` reddens 1; a resolver that
ignores the override reddens 3, including the guard that makes the destructive checks REFUSE to run rather
than delete a real journal to satisfy a test; a save that writes elsewhere reddens 4; and dropping either
branch's `createDirectory` reddens 1 and 3.
The redirect guard runs from the **top of the driver**, before section 13 — the resolver fails closed
*silently*, so a harness whose override did not validate would otherwise press Stop 80+ times against the
operator's own state and only find out at section 16. It also now logs a loud warning when an override is
requested and rejected. Production behaviour with the flag absent is unchanged, including the
create-the-directory side effect — which exists for the **`.atomic` write** in
`savePendingBatch`/`savePendingRun` (it needs somewhere to put its sibling temp file), not for the banner
refresh, which reads through `Data(contentsOf:)` and is indifferent to a missing directory.

**W16.bat2 — CLOSED 2026-08-01.** The other promoted item: the cancel path's journal-retention rule had no
regression test either, because it was welded to three live network clients — the only way to verify it was
to read it. It now lives in one seam, `performServerBatchCancellation` (`+Pipeline.swift:1565`), which takes
the provider's per-chunk cancellation as an injectable closure and returns what it did to the journal; the
extraction is behaviour-preserving (same switch, same order, same message, same single delete condition).
`BatchCancelContract` drives it with a stub canceller and a **real temp file**, so "kept" means a file that
is still on disk: 28 checks (`scripts/test-batch-resume.sh` 161 → 189), including the invariant swept over
all four providers × chunk counts 0–6 × no refusal / each chunk refused in turn / all refused — 132 trials
asserting *deleted ⟺ confirmed* in the outcome **and** on disk, confirmation matching an independently
written statement of the providers' capabilities, no attempt a provider's rule could not act on, the
"kept for recovery" sentence present exactly when the file survived, and delete called at most once.
Non-vacuity measured with **five neuters**, each reddening exactly its own checks — including one shaped
like W16.bat3 (journal deleted while the outcome still claims it was kept), which reddens 13.
Note what this does and does not buy: it pins the *rule*, not the *whole Stop path* — W16.bat3's bug lived
in the poll's cancellation guards, downstream of this seam. That half is now closed too (see **W16.bat3**
below) and pinned by `BatchPollCancelContract`, section 17; cite the two together for the whole Stop path.

Original analysis below.

## Original text: unify paid-batch providers behind one durable state machine

The Processor's crash-safety fixes now journal paid-batch progress at the orchestration boundary, but the
Anthropic, Gemini, and Mistral clients still expose separate stringly-typed submit/status/result/cancel
flows. Gemini also returns multiple job IDs as a comma-separated string. That representation makes it too
easy for a future provider-specific path to forget a persistence transition, mishandle partial submission,
or delete recovery state before cancellation is confirmed.

This should be a deliberate revision rather than part of a narrow bug patch. Replace the provider switches
with a typed `BatchProvider` interface and one reducer-owned lifecycle (`prepared → submitting → submitted →
retrieving → materialized → finalized`, plus explicit ambiguous/interrupted/cancel states). Give every
server job a typed chunk record, persist transitions before scheduling the next irreversible action, and
let providers supply reconciliation hooks where their APIs can list/recover a create request whose response
was lost. Keep a migration decoder for existing `pending_batch.json` manifests.

Verification plan:

1. Inject a crash/failing manifest write before and after every state transition and prove restart resumes
   without repeating a billable create or duplicating an output.
2. Cover partial multi-chunk submission, mixed terminal states, empty/malformed result sets, and a response
   lost after server acceptance.
3. Prove cancellation retains the journal until every server job is terminal or cancellation is confirmed.
4. Round-trip and resume legacy single-ID and comma-separated Gemini manifests.
5. Run provider contract fixtures for all three clients plus the existing no-network and Debug build gates.

Deferred because this changes the shared internal batch architecture across three providers and needs
provider-level contract fixtures; folding it into the current Gemini lifecycle bug fix would make that fix
substantially harder to audit and back out.

---

## LOW (not queued): paid-batch lost-create reconciliation — no way to re-adopt an orphan server job

Split out of the paid-batch entry above by the 2026-07-18 owner review, so the one genuine (if unlikely)
money-risk gap stays visible on its own terms rather than being bundled into a refactor that was dropped.

**The gap.** If a provider accepts a batch-create POST and the response is lost in transit, the app records the
ambiguity **honestly** — the journal is retained, the message differentiates "no server ID was received … review
before retrying" from "stopped after N server jobs" (`OCR/OCRProcessor+OCR.swift:558-571`), and resume refuses to
auto-retry a v1 journal with no chunk IDs because "retrying automatically could duplicate a paid job"
(`+Pipeline.swift:748-753`). But there is **no reconciliation hook**: the app cannot list the provider's batches
and re-adopt the orphan. The operator must open the provider console.

**Cost if it fires:** one batch's spend possibly paid twice. **No data loss, no duplicate output** — the run
halts loudly rather than proceeding past its journal.

**Why it is not being built.** Auto-adoption needs **live paid API calls** against each provider's list endpoint
to develop and verify — outside the autonomous daemon's envelope — for a failure mode **never observed in this
project**. The `NetworkSession` `.nonIdempotent` retry policy (`BatchOCR.swift:130, :421, :722`) already prevents
the app from creating the duplicate itself, and the UI actively discourages the operator from blind-retrying.
An adoption mistake would also attach results to the wrong local run, so the UI needs owner design input.

**Decision:** ship an operator-facing note pointing at the provider console (folded into **W16.bat1**); build the
real reconciliation **only if a lost-create event is ever actually observed.** ✅ **The note SHIPPED 2026-08-01**
with W16.bat1 — `README.md` §"Batch Processing → If a batch submission reports an uncertain outcome": quotes the
exact in-app message, says do **not** press Resume before checking the provider's own console, links all three
consoles, and distinguishes this from the *"stopped after N server jobs"* message. ⚠️ **That sibling message is
no longer unconditionally benign, and the README section was rewritten accordingly on 2026-08-02
(W16.bat3-fu2).** Its N is now the number of jobs the submit loop CREATED — read off a tally `cancel()` cannot
clear, rather than out of the journal a Stop has just nil'd, which used to make the app report **zero server IDs
received** on a batch it had already been billed for, and claim the journal was "kept" without looking at the
file. Whether Resume suffices is now a separate clause of the same sentence: the journal was kept and holds them
all (benign — press Resume), the journal was kept but K of them are missing from it (those K need the provider
console, exactly as the uncertain-outcome case above), or no journal is on disk at all. The reconciliation
itself remains unbuilt, by decision. If it is built, it must preserve
the per-call idempotency declaration — dropping that silently reopens the FIXED CRITICAL "ambiguous retries could
duplicate billable requests."

---

## PARTLY CLOSED (accepted risk) + PROMOTED → Wave 16: Live Capture LAN channel [MEDIUM — was HIGH]

**Owner review 2026-07-18 split this entry in two.**

**A) The encryption/transport redesign is CLOSED as accepted risk — do NOT re-promote it.** No TLS, no AEAD, no
companion changes, no packet-capture harness. Rationale, recorded so it isn't reopened: the payload is
photographs of **public archival records the owner intends to publish**, so confidentiality is near-worthless;
the integrity loss is bounded by the **Recovery Core Directive** (idempotent `(group, seq)`, originals retained
in the visible backup folder, deletions via Trash not `rm`), so a forged overwrite is noticed at tag-card review
and is recoverable; and the attack needs a targeted adversary physically co-located in the same reading room.
Encrypting would change the wire contract on **all three platforms** and needs a physical iPhone plus the
`ap_test36` emulator E2E gate to verify. **Operator guidance instead: on untrusted venue Wi-Fi, use the USB bridge
or the Drive relay.**

*Nuance worth keeping:* venues that enforce client isolation **block the LAN transport entirely** (which is why
the relay and `USBBridge` exist), so LAN capture works precisely on the open/shared-PSK guest networks that ARE
sniffable. That is why the residual risk is real rather than hypothetical — it is simply low enough to accept.

**B) The credential weakness — FIXED (W16.lan2, 2026-07-28, `c335abd` + this commit).** Both promoted items are
now done: **W16.lan1** (threat-model + accepted-risk doc, in this entry + `CLAUDE.md` §"Primary Function 3: Live
Capture" → *LAN transport security — accepted risk*) and **W16.lan2** (the credential fix). This finding survived
the crypto-redesign deflation because it **requires no sniffing at all** — only network reachability to the Mac —
so the old ~29.7-bit persistent shared code was the real exposure. Now: `CaptureSession.lanToken` is a fresh
**~158-bit** LAN credential (32 chars over the 31-symbol alphabet, CSPRNG-drawn via `randomElement()`, persisted
under `LiveCaptureLANToken`), authenticated by `CaptureServer` and carried in the QR's `token` field; and
`CaptureServer` now applies a **per-source failed-auth throttle** (`AuthThrottle`: 5 free 401s, then exponential
backoff capped at 30 s, keyed per remote IP, fail-open on an undeterminable source, cleared on any authenticated
request) so a hostile LAN peer can't sweep tokens at connection speed. **The credentials are SPLIT** per the owner
decision: the 6-char **Drive-relay token is untouched** (`session.token`, still stamped as `appProperties.relayToken`
and carried in the QR's `relay` key — `SPEC/relay-object-format.md:38` pins it, with committed golden fixtures and a
shipped Android transport). Both companions parse `token` as opaque (Android `MacEndpoint.fromQrPayload`, iOS
`MacEndpoint.decode` — non-empty check only, no length assumption), so the sole migration cost is **one QR re-scan
per phone** for the LAN path; the Cloud path is unaffected. Verified headlessly: a standalone algorithm test (token
entropy + the full throttle schedule) plus the committed `ManifestPersistenceTestDriver` W16.lan2 checks (real
`CaptureSession`/`CaptureServer` types); Processor Debug build clean, 0 warnings.

**Stale sub-item corrected:** verification-plan item 4's *"Bonjour discovery"* is moot. The Mac advertises
`_archivecap._tcp` (`CaptureServer.swift:68`) but **neither companion browses for it** — pairing is QR-only.

**Already shipped (don't rebuild):** unauthenticated resource exhaustion is closed (header-first admission,
8-connection cap, 96 MB aggregate budget, 30 s idle timeout); `constantTimeEquals` is timing-safe; auth precedes
route disclosure; `CaptureValidation.isSafeGroupId` gates every phone-supplied id. The **Drive relay already has
the epoch binding** this entry wanted for LAN (`FileRelayReceiver.swift:152-153, :212, :242`) — if replay
protection is ever revisited, copy that reviewed design rather than inventing one. `CaptureServer._testAdmission`
makes all of this headlessly testable without a phone. Original analysis below.

## Original text: authenticate and encrypt the Live Capture LAN channel

The LAN receiver authenticates requests with a bearer token, but the current HTTP transport is plaintext
and the token is persistent. A device able to observe local Wi-Fi traffic can recover that token and replay
photo/control requests. The new header-first admission and memory caps prevent unauthenticated resource
exhaustion, but they do not provide confidentiality, peer identity, or replay protection.

Revise pairing across macOS, iOS, and Android to establish authenticated encryption: either pinned TLS with
a pairing-generated device certificate/key, or a small reviewed AEAD protocol derived from a high-entropy
pairing secret. Rotate credentials per capture session, bind every request to a session ID plus monotonic
nonce, retain USB-tunnel compatibility, and provide an explicit migration/re-pair path for existing saved
hosts. Do not improvise crypto inside the current HTTP parser; use platform cryptography and a documented
wire contract.

Verification plan:

1. Packet-capture a full pairing/upload session and prove tokens, metadata, and JPEG bytes are unreadable.
2. Replay captured photo, completion, and disconnect requests and prove all are rejected without mutating
   the Mac session.
3. Prove a phone paired to one Mac/session cannot authenticate to another and that credential rotation
   invalidates prior traffic.
4. Exercise Wi-Fi, Bonjour discovery, host/port persistence, and `adb reverse` USB flows on both phones.
5. Add downgrade tests so a secure-capable client/server never silently falls back to plaintext.

Deferred because this changes the pairing and transport contract on all three platforms and needs an
explicit compatibility rollout; it should be reviewed as a security feature, not hidden in a macOS memory
limit patch.

---

## ✅ FIXED (2026-07-17): unauthenticated LAN uploads were buffered before authentication and had no global cap [CRITICAL]

**FIXED:** `CaptureServer` now reads at most a bounded header prefix, rejects ambiguous framing, verifies the
bearer token, validates the route-specific declared size, and reserves aggregate capacity before reading a
body. The receiver admits at most eight concurrent connections, caps retained/declared bodies at 96 MB
across them, limits control bodies separately, and holds each reservation until ingest/response releases
the request. A single mutable accumulator avoids recursive `Data` copy-on-write spikes, and stop/timeout
release tracked connections. The no-network Live Capture regression covers authentication order, per-route
and aggregate limits, invalid/duplicate framing, unknown routes, and bytes beyond `Content-Length`.
(2026-07-17)

---

## ✅ FIXED (2026-07-17): paid multi-chunk batches lost submission/consumption progress on relaunch [CRITICAL]

**FIXED:** paid batches now use a versioned, integrity-checked lifecycle journal. It is created before the
first irreversible request; each acknowledged Gemini chunk ID is atomically appended before another chunk
is submitted; every materialized result and exact output path is persisted before its chunk is marked
consumed. Resume restores those associations, skips already-written files, reopens consumed chunks if an
output disappeared, and retains legacy single/comma-separated manifests. An interrupted submission with no
received ID remains visibly ambiguous instead of being retried automatically. New work cannot overwrite any
preserved batch/run record, and Cancel deletes a paid-batch journal only after every server cancellation is
confirmed. The headless crash-resume regression covers partial submission, tampering, escaped paths, missing
outputs, and legacy decoding. (2026-07-17)

---

## ✅ FIXED (2026-07-17): Process Files resumed with changed settings and an order-insensitive identity [CRITICAL]

**FIXED:** new non-batch runs persist a versioned immutable runtime snapshot covering tagging/source-tag
mode, rotation/review, merge, vocabulary, image scale, Live Capture grouping metadata, dual output,
worker count, and PDF/export sizing. Resume applies that snapshot instead of current UI/UserDefaults.
The v2 integrity hash is order-sensitive and covers the full configuration plus each evolving
index-to-result/output association; invalid versions, ranges, parallel arrays, or escaped output paths
fail closed. Initial snapshot failure prevents OCR from starting, and incremental persistence failure
stops further work to limit duplicate charges. New paid-batch fingerprints are also order-sensitive,
while legacy unversioned batches retain their old validation path so existing jobs are not stranded.
Legacy manifests remain readable. (2026-07-17)

---

## ✅ FIXED (2026-07-17): Local Agent ignored an invalid CLI override and accepted malformed Claude output [HIGH]

**FIXED:** a non-empty CLI path override is now authoritative, so an invalid configured path reports
`cli_not_found` instead of silently launching a different standard installation. Claude's requested JSON
contract is enforced; arbitrary stdout now reports `cli_bad_response` rather than being accepted as OCR
text. The Local Agent regression also isolates its backup directory. (2026-07-17)

---

## ✅ FIXED (2026-07-17): ambiguous retries could duplicate billable requests [CRITICAL]

**FIXED:** every HTTP call now declares whether it is idempotent. Billable generation, upload, and
batch-creation POSTs retry only an explicit 429 rejection; they are never repeated after a timeout, lost
connection, or ambiguous 5xx. Idempotent status/result reads retain transient retries. Cancelled limiter
waiters are removed without inventing active slots. An injected, no-network driver proves both retry
policies and stresses cancellation/drain accounting. (2026-07-17)

---

## ✅ FIXED (2026-07-12): capture completion was acknowledged before durable Mac persistence [CRITICAL]

**FIXED:** segment and whole-session completion are now transactional: they snapshot affected completion
state (and segment photo metadata), write the manifest, and return success only after the atomic write
succeeds; failure restores the snapshot. LAN sends HTTP 500 instead of 200 on failure, and the relay
retains its control object for retry instead of deleting it. Operator Finish also stops with a retryable
message. Headless manifest/relay drivers inject failure and prove rollback, retained controls, successful
retry, and restart recovery. (2026-07-12)

---

## ✅ FIXED (2026-07-12): dismissing the macOS live tag card silently acted as Skip [HIGH]

**FIXED:** interactive dismissal is disabled and the sheet binding no longer translates a nil write into
`skipMacTags`. A live segment is resolved only by the card's explicit Apply or Skip buttons, so Escape,
click-outside, or other dismissal attempts cannot discard typed metadata. Android already used this explicit
action policy; iOS already disabled interactive dismissal. macOS Debug build passes. (2026-07-12)

---

## ✅ FIXED (2026-07-12): controlled subject vocabulary was prompt-only and accepted invented tags [HIGH]

**FIXED:** parsed model subjects now pass through a pure enforcement boundary. With a configured vocabulary,
only case-insensitive, whitespace-trimmed matches survive; output uses the first configured canonical spelling,
deduplicates matches, rejects inventions, and retains the six-tag cap. Empty vocabulary preserves existing
free-form behavior. A standalone pure regression covers canonicalization, duplicates, inventions, blank
vocabulary entries, and free-form compatibility. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android capture thumbnails decoded on the UI thread [MEDIUM]

**FIXED:** each thumbnail now loads through a key-scoped Compose producer and performs file probing plus
downsampled `BitmapFactory` decoding on `Dispatchers.IO`. Removing/replacing an item cancels its producer;
composition only receives the finished `ImageBitmap`. The macOS collection and document review panes were
already using asynchronous thumbnail loaders. Android debug compilation and JVM tests pass. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android Clear raced uploads and manifest saves, then reused item IDs [CRITICAL]

**FIXED:** Clear now gates new captures/persistence, cancels and joins every tracked upload and segment
signal, deletes source files only after those jobs stop, and clears the manifest through the same ordered
persistence worker so a queued old save cannot resurrect it. Item IDs remain monotonic for the ViewModel lifetime, preventing stale
delayed callbacks from matching a new photo. Camera callbacks carry a session-generation token, so a shutter
started before/during Clear cannot populate the new session afterward. Android JVM tests cover that delayed
callback policy in addition to building the lifecycle changes. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android manifest fallback deleted the last good session before replacement [CRITICAL]

**FIXED:** session saves now write and `fsync` a unique temporary sibling, then publish it with replace
semantics (atomic when supported). The fallback never explicitly deletes `session.json`; if publishing fails,
the previous durable manifest remains intact and only the operation-owned temporary file is cleaned up.
Plain-JVM tests inject replacement failure and verify the good manifest survives byte-for-byte. (2026-07-12)

---

## ✅ FIXED (2026-07-12): Android reported zero pending while failed pages were auto-retrying [CRITICAL]

**FIXED:** the phone's status heartbeat now counts every page not yet confirmed `UPLOADED`, including
`FAILED` pages. Those pages are automatically retried every eight seconds, so excluding them could let the
Mac finish a session before the retry arrived. Deferred P10/reclassification resends transition atomically
back to `PENDING`, and one serialized/conflated writer prevents older heartbeat coroutines from arriving
after newer state. Crash restore normalizes a persisted resend marker to `PENDING` before uploaded-page
pruning. Plain-JVM queue-policy tests cover all states, deferred-resend transitions, and the between-saves
restore state, proving the count reaches zero only after required delivery is confirmed. (2026-07-12)

---

## ✅ FIXED (2026-07-12): failed merged-PDF tag transfer still deleted component PDFs [CRITICAL]

**FIXED:** merging now treats a successful, verified tag write as a prerequisite for retiring the
per-page PDFs. If tag reading, writing, coordination, or verification fails, the component PDFs remain,
the source-to-output mappings remain unchanged, and the merged recovery copy is preserved for inspection.
The implicit `Unread` tag is transferred even when generated tags are otherwise empty. Optional JSON is
reserved under the same collision-safe basename and copy-verified before component cleanup. The headless
merge-safety regression injects a tag-write failure and proves the sources remain retryable; its success,
empty-tag, and JSON-only-collision cases prove cleanup occurs only after all required artifacts are durable.
(2026-07-12)

---

## ✅ FIXED (2026-07-12): output generation and organization could overwrite prior files [HIGH]

**FIXED:** normal OCR now reserves against both current-run paths and files already on disk; dual-image
export chooses a distinct destination unless it intentionally reuses the pristine source; collection
organization preflights PDF/JSON/image destinations as a set and advances numbering instead of deleting a
collision. The actual exported-image path is carried through organization, including collision-renamed
images. Standalone destination tests plus the synthetic collection-organization driver cover prior-run PDF,
reserved-path, source-image reuse, JSON-only collision, and artifact alignment. (2026-07-12)

---

## ✅ FIXED (2026-07-12): pre-OCRed review removal deleted the original PDF [CRITICAL]

**FIXED:** pre-OCRed inputs map their source PDF as the output. Both manual and document-segmentation
removal flows previously deleted that mapped URL and its same-basename JSON sidecar. Removal now detaches
source-as-output mappings without deleting them, using a shared conservative file-identity guard with
standalone regression coverage. Cleanup removes only the explicitly tracked output—never an inferred JSON
sidecar—and retains failed cleanup mappings for retry. `OCR/OutputFileSafety.swift`, `OCRProcessor+Tagging.swift`,
`OCRProcessor+ReviewFlows.swift`.

---

## ✅ FIXED (2026-07-08): resolved tag cards re-surfaced after a mid-session Mac restart (B9) [LOW]

> ⚠️ **Amended 2026-07-30 (W23.m7).** "Write the manifest on resolve" below was only half true: the write's
> `Bool` was **discarded**, so a resolve that never reached disk still counted — and live processing was told
> before the write besides. B9's round-trip claim (the manifest *format* carries `resolvedGroupIds`+`macTags`)
> stands; its durability claim did not, and is fixed in the W23.m7 entry at the top of this file.

**FIXED:** `SessionManifest` now also persists `resolvedGroupIds` + `macTags` (both optional → pre-B9
manifests still decode, to empty); `applyMacTags`/`skipMacTags` write the manifest on resolve, and
crash-recovery restore repopulates both — so a mid-session Mac restart no longer re-surfaces an
already-resolved tag card (nor drops its Mac-entered tags), and a resolve interrupted *before* staging now
recovers with its tags instead of being lost. `clear()`/`clearFiled()` keep the three co-dependent sets
(`completedDocGroups`/`resolvedGroupIds`/`macTags`) in sync. Verified: headless `ManifestPersistenceTestDriver`
round-trip + pre-B9 back-compat (13/13 PASS), Tier-2 adversarial review (APPROVE, 0 findings), build clean,
smoke PASS. `Capture/CaptureSession.swift`, `Capture/CaptureModels.swift`. Original report below.

Found by the B4/B5 review (2026-07-08). `CaptureSession` persisted `completedDocGroups` (B5-ii) but NOT
`resolvedGroupIds`, so after a mid-session Mac restart a group already resolved+finalized re-showed its tag
card (`pendingTagGroup`); re-tagging it no-oped on the already-baked staging output (the new tags never
reached it). **Pre-existing root cause** — the same fires at Finish via `completeAllOpenDocGroups`
post-restart; B5-ii merely triggered it mid-session too. **NO data loss / NO double-file** (guarded by
`finalizedGroups.contains` in `segmentResolved`).

---

## ✅ FIXED (2026-07-09): FileRelayReceiver.persistProcessed() return ignored — source deletion on persist failure [HIGH]

**FIXED:** Both call sites (post-ingest and post-tombstone) now check `persistProcessed()`'s return value.
On failure: revert the in-memory `processed` entries, skip receipt-write and source-deletion, and leave the
source objects for retry on the next scan. `ingest` is idempotent on `(group, seq)`, so re-processing is
safe. `Net/FileRelayReceiver.swift`. Found by lean-review (`.maintenance/review/Processor-Net.md`).

**Root cause:** `persistProcessed()` returns `Bool` (false on encode/write failure) but both call sites
(lines 181, 190) discarded the result. If persist failed, the code proceeded to delete the source JPEG +
sidecar — losing track of the ingested photo on restart (the processed-set file didn't record it) while the
source was already gone. Low practical likelihood (local filesystem write to a known-writable directory) but
a **no-undo** data-loss path when it does fire (e.g. disk-full, permission change, sandboxing edge).

---

## ✅ FIXED (2026-07-08, Android UI-fixes batch) — Android capture-screen controls lacked accessibility labels  [LOW — a11y]

**FIXED:** `contentDescription` added to the shutter, captured thumbnails, and Box/Folder/End-segment/Re-pair controls. Landed with the connect-flow dark-mode + layout fixes (compile + review verified; on-device TalkBack confirmation deferred to the device visual check). Original report below.

Found in the 2026-07-08 on-device UI review (Pixel 9). The center shutter button (and the preview/status
controls) have no `contentDescription`, so VoiceOver/TalkBack announces an unlabeled button. No functional or
data impact. Fix: add content descriptions to the shutter + Box/Folder + End-segment + Re-pair controls
(`ArchiveCapture/.../ui/CaptureScreen.kt`). Part of the deferred "accessibility pass".

## ✅ FIXED (2026-07-07): Live "Process live" finalize deleted a run's originals — 0 files moved, sources gone

**Severity: CRITICAL data loss (no undo). Fixed; see the Recovery Core Directive in `CLAUDE.md`.**

**What happened (real run):** A Live-Capture run (LBJ, ~document photos) was shot, OCR'd, tagged, rotation-
reviewed, and the operator named the collection at Finish. Result: the destination collection folder was
**created but empty**, the backup folder held only `manifest.json` = `[]` (zero images), and every source
JPEG was gone. `finalizeSummary` showed "Finalized 1 collection · **0 files moved**" with **no error**.

**Root cause:** `finalize`'s success gate was `outcome.failedMoves == 0`, where `failedMoves` counted only a
real `moveItem` throw (`.failed`). A staged output that was **missing** (its file never existed at move time)
was classified `.absent` — *not* counted. Two facts combined into total loss:
1. `writeSegmentFiles` appended `stagedPDF` to `pdfURLs` **unconditionally**, even when `pdfGen.generate`
   silently failed (`try?`) and wrote nothing — a *phantom* output URL in the manifest.
2. `finalize` computed `filedSources` from **all** of `retained` (i.e. everything *staged*), not from what
   actually reached the destination, and then `clearFiled`-deleted those sources via `removeItem` (bypassing
   the Trash). So when every move was `.absent`: gate passed (`failedMoves == 0`), staging dir deleted, all
   source photos permanently deleted. The intent of the earlier "straggler" guard (below) was right —
   *delete only what was filed* — but it equated "filed" with "staged".

**Fix (this commit):**
- `executePlans` now reports `filedGroupIds` (segments whose **every PDF landed at the destination**, verified
  on disk) + `movedFiles` + `allFiled`. `finalize` deletes a source **only** for a segment in `filedGroupIds`;
  a missing/failed output keeps its source + staged output in the backup folder for retry/recovery.
- `writeSegmentFiles` records a PDF/JSON URL **only if the file exists on disk** (no phantoms). A segment that
  produced no PDF is marked `.failed` (retryable), never silently "staged".
- All post-processing deletions of capture data go to the **Trash** (`CaptureSession.trashOrRemove`), not `rm`.
- Staging moved **into the visible backup folder** (`<session>/_processed/`) so processed PDFs (with tags) are
  recoverable next to the raw sources if the app fails before finalize.
- Regression: `LiveCaptureRecoveryTestDriver` ($0, no OCR, `LIVECAPTURE_RECOVERYTEST=1`) asserts a missing
  output is never reported filed, and that `trashOrRemove` trashes rather than hard-deletes.

**Later (W3.cap-r6, 2026-08-02) — the same straggler, one step downstream.** The guard above keeps a
straggler's *source photo*; it did not keep a straggler's *processed output*. `finalize` reclaimed the whole
staging directory whenever every **planned** segment filed — but `plans` is snapshotted before the
`executePlans` await, so a segment that finished processing during the move wrote fresh output into that same
directory without ever being in `plans`, and `allFiled` (which reports only on the planned segments) stayed
true. That output went to the Trash and its `staged` entry was left pointing there. The gate is now
`stagingSafeToReclaim(allPlannedFiled:segmentsStillStaged:)` — reclaim only when nothing is left staged — so
a survivor keeps the directory, gets the reduced manifest persisted, leaves the session live, and is reported
to the operator ("Finish again"). Recovery driver Test 13 proves the decision, the wiring through the real
`finalize`, and that the happy-path reclaim still happens.

**Recovery note for the original run:** those source JPEGs were `removeItem`'d (Trash bypassed) so they are
**not** recoverable from this Mac. The only surviving copy would be the phone's manual **"Save to phone"**
gallery album (`Pictures/Archive Capture`) *if the operator tapped it* — the phone auto-deletes each page
~650ms after the Mac acks it, so the app's own queue no longer holds them.

---

## ✅ FIXED (2026-07-08): Merged multi-page documents left their exported original images loose in the output dir

**Status:** FIXED (2026-07-08). Found by the OCR-pipeline code review. Was **misplacement, not data
loss** — the images were not deleted, just not moved into the collection folder / renamed.

**Fix (this change):** `exportOriginalImages` now records a `source-URL → per-page exported-image URL`
map (`OCRProcessor.exportedImageMap`) at export time — i.e. BEFORE merge repoints `outputURLMap` to the
single merged PDF — and threads it into `CollectionSegmenter.organizeOutput`. For a merged multi-page
document (several source pages → one PDF) with dual output on, `organizeOutput` now NUMBERS + MOVES each
page image into the collection folder and gives the merged PDF the first image's number, mirroring
`LiveCaptureProcessor.executePlans`'s merged branch. The complete image/PDF/JSON set is now copied to
transaction-owned staging files, byte-verified, and installed without replacement before its sources are
removed; a collision advances the entire numbered set. Non-merged / no-export / crash-resume paths are
unchanged (the merged image branch requires every source page's tracked export; resume paths do not populate
`exportedImageMap`, so they use the empty default). Proven by the `$0` `CollectionOrganizeTestDriver`
(`COLLECTIONORGANIZE_TEST=1`): 17/17 PASS, including the repro (per-page images filed as
`00001`/`00002` inside the collection folder, none left loose in the output root), JSON-only collisions,
missing tracked exports, and the non-merged, no-export, and no-overwrite regressions.

**Repro:** enable *output image file* (`exportOriginals`) **and** *merge documents* **and** collection
organization, then process a multi-page document.

**Root cause:** `exportOriginalImages` runs before merge, so it writes one `<pageBase>.jpg` per source page
(`page1.jpg`, `page2.jpg`, …). Merge then collapses the per-page PDFs into `page1_merged.pdf` and points the
sources' `outputURLMap` at it. In `CollectionSegmenter.organizeOutput`, the merged PDF is moved once (via the
`movedOutputs` dedup) and the sibling-image move searches for `<mergedBase>.jpg` (`page1_merged.jpg`) — which
doesn't exist — so the real page images stayed in the output dir, unmoved and unrenamed.

---

## 1. Live "Process live" rotation review skips segments restored from a legacy staging manifest

**Status:** ✅ **FIXED in code 2026-07-17 (W14.5 — Fix option 1).** `LiveCaptureProcessor.loadStagingManifest()`
now migrates a legacy manifest instead of restoring it verbatim: via the new
`migrateLegacyManifestSegments(_:sourcesPresent:)`, each legacy segment **whose source photos all still exist**
is DROPPED (its stale staged output deleted) so the existing `activate()` resume path re-processes it from
scratch (re-OCR + re-tag → a proper `retained` entry → the end-of-session rotation review now includes it);
the manifest is then rewritten in the current `StagingManifest` format so recovery is idempotent (a crash
before re-finalize won't re-enter the legacy branch). This is exactly Fix option 1 below (cleanest correctness),
and deliberately NOT the "show all staged pages" non-fix (which would regenerate at 0° and un-rotate an
auto-rotated page). **Data-safety guard (Recovery Core Directive):** a legacy segment whose source is *gone*
(e.g. the operator hit Clear before recovering) is KEPT as-is — staged, un-reviewable, filed exactly as today —
because we must never delete regenerable output we can no longer rebuild; the raw sources always remain in the
visible backup folder, so a dropped-but-not-yet-reprocessed segment is fully recoverable. **Tier-2 gate met
unattended:** build clean (0 new warnings) + `LiveCaptureRecoveryTestDriver` ($0, no OCR) asserts the drop /
keep / delete-stale / preserve-unrecoverable behavior (ALL PASS) + adversarial self-review. **Deferred to owner
(Daemon Report):** the full end-to-end verify — stage a session with a real legacy build, recover, Process,
Finish with "Review rotation" on, and confirm every page (incl. the former legacy segments) appears — needs a
legacy manifest + an OCR key to actually reprocess. The "Related, milder" `resolvedGroupIds` sub-issue below is
already independently resolved (it IS persisted + restored now — `CaptureSession.swift`), which is what lets the
resume path re-finalize a dropped document without re-popping its tag card unnecessarily.

The original analysis (kept for context; superseded by the fix above):

**Original status:** deferred (2026-07-03). Low impact, no data loss, transitional. Does NOT recur for
sessions created by the current build.

**Symptom (as reported):** After recovering an unprocessed live session and clicking *Process*, the
end-of-session rotation review showed only 2 of 6 pages — yet **all 6 files were output correctly**.

**Root cause (confirmed in code):**
- `LiveCaptureProcessor.finishSession()` (in `Capture/LiveCaptureProcessor.swift`) builds `rotationReviewPages`
  by iterating `retained.values`. `retained` holds the per-segment inputs needed to
  regenerate a segment (source URLs, `OCRResult` incl. `rotationDegrees`, tags, model, …).
- `retained[groupId]` is written **atomically with every `staged.append(...)`** in `finalizeSegment`,
  so for any segment the current build finalizes, `staged` and `retained` stay in sync.
- The **only** way `staged` can contain a segment with no `retained` entry is `loadStagingManifest()`
  restoring a **legacy-format** staging manifest — a bare `[StagedSegment]` array written
  before retained-persistence (commit `c0312f4`). The new format is `StagingManifest { staged, retained }`;
  the legacy branch restores `staged` + `finalizedGroups` but leaves `retained` empty for those segments.
- Result on recovery of such a session: legacy segments are re-staged/output (they're in `staged`) but
  **excluded from the rotation review** (not in `retained`), while freshly-processed segments appear.

**Impact:** minor. Output is correct — legacy segments keep the rotation that was baked when they were
first staged (auto-detected). The user just can't *manually re-review* those pages' orientation.

**Why not fixed now (the trap):** faithfully regenerating a legacy segment with a corrected rotation
needs its original `rotationDegrees` + OCR text + tags + model. A legacy manifest has none of these.
Reconstructing from `staged` + the segment JSON + `session.groups` still lacks the **original
`rotationDegrees`**, so regenerating a page seeded at 0° would *un-rotate* a page that had been
auto-rotated — strictly worse than today. So a naive "show all staged pages in the review" change is
unsafe unless regeneration is gated.

**Fix options for later:**
1. On legacy-manifest recovery, DROP those segments from `staged`/`finalizedGroups` so they're
   re-processed from scratch (re-OCR + re-tag → proper `retained`). Guarantees a complete review;
   cost = redoes OCR + re-prompts tagging for already-staged segments. Cleanest correctness.
2. Drive `finishSession` from `staged` (authoritative), include legacy segments in the review, but in
   `applyRotationReviewAndFinalize` **skip regeneration for any segment lacking `retained`** (they keep
   their staged output). Review is then complete, but rotating a legacy page does nothing — needs a
   clear UI affordance so it isn't confusing.
3. Persist `rotationDegrees` (and enough to regenerate) in the per-segment staging JSON going forward,
   so any future format gap is recoverable. Doesn't help already-written legacy manifests.

**Related, milder:** on recovery `session.resolvedGroupIds` isn't persisted, so already-staged document
groups can re-pop their tag card. No data harm — `finalizeSegment` guards `!finalizedGroups.contains`,
so re-saving is a no-op — but it's confusing UX. Seeding `resolvedGroupIds` from restored staged groups
in `loadStagingManifest` would fix it.

**Repro (approx):** stage a live session with an older build (legacy manifest) → force a restart so the
session is recovered → *Process* → *Finish session* with "Review rotation" on → review shows only the
segments finalized in the current run.

---

## Live Capture main-window OCR/progress text is stale while the per-segment tag card is open  [LOW — UX]

**Severity: low (cosmetic/UX).** Observed 2026-07-06 (Process-live, Mac): while the per-segment tag card
dialog is open, the left-pane status ("0/1 segments processed", "OCR…") does **not** update — it looked
frozen on "OCR…" for minutes even though OCR had actually completed. It refreshed to "Staged" only after
the tag card was submitted. Harmless (OCR was fine; provider=Gemini, key present, Mac reaches the API),
but it makes OCR look **hung** during tagging and cost real diagnosis time in the walkthrough. Fix: keep
the progress/OCR status live while the tag card is presented (the `@Published` progress updates aren't
re-rendering behind the modal, or the sheet blocks the main-window refresh). `Views/LiveCaptureView.swift`.

**FIXED in code (pending owner GUI-verification).** The Processing status/segment list was extracted into a
dedicated `LiveProcessingBox` view that **owns** the `@ObservedObject` subscription to `LiveCaptureProcessor`
(and `CaptureSession`). Because the child subscribes to `liveProc` directly, SwiftUI invalidates it on each
published phase/progress change even while the parent presents the tag-card sheet — so it no longer freezes
behind the modal. View-only change (`Views/LiveCaptureView.swift`).

---

## Live Capture "Clear" empties the Captured pane but leaves the Processing pane's segments  [LOW — UX]

**Severity: low (cosmetic/UX; no data loss).** Reported by the owner (2026-07-07). In Live Capture, clicking
**Clear** empties the **Captured** pane (the shot photos disappear) but the **Processing** pane's segment
rows **remain** — so the two panes disagree about session state after a Clear. Expected: Clear resets both
panes to empty together. Likely the Clear action resets `CaptureSession`'s received-photos/captured state but
not the `LiveCaptureProcessor`'s staged/segment list that drives the Processing pane; wire Clear to also reset
(or reconcile) the processor's segment state so both panes clear as one. `Views/LiveCaptureView.swift`,
`Capture/LiveCaptureProcessor.swift`, `Capture/CaptureSession.swift`.

**FIXED in code (pending owner GUI-verification).** The Clear button resets the Processing pane's in-memory
segment/staged state together with the Captured pane. It is a **pure in-memory/UI reset** —
no on-disk deletion beyond what `session.clear()` already did (received photos → Trash); any already-staged
`_processed` output stays recoverable in the backup folder, so the Recovery Core Directive is unchanged.

**Superseded shape (`W3.cap-r3-fu11`, 2026-08-04, `fb833ea`/`c903bb8`).** The fix originally landed as two
calls in the button's action — `session.clear(); liveProc.clearSessionState()` — which is a pair that a
refusal can split. It is now ONE model call, `LiveCaptureProcessor.clearSession()`, behind one
`guard !isFinalizing`; `clearSessionState()` is `private` so that is the only way in, and the button carries
`.disabled(liveProc.isFinalizing)`. Reason: in the rotation-review regeneration window the ungated Clear
Trashed the source photos the detached `writeSegmentFiles` was still reading and emptied `staged`/`retained`
under the loop about to index them. Both panes still clear as one — that is exactly what the atomicity buys.
Driver Test 22 covers it (five mutants; `SUITE_TODO_DONE.md`).

---

## Mac doesn't detect a phone-side Re-pair — stale "paired" state, QR must be re-shown manually  [LOW–MED — UX]

**Severity: low–medium (UX / confusion).** The **Re-pair control on the phone works** (returns the phone
to the scanner — verified 2026-07-06). But the phone↔Mac protocol has **no disconnect signal**, so when
the phone re-pairs the Mac keeps its "connected / QR hidden" state; the operator must know to click **Show
QR** to re-display it. The "listening" status dot staying green further reads as "still paired," which
confused the operator into thinking Re-pair hadn't worked. **Fix ideas:** (1) when the phone re-pairs,
have it fire a lightweight `POST /session/disconnect` (or the Mac infers a drop from ping-timeout) so the
Mac auto-re-shows the QR; (2) distinguish "server listening" from "phone connected" in the status UI
(e.g., last-seen heartbeat). Also observed alongside: the **`adb reverse` USB forward is torn down** on
re-pair, so a subsequent **Wired** re-pair needs it re-established (the Mac's `USBBridge` should re-run
`adb reverse` on reconnect; verify it does). `Net/CaptureServer.swift`, `Net/USBBridge.swift`,
`Views/LiveCaptureView.swift`, + both companions' capture screens.

**FIXED in code (B4 — pending owner live-verify).** (i) `POST /session/disconnect` now calls a new
`CaptureSession.phoneDidDisconnect()` (instead of just `unpairDisplay()`), which resets the pairing +
connection indicators (`paired`, `phoneConnected`, `lastPhoneContactAt`, `connectedDeviceName`) and
re-shows the QR automatically; received photos + session state are untouched (they re-upload idempotently).
(ii) The Connection box now splits **"No phone connected" vs "Connected · <device>"** from mere receiver
"Listening (Wi-Fi / USB)"/"Watching Drive" (A5 rows kept), driven by a new `phoneConnected` — a published
liveness flag set on any phone contact (ping / `/phone/status` heartbeat / ingest) and expired by a 5s
freshness timer (25s window) so a stale green dot no longer reads as "still paired." (iii) `USBBridge`
already re-asserts `adb reverse` on a 5s heal timer (so a wired re-pair self-heals); added
`USBBridge.reassertNow()`, fired from `phoneDidDisconnect()`, so it re-asserts immediately instead of
waiting up to 5s. The live re-pair walkthrough (incl. wired) is owner-GUI-gated.

---

## Per-capture streaming — implemented; residual refinements (from the 2026-07-06 Tier-2 review)

Per-capture streaming is now implemented (photos stream to the Mac as shot; End segment sends
`POST /segment/complete` with the tags; Mac gates the tag card on `completedDocGroups`). An adversarial
Tier-2 review confirmed one **critical** data-loss path, now **guarded**, plus refinements. **All of this
needs the on-device Wi-Fi/Run C walkthrough to verify — implemented build-verified only, not yet run on a phone.**

**FIXED (guard shipped): straggler page permanently deleted.** If the tiny `segment/complete` (or
`session/complete`) signal outraced a still-uploading page, the Mac finalized the segment without it, then
`session.clear()` deleted its backup → permanent loss of an irreplaceable page. Guard: `finalize` now calls
`session.clearFiled(filedSourceURLs)` — deletes only pages actually filed into output and **keeps any
un-filed (straggler) page** in the backup folder + Captured pane. No page is ever deleted before it's filed.
(`LiveCaptureProcessor.finalize`, `CaptureSession.clearFiled`.) **⚠️ Update 2026-07-07:** this guard derived
`filedSourceURLs` from `retained[].pages.sourceURL` — i.e. everything *staged*, which is **not** the same as
*filed at the destination*. That gap caused the CRITICAL total-loss bug now fixed at the top of this file
(`finalize` deleted a run's originals). Deletion now keys off `executePlans.filedGroupIds` (confirmed on disk).

**Residual refinements (next session, device-verify):**
1. **Straggler still omitted from finalized output (HIGH, not data-loss).** With the guard a straggler isn't
   lost but isn't auto-filed into its collection either — it lingers unfiled in the Captured pane. Full fix:
   the phone defers `sendSegmentComplete` (and `finishSession`'s `/session/complete`) until **every page of
   the segment is confirmed UPLOADED**, so the Mac never finalizes a partial segment. Both companions (record
   a pending-complete group; flush when all its pages hit UPLOADED, from the upload-success path + auto-retry).
   **FIXED in code (`ce55511`, 2026-07-07; verified + reconciled 2026-07-17 as W14.1 — pending owner device-verify).**
   Both companions record ended-but-unacked segments (`endedSegments`) and emit the completion signal only via
   `trySendSegmentComplete`, which early-returns unless **every page of the group is `UPLOADED`** (Android
   `CaptureViewModel.kt:527` / iOS `:369`) — the sole caller of the transport `segmentComplete(...)`. It's flushed
   from the upload-success handler (Android `:622` / iOS `:456`), the 8s auto-retry loop (Android `:229` / iOS
   `:524`), and reconnect/resume (`:209`/`:508`), so a straggler that finishes late still completes its segment.
   The `session/complete` half is moot on the phone: the transport `sessionComplete()` has **no caller** (the phone
   "Finish" action that once sent it was removed — End segment is the only phone-side "done"), and whole-session
   force-completion is a Mac-side backstop. An adversarial re-read of both companion trees (2026-07-17) could not
   break the gate. **Owner device-verify tail:** `scripts/e2e-phone-mac.sh` (Gemini key + `ap_test36` emulator).
2. **Per-page P10 toggled while a page is UPLOADING never reaches the Mac (MEDIUM).** `toggleP10` re-uploads
   only when `state == UPLOADED`. Fix: a `needsResend` flag the upload-completion handler honors. Both companions.
   **FIXED in code (B5-i — pending owner device-verify):** both companions gained a persisted `needsResend`
   field on `CapturedItem`. `toggleP10`/`reclassifySelected` now call `resendOrEnqueue`: enqueue if idle, else
   set `needsResend`. The upload-completion handler, on success, honors `needsResend` by re-sending with the
   CURRENT fields (and NOT removing the photo) instead of confirming — so a change made mid-upload is never
   dropped. (iOS `Capture/CaptureViewModel.swift`, Android `capture/CaptureViewModel.kt`.)
3. **Reclassify of a doc page whose `/photo` is in-flight is dropped (MEDIUM).** The `inFlightUploads` guard
   suppresses the reclassify re-enqueue. Same `needsResend` fix. Both companions. **FIXED in code (B5-i, same
   `resendOrEnqueue`/`needsResend` path as #2 — pending owner device-verify).**
4. **`completedDocGroups` not persisted across a Mac restart (LOW).** After a mid-session Mac restart, no
   document tag card appears until Finish. Fix: persist it in the manifest, or on restore treat every
   restored document group as complete. **FIXED in code (B5-ii):** the session manifest is now a
   `{photos, completedDocGroups}` object (was a bare `[ManifestEntry]` array); `decodeManifest` accepts both
   shapes so legacy in-flight sessions still recover (completion set empty). `markSegmentComplete`/
   `completeAllOpenDocGroups` persist the set, and restore rehydrates it. Proven headlessly by
   `ManifestPersistenceTestDriver` (`LIVECAPTURE_MANIFESTTEST=1` — round-trip + legacy + corrupt-bytes).

---

## Cloud/relay: reclassify a page whose original document group already finalized → duplicate output  [MEDIUM — relay-amplified]

**Status:** partially mitigated (2026-07-09); post-finalize race remains deferred to Drive milestone.

**Partial fix (2026-07-09):** the `replaces` reclassify chain divergence is fixed — both iOS and Android
now **append** the old group to the existing chain (SPEC A3: `"G,H"` not just `"H"`), and the Mac's HTTP
receiver (`CaptureServer`) now splits the comma-joined chain and tombstones each prior group individually
(matching `FileRelayReceiver`). A chained reclassify G→H→I no longer strands G. The **post-finalize race**
(A11: reclassify after the original group is already staged/finalized → `removePhotoIfSafe` no-ops) remains
deferred — see below.

`removePhotoIfSafe` no-ops when the old group `isFinalized` (`CaptureSession.swift:231`). Over HTTP this is
nearly unreachable (uploads are consumed immediately). With a **relay** (objects persist until the Mac drains
them) the sequence is reachable: a page uploads into group G; the phone's `postPhoto` times out (or its receipt
is swept) before the phone marks it UPLOADED, so it stays on the phone; G finalizes with the page; the operator
then reclassifies the still-held page to a Box → the Mac ingests the new marker but `removePhotoIfSafe(G,seq)`
no-ops (G finalized) → the photo exists in **both** G's collection AND the new marker (duplicate output of an
irreplaceable photo + wrong classification).

**Fix (Drive milestone):** on ingesting a late `replaces=G` object where G isFinalized, reconcile — remove the
reclassified page from G's already-staged output (+ renumber), or refuse the reclassify and signal the phone.
Touches the Tier-2 finalize/staging path + needs a phone-signal channel, hence deferred. For the FileRelay
milestone the Mac logs the collision and does not expand the existing no-op.

---

## Collection pinned in arrival order on relay transport  [MEDIUM — FIXED]

**Status:** FIXED (2026-07-09; **closed end to end 2026-08-02** — see the two amendments below. Both windows
the original fix left open are now shut: a Box arriving mid-finalize, and a correction the rotation review
reverted afterwards.)

On relay transport, network reordering could cause a document to arrive before its Box marker. The Mac
pinned `groupCollectionKey` at arrival time, so such a document was assigned to the *previous* collection
(or `__unfiled__`), then its source photos were trashed at finalize — filed under the wrong box.

**Fix:** `LiveCaptureProcessor.backfillCollections()` — when a Box arrives, re-resolve collection assignments
for all not-yet-finalized groups AND already-staged segments using the phone's capture sequence (`CaptureGroup.order`)
as the source of truth. Also corrects `currentCollectionKey` to the highest-seq box (not the most-recently-arrived).
Persists the corrected manifest so a crash doesn't revert the fix.

**Amended 2026-08-02 (`d67b9cb`, W3.cap-r5).** Those two loops left a gap *between* them. A group enters
`finalizedGroups` the moment `finalizeSegment` starts but only reaches `staged` seconds later, after the
per-page OCR awaits, the LLM tag call and the off-main write — and for that whole window it was skipped by the
first loop (already finalized) *and* invisible to the second (not yet staged). So a Box arriving mid-finalize
could not re-pin it, and the very misfile described above still happened, just in a narrower window. The first
loop now skips only groups already in `staged`, and `finalizeSegment` binds the key it records **after** its
last await instead of at the pin, so a correction made inside the window still reaches the staged record.
Regression cover: recovery-driver Test 15 (`scripts/test-recovery.sh`), which holds the window open with a
gate on the stub OCR and delivers the Box inside it.

**Amended 2026-08-02 (`d719e3f`, W3.cap-r4) — the last window, now shut.** A correction that *did* land could
still be undone afterwards. The collection was recorded in three places: the live `groupCollectionKey` map,
the `staged[]` record, and a third copy on the private `RetainedSegment`. `backfillCollections` corrected the
first two; the third was taken at finalize and never touched again. `applyRotationReviewAndFinalize`
regenerates a straightened segment from those retained inputs and **replaces** the staged record with the
result — so straightening a page in the end-of-session rotation review wrote the pre-correction key straight
back over the corrected one, on the operator's last action before the move, with nothing on screen to say so.
**The retained copy is now deleted rather than synchronised** — the collection was never a write input, so
there is exactly one reader (`liveCollectionKey(for:)`) and nothing left to drift — and regeneration re-reads
the key on the way into `staged`, after its detached write, for the same reason `finalizeSegment` does.
Regression cover: recovery-driver Test 16, the mirror of Test 15, ending on the naming sheet the operator
actually sees; mutation-verified against the real pre-fix commit.

---

## ✅ FIXED (2026-07-09): data race on `MacOSTagger.stampUnread`  [MEDIUM — concurrency]

*(The property itself was deleted 2026-08-01 by W16.cfg6-fu — don't go looking for the symbol. The entry
below is the historical record of how it was made safe while it still existed.)*

**Status:** FIXED. `nonisolated(unsafe) static var stampUnread` was written on `@MainActor` (from
`OCRProcessor.taggingMode.didSet` and `LiveCaptureProcessor.startProcessing`) and read from detached
OCR tasks in `applyTags`. Under Swift 6 strict concurrency the `nonisolated(unsafe)` annotation suppressed
the diagnostic but did not provide a memory-ordering guarantee — the write on MainActor could be invisible
to a reader on another thread, causing a live document to be mis-tagged (e.g., Unread stamp missing or
applied in copy-source mode).

**Fix:** replaced the bare `nonisolated(unsafe) static var` with an `OSAllocatedUnfairLock`-backed computed
property — same `Bool` get/set interface, zero call-site changes. The lock guarantees the MainActor write is
visible to any detached-task reader. (`Tagging/MacOSTagger.swift`.)

---

## ✅ FIXED (2026-07-09): idle-connection leak in `CaptureServer`  [MEDIUM — resource leak]

**Status:** FIXED. `CaptureServer.handle(_:)` started an `NWConnection` and entered the `readRequest` loop,
but if the remote peer never sent data (or sent only partial data and stalled), the connection was never
cancelled — leaking its file descriptor, receive buffers, and associated Network.framework state for the
process lifetime. Over a long Live Capture session with network churn (port scans, half-open TCP connects,
or a phone that opens a connection then loses Wi-Fi), this could accumulate leaked FDs and memory.

**Fix:** added a 30-second idle timeout (`DispatchWorkItem` on the serial `queue`). If no complete HTTP
request arrives within the deadline, the connection is cancelled. The timeout is cancelled on every terminal
path (successful parse, error, too-large, bad request) so well-behaved clients are unaffected. The timeout
work item captures the connection weakly to avoid preventing deallocation. All dispatch happens on the same
serial queue, so there is no race between the timeout and the receive callback.
(`Net/CaptureServer.swift`.)

---

## ✅ FIXED (2026-07-09): review-sweep Tier-A batch — 7 file-safety / data-loss / SPEC fixes  [MED–HIGH]

**Status:** FIXED. Found by the parallel review sweep (`.maintenance/review/sweep-raw-2026-07-09.md`),
each verified against the actual code before fixing. All Tier-2 (adversarial review + build clean).

1. **Merged-PDF overwrite-by-basename** (`OCRProcessor+Tagging.swift:785`): two multi-page segments sharing
   a first-page source basename would overwrite each other's merged PDF (sources already deleted). Fix: name
   the merged PDF after the dedup'd OUTPUT URL, not the raw source.
2. **`try?`-swallowed PDF write error** (`OCRProcessor+OCR.swift:787`): `handleOCRResult` marked a job
   `.succeeded` based on OCR text alone; a failed `PDFGenerator.generate` was invisible. Fix: `do/try/catch`;
   on write failure mark `.failed` + log.
3. **JSON-sidecar wrong-file rename** (`OCRProcessor+Tagging.swift:804`): the merge renamed JSON by the raw
   source basename, not the dedup'd output name — moving the wrong file when output URLs were dedup'd. Fix:
   derive the JSON path from the first output PDF.
4. **`readTags` coerced read-failure → `[]`** (`MacOSTagger.swift:23`): the read→append→rewrite callers
   (priority tags, image tag mirroring) would WIPE existing tags on a read failure. Fix: `readTags` now
   `throws`; callers bail on error instead of writing empty tags.
5. **Raw `applyTags` promoted subject "Red"/"Purple" to Finder color** (`MacOSTagger.swift:64`): the merge
   path called the `[String]` overload without `colorIsAuthoritative`, so a subject tag "Red" was promoted to
   a color label. Fix: derive the authoritative color from the job's classification.
6. **Numeric month/day coercion** (`TagGenerator.swift:263`): `stringField` turned a JSON number `3` into
   the bare string `"3"` — a SPEC-nonconforming month tag. Fix: normalize to "MM Month" / "Day N" format.
7. **Free-text manual date tags** (`ManualTaggingSheet.swift:164`): user-typed bare month/day values were
   written verbatim as Finder tags. Fix: normalize through the same `monthTag`/`dayNumber` helpers.

Files: `OCRProcessor+OCR.swift`, `OCRProcessor+Pipeline.swift`, `OCRProcessor+Tagging.swift`,
`MacOSTagger.swift`, `TagGenerator.swift`.

---

## ✅ FIXED (2026-07-09): data race on `CaptureServer.listener` between `stop()` and `retryWithSystemPort()`  [HIGH — concurrency]

**Status:** FIXED. The class comment claimed `listener` is "only touched on the serial `queue`," but
`start()` and `stop()` accessed it directly from whatever thread called them (typically `@MainActor` via
`CaptureSession`), while `retryWithSystemPort()` ran on `self.queue` from the NWListener state callback.
A MainActor call to `stop()` concurrent with a queue-dispatched `retryWithSystemPort()` was an unsynchronized
read/write on the same mutable property.

**Fix:** `start()` and `stop()` now dispatch their `listener` access onto `self.queue`, making the class
comment true — all `listener` reads and writes serialize on the single serial queue. Both methods are
fire-and-forget from the caller's perspective (no return value, no completion), so the async dispatch is
transparent. (`Net/CaptureServer.swift`.)

---

## ✅ FIXED (2026-07-09): iOS/file relay segmentComplete/sessionComplete return true without confirming write  [HIGH — silent tag loss]

**Status:** FIXED. Both `DriveRelayTransport` and `FileRelayTransport` returned `true` from
`segmentComplete()` and `sessionComplete()` immediately after writing, without checking whether the
write succeeded. The underlying `upsert` (Drive) and `writeAtomic` (file) swallowed all errors via
`try?`. The caller (`CaptureViewModel.trySendSegmentComplete`) removes the group from `endedSegments`
on `true`, stopping all retries — so a silently-failed write meant the Mac never received the
segment-complete signal, and the document's tags were permanently lost.

Contrast with `postPhoto`, which correctly gates `true` on a Mac-written receipt (receipt-wait loop).

**Fix:** `writeAtomic` and `upsert` now `throw` instead of silently swallowing errors.
`segmentComplete` and `sessionComplete` wrap the write in `do/try/catch` and return `false` on
failure — triggering the caller's 3-attempt retry. `postPhoto` callers use `try?` on the write
(receipt-wait is the true confirmation). (`Net/FileRelayTransport.swift`, `Net/DriveRelayTransport.swift`.)

---

## ✅ FIXED (2026-07-09): iOS `accessTokenBlocking()` deadlock risk + unbounded semaphore wait  [HIGH — concurrency]

**Status:** FIXED. `DriveAuth.accessTokenBlocking()` used `DispatchSemaphore.wait()` with no timeout,
bridging to a `Task { @MainActor in }` for token refresh. Two bugs: (1) if called from the main thread
(e.g., a future call-site mistake), the semaphore blocks the main thread while the `@MainActor` Task
needs the main thread to run — instant deadlock; (2) if the Google token endpoint is unreachable or
stalls, the semaphore waits forever, hanging the upload thread permanently.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** added `dispatchPrecondition(condition: .notOnQueue(.main))` to trap immediately if called from
the main thread (instead of silently deadlocking), and changed `sem.wait()` to
`sem.wait(timeout: .now() + 65)` with a `DriveError.tokenRefreshTimedOut` throw on timeout — matching
the Android `CountDownLatch.await(30, SECONDS)` pattern and the macOS `DriveClient` semaphore timeout
(W3.n4). (`Net/DriveAuth.swift`, `Net/DriveClient.swift`.)

---

## ✅ FIXED (2026-07-09): iOS deleteItem has no upload-state guard — un-uploaded photos irrecoverably lost  [HIGH — data loss]

**Status:** FIXED. `CaptureViewModel.deleteItem()` unconditionally deleted the local JPEG and removed the
item from the model, regardless of upload state. If a photo was `.pending`, `.uploading`, or `.failed`
(never confirmed on the Mac), the tap-to-delete cycle (select → arm → delete) permanently destroyed it
with no confirmation and no recovery path.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** `deleteItem` now checks `items[i].state`: if `.uploaded`, delete immediately (the Mac has it);
otherwise, set `pendingDeleteId` to trigger a destructive confirmation dialog ("This photo hasn't reached
the Mac yet. Deleting it here loses it forever."). The user must explicitly confirm before an un-uploaded
photo is removed. (`Capture/CaptureViewModel.swift`, `UI/CaptureScreen.swift`.)

---

## ✅ FIXED (2026-07-09): iOS clearSession confirmation doesn't distinguish uploaded from un-uploaded photos  [MED — data loss risk]

**Status:** FIXED. The "Clear all photos?" confirmation dialog showed a generic message regardless of
whether any photos had NOT been uploaded to the Mac. A user could tap Clear thinking everything was
safely on the Mac when `.pending`/`.failed` items still existed only on the phone.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** The confirmation message now branches: if all items are `.uploaded`, it says "All photos have
been uploaded to the Mac"; otherwise it warns with the exact count of un-uploaded photos that will be
permanently lost. (`UI/CaptureScreen.swift`.)

---

## ✅ FIXED (2026-07-09): DriveRelayTransport epoch cached, not re-read per iteration  [MED — correctness]

**Status:** FIXED. `DriveRelayTransport.postPhoto` resolved the Mac-published epoch once
(`if ep == nil { ep = epoch(f) }`) and cached it for the entire receipt-wait loop. If the Mac
restarted mid-transfer with a new epoch, the phone kept using the stale value — receipts (which carry
the new epoch) would never match, and sidecars were written with the wrong epoch. The photo would time
out and retry, but the retry re-entered the same `postPhoto` call with a fresh `ep = nil`, so it
would eventually recover — but only after a full 20s timeout per photo per Mac restart.

By contrast, `FileRelayTransport` correctly calls `currentEpoch()` every iteration and tracks
`wroteForEpoch` to re-write the sidecar if the epoch changes mid-loop.

Same bug existed in the Android Kotlin mirror.

Found by the iOS companion lean-review (`.maintenance/review/iOS-companion.md`).

**Fix:** Both iOS and Android `DriveRelayTransport.postPhoto` now re-read `epoch(f)` every iteration
(matching `FileRelayTransport`), and use `wroteForEpoch` (string, not bool) so the sidecar is
re-written with the correct epoch if it changes mid-loop.
(`Net/DriveRelayTransport.swift`, `net/DriveRelayTransport.kt`.)
