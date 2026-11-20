# The mixed-page pre-flag in the app against ATRIUM as the bench ran it (W47.wh-mixed-preflag)

The Processor's `MixedPagePreflag` (ATRIUM v4.3 converted to Core ML by `packages/VisionOCRKit/ops/convert-atrium.py`, installed from the pinned `atrium-page-kind.tgz` by the app's own installer, Pillow's bicubic squeeze reimplemented in Swift) read the 144 owner-labelled pages that `kind_atrium.py` scored in PyTorch (`kind-atrium/k144.npz`). Run by `scripts/segbench/mixed_preflag_parity.sh`; no reader, no money.

| measure | value |
|---|---:|
| pages read by both | 144 of 144 (0 unread by the app) |
| same top class | 144 of 144 |
| same mixed flag (top class TEXT) | 144 of 144 (30 flagged by the bench) |
| largest probability difference, median page | 0.00048 |
| largest probability difference, worst page | 0.09971 |
| app time a page, median (Core ML, first page includes loading) | 5.091 s |

The time is the Debug Processor's, whose Swift is unoptimised, so the resize dominates it; it is not the shipped app's time a page.

## Measurement card

- **Truth.** ATRIUM as W46.kind-atrium ran it, saved in `kind-atrium/k144.npz`: timm regnety_160 at revision 543216d6b7e1 in PyTorch, Pillow 13 bicubic squeeze to 384 px, ImageNet normalisation. No owner truth is involved: this checks the port, not the flag's accuracy.
- **Selection.** The 144 owner-labelled kind-classifier pages, the set the bench saved ATRIUM's probabilities for; not chosen by either side's calls.
- **Comparison.** The same files, decoded by Pillow for the bench and by ImageIO for the app; the same weights, class order and preprocessing (the resize ported from Pillow and checked against it on two fixed cases).
- **Noise.** Deterministic on both sides; the residual probability differences come from the two JPEG decoders and Core ML against PyTorch arithmetic. A flag that differed would be a port defect, not noise.
- **Scope.** The flag's recall and precision (51-60% and 69.8%, finite bounds 18-95% and 7-97%) are kind-atrium.md §5's, on the 2,000 bulk pages under the owner's cut; their page images are in the owner's backup (MOVED), so they were not re-read here. This does not re-measure them.

