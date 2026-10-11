# The subscription route — can it work, may it, and how its cost is shown

W36.seg-opt-usage, 2026-10-11. Answers the two open questions in `execution-plans/segmentation/04-options-build.md`
Part 1, and specifies how the Processor shows a subscription's cost. Measured with
`scripts/segbench/usage_calibrate.py` (log: `usage-calibrate-calls.jsonl` in the bench cache). Sources were read on
2026-10-11.

## The answers

| | Claude (`claude` CLI, the user's own login) | ChatGPT |
|---|---|---|
| Technically possible | **Yes.** The bench ran all 310 Claude windows this way, and the Processor already has the client (`OCR/LocalAgentClient.swift`, `claude -p`). The app is not sandboxed, so it can start the user's installed binary. | **Yes, by Sign in with ChatGPT.** `codex exec` would also work technically (`-i` images, `--json` reports tokens), but it is not the route chosen. |
| Permitted by the terms | **Yes, on four conditions** (below). | **Yes, by Sign in with ChatGPT only.** Running the user's `codex` login from the app is not covered by any grant, and OpenAI's docs send programmatic use to API keys. |
| Meter the app can read | **Yes.** `claude -p --output-format stream-json` emits a `rate_limit_event` on every call, with the account's five-hour and weekly utilization. It is in **whole percent.** | **No documented meter for apps.** The user sets a per-app weekly limit and reviews usage in ChatGPT Settings. |

So the route is **not dropped.** `W36.seg-opt-subscription` builds it for Claude now. The ChatGPT half waits for
`W36.seg-opt-openai`, because there are no ChatGPT figures to show yet.

## Claude: what the terms say

Claude Code's *Legal and compliance* page (https://code.claude.com/docs/en/legal-and-compliance), under
"Authentication and credential use":

- Against: "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications,
  or to route requests through Free, Pro, or Max plan credentials on behalf of their users. Moreover, developers may
  not collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must
  complete through Anthropic's own flow."
- For: "Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude
  subscription, including where a platform hosts Claude Code as described under *Can customers offer Claude Code in
  their products?*"
- That section: "preinstalling or running Claude Code in your products or services … requires agreeing to our
  Commercial Terms of Service and complying with the conditions below: **The Claude Code binary must not be
  modified.** … **Customers may not pay for, resell, or intermediate Claude usage on their end users' behalf.** Each
  end user must authenticate with their own Anthropic API key, Claude subscription plan credentials, or 3P inference
  provider credential".
- Also: "Advertised usage limits for Pro and Max plans assume ordinary, individual usage of Claude Code and the Agent
  SDK."

The Consumer Terms (https://www.anthropic.com/legal/consumer-terms, effective 8 Oct 2025) forbid automated access
"Except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it."
Claude Code's headless mode is documented and, through the clause above, explicitly permitted.

**The four conditions the Processor must keep** (they are the build's rules for `W36.seg-opt-subscription`):

1. Run the user's own installed, unmodified `claude`, resolved to an absolute path as `LocalAgentClient` does. Never
   bundle, download or patch it.
2. Never read, copy or store the user's login. The Agent Manager reads the Keychain item `Claude Code-credentials`
   for its meter. The Processor must not do that, because that is the "collect … or intermediate" the terms forbid.
   It reads the meter from the CLI's own stream instead.
3. Offer no Claude login of its own. If `claude` is not signed in, tell the user to run `claude` and sign in, which
   uses Anthropic's own flow.
4. Each user pays with their own plan. The app never supplies a login or a key for anyone else.

The Commercial Terms condition binds whoever distributes the app. That is the owner, who already holds an Anthropic
API account.

## ChatGPT: what the terms say

- Sign in with ChatGPT (https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt): "ChatGPT plan usage
  is available to open-source projects, personal projects that run locally, and selected private apps." Paid or
  remotely hosted apps join a waitlist. Archive Suite is public and runs locally.
- The app must show when the plan is powering requests ("Using ChatGPT plan") and give a "Manage usage" link to
  ChatGPT Settings.
- OpenAI Service Terms §15 (https://openai.com/policies/service-terms/): "Sign in with ChatGPT allows developers to
  enable users to connect their ChatGPT accounts … to their tool, application, or website."
- Against running the user's `codex` login instead:
  - The Terms of Use (https://openai.com/policies/row-terms-of-use/, effective 1 Jan 2026) forbid users to
    "Automatically or programmatically extract data or Output".
  - Codex's auth docs say "Use API key authentication for programmatic Codex CLI workflows".
  - No text grants the `codex exec` route. Read through a proxy (the pages refuse direct fetch), so recheck the wording
    before quoting it further.

## The meter, and why a 20-page sample cannot be read

The `rate_limit_event` reports `unifiedWindows.five_hour.utilization` and `seven_day.utilization` as fractions in
whole percent (0.26, 0.27 …). On the owner's plan, 20 pages move the five-hour meter by about one point, which is
within the meter's resolution. Part 1's "about 20 pages" sample would be ±100%. Each call's notional list price
(`total_cost_usd` in the same stream) is exact. So the app measures a **ratio**, meter points per notional dollar,
from a stretch long enough to cross several points, and scales the folder by its notional dollars.

## Worked example: the owner's plan

Owner's Claude plan (an enterprise seat with five-hour and weekly windows), 2026-10-11. Claude Sonnet 5.5 windows
through `claude -p`, exactly the bench's prompt. Box: Dean (development box, 202 pages, 68 windows, three at once,
302 s).

| | value |
|---|---|
| idle control, 240 s with no calls of ours | five-hour 27% → 27%, weekly 75% → 75% |
| the run | five-hour **27% → 37%**, weekly **75% → 76%** |
| notional list price | $10.22 (**$50.6 per 1,000 pages**; the bench's figure over all five boxes is $50.29) |
| tokens (per 1,000 pages) | 11.0M cache-write, 12.5M cache-read, 0.41M output, ~0 uncached input |
| ratio | about **1 point of the five-hour window per $0.98** notional (9 steps, evenly spaced: one every 6 windows, about 18 pages) |
| **five-hour window** | **about 5% per 100 pages** (4.5–5.4% for 9–11 points), **about half a window per 1,000 pages** |
| **weekly window** | **about 0.5% per 100 pages** (0–1% for 0–2 points), about 5% per 1,000 pages. This is the coarse figure: one meter step. |
| time | about 25 minutes per 1,000 pages at three calls at once |

Owner's guess in Part 1 was "about 6% of a five-hour window per 100 pages, about 1% of your week". The measurement
is close. "Claude and Gemini together" draws the same Claude share plus Gemini's API dollars. The meter covers the
whole account, so other use during a run inflates it. The idle control and the even spacing of the steps say there
was none here.

## How the app shows it (the spec for `W36.seg-opt-design` / `-subscription`)

**The unit.** Each approach's notional dollars per page come from the shipped figures: `options.md` has $50.29 per
1,000 pages for Claude through `claude -p`. A folder's estimate is notional $/page × pages × the account's ratio, per
window.

**Measured on your account.** The ratio comes from a calibration on the user's own account. It is labelled "measured
on your account, <date>". The calibration is not a thrown-away sample. It is the start of the real run:

1. Read the meter on the first call.
2. Segment pages in order, summing each call's `total_cost_usd`.
3. Once the five-hour meter has moved **3 points**, or after 100 pages, whichever comes first, compute points per
   notional dollar. Show "about X% of a five-hour window, about Y% of your week for this folder", and ask whether to
   go on.
4. If 3 points are not crossed in 100 pages, show "under about 3% of a five-hour window per 100 pages".
5. Store the ratio per window, keyed by plan, and refine it after every run as the median of the runs that crossed
   3 points. Later runs show the stored figure up front, with no pause.
6. The weekly ratio is shown as a bound until enough runs have crossed several weekly points, because one weekly
   point takes about 200 pages on the owner's plan.
7. Discard a run's ratio when the meter moved backwards (a window reset) or jumped faster than the calls explain
   (other use of the account).

**When the meter cannot be read** (an older CLI, a missing `rate_limit_event`, an API-key login), show:
- the notional figure, "uses about as much of your plan as $X of API calls at list price";
- the token counts;
- a tier figure where one exists, labelled approximate.

**Plan tiers.** Anthropic publishes only relative sizes. Max is "5x or 20x more usage than Pro per 5-hour session"
(https://claude.com/pricing), and no plan has published absolute limits. So the tier fallback needs one measured Pro
point, scaled down by 5 and 20 for Max. Until a Pro measurement exists, the fallback is the notional figure alone.
The owner's enterprise seat is not on that scale and is never used as the rule.

**Limits.**
- When the five-hour meter reaches 90%, pause and say when the window resets (`resetsAt` from the same event).
- On a usage-limit error, stop cleanly and keep the pages done. `LocalAgentClient` already parses the reset time.

**ChatGPT.** The route is Sign in with ChatGPT. There is no meter to read, so the app shows:
- tokens, and the notional API price of the same calls, labelled approximate;
- "Using ChatGPT plan";
- the "Manage usage" link.

**Gemini** stays API-key only. It costs $3.61 per 1,000 pages at list price.
