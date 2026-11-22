# 14. The owner's calls, Phase 4 (2026-11-06, interactive)

Walked one at a time in the owner-started session, after the twelve rule notes were drafted. Calls the figures settle,
and technical picks taken on the notes' recommendations, are listed in section 2 for the owner's veto; the owner's own
calls are section 1.

## 1. The owner's calls

1. **Where a collection's settings live.** Beside the collection's output folder, as the design proposed (§3.5), written
   by the Processor from the settings build; the general layer in the app's own store; resolved settings frozen into each
   run's record. The Reader and Notes reading the document is filed as its own item behind the settings build, not part
   of it.
2. **The two limits the design dropped from the integration plan.** A per-batch switch "this batch stays on the Mac"
   is added, hiding every route that leaves the Mac (for sensitive material; without it a user with keys for other work
   would have to remove them or override every card). No quality floor: the preference stands in for it, and each stage
   card names what a better figure would need. Integration plan decision 4 is superseded accordingly.
3. **What a user who skips both interviews gets.** "Free, on this Mac", always: detected keys and plans are shown on the
   sheet but nothing is spent until the user picks a route or a starting point (the design's §3.7 proposal to fill "A few
   dollars, overnight" when a key is detected is not taken). Default priority order reading, finding documents, dates,
   names (stage weights 45/30/15/10, the prototype's); the mixed-page switch off until its time cost is measured like
   for like (P11-4).
4. **The free default's reader per kind (note 04, call 7.1).** Typed and printed pages read at once with Apple Vision.
   Handwritten pages: on a 16 GB Mac the sheet proposes LightOnOCR-3 4B 8-bit as a download; a user who declines, or a
   smaller Mac, gets them flagged "needs a download or a key" rather than read at about 60. A page Vision returns empty
   for is flagged, never skipped, on every profile.
5. **The failure cascade (notes 04 call 7.2 and 10 call 2).** A route like any other: each measured cascade is a row
   with its own figures on the reading chart, and the solver picks it when it beats the single routes within the user's
   limits. No separate on/off default; failure is the only trigger; the Vision word-count trigger stays opt-in. Note 04's
   "on whenever a second route exists" and note 10's "no default beyond off" are both superseded by this.
6. **What may touch the reading copy (notes 01 calls 2-3, 02 C2, 05 call 2, 06 call 3).** Straightening (deskew above
   a 1 degree median line angle) on by default, switchable off. Dewarping is not offered: UVDoc removes content (900 of
   15,067 lines on Real5; a loss on the owner's pages), and no per-page guard exists; a guarded dewarp is filed to revisit.
   Shading division is not offered for viewing: it greys coloured marks by about a fifth and helps no reader. Note 06's
   "may be offered for viewing" is withdrawn.
7. **The training kit's scope in this release (notes 12 calls 7.1 and 7.4, 07 call 1).** The cluster kit ships: the
   student from the user's tags, and the continuation once 200 corrected gaps of one material exist ("adaptation after
   about 200 corrections, flagging kept on", labelled measured on one material), every model past the gate; the Mac step
   (W46.kit-mac-build) before it ships. No Mac segmentation LoRA (not measured to fit). Amended by the owner,
   2026-11-17 (review of the pipeline doc): the handwriting fine-tune does not ship. No line-correction screen and no
   kraken PP-OCRv6 fine-tune per hand; `W46.kit-hands` is dropped. The cluster segmentation kit and the continuation
   still ship. (Was, 2026-11-06: the fine-tune ships, offered from 80 corrected lines with 160 as the target, on the
   handwritten kind, with a line-correction screen built in this release.)
8. **The Gemini 3.8 Flash offsets on the personal key, about $2.60 (note 07 call 4; pass 7).** Declined. No personal-key
   spend; Gemini 3.8 Flash stays the app's segmentation default, and its card shows Gemini 3.7's measured range labelled
   as 3.7's, with the single 3.8 run shown as a single run. The Sasha lead over the 2B stands on the 3.7 card only.
9. **How a non-explicit date appears (note 08 calls 7.1, 7.2, 7.6).** Second-role dates (received stamps, postmarks,
   filing dates) go in the document's JSON sidecar with role, quote and place, never as a second bare year; no SPEC
   change. Every non-explicit date shows its evidence class and the cited quote with its place; the 90% conformal
   interval appears only on routes where it was measured, in the sidecar and the PDF header. An estimate that fails the
   evidence check is not shown at all until the checker's false refusals are fixed (item 8.3).
10. **The names the tagging prompt writes (note 09 calls 1 and 6).** Both provisional rules (person-only sender,
    heading-or-address place; 4cdbba41, 4374254d) move to the entity feature's own prompt and the tagging prompt is
    reverted to its pre-November name behaviour; the entity feature decides them with its own measured prompt. A name the
    page does not show may be written when marked inferred, as Date Uncertain is accepted for years.
11. **When entities run, and the export (note 09 calls 3 and 4).** On a cloud route names are extracted always (they
    come with the call at no cost) and shown when the collection interview ranks names; on the Mac the local extractor
    runs only when names are ranked, on typed and printed correspondence, the sender never taken from Vision text
    (ent-robust rule), the 4B not offered. No export format until a user asks; CMIF against CSV goes to
    POTENTIAL_FEATURES, not the queue.
    Changed at the walkthrough of 2026-11-13 (W46.ent-feature-owner-calls): on a cloud route too, names are extracted
    only when the collection interview ranks them, since the feature became its own call ($2.37 per 1,000
    correspondence documents) and nothing reads unshown names; and where the feature does not run on Apple Vision
    text, the sidecar leaves out the tagging call's sender as well.

12. **The owner's calls of 2026-11-17 (review of the pipeline doc).** Call 7 amended above (no handwriting fine-tune).
    Handwriting placement: every handwritten page gets a separate text page, and the placed layer stays on the image
    only where alignment confidence is 0.9 or more (note 05; built in W46.place-hands-textpage, 663cee4b). Licences: no
    model is excluded on its licence alone; AGPL, GPL and non-commercial models may be offered as separate optional
    downloads with their licence shown, nothing GPL or AGPL linked or bundled into the app, the app's own code MIT
    (`00-plan.md`). Model families: versions within one family (e.g. Gemini 3.7 and 3.8 Flash) count as one unless a
    pick depends on the difference; no further same-family comparisons are filed.

13. **Withholding for a quality floor (2026-11-18).** No feature, field or route is withheld, dropped or left unoffered
    because a measurement falls short of a fill rule, threshold or baseline without the owner's confirmation; the session
    asks with the figures and what the user would lose. Authority: the repo `CLAUDE.md`, "Withholding a feature for a
    quality floor". The withholdings already made are listed in `../16-withheld-review.md` (W47.withheld-review, 24
    entries); his answers are recorded here by `W47.withheld-calls`.

14. **The segmentation rerun floor (2026-11-18).** Two segmentation routes tie when the paired interval holds 0, as
    before; the students' 3.2-point rerun floor (SEG-10) is reported beside it as `tie_floor` and does not decide a
    pick, so the five picks it would move to the 2B stay as they are (W46.p16-seg-floor-apply; seg-pair-ties.md).

15. **The features withheld before call 13 (2026-11-19, the withheld-review sheet; W47.withheld-calls).** The owner
    answered all 24 entries of `../16-withheld-review.md`; the figures and files are there. These are now his calls,
    and where one overlaps a session decision in section 2, this governs. Work filed: `SUITE_TODO.md` §"The withheld
    features".
    - **Released as measured (4).** The read-poorly flag for readers other than Apple Vision, with his note
      "Shouldn't we also do this for other readers like Gemini?" (W47.wh-read-flag-readers: LightOnOCR's flag ships,
      each other reader gets its own cut or a question). DocLayout-YOLO's newspaper-ocr route as a detector for
      scanned newspapers (W47.wh-yolo-scans). Whole-page reading of newspapers for large readers
      (W47.wh-whole-page-large). The readers that scored below what ships (Apple's on-device model, Azure, Textract,
      Transkribus, the fifteen dominated routes): "Our findings are only based on our tests and our corpus. The user
      may have reason to want to use a different model, based on their corpus and their own knowledge of model
      capabilities." (W47.wh-readers-lost).
    - **Released with a label (5).** ATRIUM as the mixed-page pre-flag, call 3 re-asked once it is built
      (W47.wh-mixed-preflag). Trained segmentation models under the kit gate's minimums, labelled "small held-out
      set" (W47.wh-kit-minimums). The image-grounded post-correction stage (W47.wh-post-correction). The Mac
      Qwen3-VL 8B image pass for dating, labelled "no measured gain" (W47.wh-date-8b-image). Names on Macs too small
      for the 8B and on pre-modern material, marked low confidence (W47.wh-names-small-mac).
    - **An Advanced level.** On the 8B image pass: "We'll likely need to revise the Settings panel in Processor.
      Things like this should be in an Advanced panel or similar. The whole panel likely needs to be broken out into
      multiple panels and also into multiple levels depending on user sophistication." On small-Mac names: "Again
      this should only go in Advanced settings or similar." Filed as W47.settings-levels, a design put to him before
      it is built; the readers that lost, the 8B image pass and the low-confidence names wait for it.
    - **Ask again after the named work (7).** DocRes cleaning on glare pages, "Put this in Nice to Have"
      (W46.enh-small-reader-power). The magazine figure for the older prompts and the students (W47.wh-seg-magazine).
      The 8,000-character entity prompt (W47.wh-ent-8k-paired). Routing by kind under the classifier's 0.8 floor
      (W47.wh-kinds-floor). The phone's retake warning, "Keep this in Nice to Have." (W46.capture-warning). Item
      fields off the remote gateway: "This should be tested not only with Vision but with other models that can run
      on the Mac." (W47.wh-item-fields-mac). Cascade triggers other than failure, "Put this in Nice to Have"
      (W47.wh-cascade-disagree); call 5 stands meanwhile.
    - **Kept withheld (8), each now the owner's call.** The half-size retry when a cluster reader loops (351 of 1,573
      looped pages answered, at 4.2-11.0 NES). Cleaning the image before reading (no method gained on any reader on
      the 63 originals and the 96; Vision with SBB -6.4). Rotation without Apple Vision (Tesseract 62.7%, Qwen3-VL 8B
      78.1% of turns; PP-LCNet alone flips 73 of 80 Hebrew turns). Layout regions off newspapers (-3.9 on the 96,
      -15.3 on 16 hand pages, -10.8 on 80 registers). The other line layers (Orli a tie at -4.6; Vision's
      document-request lines -10.8). A stamps and signatures layer (8 of 45 marks found, precision 42-53%);
      W46.marks-detect-own stays behind nice-to-have. The segmentation options that did not help (split and feature
      models 27.1% unchecked against the 2B's 79.4%; few-shot no gain at 1.43-2.01 times the tokens). The dating
      options below the baseline (trained 2B and 4B 38.9% against 47.3%; typeface ranges 50 years wide; retrieval 27
      of 122 against 52; enclosure 0 of 3; entity links 2 of 54).
    - **His general note, "Look into it"**, answers the sheet's closing point: call 9 hides an estimate that fails the
      evidence check until item 8.3 fixes the checker, and 8.3 shipped on 11 November (W47.wh-date-evidence-shown).
16. **The settings design, failed date estimates and the kind floor (2026-11-19, walkthrough of 10:39).**
    - **Settings (W47.settings-levels-owner-ok).** The design in `../settings-design/levels.md` is approved as
      written: eight panels and three levels (Basic, Standard, Advanced); all twelve control groups listed there move
      to Advanced; trained segmentation models under the kit minimums and the post-correction stage both sit at
      Advanced; a new user starts at Basic.
    - **Date estimates that fail the evidence check (W47.wh-date-suggest-owner-ok).** Keep them hidden: call 9
      stands now that its condition is met, and W47.wh-date-suggest is declined and not built
      (`ArchiveProcessor/segbench-results/date-failed-estimates.md`).
    - **Routing by kind under the classifier's 0.8 floor (W47.wh-kinds-floor).** Keep the floor as it is: no routing
      of unsure pages by their top class, and no document prior (`segbench-results/kind-floor.md`: a tie for every
      run model, the gain resting on two pages).
17. **The read-poorly flag for Claude Sonnet 5.5 and Mistral OCR (2026-11-19, walkthrough of 12:20;
    W47.wh-read-flag-cm-owner-ok).** Leave both unflagged. Their cuts hold the 5% false-alarm ceiling on the 96 but
    caught none of their poor readings (0 of 2, 0 of 7), so a flag would only be false alarms on about 4% of good
    pages (`ArchiveProcessor/segbench-results/post-read-flag.md`). W47.wh-read-flag-cm is declined and not built.
18. **The entity call's window (2026-11-19, walkthrough of 14:50; W47.wh-ent-8k-apply-owner-ok).** Move
    EntityExtractor from the first 3,000 characters of a letter to the first 8,000. Paired and replicated on the 138
    correspondence documents (Gemini 3.8 Flash), the sender rises 0.70 to 0.81 (+0.107, 95% +0.038 to +0.189), all on
    the 48 letters past 3,000 characters; recipient and place tie; +$0.55 per 1,000 letters
    (`ArchiveProcessor/segbench-results/ent-8k-paired.md`). W47.wh-ent-8k-apply builds it.
19. **The ChatGPT plan route against OpenAI's real servers (2026-11-19, walkthrough of 16:07;
    W49.proc-chatgpt-real-signin-owner-ok).** Yes: the owner signs in once with a real ChatGPT account in the Processor's
    own Sign in with ChatGPT (the Codex login does not carry over: the route registers its own client id) after the
    plan's weekly reset on Sat 21 Nov 13:25, since a request on the spent week could not be told from a real failure.
    W49.proc-chatgpt-real-signin then runs one real segmentation window and fixes what fails. Reason: the suite is
    for other users, and one with only a ChatGPT plan would take this route.
20. **Notes keeps what is typed (2026-11-19, after the walkthrough of 16:07; W49.notes-keep-blank-lines).** The four
    blank-line and empty-list losses W40.fix-notes-editor-lines accepted as "Markdown has no form for it" were the
    session's trade-off, not a limit: Markdown can hold them (`&nbsp;` paragraphs, a bare `-` item) at the cost of
    some clutter in the raw file. The owner chose fidelity to what is typed over a tidier file.
21. **The accepted-issues sheet (2026-11-19, after the walkthrough; W49.accepted-review-owner-ok).** Of 31 items,
    17 answered: change all 14 recommended changes; change four the sheet recommended keeping (Improve OCR on
    searchable files, compressing the image-and-text pair at a handwriting-fit quality, PDF pages in the kind sample,
    aligned Find pairing, and Set for Selection without arbitrary limits); check the sender row first. His notes set
    three more: refuse encrypted and signed files only for Improve OCR; do the three settings rules properly; a
    changed folder date updates the dates it gave that nothing else has changed or confirmed. Two design notes are
    queued: preservation copies under lossy compression, and how Notes stores its material (folder, bundle or
    package). The rest are answered in the session that folded the sheet. Answers:
    `answers/17-accepted-review-answers-20261119.json`; the items are filed under `W49.` in SUITE_TODO.md.
22. **The accepted-issues sheet, round two (2026-11-19; W49.accepted-review-owner-ok).** All six changes as
    suggested: Intel compression tools and hidden Apple-silicon-only downloads (behind nice-to-have, his note), the
    read-poorly flag's four wiring cases plus a newspaper measurement, OpenRouter rotation, undo surviving a crash,
    the Containers facets as a searchable narrowed list, and unclashable pasted-image names. His note on images
    outside a note's assets folder: copy them in automatically wherever Notes can read them. Re-tagging labels waits
    on W49.corpus-specific-audit (his 2026-11-19 ask to move corpus-only code into a one-time migration).
23. **Item fields on the Mac's own models (2026-11-19, walkthrough of 21:58; W47.wh-item-fields-mac).** Use them,
    though none clears the fill rule (point 0.90, lower bound 0.85): byline 0.89 [0.74, 0.96] and kind 0.86 [0.74, 0.92]
    from Qwen3-VL 8B on images, publication date 0.89 [0.69, 0.95] from Qwen3.5 4B on Vision text, on his checked
    values. On by default for Mac and Local Agent users, each value marked lower confidence; the other three fields
    stay empty. W47.wh-item-fields-mac-fill builds it. The bar itself is unchanged for other routes.
24. **The walkthrough of 2026-11-20 06:07.** The two model downloads he released in call 15 (the scanned-newspaper
    detector, the mixed-page pre-flag) uploaded to models-1 at his yes. Sender, Recipient and Sending place in the
    Reader's Inspector, editable and checkable like the other item fields ("Can't all fields like this be checked and
    updated by the user?"; W49.reader-sender-row-check). Notes stores a visible .archivenotes library package, plus
    the "inside an archive?" question (W49.notes-store-format). Folder dates: the earlier middle year of an even span
    stays; a mid-point year shows Date Uncertain alone, without its figure; a stamp's year on the page beats the
    folder's, since "the folder year should only be used when we don't otherwise know the date of a document"
    (W46.folder-date-midpoint-call, W49.folder-date-stamp-first). Item-field corrections on a Processor re-run and
    through renames: not answered as asked; he questioned whether fields users are expected to correct belong on
    page 2 at all (W49.item-fields-home, a design note that both wait on). "Read handwriting on typed pages" on by
    default, with or without the pre-flag (call 3 answered; W47.wh-mixed-preflag-default). The read-poorly flag off
    for the five readers that catch nothing the app can see (W46.p17-flag-unflag-five); refused readings stay with the
    refusal second reader and the failed-page retry. Backlog: Vision OCR's Zotero library sweep moved here behind
    nice-to-have (W49.zotero-library-sweep); the bench's remaining kind prices and reproduce attempts for suspects
    S-004 and S-005 queued; the rest kept as wishes or as earlier calls left them.
25. **After the walkthrough of 2026-11-20.** Azure Document Intelligence, AWS Textract and Transkribus are left out of
    the lower-scoring readers: no clients, no Transkribus upload ("It would be a bit much to build whole clients just
    for these inadequate readers"). Their bench scores stay; Textract's $1.35 was already spent. The Reader's rule
    against changing PDFs is open to change ("Maybe we should be less adamant about Reader never changing PDFs given
    how much the app has developed"): W49.item-fields-home weighs it.
    The handwriting placer (hands.tgz) uploaded to models-1 at his yes; fuzzy OCR search in the Reader queued behind
    nice-to-have (W49.reader-fuzzy-search).
26. **File names and where facts are stored (2026-11-20).** Filed names stay simple and unchanging (the collection name
    and a sequence number, as in his corpus), now with six digits (W49.proc-six-digit-names; nothing already filed is
    renamed). The many places dates are saved look like an artifact of development: survey them and similar facts
    and propose one home each (W49.storage-simplify-audit, which W49.item-fields-home now waits on).
27. **The walkthrough of 2026-11-20 08:05.** No open questions. Backlog: resuming an interrupted standard Files run
    queued (W49.proc-resume-standard-runs); reproduce attempts for suspects S-006 and S-007 queued
    (W49.notes-s006-reproduce, W49.notes-s007-reproduce); the Gemini dated-set run and the OpenRouter JPEG panels stay
    deferred; the NewsBench chart behind nice-to-have and the segmentation checking chart conditional on the table;
    the CMIF export, cloud drives, creation-date mirror, a shared Notes and Reader window and a richer Markdown editor
    kept as wishes. The Sherlock family-coverage batch (submitted 2026-11-17) was still pending on priority, with
    nothing failed; it is collected after it runs. Revisited the same morning: the Notes editor's undo across the ⌘/
    switch queued (W49.notes-undo-across-toggle) and its missing constructs behind nice-to-have, with the question of
    what can be borrowed (W49.notes-editor-constructs); the CMIF export stays parked on his 2026-11-06 call.
    The entries settled without him that morning were then put to him one at a time (his new rule: only an earlier
    call or a stale record settles an entry): S-006 and S-007's reproduce attempts stay queued; cloud-drive support
    behind nice-to-have (W49.reader-cloud-drives), and "warn users at first launch that material must not be in a
    cloud drive" (W49.cloud-drive-first-launch-warning); the creation-date mirror declined; Notes and the Reader stay
    separate apps; the NewsBench chart and the segmentation checking chart behind nice-to-have (W49.bench-news-chart,
    W49.bench-seg-check-chart). From Vision OCR, which merges into the Processor: symbol-mode JBIG2 is never used,
    as his rule (the Xerox digit-swap mechanism; this carries over to the Processor's PDF writing), and `--roi`
    region selection is dropped.
    Then an audit of the two earlier walkthroughs' Backlog entries (2026-11-19 21:58, 2026-11-20 06:07) found 15
    settled without him, some recorded as his. Put to him one at a time: OCR confidence scoring and the side-by-side
    view stay deleted (the read-poorly flag and the Reader's panes cover them); the suite-wide storage path moves from
    W49.notes-store-format into W49.storage-simplify-audit, with several Reader roots; the reproduce attempts for
    S-002 to S-005 and W49.bench-kind-price-rest stay queued; charts for clippings and tables, the processing queue
    (after W49.proc-resume-standard-runs) and undo across the review dialogs go behind nice-to-have
    (W49.bench-more-kinds, W49.proc-run-queue, W49.proc-review-undo); refreshing an extract from its source is
    declined. Sonnet's measured price and the per-kind prices had already shipped ($0). The rest of those two
    walkthroughs' entries were settled by earlier calls of his or were his own answers.
28. **The Backlog review sheet (2026-11-20).** Every backlog entry no walkthrough had shown him, 68 in all, on one
    sheet (`18-backlog-review.json`; he asked for it, with the bugs batched). Suspected bugs: the three seen in real runs
    get fixes with the run as their test (W49.proc-fix-s040, -s041, -s042); the 27 found by reading the code are
    reproduced only under a new strict rule, phase rule 5a, because "LLM reviews can produce ghost bugs which then
    produce more ghost bugs" (six W49.*-suspects-* items). Wishlists: 13 entries closed as built or covered, five July
    ideas and Tropy declined, Vision language detection and Zotero page links queued, table CSV export, neighbour-informed
    subjects, Shortcuts actions, Notes block identities and merged-PDF scrolling behind nice-to-have, the bench page kept
    private. Releasing: the Mac route is decided when a public release is near, and store publishing for the phones waits
    on it. Paid runs: Azure and Textract on the public 895 declined; the two others stay with his 17 Oct hold. Vision
    OCR's visible-text debugging mode declined.
29. **The walkthrough of 2026-11-20 13:42.** Storage (W49.storage-one-home-owner-ok): none of A, B or C. He leans
    toward the sidecar over the Finder-tag scheme ("easily transferrable to other apps but it doesn't need to be
    directly readable by other apps"), wants tag and page-2 facts shown as specific Reader fields, and asks for a
    deeper analysis first: page 2 against sidecar, whether a sidecar is right at all, and user toggles for Spotlight and
    Finder tags (W49.storage-model-analysis; the gate waits on it). S-014: a Notes link whose root was moved or renamed in
    session asks for the folder or says the search could not finish, never "not found". Backlog: S-043 and S-044
    reproduced under phase rule 5a (W49.notes-s043-reproduce, W49.proc-s044-reproduce). Sherlock family-coverage batch
    still pending on priority (11 GPU jobs, fair-share 0.32; 11 public nodes have 48 or 80 GB cards), nothing failed.

30. **The walkthrough of 2026-11-21, begun 08:46.** Reader cloud-only PDFs: match Notes, showing "This PDF is in
    the cloud" with **Download and Show** before materializing an explicitly opened PDF. Selection, thumbnails and
    neighbor prefetch do not download. S-002's independent check still precedes the fix. Resume (S-035 and S-050):
    **skip only reviews the user already explicitly skipped; otherwise show the applicable reviews**, for paid
    batch and ordinary interrupted runs. Resume alone is not permission to omit reviews. Collection ID (S-034):
    keep Box/Folder label markers under No tagging and Copy source tags, **preserve every copied source tag**, and
    explain the exception in the SPEC with the fix. S-034/S-035 fixes still await W49.proc-suspects-filing-check.
    Backlog S-045 through S-053: queue verification; **all future bug suspects are automatically queued for
    verification without individual owner review**. Phase rule 5a and owner questions about intended behavior
    remain. New verification tags: W49.proc-s045-verify through W49.proc-s053-verify. No feature wish was approved
    by this blanket instruction. The new storage analysis f1adc8af arrived after this walkthrough's digest;
    W49.storage-one-home-owner-ok remains unanswered. Sherlock checked at about 09:03: setup 52765234 completed
    successfully in 10:10; all eleven GPU jobs still pending, six on priority/resources and five on dependencies;
    no failed job and no scheduler start estimate. Nothing resubmitted.
    Disk cleanup: 11 MB of rebuildable uv downloads moved to Trash; available space including purgeable
    measured 100.1 GiB before and after. Both retired worktrees remain for unfinished items; rehearsal,
    model and dewarp inputs remain for open work. No backup handoff prepared.

31. **Walkthrough follow-up, 2026-11-21.** Catalogue storage remains open. Compare filesystem metadata and
    other external stores before choosing a durable home for corrections. Preservation (2A): keep the exact,
    full-resolution intake original in a visible Preservation folder by default. Make this a prominent initial
    Processor interview choice, with an explicit opt-out and an explanation of extra space and PDF-only sharing.
    Adoption (3A): put the archive-specific colour rules, named PDF/JPEG pairing and old-label backfill in one
    scratch-first adoption tool. Keep the classifier optional with a time and cost preview. Plan an LLM-assisted
    migration kit for other users' existing personal repositories behind W46.nice-to-have. S-046 (4B): fresh
    Process Files document review is on by default and the user can turn it off. Off skips the whole-run page
    review before tagging. Independent confirmation still precedes the fix, and the separate Resume decision
    remains in call 30.

32. **Catalogue storage decision, 2026-11-21.** Choose 1A (S in the storage plan). One adjacent JSON
    companion per PDF is the authoritative record for current catalogue fields, including Reader corrections.
    Reader saves catalogue changes to the companion. A full transfer uses the PDF and its companion or a Suite
    export. The existing optional Processor segment JSON remains a distinct output. Finder and Spotlight
    defaults and any migration of the real archive remain separate decisions.

33. **Enclosure cover selection (S-047), 2026-11-21.** When window segmentation splits the
    covering letter proposed by OCR and drops the enclosure relation, offer an optional choice in
    document review to identify the actual covering document. Use that document's final date as
    Sent With and preserve the enclosure's own date. Leaving the choice blank keeps the relation
    and Sent With unset. Never infer the cover from adjacency. File implementation after the
    independent reproduction in W49.proc-s047-check.

34. **Walkthrough of 2026-11-22, begun 08:17 Pacific.** Drop the Improve OCR safeguard that
    retains stale hidden search text to preserve the previous scan page's presentation. Queue the additional
    coverage in W49.proc-reocr-searchable. When a matching full-resolution Preservation Copy exists, use it
    as the OCR input for that document page. W49.proc-reocr-preservation follows the verified source map
    from W49.preservation-copies-build. Queue improved tracking of paid requests as they happen, including
    Live Capture, in W49.proc-ledger-track-paid. The owner opted in to recording, marking and publishing the
    tracker update.

## 2. Settled by the figures, or decided by the session on the notes' recommendations (owner may veto)

Each is a table default or a filed item, reversible without app work; the figures and files are in the note named.

- **Rotation (note 01 call 1, W46.rotation-default):** the agreement rule per profile: free "Vision checked by PP-LCNet,
  else flag" (5 of 119 held-out pages wrong, 14 flagged); cloud "agree, else llmSingle" on the gateway only until a
  direct-key model is measured (P9-3); llmSingle on every page for charters and non-Latin scripts. The five set-apart
  pages are shown to the owner in a later sheet, about a minute (P10-7). Deskew's 1 degree trigger stands.
- **OCR input (note 02 C1):** no enhancement for any route, stated for the five readers measured; a small-reader power
  test filed, not run.
- **Layout (note 03 calls 1-5):** PP-DocLayoutV3 regions on newspapers for every reader (the gain is nil, not negative,
  for large readers on 15 pages); everything else whole page; never on handwriting or registers; the cluster "regions
  first for small readers" lives as a kind rule on note 04's cluster rows; the PP-DocLayoutV3 against DocLayout-YOLO
  pair test on L9 filed.
- **Placement (note 05 calls 1 and 3):** aligned lines on handwriting, default on, gate at 0.67 as filed; the hand line
  detector is a visible setting on the cluster profile only (PP-OCRv6 det needs 32 GB on the Mac CPU); its own peak
  memory and alignment time measured by a filed item before the 16 GB claim is made.
- **Marks (note 06):** no layer offered; the two-pass route described, behind W46.marks-detect-own (nice-to-have, as the
  owner set on 2026-11-06); region routes must keep picture regions (7 of 45 marks kept by the app's filter against 26).
- **Reading (note 04 calls 7.3-7.7):** hands routes ranked on the public L1-L3 where both figures exist, hands16
  otherwise, every hands figure labelled (OCR-1): LightOnOCR-3 4B on the Mac, Gemini 3.8 Flash on an API labelled
  "conditional on the truth", Infinity-Parser2-Pro on a cluster pending its pair. Loop fallback: a second VLM reader
  first where installed, kraken PP-OCRv6 on Latin lines where none, never a half-size retry on the cluster; a solver
  setting, not a measured optimum (18 pages). Public strata shown per row for the run that read them; a Mac row may show
  its cluster twin's figures only for the same weights and precision. 32 and 64 GB Macs pick from the 16 GB rows until a
  Mac measurement of a 27B-class reader exists (filed). Ties judged against the best feasible route only, faster wins
  among equal cost; no chaining. The ChatGPT plan has no OCR row (unmeasured; filed).
- **Segmentation (note 07 calls 2, 3, 5-8):** the text-only cloud window is filed as a test-box run on the gateway
  (about $1.30) before any tier is offered; the review rule is disagreement with a second model for the 2B when a partner
  is feasible, own confidence otherwise and for the cloud routes; the magazine kind is shown with "ranks nothing yet"
  until W46.seg-magazine-rule-redo; the 20 s checking-time assumption is kept, labelled, with a timing measure filed for
  an owner session after the redo; the 2B is offered to every 16 GB Mac with no key with a zero-shot card and the
  manuscript warning, and as an optional disagreement partner beside a cloud voter; the tie threshold is 3.2 points,
  the top of the rerun floor, until a measured range exists.
- **Dating (note 08 calls 7.3-7.5):** the image pass runs only where the app's own text gives no year candidate (its
  whole cost would otherwise apply to every document); the trained 2B and 4B are not dating defaults; the no-key laptop
  route is Vision text, rules, the 2B chooser and propagation at t=3, every propagated year Date Uncertain with its
  source document, the Mac 8B image pass added at 16 GB once item 8.1 shows its quotes help.
- **Entities (note 09 calls 2 and 5):** the inside-address and non-correspondence-date tests filed (offline, cached text);
  the Mac extractor under the ent-robust rule, the 4B not offered.
- **Kinds (note 10 calls 1, 3-5):** one mixed switch acting on every typed or printed page, wording "measured level on
  typed pages, not measured on mixed pages", Mac time "figure pending" until timed like for like (P11-4), off by default
  (call 3 above); the mix shown with its sample size and the classifier's error (137 of 141; 723 of 895) and pages under
  the 0.8 floor shown as unsure; kinds the classifier does not measure (clippings, newspapers, registers, mixed) asked in
  the interview labelled "not measured"; ATRIUM's licence conflict noted, moot while the shipped classifier is kept (and since 2026-11-17 no conflict: a CC BY-NC model may be an optional download with its licence shown, `00-plan.md`).
- **Capture (note 11 calls 1-3):** static guidance only until a sharpness cut is validated on real captures (the
  in-sample cuts false-alarm on 17-34% of good pages); flash off, raw original kept, no on-phone processing; the Android
  and iOS quality settings wait on a device read; 2,048 px at JPEG 0.85 stands as measured (`enh-dewarp.md` §"The app's encoding": Vision +0.5, Qwen3.6-27B -0.3, LightOnOCR -0.4,
  PP-OCRv6 +0.8, Gemini -0.1), so no encoding test is filed.
- **Kit (note 12 calls 7.2, 7.3, 7.5, 7.6):** the gate is gap accuracy against the shipped 2B with a checker-enforced
  minimum known-gap count from the measured "needed" column, two scored runs, and an anchor margin of 3.2 points (the
  rerun floor's top) on the public anchor; the licence statement goes in the kit README and a manifest `licence` field the
  range view shows, wording the owner's at ship time; corrections for the continuation live in the review records, the
  next box of the same material is the held-out set; "with a coding agent" means Mac-side steps, "on a cluster" adds the
  cluster rows.
- **Design (12-settings-design.md):** figures shown as points with sample size and the tie rule, as the design session
  decided; the solver's memory headroom stays 5 GB over the measured peak until a measurement says otherwise.
