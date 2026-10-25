# Window reply duplicate audit — W46.fix-window-duplicates

Audited 2026-10-25 at baseline `895d754c`; the parser defect was filed against `f0bec0f4`.
No published score is affected by duplicate entries. No model call or paid rerun was made, and no
cache, ledger or source image was changed.

## Scope and method

Two independent read-only scans examined stored replies, including already-failed records. For
`responses/window-*/*/*.json`, read `result`, or the Gemini response's first candidate's non-thought
text parts. Strip the parser's optional fence/prose wrapper by taking the first `{` through the last
`}`. Check repeated integer page IDs and integer `(left, right)` gap pairs directly in the arrays,
before turning them into dictionaries. Equal entries count as duplicates too. Then run the patched
`method_window.parse_answer` on readable window replies. For corpus rows use their recorded `window`;
for gateway rows use `request.span`; response-cache records have no independent requested-page list,
so their parser check uses the sorted unique returned page IDs. This last check cannot establish that
the original request's complete page set was returned, but does detect all repeated entries.

Gateway scoring membership comes from joining `request.id` to `seg-lincoln-gateway.json`'s
`calls[].used`, rather than trusting the old `valid` flag. Its three whole-stream replies use
`method_whole`'s separate parser and are excluded below.

| Stored window replies | Records | Readable JSON | Duplicate-bearing replies |
|---|---:|---:|---:|
| Owner cache, 39 window namespaces | 5,523 | 5,501 | 0 |
| Public cache, six window namespaces | 783 | 783 | 0 |
| Gateway replies plus failed-reply archive | 265 | 261 | 3 |
| Collected corpus/public `answers.jsonl`, 12 files | 3,748 | 3,745 | 0 |
| Total | 10,319 | 10,290 | 3 |

Local roots (not published data): owner `~/Library/Caches/ArchiveSuiteRehearsal/segbench/responses/`;
public `~/Claude/Long term storage/FarmShare-20261018/public-segmentation/cache/responses/`;
gateway `~/Library/Caches/ArchiveSuiteRehearsal/seg-lincoln-gateway/{replies,failed-replies}/`;
corpus `~/Claude/Long term storage/FarmShare-20261018/results/seg/**/answers.jsonl`.

The 22 unreadable owner records (20 malformed, two empty) and three malformed corpus records were
already `status: failed`. Four unreadable gateway records were already invalid and unused. Five
additional readable owner records still fail pre-existing kind/missing-gap checks and were already
marked failed. All 783 public cache replies, all 3,745 successful corpus rows and all 187 gateway
window replies used in published scores pass the patched parser. The two used whole-stream replies
are outside this parser change (hence the earlier gateway audit's 189 used replies).

## The three rejected replies

All are Lincoln GLM replies, each explicitly `used: false` in the committed gateway report:

| Cache file (under gateway root) | Pages | Repetition | Previous status |
|---|---|---|---|
| `replies/a13ed29e254a2d46c7acea68f6b2a0c2dbed6e47012cfb3afbb491a5ef96a35f.json` | 151–157 | Identical gap 156–157 | `valid: true`, unscored partial arm |
| `replies/286572dd2e8474cc4ba6b64e885e902e6866f80f4e2be0b05740e66ea777a0c3.json` | 163–169 | Gap 168–169, different cues | Already invalid; gap 167–168 missing |
| `failed-replies/eb58ebb0497f4c72828401a1d0e775d5.json` | 163–169 | Gap 168–169, different cues | Already invalid; gap 167–168 missing |

The final two are separate billed attempts with identical raw reply bytes. The new parser rejects
all three with `ParseError: duplicate boundary [...]`, before dictionary insertion. Lincoln GLM
continues to have no full-box score. Its existing historical parsed-reply counts and ledger describe
validation at collection time; they were preserved, not silently reclassified or retried. Scored
Gemini, Claude and CREST GLM results need no correction. Existing failed-window fallbacks remain as
reported; this audit does not turn failed records into usable votes.

## Verification

`python3 -m unittest test_window test_gemini test_whole test_lincoln_cloud test_lincoln_gateway
test_public_segmentation` passes all 70 tests from `scripts/segbench/`. New regressions reject equal
and conflicting page/gap entries, string IDs that normalize to the same number, and duplicates with
missing entries. A cached duplicate fails without a model call or cache write even with calls enabled.
Against the original `f0bec0f4` parser, the equal/conflicting and cache-hit regressions produce 11
failed subtests with zero errors. A separate adversarial review found no open issue in the change.
