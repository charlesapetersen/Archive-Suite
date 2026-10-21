# W46.fix-capture-tags — capture-defect tags on the 96, and every saved route's NES by tag

Tags drafted from each page image by Claude Opus 5.5 (four subagents, 24 pages each) against the schema in "attributes" (levels 0 absent, 1 present, 2 severe); audited with the draft in view by Claude Sonnet 5.5, which changed 11 of 1344 cells; tagged again blind by Claude Sonnet 5.5, which disagreed with the audited draft on whether a defect is present in 173 cells on 81 pages; each of those cells settled by a third look (Claude Opus 5.5, the image and both notes in view). Where the two agreed on presence the audited draft's level stands. Not owner-labelled (STATE Phase 2 decision 2). All subscription calls; no money.

What the tags say. The defects that cost words on the 96 are framing and material, not optics, as L-capture expected from the six worst pages. Median over the 29 routes, against pages of the same kind and source without the tag: edge cut -6.4 NES points (26 of 29 routes worse), coloured stock or a colour cast -4.1 (27/29), mixed content -3.0 (26/29; the two severe pages -20.4), neighbouring material in frame -1.9 (21/29; the 18 severe, where it carries readable text, -5.2), faint ink -1.8 (20/29), show-through -0.7 (21/29; the 12 severe -5.2). The optical tags show no loss: perspective +1.1, glare +2.0, defocus +2.2, shadow +2.5, curl +2.6, hand in frame +3.2, low light +9.0 on 3 pages, and no page shows motion blur. The cheap and small readers carry most of the spread (Apple Vision -31 on faint ink, -24 on glare; the strongest cloud readers lose 1 to 3 points on any tag). Small groups: glare, defocus, shadow, hand and low light are on 3 to 9 pages each, so their signs are not settled. The 20 ladder pages are among the 96 and carry the same tags. On them the quarter-size copies lose most on the 5 defocus-tagged pages (44 points against 12, pooled), but that is native size, not focus: four of the five are PDF images 1,255 to 2,538 px long, which collapse at a quarter whatever their tags (the untagged 1,297 px page loses a median 98 points across routes), and the one defocus-tagged phone original loses nothing. No ladder tag effect is separable from native size on 20 pages.

96 pages tagged; 6 carry no tag. Loss is in NES points, tagged page minus the pages of its kind and source class without that tag, on the same route (negative = the tag costs words; "any" is against the pages with no tag). Tags co-occur, so a tag's loss carries some of its companions'. "routes worse" counts routes whose paired loss is below zero; a tag on fewer than 3 paired pages is listed without a number.

## Per tag, over all routes

| tag | pages | severe | unpaired | median loss | median loss, severe only | routes worse |
|---|---:|---:|---:|---:|---:|---:|
| edge_cut | 19 | 2 | 0 | -6.4 | -0.6 | 26/29 |
| colour | 52 | 0 | 0 | -4.1 |  | 27/29 |
| mixed | 47 | 2 | 2 | -3.0 | -20.4 | 26/29 |
| neighbour | 67 | 18 | 2 | -1.9 | -5.2 | 21/29 |
| faint_ink | 16 | 1 | 0 | -1.8 | -8.8 | 20/29 |
| show_through | 61 | 12 | 2 | -0.7 | -5.2 | 21/29 |
| perspective | 23 | 0 | 0 | +1.1 |  | 12/29 |
| glare | 6 | 2 | 0 | +2.0 | +4.1 | 10/29 |
| defocus | 8 | 0 | 0 | +2.2 |  | 9/29 |
| shadow | 9 | 0 | 0 | +2.5 |  | 7/29 |
| curl | 15 | 0 | 0 | +2.6 |  | 5/29 |
| hand | 7 | 0 | 0 | +3.2 |  | 10/29 |
| low_light | 3 | 0 | 0 | +9.0 |  | 2/29 |
| motion_blur | 0 | 0 | 0 | too few |  |  |
| any | 90 | 33 | 49 | -3.4 | -5.3 | 29/29 |

## How far the two taggers agreed (presence, before the third look)

| tag | drafted and audited | blind | pages agreeing | kappa |
|---|---:|---:|---:|---:|
| neighbour | 67 | 48 | 77 | 0.60 |
| edge_cut | 18 | 8 | 82 | 0.39 |
| hand | 7 | 7 | 96 | 1.00 |
| perspective | 25 | 43 | 72 | 0.47 |
| curl | 15 | 25 | 86 | 0.69 |
| shadow | 10 | 27 | 75 | 0.33 |
| glare | 4 | 10 | 86 | 0.24 |
| low_light | 3 | 8 | 87 | 0.14 |
| motion_blur | 0 | 0 | 96 | 1.00 |
| defocus | 8 | 24 | 80 | 0.43 |
| colour | 53 | 57 | 74 | 0.53 |
| show_through | 63 | 56 | 89 | 0.85 |
| faint_ink | 16 | 13 | 87 | 0.64 |
| mixed | 47 | 45 | 84 | 0.75 |

