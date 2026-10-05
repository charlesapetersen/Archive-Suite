"""Gemini models and thinking levels compared on one development box (owner, 2026-10-05).

    python compare_gemini.py estimate [Deaver]   # countTokens (free) and a cost estimate per variant
    python compare_gemini.py collect [Deaver]    # the paid calls, cached per variant
    python compare_gemini.py report [Deaver]     # scores; writes segbench-results/gemini-variants-<box>.md

The owner asked which Gemini model is best, whether thinking helps, and whether a newer Lite model does
better, and preferred to spend less on a smaller sample. So: the W36.seg-second method unchanged
(method_gemini's windows, prompt g1, response schema, combining and assembly), with only the model and
thinkingLevel varied, on one box. Each variant has its own response cache and call log. The module
globals of method_gemini are swapped per variant; nothing else in it changes.

Prices are list prices found on 2026-10-05 (the models endpoint gives none), USD per million tokens,
standard tier; thinking is billed as output. Gemini 3.8 Flash is at its introductory price, which ends
31 Dec 2026 (then $1.50 / $7.50).
"""
from __future__ import annotations

import json
import sys

import data
import method_gemini as G
from score import derived, score_labels

# (model, thinkingLevel, USD/M in, USD/M out)
VARIANTS = [
    ("gemini-3.5-flash-lite", "minimal", 0.30, 2.50),
    ("gemini-3.8-flash", "low", 0.75, 3.75),  # minimal is refused by 3.8 Flash (HTTP 400)
    ("gemini-3.8-flash", "high", 0.75, 3.75),
]
BASE = "gemini-3.1-flash-lite", "minimal"  # W36.seg-second, cached under its own name


def use(model: str, thinking: str, p_in: float, p_out: float) -> str:
    tag = f"{model}-{thinking}"
    G.MODEL, G.THINKING, G.PRICE_IN, G.PRICE_OUT = model, thinking, p_in, p_out
    G.GEN_CONFIG = dict(G.GEN_CONFIG, thinkingConfig={"thinkingLevel": thinking})
    if (model, thinking) == BASE:
        G.CACHE = data.ResponseCache("window-gemini-lite")
        G.LOG = data.CACHE_DIR / "window-gemini-lite-calls.jsonl"
    else:
        G.CACHE = data.ResponseCache(f"window-{tag}")
        G.LOG = data.CACHE_DIR / f"window-{tag}-calls.jsonl"
    return tag


def calls(model: str) -> list[dict]:
    recs = [json.loads(l) for l in G.LOG.read_text().splitlines()] if G.LOG.exists() else []
    return [r for r in recs if r.get("event") in ("call", "parse-failure") and r.get("model") == model]


def score(name: str) -> dict:
    col = data.load(name)
    pred = G.WindowGemini(False).predict(col)
    return derived(score_labels(col.labels, pred.labels, name))


def report(name: str) -> str:
    lines = [f"# Gemini variants on {name} (development box)", "",
             "Same windows, prompt and assembly as W36.seg-second; only the model and thinkingLevel differ. "
             "Own photo labels. One box, so a difference of a few pages is within noise.", "",
             "| model | thinking | pages in exact doc | false splits | false merges | calls | thinking tokens/call "
             "| cost |", "|---|---|---|---|---|---|---|---|"]
    for model, thinking, p_in, p_out in [(*BASE, 0.25, 1.50)] + VARIANTS:
        use(model, thinking, p_in, p_out)
        row = score(name)
        cs = [c for c in calls(model) if c["collection"] == name]
        usd = sum(c["usd"] for c in cs)
        th = sum(c["thought"] for c in cs) / max(1, len(cs))
        lines.append(f"| {model} | {thinking} | {100 * row['pages_in_exact_doc']:.1f}% | {row['false_splits']} | "
                     f"{row['false_merges']} | {len(cs)} | {th:.0f} | ${usd:.2f} |")
    lines += ["", "Prices: list, standard tier, found 2026-10-05; 3.8 Flash at its introductory price to 31 Dec 2026. "
              "window-claude on this box: see window-claude-dev.tsv."]
    return "\n".join(lines) + "\n"


def main(argv) -> int:
    if not argv or argv[0] not in ("estimate", "collect", "report"):
        print(__doc__)
        return 2
    names = argv[1:] or ["Deaver"]
    G.refuse_test(names)
    if argv[0] == "report":
        for name in names:
            text = report(name)
            print(text)
            (data.HERE.parent.parent / "segbench-results" / f"gemini-variants-{name}.md").write_text(text)
        return 0
    for v in VARIANTS:
        print(f"== {use(*v)}", flush=True)
        G.estimate(names) if argv[0] == "estimate" else G.collect(names)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
