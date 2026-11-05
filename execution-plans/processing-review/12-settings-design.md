# 12. How users choose their settings (W46.settings-design-research)

Owner, 2026-11-04: "A Fable session should do research on the best way to approach the various trade-offs available
and present them to the user interactively so they can see the range of possibilities and change them dynamically."
Done in an owner-started Fable session on 2026-11-04. The owner also ruled, during the session: "Don't assume that
we'll stick with the current Processor settings approach." Nothing below assumes it.

Phase 4 (`00-plan.md` §"Phase 4") fills this design with rules: one decision note per stage, ending in the rule the
settings layer applies. This note says what the layer is, what it asks, what it shows, and what the rule table it
reads looks like. The working prototype that the owner's calls were made on is in `settings-design/` beside this
note (section 4).

## 1. The owner's calls (2026-11-04, interactive, on the prototype)

| call | the owner's decision |
|---|---|
| The shape | Two interviews. One at the app's first start lays out the general resources (the Mac, keys and plans, a cluster, money and time habits, fine-tuning). One when a collection, or a project of similar collections, is created asks what is specific to it. No wizard after them. |
| The main screen | Shape A: the limits (ceiling, hours, preference) at the top drive one pick per stage; each stage card says what a better figure would need; the range charts are one tab away for overriding. (Shapes B, range first, and C, both side by side, were built and shown; A chosen.) |
| Layers | Inherit live, override per value: a collection holds only what it answered itself; everything else reads the general layer at run time; the sheet shows where each value comes from, with a reset to the inherited one. |
| The document mix | Measured by the on-device kind classifier from a sample, shown, and correctable; and the interview also asks what a classifier cannot see: the period (decades or centuries), the languages, the scripts. |
| Starting points | Kept, as fills of the answers, not modes: "Free, on this Mac", "A few dollars, overnight", "My plan, no money", "Best measured, no limit". Nothing depends on which was pressed. |
| Priorities | The collection interview asks what matters most (reading, finding documents, dates, names); the order becomes stage weights shown on the sheet, which the user can edit by hand. |

Decided by the session, not put to the owner: figures are shown as points with their sample size and the bench's tie
rule beside them, not as bands, because the bench has ranges for few cells; where it has one, the sheet shows it.

## 2. What the research found, and what the design takes from it

Two research passes (setup interviews against editable settings; trade-off views) and one codebase sweep, all on
2026-11-04. Sources are listed at the end of this section.

- **A setup interview is the right tool for a one-time, infrequent decision, and the wrong one for the repeat
  path.** Nielsen Norman Group: wizards suit novices and setup, become controlling when repeated, and should reuse
  earlier answers as defaults. Apple's onboarding guidance: reasonable defaults first, postpone non-essential setup,
  infer rather than ask. Material Design's "Self-Select" first run is this exact case. Taken: the general interview
  runs once; the collection interview is short; both write ordinary settings; nothing is taught in them.
- **Detect, then ask one axis, then bundle, and keep everything editable.** GeForce Experience reads the GPU and
  asks for one quality-against-speed preference; LM Studio and Ollama estimate whether a model fits memory and warn
  rather than block; HandBrake and GCC name bundles and let every member be changed. Taken: the Mac's memory, the
  keys in the Keychain and the signed-in CLIs are read, not asked; the ceiling and the hours are the asked axes; a
  route that will not fit is shown hollow with the reason, never hidden.
- **Layered settings with a visible source.** git shows the origin and scope of each value; VS Code marks modified
  settings and offers "Reset Setting"; Xcode resolves levels right to left; Lightroom keeps catalog settings apart
  from preferences. Taken: general layer, project, collection; each value says where it came from and resets.
- **Live readouts beside the control, and only figures one can stand behind.** Photoshop's Save for Web shows size
  and download time under each preview; HandBrake and Premiere show estimates that miss by a lot and are distrusted
  for it; game menus show a live memory meter. Taken: every figure on the sheet is a bench measurement with its
  source; the few that are not (cloud seconds a page) are marked est., and the sheet never prints a figure the bench
  has not produced.
