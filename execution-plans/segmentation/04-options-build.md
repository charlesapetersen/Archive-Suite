# Segmentation options: let the user choose the approach

Written 2026-10-11 from the owner's answer to `W36.seg-decision`. The results it builds on are in
`01-results.md`. Part 1 is for the owner. Part 2 is the daemon's detail.

---

## Part 1 — for the owner

### What you decided

Build segmentation as a choice, not a single method. The user picks one of these approaches for a folder or a
box:

1. **Full manual.** The modes the app has today. Nothing is proposed.
2. **Claude only.**
3. **Gemini only.**
4. **ChatGPT only**, if it can be done. The Processor already has an OpenAI client for OCR, so an API-key route
   exists; the bench has only tried an OpenAI model once, on one box.
5. **A mix of the models**, using whichever combining rule the measurements show works best.

For each approach the app shows rough figures, so the user can weigh accuracy against effort and cost:

- how many pages land in an exactly right document with no checking;
- how many boundaries the user will be asked to check per 100 pages;
- how many pages are right after those checks;
- how many errors are left that the user is never shown, per 500 pages;
- what it costs.

### Cost: dollars, and a share of a subscription

There are two ways to pay for the model calls, and the app should show both where both exist.

**By API key** is paid in dollars. The figure is a cost per 1,000 pages at the provider's list price, and at the
batch price where one exists.

**By a subscription** (a Claude or ChatGPT plan the user already pays for) costs no extra money, but uses up the
plan's usage windows. Here the figure should be a share of the user's own limits, such as "about 6% of a five-hour
window per 100 pages, about 1% of your week." Plans differ in their limits, and the providers do not publish
them as exact numbers, so the app cannot carry one fixed conversion. The approach is:

- The bench measures what does not depend on anyone's plan: the input and output tokens each approach uses per
  1,000 pages, by model.
- The app turns that into a share of the user's own windows by measuring on the user's own account: before a large
  run it segments a small sample (about 20 pages), reads the provider's usage meter before and after, and scales
  up to the folder. The Agent Manager already reads these meters for Claude and Codex, so the method is known to
  work.
- When the meter cannot be read, the app shows the token figure and a rough share for the user's plan tier,
  labelled as approximate.
- The owner's own plan is one worked example in the results, never the rule.

**Answered 2026-10-11** (`W36.seg-opt-usage`; detail and sources in
`ArchiveProcessor/segbench-results/usage.md`):

- **Claude: yes, on both counts.** Anthropic's terms allow a user to sign in to the unmodified `claude` tool with
  their own plan, also inside another product. They forbid an app to offer its own Claude login or to touch the
  user's credentials. So the Processor runs the user's own `claude`, never reads the login, and reads the meter
  from the tool's own output.
- **ChatGPT: yes, but by Sign in with ChatGPT, not the `codex` tool.** OpenAI offers ChatGPT-plan usage to
  open-source apps that run locally. It gives no such grant for an app driving the user's `codex` login, and its
  terms steer programmatic use to API keys. Sign in with ChatGPT has no usage meter an app can read, so the app
  shows the token figure and the user's own "Manage usage" link.
- **The meter is in whole percent.** A 20-page sample moves it about one point, which is too little to read. So the
  first stretch of the real run is the measurement: about 50 pages, until the meter has moved 3 points.
- **On your plan**, Claude windows used about **5% of a five-hour window and 0.5% of the week per 100 pages**
  (Dean box, 202 pages: 27% → 37% and 75% → 76%). That is close to your own guess.

### What it will not do

It will never segment silently. Every approach other than full manual is a first draft that the user reviews:
the doubtful boundaries are put in front of the user, page n beside page n+1, and the rest stay visible in the
review sheet for a skim. From the bake-off, even the best approach leaves about one unflagged error per 120 pages,
and the figures will say so.

The on-device and overnight routes are not part of this build. The idea of training a local model on the tagged
corpus is filed in `FUTURE_FEATURES.md`.

### What waits for it

The Processor's verification items (`W40.b3`, `W40.d1`–`d4`) wait for this build, so that they verify the
Processor as it will ship.

---

## Part 2 — the daemon's detail

The rules for every W36 item in `00-plan.md` Part 2 still apply: never write into `Test Files/`; every number says
which boxes it was measured on and whether they were tuned on; paid runs use the cheapest capable model first, use
batch where it exists, state the cost before the run and cache responses; thresholds come from held-out boxes.

