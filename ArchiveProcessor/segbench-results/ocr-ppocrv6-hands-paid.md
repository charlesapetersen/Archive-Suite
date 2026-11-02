# Gemini given corrected handwriting lines — interrupted (W46.ocr-ppocrv6-hands-paid)

**Blocked; no accuracy verdict.** The original 71-page / 213-condition experiment stopped when the gateway returned 502 without usage, then a connection failed before a reply. The frozen 0/8/16-line requests and every paid outcome are retained. No pilot answer was repeated.

68 successful replies; 9 HTTP 502 replies without usage; 1 outstanding connection-error request; 135 conditions never attempted. No zero-example repeats run. Counts describe conditions, not independently sampled pages.

## Cost and resume boundary

Known usage/header charges: **$0.545493**. Unknown allowances retained: **$0.80**, so **$1.345493** counts against the owner-revised $2.50 working cap (OWNER_AUTHORIZATIONS.md, 1565f7d9). The allowances are not asserted to be actual bills. The initial 24-request pilot ($0.1950195, projected $1.7958 for 221 requests) is included, not added twice.

The runner initially continued across nine HTTP 502 replies because their full allowances were retained as settled records. That violated the stricter stop-on-uncertain-billing instruction; `call` now stops at the first missing-usage response, and `run` refuses any unresolved or missing-usage history before reading credentials. Offline regression tests cover both. There is no retry or automatic re-spend.

Outstanding request: `public-btp-mss184240101-32-n16`. Reconcile all ten unknown outcomes before any further paid call; preserve the nine failed replies and do not repeat them. After resolution, resume the never-attempted conditions with `hand_icl_gateway.py run`, then the eight preselected zero-example repeats, final scoring, verdict and bench panel. The unused sheet alternative sent no request.

## Measurement card

- **Truth:** public By the People transcriptions; owner target truth after W46.ocr-hands-rescore, partly Gemini/Claude drafted, with ten unresolved hand places. Owner references cannot independently rank models. Existing corrected-line pairs are filtered by the base recognizer; owner pairs precede the sheet corrections.
- **Selection:** frozen Qwen pack, 40 seeded public L1 pages, 19 owner hand pages and 12 held-out Blackwell diary pages. The latter use only 24 training pages as examples; Shils leaves its target out. Other cohorts have unverified hand identities. Source hashes reject target/exemplar aliases.
- **Comparison:** same target JPEGs and nested 0/8/16 example-image/text contexts. Gemini 3.7 Flash on the Stanford gateway, temperature 0, low reasoning, 8192-token cap, cache disabled, single attempts. Only 78 of 213 conditions attempted: no paired accuracy comparison is published.
- **Noise:** final paired page/collection intervals and the nine clear-owner-page sensitivity remain unrun; no new rerun floor measured. One diary and a four-page folder proxy cannot estimate across-hand variability.
- **Scope:** this is a spending/support checkpoint, not evidence for or against corrected-line prompting. Incomplete results are hidden on the bench page; whole-96 and whole-895 charts cannot take these subsets.

## Provenance

Pack freeze SHA-256 `6f644e4d11b075429095642fa5b71e254bed99604726d5d951dfa0736c7a7b07`; truth index `051664c1e67ec8b713181f198f21af20bef43aa5ff18c42b8afdc7d4f89c3210`; ledger `ee687a7774b76c9117c65d4007c966f78a2293051199c7db33849cb89544d065`. Private inputs: `~/.local/state/archive-autonomous/artifacts/hand-icl-20261101` and `hand-icl-truth-20261101`; paid replies, write-ahead ledger, original receipt and working-cap sidecar: `hand-icl-gateway-20261101`. No new model/download/page cache created; paid replies and audit receipts retained, shared inputs untouched.