- **A frontier the user can click.** Artificial Analysis draws accuracy against cost with a Pareto line; OpenRouter
  sorts by price, throughput or latency, with a hard `max_price` that refuses and soft thresholds that deprioritise;
  AWS's Spot advisor shows risk bands; AutoML tools offer two or three discrete points. Taken: one scatter per stage,
  the undominated line drawn, a hard ceiling (drawn as the money left for that stage) and soft preferences
  ("cheapest within a point"), and discrete routes rather than a continuous slider, because the routes are discrete.
- **Budget-first tools do not say what they traded away.** Lightroom's size limit, two-pass encoders, AutoML
  training budgets, batch pricing at half price: none states the loss. Taken: the per-stage box "What a better figure
  would need" names the better routes, their gain, and the one reason each is out (a key, memory, the ceiling, the
  hours, a plan).
- **OCR tools expose no accuracy at all.** Transkribus prices credits per page by material (handwritten 1, printed
  0.5, tables 1); ABBYY offers "fast" or "thorough" in prose; Textract and Document AI price per page and feature.
  Taken: per-kind pricing is the one precedent for per-kind figures; showing accuracy beside the price is new.

What the evidence does not settle, and so went to the owner: interview-first against inline questions; inherit
live against copy at creation; how a product's presets should relate to the derived settings. No study compares a
resource interview with detect-and-default for a compute or money decision.

Sources: nngroup.com/articles/wizards, /mobile-tutorials, /the-power-of-defaults; developer.apple.com HIG Onboarding
and Settings; m2.material.io onboarding; learn.microsoft.com uxguide win-wizards; nvidia.custhelp.com a_id/3459;
lmstudio.ai/docs/cli/local-models/load; docs.ollama.com/context-length; handbrake.fr docs custom-presets and
adjust-quality; gcc.gnu.org Optimize-Options; git-scm.com/docs/git-config; code.visualstudio.com/docs/configure/
settings; developer.apple.com WWDC21 10210; helpx.adobe.com save-for-web; artificialanalysis.ai/models and
/methodology; openrouter.ai/docs/guides/routing/provider-selection; aws.amazon.com/ec2/spot/instance-advisor;
docs.notdiamond.ai/docs/key-concepts; transkribus.org/credits; help.abbyy.com finereader/16 recoptions;
aws.amazon.com/textract/pricing. Full reports with per-claim URLs are in the session transcript; the claims above are
the ones the design uses.

## 3. The design

### 3.1 The general interview (first start of the app)

Read, not asked: the Mac's chip and unified memory; which API keys are in the Keychain (Gemini, OpenRouter, OpenAI,
Mistral); whether `claude` is installed and signed in (the plan route; `usage.md` gives the four conditions);
whether a ChatGPT sign-in exists. Shown back so the user can see what was found.

Asked: a Slurm cluster with GPUs, and how many GPUs a job may use; the money habit (none; a ceiling per batch; a
ceiling per month, which the layer then tracks against a ledger of what batches have spent); how long a batch may
usually run (overnight unlocks batch prices at half the list price); whether the user can run the training kit (no,
with a coding agent, on a cluster). Every answer has a default most users keep, and the cheapest safe one where
money is involved: no cluster, no money, overnight, no kit.

### 3.2 The collection interview (a collection or a project of similar collections)

Measured: the document mix (typewritten, printed, handwritten, forms and registers, clippings, newspapers) by the
on-device classifier on a sample of the photographs (139 of 144 right, 0.2 s a page, `kind-classifier.md`), shown as
shares the user can correct; the page count.

Asked: the period (decades or centuries), the languages, the scripts (Latin, Kurrent, Greek, Hebrew, Arabic,
Cyrillic, Chinese, Devanagari and so on). These select which public strata's figures apply (L5 to L8 and N1 to N6 of
the 895) and which specialist readers are candidates; a classifier cannot see them. This batch's ceiling and hours,
defaulted from the general layer. How many minutes the user will spend checking boundaries. What matters most, as an
order of reading, finding documents, dates and names; the order becomes the four stage weights, shown on the sheet
and editable. The reading-copy switch (deskew or dewarp the copy a reader sees, content-preserving methods only;
owner, 2026-10-20). A starting point may fill all of this in one press.

A user who skips both interviews gets the owner's defaults (section 3.7).

### 3.3 The settings sheet (shape A)

