"""The measurement card the segmentation report writers append (CLAUDE.md, "Every result carries a measurement card").

W46.seg-report-refresh (measurement review 2026-10-31 pass 2, P2-5): a writer that regenerates its whole report
writes the card itself, so a second offline generation keeps it. ``TRUTH`` is the segmentation truth as it now
stands, read from the committed public manifests so the hashes and counts cannot drift from the files scored.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

MANIFESTS = Path(__file__).resolve().parents[2] / "segbench-results" / "public-segmentation"


def public_truth() -> dict:
    """box -> sha256 of the committed manifest, the owner's rulings folded into it, and its unsure gaps."""
    out = {}
    for box in ("lincoln", "crest"):
        path = MANIFESTS / f"{box}.json"
        m = json.loads(path.read_text())
        rulings = (m.get("owner_rulings") or {}).get("gaps", ())
        out[box] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "ruled": len(rulings),
                    "unsure": [f"{u['left']}|{u['right']}" for u in m.get("unsure", ())]}
    return out


def _truth() -> str:
    pub = public_truth()
    parts = [f"{'Lincoln' if b == 'lincoln' else 'CREST'} (`{v['sha256'][:12]}…`: {v['ruled']} gaps owner-ruled, "
             f"unsure {', '.join(v['unsure']) or 'none'})" for b, v in pub.items()]
    return ("The owner's ruled boxes: development Dean, Deaver and Herrnstein, test Stanton and RG165; Stanton "
            "carries the owner's 2026-10-31 segmentation-sheet rulings (W46.seg-truth-rescore). The public boxes are "
            "agent-audited truths with the owner's rulings on their disputed gaps folded in: " + "; ".join(parts) +
            ". Their other gaps remain agent-audited. Unsure gaps are out of every boundary count; segment figures "
            "(pages exact, PQ) are the conditional reading, the route's own call at an unsure gap, so they are not "
            "one fixed truth across routes (W46.seg-unsure-mask, `score.py`).")


TRUTH = _truth()


def card(truth: str, selection: str, comparison: str, noise: str, scope: str) -> list[str]:
    """The card's lines, ending with a blank line."""
    return ["## Measurement card", "",
            f"- **Truth.** {truth}",
            f"- **Selection.** {selection}",
            f"- **Comparison.** {comparison}",
            f"- **Noise.** {noise}",
            f"- **Scope.** {scope}", ""]
