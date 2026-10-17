# The local route's guards, measured at scale on FarmShare (W41.app-local-models, 2026-10-16)

The app's local open-weight route (Settings → API Gateway → A model on this Mac, `LocalModelRoute`) fails a page in
two ways besides an error: a reply that reaches its 4,096-token cap, and a reply that ended by itself but repeats
itself (`isRepetitionLoop`: one 4-400 character span with three or more visible characters, repeated 8+ times over
2,000+ characters). Both were set from the 99-page Mac measurement. Here they are replayed over FarmShare's replies,
the rule through a line-for-line port (`farmshare/app_loop_rule.py`, which passes the Swift driver's cases). The
replies are vLLM's on L40S cards, bf16 or fp8, not the Mac's MLX 4-bit, so the loop rates are the models' own and
a 4-bit build may loop somewhat more. No transcript text here; the replies stay on FarmShare scratch.

## The two guards on answered pages

| replies | model | answered | rule fires (would fail a good page) | answered over 4,096 tokens |
|---|---|---:|---:|---:|
| 2,000 corpus pages (the bulk pilot) | Qwen3.6 27B fp8 | 1,987 | 0 | 1 (5,766) |
| 2,000 corpus pages, the same | Qwen3-VL 8B bf16, no guard, 8,192 cap | 1,928 | 0 | 0 (longest 3,738) |
| the 99 truth pages, six runs | Qwen3.6 27B (three settings), 3.6 35B-A3B, 3.8 27B, 3.5 122B | 592 | 0 | 0 |
| 19 NewsBench broadsheets, whole page | Qwen3.6 27B, 3.8 27B | 32 | 0 | 18 (4,341-7,371) |

- **The repetition rule fails no good page.** Across 4,539 answered replies it never fired.
- **The 4,096 cap is right for archive pages** (the 8B's answered pages: median 403 tokens, 99.9% under 2,650) **and
  wrong for whole newspaper pages**: 18 of 32 answered broadsheets needed more, so the route fails most newspaper
  pages read whole. The bench reads newspapers best by region anyway (`farmshare/README.md`, Newspapers).

## The loops: how often, and how early a streamed stop would catch them

Qwen3-VL 8B, the route's pick for an 18 GB Mac, ran to the 8,192 cap on **71 of 2,000 corpus pages (3.6%)**, against
13 of 2,000 (0.65%) for Qwen3.6 27B. Read a second time with the whole reply kept (`FS_KEEP_RAW=1`): **9 answered**
(a second attempt rescues about one in eight), 62 looped again. Replaying the app's own rule over those 62 at every
250 characters, as a streamed reply would meet it:

| | |
|---|---:|
| loops the rule catches while streaming | 51 of 62 |
| tokens read before it fires: median / 90% / most | 1,232 / 1,853 / 3,707 |
| share of an 8,192-token runaway read before it fires: median | 15% |

The route does not stream today (`ArchiveProcessor/KNOWN_ISSUES.md`), so every loop runs to 4,096 tokens, about
200 s on the 8B. Streamed, the same rule would stop four loops in five after about 1,200 tokens, about a minute.
At the 8B's 3.6% that is roughly an hour saved per 1,000 pages, against about 11 hours of reading them (41 s a page
on the M3 Pro): an estimate from the Mac's mean speed, not a Mac measurement. Filed as W41.app-local-models-fu1.