## Per route, the tags with enough pages

| route | edge_cut | colour | mixed | neighbour | faint_ink | show_through | perspective | glare | defocus | shadow | curl | hand | low_light | any |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| apple-vision | -1.1 | -3.7 | -7.2 | -7.1 | -6.9 | -0.2 | -12.6 | -8.5 | -3.9 | +5.8 | +1.1 | -6.2 | -2.0 | -5.7 |
| claude-sonnet5.5 | -2.0 | -1.6 | -1.1 | +0.0 | +4.2 | -0.8 | +1.1 | +2.0 | +0.2 | +2.8 | +1.2 | +1.6 | +4.6 | -1.7 |
| gemini3.1-flash-lite | -12.1 | -2.3 | +0.8 | +1.2 | -0.8 | -2.1 | +3.4 | -2.6 | +4.1 | +4.1 | +1.7 | -2.4 | +8.1 | -3.5 |
| gemini3.1-pro | +1.2 | -3.4 | -1.8 | -0.8 | +1.1 | -0.2 | +0.2 | +1.0 | -0.2 | +1.2 | +2.8 | +2.6 | +3.1 | -1.4 |
| gemini3.5-flash | -3.2 | -5.1 | -0.8 | -2.0 | -6.9 | +0.9 | -2.9 | +2.6 | +3.7 | +2.5 | +5.4 | +4.2 | +8.8 | -1.1 |
| gemini3.5-flash-lite | +0.1 | -2.5 | -3.0 | -1.1 | +5.2 | +0.5 | +1.9 | +3.3 | -0.8 | +1.9 | +4.6 | +3.5 | +9.0 | -2.4 |
| gemini3.8-flash | -0.2 | -2.8 | -4.6 | -2.9 | -1.3 | +2.4 | -2.7 | +3.0 | -0.2 | +2.1 | +6.1 | +4.2 | +11.4 | -1.4 |
| gemma4-26b-a4b | -7.5 | -11.7 | -4.7 | +7.3 | -7.5 | +8.3 | +7.4 | -8.8 | -35.0 | +6.7 | -1.1 | -3.1 | +30.9 | -11.4 |
| gemma4-31b | -8.4 | -8.9 | -5.9 | -7.3 | -5.2 | +1.6 | -8.3 | +4.7 | +2.1 | +6.8 | -5.3 | -5.1 | +21.2 | -2.9 |
| gpt5.4-mini | -9.1 | -0.2 | +0.5 | +3.2 | -4.6 | -0.4 | +1.6 | +4.2 | -1.9 | +3.3 | +6.1 | +4.9 | +9.1 | -4.5 |
| gpt5.6-luna | -10.4 | -0.5 | +0.9 | +2.9 | -1.8 | -0.6 | +4.1 | +0.0 | -3.4 | +5.0 | +1.8 | +0.8 | +7.6 | -5.9 |
| lightonocr-3-4b-mlx8 | -4.1 | -6.0 | -2.0 | -1.8 | -5.5 | -5.6 | +1.5 | -1.1 | +5.5 | +2.5 | +11.7 | +10.5 | -3.8 | -7.0 |
| mistral-large4 | -7.8 | -3.4 | -2.3 | -1.9 | -2.0 | -1.1 | +3.3 | -5.1 | +5.6 | -5.2 | +5.5 | +5.5 | +8.3 | -3.4 |
| mistral-medium3.5 | -6.7 | -5.1 | -4.5 | -3.4 | -6.7 | -0.9 | +1.7 | -3.6 | +0.4 | +5.1 | +4.1 | -2.2 | +8.9 | -5.2 |
| mistral-ocr-4-1 | -6.9 | -4.3 | -4.6 | -1.5 | -2.1 | -1.1 | +2.8 | -4.7 | +2.3 | -0.7 | +1.7 | -2.3 | +7.2 | -4.4 |
| mistral-small-24b | -11.7 | -9.8 | -3.7 | +7.1 | -6.9 | -3.2 | -0.7 | -5.6 | +2.0 | -12.0 | -2.2 | -2.2 | +11.8 | -6.6 |
| qwen3-vl-235b | -6.4 | -5.9 | -2.4 | -2.6 | -1.2 | -0.7 | +0.4 | +2.9 | +2.6 | +0.3 | +2.9 | +5.7 | +7.6 | -2.6 |
| qwen3-vl-30b-a3b | -9.9 | -4.6 | -2.5 | -1.8 | +0.0 | -2.3 | -5.8 | +3.9 | +4.0 | +6.7 | -3.4 | -10.2 | +16.8 | -2.3 |
| qwen3-vl-8b | -7.0 | -6.2 | -6.0 | -6.1 | -2.4 | -0.0 | -0.8 | +5.6 | +4.9 | +4.2 | -0.5 | +1.9 | +13.8 | -2.2 |
| qwen3-vl-8b-mlx4 | -11.3 | +1.8 | -7.6 | -7.0 | -4.3 | +8.4 | -6.7 | +5.2 | +5.2 | +3.9 | +0.8 | +7.6 | +15.3 | -7.4 |
| qwen3.5-27b | +6.1 | -3.2 | -15.0 | -9.4 | +10.8 | -4.5 | -0.1 | +9.8 | -9.4 | -1.4 | +3.1 | +9.7 | +15.8 | -21.3 |
| qwen3.5-35b-a3b | -6.4 | -3.3 | -3.5 | -0.9 | -9.5 | -2.7 | -5.2 | +1.9 | +4.4 | -4.7 | +9.1 | +5.1 | +15.5 | -7.9 |
| qwen3.5-397b | -3.8 | -4.8 | -1.5 | -2.6 | -0.2 | -1.0 | +1.7 | +3.8 | +3.3 | +1.7 | +5.2 | +4.9 | +9.6 | -2.5 |
| qwen3.5-9b | -6.8 | +2.8 | -4.2 | -6.7 | +3.5 | -3.3 | -7.3 | -4.0 | +4.2 | +6.5 | +10.4 | +8.5 | +17.1 | -11.1 |
| qwen3.5-9b-mlx4 | -2.4 | -5.9 | -5.4 | -5.8 | -9.9 | -1.7 | +1.8 | +4.9 | +9.1 | -2.2 | +8.4 | -8.0 | +11.2 | -2.6 |
| qwen3.6-27b | -4.4 | -4.2 | -0.9 | +0.5 | +1.9 | +0.2 | +3.5 | +0.4 | +1.8 | +1.2 | +2.6 | +3.5 | +7.4 | -0.8 |
| qwen3.6-27b-farmshare | -4.3 | -4.1 | -1.2 | -2.8 | +0.8 | -0.0 | +1.2 | +2.8 | +2.2 | +1.5 | +2.6 | +3.3 | +6.8 | -1.1 |
| qwen3.6-35b-a3b | -6.2 | -3.0 | -3.1 | -4.1 | +1.1 | -1.5 | +1.2 | -4.1 | +4.3 | +2.9 | +1.4 | -1.8 | +9.4 | -4.5 |
| qwen3.8-flash | -2.3 | -4.3 | -1.6 | +1.2 | -0.1 | +0.9 | -2.0 | +2.2 | -3.1 | -2.7 | +2.6 | +3.2 | +6.9 | -2.8 |