The development boxes are Dean, Deaver and Herrnstein. The locked boxes, Stanton and RG 165, are scored **once
per approach**, with the method and threshold fixed on the development boxes first, as was done for Claude.

### Items

- **`W36.seg-opt-measure`** — the figures for every approach [M · ~2 sessions] (uses: paid). For Claude Sonnet
  5.5 windows (already measured; re-read its saved results and record tokens), Gemini 3.8 Flash windows (Dean and
  Herrnstein are new, Deaver is done), an OpenAI model through the same window prompt (all three development
  boxes; run through Codex on the ChatGPT subscription, never an OpenAI API key, owner 2026-10-11), and the best
  mix: choose each approach's flag threshold on the development boxes, held out per box, then
  score it once on the locked boxes. Record for each the five Part 1 figures, the dollar cost per 1,000 pages at
  list and batch price, and input and output tokens per 1,000 pages. Write the table to
  `ArchiveProcessor/segbench-results/options.md` and as data the app can read (`options.json`). Manual mode is a row
  with no cost and every boundary judged by the user. Paid spend for the item: at most $5, stated before each run,
  and the owner is asked before the total passes $3 (the standing rule in `~/Claude/CLAUDE.md`). It spent $2.73,
  all on Gemini. The Claude and OpenAI calls run on the subscriptions and cost no money.
  ✅ Shipped 2026-10-11: `ArchiveProcessor/segbench-results/options.md` and `options.json` (manual, Claude, Gemini,
  Claude + Gemini; ChatGPT not measured, split to `W36.seg-opt-openai`). $2.73 spent. ChatGPT measured 2026-10-12 by
  `W36.seg-opt-openai` through Codex ($0): alone at <= 0.990, 92% exact with no checking but 79 checks per 100 pages;
  the re-ranked mix became **Claude + ChatGPT**, min, <= 0.850 (92% / 10.2 checks / 3 unflagged on the test boxes).
- **`W36.seg-opt-usage`** — can the subscription route work, and how is its cost shown [S-M · ~1 session] (uses:
  light). Answer the two open questions in Part 1 (technically possible, permitted by the terms), with the
  sources cited. If yes, specify the sample-and-meter calibration, the fallback by plan tier and how each is
  labelled, and give the owner's plan as a worked example from the measured tokens. If no, say so; the route is
  dropped and `W36.seg-opt-subscription` is closed as not possible.
  ✅ Shipped 2026-10-11: `ArchiveProcessor/segbench-results/usage.md` (bench: `scripts/segbench/usage_calibrate.py`).
  Claude permitted on four conditions, and ChatGPT by Sign in with ChatGPT only; ChatGPT split to
  `W36.seg-opt-siwc`. The calibration spec and the owner's plan (5% of a five-hour window per 100 pages) are in that
  file.
- **`W36.seg-opt-design`** — the design note [S · ~1 session] (uses: light) (blocked-on: W36.seg-opt-measure,
  W36.seg-opt-usage). How the user chooses an approach in the Processor, how the figures are shown and scaled to
  the folder's page count, how the review of flagged boundaries works, and where the shipped figures live.
  Appended to this file as Part 3.
  ✅ Shipped 2026-10-11: Part 3 below.
- **`W36.seg-opt-engine`** — a provider-neutral window segmenter [M · ~2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-design). Seven-page windows, a confidence per boundary, the flag threshold per approach from
  `options.json`, the mix rule, and the Claude, Gemini and OpenAI clients the Processor already has. Unit tests on
  recorded responses; no paid call in tests.
  ✅ Shipped 2026-10-11: `macOS/Sources/ArchiveProcessor/Segmentation/` and `scripts/test-segmentation-engine.sh`,
  reproducing the bench's verdict on every Deaver gap for Claude, Gemini and the mix. The `TaggingMode` split moved
  to `W36.seg-opt-review` (§6).
- **`W36.seg-opt-chooser`** — the approach chooser [M · ~1-2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-engine). The setting, with each approach's figures and both kinds of cost.
  ✅ Shipped 2026-10-11: `Segmentation/SegmentationChooser.swift`, `Views/SegmentationChooserView.swift`,
  `scripts/test-segmentation-chooser.sh`. N in Process Files is the image pages (multi-page PDFs are rebuilt untagged,
  so not segmented), not §3's `droppedFiles.count + droppedPDFPageCount`. With both a key and `claude`, the row
  prices by key and shows the plan line only without one; the route choice itself is `W36.seg-opt-subscription`'s.
