# The Processor's settings in panels and levels (W47.settings-levels)

Owner, 2026-11-19, on the withheld-features sheet (`../13-stage-rules/14-owner-calls.md` call 15): "We'll likely need
to revise the Settings panel in Processor. Things like this should be in an Advanced panel or similar. The whole panel
likely needs to be broken out into multiple panels and also into multiple levels depending on user sophistication."

This is the design that goes to him before anything is built. The settings design in `../12-settings-design.md`
(the two interviews, the limits-first sheet with the range one tab away, the three layers with every value's source
shown) and his six calls there stand; this note changes only where the controls sit and who sees them. Nothing here
changes a default, a route, a figure or a solver pick.

## 1. What the Settings window is today

Surveyed on main at 94349c44 (`ArchiveProcessor/macOS/Sources/ArchiveProcessor/Views/SettingsView.swift`). One
fixed 680 by 660 window: one long scrolling form of nine sections (Appearance, This collection, Live Capture,
Provider & Model, API Keys, Input & Processing, Rotation Correction, Tagging & Segmentation, Segmentation) beside a
cost estimate for 1,000 files. About 45 controls are always there and about 30 more appear with a backend or a mode;
the interviews and the settings sheet hold about 35 more. The per-stage figures, the stage switches and the downloads
are in a separate modal sheet (Choices, Range, Rules), reached from three buttons. Three settings can be edited in
more than one place: the tagging mode (Settings and Process Files), the segmentation approach (Settings, Process Files
and the sheet), the provider and model (Settings, the sheet's "Read with this", and Cycle Provider).

What a new user meets first is the backend picker, the provider list, the gateway's URL and price fields, five key
fields, image sizes in MB and the worker count, before anything about their material.

## 2. Panels

The standard macOS settings window: a toolbar of panels, one form each, no long scroll. Eight panels, in this order.
The sheet's stage cards move into the panels they belong to, so each stage is set in one place; the modal sheet stays
as the batch summary (limits, totals, every card) opened from Process Files, and every panel's card keeps its "See the
range" link to the Range view.

| panel | holds |
|---|---|
| General | Appearance; the level (section 3); the setup interview; the starting points |
| Collection | the output folder as the collection; project; the collection interview; held values with their source and Reset; this batch's limits and totals |
| Reading | the reading card (pick, figures, override); backend, provider and model; kind routing and the handwriting-on-typed switch; the cascade; Apple Vision's options; the layout card for newspapers and its downloads |
| Documents | the segmentation card and its routes; tagging mode, vocabulary, colours; collection ID and filing; merge; review pauses |
| Dates and names | the dating card and its switches; the entities card |
| Pages and output | straightening; rotation; the text page, columns and searchable-page choices; image and PDF sizes; separate image export; skip processed files; pre-OCRed input; the hand placer download |
| Capture | live processing mode; reading box and folder labels; the Drive relay |
| Accounts | API keys and their status; the gateway key; the Claude and ChatGPT sign-ins; the CLI agent setup |

Process Files keeps its Tagging picker, segmentation chooser and per-page reader menus as shortcuts: they write the
same keys and say so, so no value has two owners.

## 3. Levels

Three levels, chosen in General and asked once at the end of the setup interview ("How much do you want to
adjust?"). A level only decides which rows are shown. It never changes a value, a default or what the solver picks.

- **Basic.** The interviews and the solver choose everything; the user sees each stage's pick with its figures, the
  limits, the keys and sign-ins, the output folder, the tagging mode and the capture switches. For someone who wants
  the app's measured choice.
- **Standard.** Every choice the bench supports: overriding a stage's route, the backend and model, the switches that
  have a measured trade (a cost, a time, a gain), image sizes, rotation, segmentation review.
- **Advanced.** Everything else, under three rules: (a) a route that scored below what ships, (b) a switch with no
  measured gain, (c) output marked low confidence; plus the raw technical controls (gateway URL and prices, custom
  models and prompt, recognition thresholds, worker count). Each Advanced row carries its figures on the row, in the
  same words as its route row, so the reason it sits there is visible.

Two rules that hold at every level, decided by the design rather than put to the owner because they follow from his
layers call (every value shows its source):

- A row whose value differs from its default or inherited value is shown at every level, marked with its level and
  its Reset. A Basic user never runs a setting they cannot see.
- A route that lost, or a switch below its baseline, is never a default and never a solver pick, at any level; at
  Advanced it can be chosen by hand and the card then says "Custom" as any override does.

## 4. Where each setting sits

B Basic, S Standard, A Advanced. Rows marked "moves to A" are controls a user can see today and would not see below
Advanced; under call 13 they are listed here for the owner, not decided by this note.

### Existing settings

| setting (panel) | level | why |
|---|---|---|
| Appearance; setup interview; starting points (General) | B | |
| Collection, project, collection interview, held values (Collection) | B | |
| Each stage card: pick, figures, cost and time (Reading, Documents, Dates and names) | B | the design's main screen |
| Override a stage's route; "Back to the app's pick" | S | |
| OCR backend; provider; model (Reading) | S | the card shows the pick at B |
| Thinking level (Reading) | A, moves to A | no bench figure for Low against High |
| Escalate failed pages to (Reading) | S | a measured cascade row (call 5) |
| Also escalate on Vision word-count disagreement (Reading) | A, moves to A | opt-in, no measured gain (call 5; W47.wh-cascade-disagree waits) |
| Choose each page's reader by its kind (Reading) | S | |
| Read handwriting on typed pages (Reading) | S | measured time and cost on the row (W46.mixed-route-setting) |
| Vision languages (Reading) | S | |
| Vision fast recognition; minimum confidence; custom vocabulary (Reading) | A, moves to A | none measured on the bench |
| Vision with an LLM for text-only judgement (Reading) | S | |
| Gateway: local-model toggle and presets (Reading) | S | |
| Gateway URL, model ID, display name, prices, cost profile (Reading) | A, moves to A | raw fields; the presets fill them |
| CLI agent tool and setup (Accounts) | S | |
| CLI path and model override (Accounts) | A, moves to A | raw fields |
| Manage custom models (Reading) | A, moves to A | raw fields |
| API keys, gateway key, sign-ins (Accounts) | B | |
| Pre-OCRed PDF input (Pages and output) | S | |
| Batch mode, about half the price (Pages and output) | S | |
| Skip already-processed files (Pages and output) | B | |
| Image resolution; standard image size (Pages and output) | A, moves to A | the bench sends 2,048 px at 0.85; no figure for other sizes |
| PDF image size; separate image export and its size; text columns (Pages and output) | S | |
| Parallel OCR workers (Pages and output) | A, moves to A | throughput only |
| Write a processing log file (Pages and output) | A, moves to A | diagnostic |
| Straighten sloping pages (Pages and output) | B | call 6, on by default |
| Rotation: every mode (Pages and output) | S | measured: the comparative prompt is the most accurate single route (`rotation-routes.md`) |
| Review rotation (Pages and output) | S | |
| Tagging mode (Documents) | B | |
| Tag vocabulary; box and folder colours (Documents) | S | |
| Collection ID and filing; confirm identifications (Documents) | S | |
| Review document segmentation; merge multi-page documents; segment JSON (Documents) | S | |
| Send previous page image (Documents) | A, moves to A | no bench figure found for the switch itself |
| Custom OCR prompt (Documents) | A, moves to A | raw field |
| Segmentation approach and its pay route (Documents) | S | the card shows the pick at B |
| Local segmenter server, model, partner (Documents) | A, moves to A | raw fields |
| Search the page image on every document, about $1.93 more per 1,000 (Dates and names) | S | measured: finds stamp dates |
| Put handwritten text on the image where it fits (Pages and output) | S | call 12 |
| Searchable page with no text page, per kind (Pages and output) | S | |
| Hand placer and newspaper layout downloads (Pages and output; Reading) | S | |
| Live processing mode; read box and folder labels (Capture) | B | |
| Drive relay client ID, secret, sign-in (Capture) | S | |

That is 12 groups moved to Advanced, about 23 controls. "No bench figure" means the survey found none in
`segbench-results/`; it is the reason the row is not Standard, not a finding that the control does nothing.

### The features released on 2026-11-19 (call 15)

| feature (item) | panel | level | figures carried on the row |
|---|---|---|---|
| Read-poorly flag for readers other than Vision (W47.wh-read-flag-readers) | none: a flag on the result | every level | LightOnOCR: 8 of 11 poor readings caught, 4 of 85 false alarms on the 96 |
| DocLayout-YOLO for scanned newspapers (W47.wh-yolo-scans) | Reading, layout card | S | +4.6 (1.1 to 8.0) over PP-DocLayoutV3 on 15 scans, 14 from one collection; not measured on photographs |
| Whole-page reading of newspapers for large readers (W47.wh-whole-page-large) | Reading, layout card | B as a solver row | 27B whole 0.967 against regions 0.965 on 15 pages |
| ATRIUM as the mixed-page pre-flag (W47.wh-mixed-preflag) | Reading, under the handwriting-on-typed switch | S | recall 51-60% at 69.8% precision (bounds 18-95%), against 12-14% for the shipped classifier |
| Trained segmentation models under the kit gate's minimums (W47.wh-kit-minimums) | Documents | A, rule (c) | labelled "small held-out set" |
| Image-grounded post-correction (W47.wh-post-correction) | Reading | A, rule (b) | a tie on the 96 (-0.42, -1.47 to +0.64); +1.47 (+0.55 to +2.63) on 120 public readings; worsens 4 of 57 and 10 of 120 |
| The readers that scored below what ships (W47.wh-readers-lost) | Reading card and Range view | A, rule (a) | Apple's on-device model 42.4 against Vision's 83.1 on the 96; Azure 89.6, Textract 86.6, Transkribus 82.5 against Mistral 4.1's 92.5 on 25 pages; the fifteen dominated routes with their rows |
| Mac Qwen3-VL 8B image pass for dating (W47.wh-date-8b-image) | Dates and names | A, rule (b), owner's word | "no measured gain": 32 of 55 against 33; false years on 20 to 21 of the 90 undated |
| Names on small Macs and on pre-modern material (W47.wh-names-small-mac) | Dates and names | A, rule (c), owner's word | sender F1 GLiNER2.5 0.24, NLTagger 0.14 on 138 documents; 0.02-0.37 on L5 and L7; every name marked low confidence |

The trained-model and post-correction placements are this design's reading of the owner's three rules; the readers,
the 8B pass and the small-Mac names are his own words.

## 5. Decided here, not put to the owner

- The panels are the standard macOS settings toolbar, not a sidebar: eight panels fit it, and it is the HIG pattern.
- The window keeps the 1,000-file estimate, as a strip in the Collection panel beside the totals.
- The interview's level question defaults to Basic when the interview is skipped, consistent with call 3 ("Free, on
  this Mac" for a skipped interview).
- The level belongs to the general layer, not the collection: it describes the person, not the material.

## 6. The build, once the owner answers

Filed from his answer, roughly: (1) the panels, moving every control and the stage cards into them, one owner per key,
the window's UITest in the VM; (2) the level mechanism, its interview question and the "set at a higher level" rule,
with a unit test that every catalog key and every route row has a level; then W47.wh-readers-lost,
W47.wh-post-correction, W47.wh-date-8b-image and W47.wh-names-small-mac, which wait on it, put their rows at the level
he sets.
