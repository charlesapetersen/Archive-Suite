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

## The streamed stop on the Mac (W41.app-local-models-fu1, 2026-10-17)

The app now streams the local reply and closes it when the rule fires. Checked on the 18 GB M3 Pro with
`mlx_vlm.server` 0.7.4 serving Qwen3-VL 8B 4-bit, text-only prompts, a Python client closing the socket as the app's
URLSession cancel does (not the app itself): a reply that would run to the cap was closed after 1,503 characters;
the server logged the generation cancelled at 465 tokens 53 ms later, and the next request answered in 0.3 s (0.2 s
before). The same reply left to run held the server 158 s (4,096 tokens at 26 tokens a second). So a stopped stream
frees the server at once, and the next page starts without waiting. LM Studio and Ollama were not checked.

## Reasoning switched off, on the Mac (W41.app-local-models-fu2, 2026-10-17)
`mlx_vlm.server` 0.7.4 serving `lmstudio-community/Qwen3.5-4B-MLX-4bit` (a thinking model), a Python client sending
the route's request shapes: the tagging-shaped call (one message, 512 tokens, temperature 0) and a streamed OCR call
on a synthetic three-line typed page (4,096 cap), each without and with the three fields `applyReasoningOff` adds.

| server | call | no switch | with the switch |
|---|---|---|---|
| default (thinking off) | text | answered, 2.8 s, no reasoning | answered, 1.2 s |
| default | OCR | read, 1.9 s, no reasoning | read, 1.1 s |
| `--enable-thinking` | text | `length` at 512 tokens, 1,720 characters of reasoning, no content | answered `{"year": "1952", …}`, 1.2 s |
| `--enable-thinking` | OCR | read, 7.1 s, after 915 characters of reasoning | read, 1.1 s, no reasoning |

So mlx-vlm 0.7.4 already thinks only when its server is started with thinking on (its template call defaults
`enable_thinking` to false); there the unswitched tagging call fails exactly as FarmShare's vLLM did (300 of 300), and
the request's `enable_thinking: false` overrides the server. The extra `think` and `chat_template_kwargs` fields were
accepted (200). LM Studio, Ollama and vLLM were not run on the Mac (none is installed); their spellings come from
their documentation and, for vLLM, FarmShare's thinking-off runs. Qwen3.6 was not run (it does not fit 18 GB).
