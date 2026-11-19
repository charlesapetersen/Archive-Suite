# Showing an estimate that fails the evidence check (W47.wh-date-evidence-shown)

Owner call 9 (2026-11-06) hides a neighbour estimate whose evidence fails `date_scorers.evidence_check` "until item 8.3
fixes the checker's false refusals". 8.3 (W46.date-evidence-check) shipped on 11 November. This counts, on the fresh
replies of W46.date-route-pipeline (scored with the widened checker, which was written on other replies), what the
check still refuses and what showing those estimates would add. Script: `scripts/segbench/date_failed_estimates.py`
(figures in `date-failed-estimates.json`). $0, no model called, no quote read by the session.

## Findings

- **The checker's remaining right-year refusals are few, and most are real citation failures.** Right years refused:
  Gemini 3.7 Flash 12 of 31 refusals on the owner's 272, the 27B 15 of 44 (`date-route-pipeline.md`, P13-5). By the
  checker's reason and the quote's digits alone: the cited neighbour is not in the context (Gemini 3) or the quote is
  not in the cited text (1; the 27B 2), which no checker could pass; the quote carries a different four-digit year
  (4; 3) or digits that are not the year (1; 5). What may still be the checker's fault is the quotes holding the year's
  two digits outside a date form it reads (2; 4) or three of its digits (1; 1): at most 3 of Gemini's 12 and 5 of the
  27B's 15, unjudged, since forms are added from counts and tests, not from a session reading quotes.
- **In the app today a failed estimate is dropped and not shown** (`DateRoute.decide`, step 4 writes only on a valid
  check): no year tag, no header line, and the sidecar's `dating` object says only `"class": "none"`, "no year with
  checked evidence". The model's year, interval and quote are not kept anywhere the user sees.
- **What showing them would add, Gemini 3.7 Flash (the cloud route):** a suggested year on 9 of the 11 owner
  documents that now get none: 3 the owner's year, 2 wrong (by 1 and 5 years), 4 of the owner's decade-tagged
  documents, all 4 inside the decade. On the 90 undated documents, 7 more suggested years, every one false (today's
  route writes a false year on 14 of them, `date-route-pipeline.md`). On 22 more owner documents a failed estimate
  sits beside a year another step wrote (9 the same year, 13 another), so a shown suggestion would there be a second,
  competing year.
- **The same on the 27B (cluster route):** 23 of the 25 owner documents with no year would get one: 8 right, 7 wrong
  (by 1, 1, 1, 2, 2, 4 and 4 years), 8 decade-tagged with 5 inside the decade. On the undated 90, 8 more false
  years. 21 more sit beside a written year (7 the same).
- **So the condition as written is about met; what is left is the old question.** Nearly every estimate still
  refused fails because its quote does not carry the year, which is the "untraceable guess" the owner's rule forbids
  writing. Showing it as an unwritten suggestion gives the user, on Gemini, a year for 9 more documents of which 3-7 are
  right or in the right decade, at the price of 7 false years on 90 undated documents and a citation that does not
  support the year it is shown with.

## Measurement card

- **Truth:** the owner's date tags (the 300; years and decades), used only to say whether a suggested year is right;
  the undated 100 (90 readable) are documents the owner tagged with no date, so any year there is false. The
  refusal reasons are the checker's own. The sorting of refused quotes is by their digits only; no session read them.
- **Selection:** every trace-neigh reply on the owner's 272 with a confirmed JPEG original and the 90 readable
  undated, as W46.date-route-pipeline sampled them; none chosen by a tested route or by ABBYY text.
- **Comparison:** the same replies and contexts for both models, the route with and without step 4's check.
- **Noise:** a deterministic count of fixed replies, n as stated; the right/wrong splits rest on 9 and 23 documents,
  so a difference of a few documents is within what another sample would move.
- **Scope:** two models, one prompt, macOS 27.2 Vision text. It does not judge whether the 3 (Gemini) or 5 (27B)
  two- and three-digit quotes are checker misses; nor how a suggestion would be worded or placed in the app; nor the
  Mac 8B route, which has no trace step.
