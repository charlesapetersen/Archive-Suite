"""The measurement card the OCR report writers append (CLAUDE.md, "Every result carries a measurement card").

W46.ocr-audit-report-fix (measurement review 2026-10-31 pass 3, P3-2): a writer that regenerates its whole report
writes the card itself, so a second offline generation keeps it. ``TRUTH_96`` is the owner pages' truth and the
owner checks made of it so far, dated, so every OCR card states the same provenance; `seg_card.card` lays it out.
"""
from __future__ import annotations

from seg_card import card  # noqa: F401  (re-exported: one card layout for every report)

TRUTH_96 = (
    "The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 "
    "Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 "
    "(W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked "
    "samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, "
    "`ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or "
    "LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, "
    "`ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader "
    "disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake.")

# W46.ocr-96-vision-filter (measurement review pass 8, P8-3): the draw's MIN_WORDS filter read every candidate
# with Apple Vision, so the 96 are conditional on Vision. Every Selection line about the 96 carries this.
DRAW_96 = ("Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, "
           "4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every "
           "comparison with Vision on them is on pages Vision could read.")

NOISE_96 = ("The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired "
            "interval across 0, is a tie.")