- **`W36.seg-opt-review`** — the review of flagged boundaries [M · ~2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-engine). Page n beside page n+1; keep, split or join; the unflagged boundaries stay in the review
  sheet. It also wires the engine into the pipeline and does the `TaggingMode` split (§6).
  ✅ Shipped 2026-10-11: `Segmentation/RunSegmentation.swift`, `OCR/OCRProcessor+WindowSegmentation.swift`,
  `Views/FlaggedBoundaryReviewSheet.swift`, `scripts/test-segmentation-review.sh` and the VM UITest
  `testFlaggedBoundaryPassNeedsEveryAnswerBeforeDone`. `automatic` + `manual` keeps the per-page review sheet (§1).
  On a usage limit or error the user chooses "check the rest myself" (every unanswered gap flagged at 0) or stop
  (resumable; the window and gap answers ride `PendingRun`). A batch resume reads the live approach (its journal
  carries none) and keeps no answers.
- **`W36.seg-opt-subscription`** — the subscription route [M · ~1-2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-usage, W36.seg-opt-engine). Claude only, through the user's installed `claude`, under the four
  conditions and the calibration spec in `segbench-results/usage.md`. It switches `LocalAgentClient` to
  `--output-format stream-json` so each call carries the meter (`rate_limit_event`). The app never reads the
  Keychain login.
  ✅ Shipped 2026-10-11: `Segmentation/PlanUsage.swift`, `scripts/test-segmentation-plan.sh`. The route choice is a
  "Pay for Claude" control under the approach, shown only with both a key and `claude`; it defaults to the key. The
  first-run question comes at 3 points or 100 pages, and a decline stops the run resumably, as a usage limit does;
  90% pauses the same way, with the reset time. The ratio is stored unkeyed (§4), as the median of the last five runs.
  Cancelling a run now stops its `claude` children.
- **`W36.seg-opt-siwc`** — ChatGPT by Sign in with ChatGPT [M · ~1-2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-openai, W36.seg-opt-engine). OpenAI's sanctioned route for open-source, locally run apps, never the
  user's `codex` login. The app shows "Using ChatGPT plan" and a "Manage usage" link. With no app-readable meter,
  the cost is the token figure and its notional API price, labelled approximate. The requirements to meet are in
  `segbench-results/usage.md` and OpenAI's cookbook page. Not a prerequisite of `W36.seg-opt-proof`.
- **`W36.seg-opt-proof`** — prove it end to end [S-M · ~1 session] (uses: build,vm,paid) (blocked-on:
  W36.seg-opt-chooser, W36.seg-opt-review, W36.seg-opt-subscription). The GUI proof in the VM, and one small real
  folder per provider (cents). Then `W40.b3` and `W40.d1`–`d4` may start.
  ✅ Shipped 2026-10-12: `scripts/test-segmentation-proof.sh` (`SegmentationProofDriver`), results in
  `segbench-results/proof.md`: Gemini and Claude by key, Claude by plan and the mix, on two real Herrnstein folders
  ($0.63); the chooser and flagged-pass UITests green in the VM.

---

## Part 3 — the design (`W36.seg-opt-design`, 2026-10-11)

This part decides how the build items fit together. The figures it uses are in
`ArchiveProcessor/segbench-results/options.md` and `options.json`, and the subscription rules are in `usage.md`.
Code names were read from the Processor on 2026-10-11 and cited as of that date.

### In short (for the owner)

- **A new setting, "Segmentation", sits beside the tagging mode.** It appears in Settings and in the Process Files
  window, and its choices are Manual, Claude, Gemini, ChatGPT and a mix (Claude + ChatGPT since `W36.seg-opt-openai`). Each choice shows its five
  figures scaled to the files you dropped. Each also shows its cost: dollars when paid by API key, and a share of
  your windows when paid by your Claude plan. ChatGPT runs by OpenAI API key until `W36.seg-opt-siwc` adds the plan route.
- **Choosing it does not run anything without review.** After OCR, the doubtful boundaries are shown one at a
  time, page n beside page n+1, and you choose keep, split or join. After that, the existing review sheet
  shows every document for a skim.