## Where the tags fall (pages carrying each tag, by kind and source class)

| kind | source | pages | neighbour | edge_cut | hand | perspective | curl | shadow | glare | low_light | motion_blur | defocus | colour | show_through | faint_ink | mixed |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| handwritten | original | 16 | 12 | 3 | 0 | 1 | 0 | 2 | 1 | 0 | 0 | 0 | 6 | 12 | 0 | 9 |
| mixed | original | 2 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 2 | 1 | 2 |
| printed | original | 13 | 12 | 2 | 2 | 10 | 5 | 1 | 1 | 2 | 0 | 0 | 11 | 7 | 3 | 7 |
| printed | pdf image | 15 | 5 | 2 | 1 | 1 | 2 | 2 | 2 | 0 | 0 | 2 | 3 | 3 | 2 | 3 |
| typewritten | original | 32 | 26 | 9 | 2 | 7 | 5 | 3 | 1 | 1 | 0 | 1 | 20 | 26 | 4 | 17 |
| typewritten | pdf image | 18 | 10 | 3 | 2 | 4 | 3 | 1 | 1 | 0 | 0 | 5 | 11 | 11 | 6 | 9 |

## The resolution ladder (20 pages), drop from the original by tag

Mean NES drop (original minus the smaller copy), pooled over the local panel's routes. Small groups; read as a direction only.

| tag | tagged pages | half | quarter | untagged pages | half | quarter |
|---|---:|---:|---:|---:|---:|---:|
| neighbour | 14 | -2.3 | 14.1 | 6 | 2.0 | 32.7 |
| edge_cut | 3 | 0.2 | 1.9 | 17 | -1.2 | 22.8 |
| hand | 2 | -6.3 | 20.7 | 18 | -0.4 | 19.6 |
| perspective | 4 | -4.9 | 12.7 | 16 | -0.0 | 21.4 |
| curl | 2 | -6.5 | 17.8 | 18 | -0.4 | 19.9 |
| low_light | 1 | 0.1 | 4.7 | 19 | -1.1 | 20.5 |
| defocus | 5 | 3.2 | 44.2 | 15 | -2.4 | 11.5 |
| colour | 12 | -0.1 | 19.7 | 8 | -2.3 | 19.7 |
| show_through | 12 | -3.0 | 14.5 | 8 | 2.0 | 27.5 |
| faint_ink | 4 | 1.3 | 19.5 | 16 | -1.6 | 19.7 |
| mixed | 9 | -2.9 | 21.2 | 11 | 0.5 | 18.4 |