At the top: the limits (ceiling, hours, preference) and the totals for this batch (money, machine time, the
weighted accuracy, whether a plan is in use). Then one card per stage: segmentation, reading, dating, entities. A
card shows the chosen route with its family (this Mac, a paid API, a plan, a cluster, by hand), the measured figures
for the user's mix (per kind, with the sample size), the cost for this batch, the time, the memory it needs, the
bench's note on the route, the box "What a better figure would need" (up to four better routes, each with its gain
and the one reason it is out), the nearest alternatives the user could use, an override menu (choosing one marks the
card Custom, with a way back), and the source file of the figures. A third tab lists what is not a choice (section
3.6). The range view is the second tab.

The solver behind the picks: a route is feasible when its needs are met (a key or plan, a cluster, the Mac's memory
against its measured peak plus 5 GB); the ceiling and the hours apply to the batch as a whole, with Mac stages
running one after another and network stages overlapping them; within the feasible combinations it maximises the
weighted accuracy, or, under "cheapest within a point" and "fastest within a point", trades a point of accuracy for
money or time; a difference under the bench's tie threshold (half a point of NES; the segmentation rerun floor of
1.4 to 3.2 points of pages exact) is a tie and the cheaper route wins it. The segmentation figure a user sees is the
no-checking figure moved toward the after-checking figure by the share of the needed checks their minutes cover
(20 s a boundary, an assumption to measure).

### 3.4 The range view

One chart per stage. Across: cost per 1,000 pages or documents at list price, on a log scale, with a band at the left
for free routes. Up: the accuracy for the user's mix. One mark per route, shaped by family. Filled marks are feasible
with the resources given; hollow marks are not, and the tooltip says why; faded marks are feasible but outside the
limits. A dashed line joins the routes nothing beats on both counts. A dashed red line marks what is left of the
ceiling for this stage once the other stages are paid for. Clicking a mark or a table row chooses it. Under the chart
the full table: every route, its per-kind figures, its public-strata figure where it was run, the list price, this
batch's cost, the time, and whether the user can use it. Cascades (a first reader checked against a second,
escalating on disagreement; `ocr-difficulty`'s frontier) are further points on the reading chart.

### 3.5 Layers, and where the settings live

Three layers, resolved at run time: the general layer (the machine and the user), a project (a group of similar
collections, optional), the collection. A collection holds only the values it answered itself; every other value is
read from the layer above when a batch runs, so a key added later is offered to old collections at once. The sheet
shows each value's source ("from your general settings", "measured on 2026-11-04 from 200 photos", "you set this on
2026-11-04") and a reset to the inherited value. When a batch runs, the resolved settings are frozen into the run's
record, so a result can always say what produced it (the pending run already freezes its settings this way).

The collection's settings are a document kept with the collection, beside its output folder, so that the Reader and
Notes, and a second Mac, can read what produced the collection; the general layer lives in the app's own store. This
is a proposal for Phase 4 to confirm; it does not reuse the Processor's present model, which is app-wide
`UserDefaults` keys with named profiles, a Settings window of fixed sections, and no per-collection state (the sweep
of 2026-11-04 found no collection or project object; `ArchiveProcessor/CLAUDE.md` says settings and structure are
free to change, with no migrations needed).

### 3.6 What is not a choice

Stages the review measured and found no trade-off in; the sheet shows them as rules with the measured reason, and a
switch only where the owner ruled one. Kinds: measured, free. Placement: Vision's own layer on print; on handwriting,
kraken lines with the reading aligned to them, about 6 s a page on the CPU, and a text page where the alignment
confidence is under 0.67 (`place-print.md`, `place-hands.md`). Enhancement: no content-removing enhancement helps any
reader as OCR input, DocRes dewarp harms every one, so there is nothing to choose for the OCR input; the reading
copy's deskew or dewarp is the user's switch (`enh-ocr-input.md`, `enh-dewarp.md`). Layout: newspapers get a layout
stage (PP-DocLayoutV3 regions), everything else reads the whole page, and a layout detector never runs on handwriting
or registers (`layout-photo.md`). Marks: no detector found a mark; nothing to offer (`marks-detect.md`). Image size:
2,048 px at JPEG quality 0.85.