- **The figures ship inside the app, from the bench's own file**, so the app never shows a number the bench did not
  measure.

### 1. The setting, and what it replaces

Today, segmentation is half of `TaggingMode` (`Models/ProviderModels.swift`):

- `automatic` and `autoDate` have the OCR model classify each page on its own (`DocumentClassification`, then
  `Tagging/DocumentSegmenter.swift`). That is the spring 2026 per-page method that the bake-off replaced.
- `autoDateManualSeg` and `human` have the user segment.

**Decision: split the two questions.**

- **New: `SegmentationApproach`**, stored under a new `DefaultsKeys` key `segmentationApproach`. Its cases are
  `manual`, `claude`, `gemini`, `openai` and `mix`, and the ids match `options.json`'s approach `id`.
- **`TaggingMode` keeps only the tagging half.** It no longer decides who segments. `autoDateManualSeg` folds into
  `autoDate` and the choice `manual`, and `human` stays as it is. The cases and their names are free to change
  because there is no production material, so no migration is written. A run that already exists has nothing to
  resume into.
- **The per-page classifier keeps one job: box and folder photos.** The figures were scored with the photos known
  (truth photo labels, `options.md`). The app therefore keeps `BoxFolderConfirmSheet` before the boundary review
  and treats a gap next to a box or folder photo as a boundary by construction, as the bench does
  (`method_window.py` `assemble`). Only gaps between two document pages go to the window segmenter.
- **`automatic` + `manual`** (decided by `W36.seg-opt-review`, 2026-10-11): the full review sheet, starting from the
  OCR model's own per-page tags, as `automatic` always had. No screen exists where the user segments and the model
  then tags everything, so this is the one choice that removes no workflow. `autoDate`/`human` + `manual` is the
  combined window (`ManualSegmentTagView`), the model filling dates for `autoDate`. Live Capture's pre-grouped runs
  with `autoDate` tag the phone's groups as they are.
- **`manual` is the app as it is today**: `ManualSegmentTagView` / `ManualTaggingSheet`, with nothing proposed. Its
  row in the chooser says "about 87 boundaries to judge per 100 pages, no cost".
- **Default: `manual`.** An approach that spends money or plan usage is never on until the user picks it.
- **Where it is chosen:**
  - In Settings, a "Segmentation" section next to the tagging-mode picker (around `SettingsView.swift:753`).
  - In the Process Files window, as a dropdown like the tagging mode's.
  - It is captured by `ProcessingProfileStore` and carried in `PendingRun`, so a resumed run keeps its approach.
- **Live Capture is out of scope.** The phone already gives the boundaries (`preGroupedBoundaries`), because the
  user ends each segment while shooting. Live Capture does not show the setting.
- **A box or a folder is the run.** A run is a flat list of files, and the user drops one box or folder at a time.
  "Choose per folder" therefore means "choose per run". There is no per-folder override inside one run.

### 2. The engine contract (`W36.seg-opt-engine`)

The engine has one entry point:

```
segment(pages: [PageInput], photoKinds: [PhotoKind?], approach: ApproachSpec) async throws -> [GapProposal]
```

- `PageInput` is the thumbnail plus the OCR text, on the bench's terms: the long edge at 1,600 px and at most
  2,500 characters of text.
- `GapProposal` is `{gap index, decision new|continue, confidence, agreed, flagged, cue}`.
- It is pure apart from the client calls, and it writes nothing to disk. Its output only changes
  `documentReviewItems`' proposed classifications, and the user's review changes those before anything is
  written, so it is not a Tier-2 path. The stage after the review that writes the files is unchanged.

**Windows, exactly as the bench ran them** (`options.json` → `window`, read at run time rather than hard-coded):

- seven pages, stride 3;
- each gap judged by the windows that cover it;
- a gap's `P(new)` is the mean of its windows' votes, its decision is `new` when that mean is at least 0.5, and its
  confidence is `max(p, 1−p)` (`method_window.py` `combine`).

**One approach, one voter.** The gap is flagged when its confidence is at or below the approach's `level`, which
comes from `options.json` (Claude 0.85, Gemini 0.965).

**Mix (`rule: "min"`):**

- Decision: the majority of the voters. A tie goes to the voter with the higher confidence.
- Flag: a gap is flagged unless every voter agrees and the lowest confidence is above the level. This is
  `ensemble.py` `judge`, verbatim.
