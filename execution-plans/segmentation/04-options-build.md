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
  boxes), and the best mix: choose each approach's flag threshold on the development boxes, held out per box, then
  score it once on the locked boxes. Record for each the five Part 1 figures, the dollar cost per 1,000 pages at
  list and batch price, and input and output tokens per 1,000 pages. Write the table to
  `ArchiveProcessor/segbench-results/options.md` and as data the app can read (`options.json`). Manual mode is a row
  with no cost and every boundary judged by the user. Paid spend for the item: at most $25, stated before each run;
  the Claude calls run on the subscription as before.
  ✅ Shipped 2026-10-11: `ArchiveProcessor/segbench-results/options.md` and `options.json` (manual, Claude, Gemini,
  Claude + Gemini; ChatGPT not measured, split to `W36.seg-opt-openai`). $2.73 spent.
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
- **`W36.seg-opt-engine`** — a provider-neutral window segmenter [M · ~2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-design). Seven-page windows, a confidence per boundary, the flag threshold per approach from
  `options.json`, the mix rule, and the Claude, Gemini and OpenAI clients the Processor already has. Unit tests on
  recorded responses; no paid call in tests.
- **`W36.seg-opt-chooser`** — the approach chooser [M · ~1-2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-engine). The setting, with each approach's figures and both kinds of cost.
- **`W36.seg-opt-review`** — the review of flagged boundaries [M · ~2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-engine). Page n beside page n+1; keep, split or join; the unflagged boundaries stay in the review
  sheet.
- **`W36.seg-opt-subscription`** — the subscription route [M · ~1-2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-usage, W36.seg-opt-engine). Claude only, through the user's installed `claude`, under the four
  conditions and the calibration spec in `segbench-results/usage.md`. It switches `LocalAgentClient` to
  `--output-format stream-json` so each call carries the meter (`rate_limit_event`). The app never reads the
  Keychain login.
- **`W36.seg-opt-siwc`** — ChatGPT by Sign in with ChatGPT [M · ~1-2 sessions] (uses: build) (blocked-on:
  W36.seg-opt-openai, W36.seg-opt-engine). OpenAI's sanctioned route for open-source, locally run apps, never the
  user's `codex` login. The app shows "Using ChatGPT plan" and a "Manage usage" link. With no app-readable meter,
  the cost is the token figure and its notional API price, labelled approximate. The requirements to meet are in
  `segbench-results/usage.md` and OpenAI's cookbook page. Not a prerequisite of `W36.seg-opt-proof`.
- **`W36.seg-opt-proof`** — prove it end to end [S-M · ~1 session] (uses: build,vm,paid) (blocked-on:
  W36.seg-opt-chooser, W36.seg-opt-review, W36.seg-opt-subscription). The GUI proof in the VM, and one small real
  folder per provider (cents). Then `W40.b3` and `W40.d1`–`d4` may start.