### 3.7 Defaults behind it

For a user who skips the interviews the owner sets the defaults, in Phase 4. The prototype's "Free, on this Mac"
fill is the natural one when no key is detected, and "A few dollars, overnight" when a Gemini key is; both are
proposals.

### 3.8 The rule table Phase 4 fills

The sheet reads a table, regenerated from the bench and never hand-edited. Per stage and route: the route id and
name; its family; what it needs (keys or plans, a cluster, the Mac's memory floor from the measured peak); the
accuracy figures per kind and per public stratum, each with the sample size, the truth's provenance and the report
that produced it; the cost per 1,000 units at list and batch price, with the date the price was read; the time per
unit, measured or estimated, and what it was measured on; the memory peak; the bench's caveats; the kind rules the
route carries (a layout stage for newspapers, no detector on hands); and the fallback when the route fails on a page.
Each stage's decision note in Phase 4 ends in the rule the table encodes: given the answers, which route, with the
measured reason, the expected cost and time, the alternatives with their own figures, and the fallback when an
answer rules the first choice out (`00-plan.md` §"Phase 4").

`settings-design/figures.json` is the first draft of that table, built by `build_figures.py` from the bench page's
`ArchiveOCRBench/data/panel-data.json` and the result notes, so every figure in the prototype has a path back to its
source. Phase 4 replaces the hand-entered parts (section 3.9) with bench outputs.

### 3.9 Gaps the sheet cannot yet fill honestly

Found while building the prototype; each is a figure the sheet would show and the bench has not produced. Phase 4
files an item where the sheet needs the figure.

- Cloud seconds a page are not tabulated by the bench (gateway OCR calls ran at 5.3 s median in `date-image.md`;
  Claude through `claude -p` at 10 s a page, three at once). The prototype marks them est.
- The dating image pass's cost and the dedicated entity prompt's cost are estimates from the tagging call's size.
- Cluster times are pages an hour on one GPU; queue wait is not in them, and FarmShare's figures stand for Sherlock.
- Per-kind reading figures exist for the owner's 96 only; the public strata have per-route figures for the reference
  routes and the FarmShare panel, not for every route the sheet lists.
- Segmentation figures are per box (letters, a magazine, typed office files, clippings), not per document kind; the
  magazine rule is pending `W46.seg-magazine-rule-redo`.
- The checking-time figure assumes 20 s a boundary; nobody has timed a user checking.
- The Claude plan's cost is a share of its windows, measured on the user's account by the method in `usage.md`; the
  ChatGPT plan has no meter an app can read.
- Every Vision figure is the macOS 27.2 reading; the public Vision row answers 305 of 320 pages.

## 4. The prototype

`settings-design/prototype.html` is the page the owner's calls were made on (a hosted private copy for the owner:
https://claude.ai/artifact/MZrgF8VayFAeVsk4eJc1Zy). Vanilla HTML and JavaScript, no app code. It carries the three
screen shapes behind a switch, the resources column, the solver, the range charts, the rules tab, four starting
points, and per-collection keeping (browser storage, a stand-in for the collection document).

Rebuild from the repository root:

```
python3 execution-plans/processing-review/settings-design/build_figures.py . execution-plans/processing-review/settings-design/figures.json
python3 execution-plans/processing-review/settings-design/inject.py execution-plans/processing-review/settings-design/prototype.template.html execution-plans/processing-review/settings-design/figures.json execution-plans/processing-review/settings-design/prototype.html
```

What it does not do: it is not the app; its cloud times are estimates; its per-collection keeping is this browser
only; its solver's stage weights are fixed at 45, 30, 15 and 10 (reading, segmentation, dating, entities) where the
app will take them from the interview's order.

## 5. For Phase 4, beyond the rules

- The per-month ceiling needs a ledger of what batches have spent, kept in the general layer.
- The kit routes (a same-hand fine-tune, a user-trained segmenter) appear as "after training" points on the range
  once the fine-tuning answer allows them, with the kit's measured gains and their conditions.
- The cascade is a route on the reading chart, with its own figures from `ocr-difficulty`.
- The settings document's format, and whether the Reader and Notes read it, is a Phase 4 decision with the
  integration stages (W42.int-s1 to s7).