- If a later bench run ships `rule: "mean"`, the engine implements that rule too (`options.py` `mean_judge`). The
  rule is read from the file and never assumed.

**Prompts, models and transport:**

- The prompts and models are the bench's: Claude prompt w1 on `claude-sonnet-5-5`, and Gemini prompt g1 on
  `gemini-3.8-flash` at thinking low.
- They are copied into the app as fixed strings with the bench's prompt id beside them. Each approach in
  `options.json` names its voter's prompt id, and a test fails if the two disagree.
- The engine reaches each model through the clients the Processor already has: `AnthropicClient`, `GeminiClient`,
  `OpenAICompatibleClient`, and `LocalAgentClient` for the subscription route.
- The engine does not use the global provider and model picker, because an approach fixes its models. That keeps
  the shipped figures true.

**Failure:**

- A window that fails, or returns an answer that does not parse, retries once.
- If it fails again, every gap that only it covered is marked `flagged` with confidence 0. A guess is never filed
  unseen.
- On a usage limit the engine stops cleanly, keeps the windows already answered, and reports the reset time, which
  `LocalAgentClient` already parses.

**Tests:** recorded responses only, with no paid call. The tests check:

- the window layout;
- the combining and both rules;
- reproducing the bench's flagged set on one recorded development box. The recorded answers ship as a test fixture,
  so this is cheap.

### 3. The figures: where they live, and how they are shown (`W36.seg-opt-chooser`)

**Where they live.**

- `ArchiveProcessor/segbench-results/options.json` is the single source. `project.yml` adds it as a bundle resource
  by relative path, with no copy, so a bench re-run reaches the app on its next build.
- A unit test decodes the bundled file. It fails if any of these hold:
  - `version` is unknown;
  - an `available` approach has no `level`, `rule`, `figures.test` or cost;
  - an approach `id` has no `SegmentationApproach` case.
- The app reads only `figures.test`, which is scored once on the locked boxes. `dev_held_out` and `test_by_box` are
  for the bench's own report.

**How a row reads.** The user sees one row per approach, scaled to the run. The page count is
`droppedFiles.count + droppedPDFPageCount` (`OCRView.swift`), and the count is `N`:

| figure | shown as | from |
|---|---|---|
| right with no checking | "about 87% of pages" | `pages_exact_no_review`, whole percent |
| to check | "about 37 boundaries to check" | `flagged_per_100_pages` × N / 100, rounded to a whole number, at least 1 |
| right after checking | "about 97% of pages" | `pages_exact_after_review`, whole percent |
| errors you will not be shown | "about 1 in 120 pages" | 500 / `unflagged_errors_per_500_pages`, rounded to 2 significant figures |
| cost | §4 | `cost.total`, `tokens_per_1000_pages` |

Two honesty rules hold for the display:

- **A zero is not shown as a promise.** When `unflagged_errors` is 0 the row says "none in 363 test pages". The
  number comes from `figures.test.pages`, so it is never a fixed string.
- **Every row carries the same footnote**, built from the file: "Measured once on two boxes (363 pages) of one
  archive, `measured` date. Your material may differ."

**An approach that cannot run** is shown greyed out, with the reason:

- `available: false`: the file's `reason`. (ChatGPT did until `W36.seg-opt-openai` filled its row on 2026-10-12.)
- No key and no signed-in `claude` for the approach's provider. The row offers the key wizard
  (`ProviderKeyWizard`), or says how to sign in to `claude`.

**The cost pane.**

- The Settings `costPane` and the Process Files estimate both gain a "Segmentation" line, from `CostEstimator`.
- Manual's line is $0.
- The window calls are in addition to OCR, so the OCR line is unchanged.

### 4. The two ways to pay

An approach that uses Claude names its route in the row. The user chooses the route only when both are present.

- **By API key (dollars).** The row shows `list_usd_per_1000_pages` × N / 1000, and the batch figure beside it
  when the run goes by batch. Gemini rows add "introductory price until 31 Dec 2026". The price and its date come
  from `cost.per_model.*.price_read`. When that date is more than 90 days old, the row says "prices as of
  <date>".
- **By the Claude plan (a share of windows).** This is `W36.seg-opt-subscription`, and it follows `usage.md`
  exactly: its four conditions, then the calibration steps 1–7, the meter-unreadable fallback and the 90% pause.
  - Before any run on the account, the row reads "uses about as much of your plan as $X of API calls at list
    price". `$X` is `subscription_route_notional_usd_per_1000_pages` × N / 1000. Under it: "measured on your
    account after the first run".
  - After one calibrated run, the row reads "about X% of a five-hour window, about Y% of your week", labelled
    "measured on your account, <date>".
  - The stored ratio is kept per window under a new `DefaultsKeys` key. It is not keyed by plan name, because the
    CLI does not report one, so a change of plan shows up as a ratio that moves and is caught by rule 7.
- **ChatGPT plan** (`W36.seg-opt-siwc`): the token figure, the notional API price labelled approximate, "Using
  ChatGPT plan", and the "Manage usage" link.
- **The mix** (Claude + ChatGPT since `W36.seg-opt-openai`) shows both: the Claude share or dollars, plus ChatGPT's dollars.

### 5. The review of flagged boundaries (`W36.seg-opt-review`)

**When.** After OCR and the box/folder confirmation, and before tagging. For any approach other than `manual`, the
review is not optional. The setting that turns it on is the approach. `reviewDocumentSegmentation` stays the
switch for the existing skim sheet, which is forced on for these approaches (below).

**The flagged pass** is a new sheet beside `DocumentSegmentReviewSheet`, and it shows one flagged gap at a time:

- page n on the left and page n+1 on the right, each at reading size;
- above them, the proposal ("New document starts here", or "Same document continues"), its confidence in words
  (low / very low) and the model's cue, truncated;
- three actions:
  - **Keep** accepts the proposal (Return).
  - **Split** makes n+1 start a document (S).
  - **Join** makes n+1 continue n (J).
- ← / → move between gaps, and an action is never final until the pass is done;
- a counter, "12 of 37";
- "Done" is enabled only when every flagged gap has been answered, because the figures assume each one is checked;
- cancelling leaves the run's proposals unapplied, and nothing is written.

**Then the skim.** The existing `DocumentSegmentReviewSheet` opens with every boundary applied. Gaps the user
answered are marked as checked, and unflagged boundaries carry no mark. The note at the top comes from the file:
"About 1 in 120 pages may still be wrong without having been flagged; a skim catches them." The sheet is
unchanged otherwise. Its edits feed the same `documentReviewItems` that tagging reads.

**What is recorded.**

- Each answered gap is recorded in the run's `PendingRun`, so a resume does not ask again.
- Nothing about the review is written into the output files.
- The decisions are kept in memory for the run's own count line at the end, for example "37 checked, 6 changed",
  which helps the user judge the approach on their own material. They are not sent anywhere.

### 6. Order of the build, and what each item proves

| item | ships | proves it with |
|---|---|---|
| `W36.seg-opt-engine` | `SegmentationApproach`, `options.json` decode, windows, rules, the clients, failure → flagged | unit tests on recorded windows, reproducing the bench's flags on one box |
| `W36.seg-opt-chooser` | the setting in Settings and Process Files, the scaled rows, the cost line, unavailable rows | unit tests on the row text for each approach and N; a render guard for the rows |
| `W36.seg-opt-review` | the engine in the pipeline, the `TaggingMode` split, the flagged pass, the skim note, resume of answered gaps | unit tests on keep/split/join → classifications; the VM XCUITest of one pass |
| `W36.seg-opt-subscription` | the Claude plan route, `stream-json`, calibration, pause at 90% | a fake CLI emitting `rate_limit_event` (extend `scripts/localagent-fake-cli.sh`); no real plan use in tests |
| `W36.seg-opt-proof` | one small real folder per provider, end to end in the VM | cents, stated before the run |

**The `TaggingMode` split (§1) moved to `W36.seg-opt-review`** (decided by `W36.seg-opt-engine`, 2026-10-11).
The engine reads the approach from `SegmentationApproach.stored()` and `SessionProcessingConfig.segmentationApproach`,
which is all it needs. The split itself changes who segments in `automatic` and `autoDate`: today the per-page
classifier does it. Done before anything replaces that classifier, the split would leave those modes with no
automated segmentation, and §1 does not say what `automatic` + `manual` should do, since no screen exists where
the user segments and the model then tags everything. The review item rewires that dispatch anyway, so it does the
split there, decides `automatic` + `manual`, and adds the approach to `PendingRunRuntimeConfig`. The chooser still
only adds the UI.
