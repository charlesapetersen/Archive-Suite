"""W46.fix-seg-scorers: do letter cues and layout regions lift the on-device feature model?

    <lab venv>/bin/python features_cues.py --public-root DIR    # -> segbench-results/features-cues.md + .json

Needs layout.py's detector pass over the owner boxes and the public boxes first. No calls, no money.

THE NEW CUES, beside the feature model's own columns (features.py, unchanged, so every earlier figure stands):
* LETTER (G-entities test 4, feature arm). The salutation and closing patterns entity_probe.py measured over
  35,563 cleaned gaps (90% precision at 24% recall), on the 12 non-blank lines at the head of the right page and
  the foot of the left, with the running-header exclusion that note proposed: a head line of the right page that
  also stands, letter for letter once case, spaces and punctuation are dropped, among the left page's head lines
  is a running header ("To: M. M. May" on every page of a memo). Four columns: ``g_salutation`` (a salutation
  line that is not a running header), ``g_closing``, ``g_both`` and ``g_running_header``. features.py's own,
  narrower salutation and closing columns stay in the base model.
* LAYOUT (E-layout test 6). PP-DocLayoutV3's regions grouped into title, header, footer, text, number, image,
  table, seal and other: a title or header region in the top fifth of the right page, a document title anywhere
  on it, a right page holding only text, number and footer regions, a seal on either page, an image on either
  page, a table on the right page, the L1 distance between the two pages' group shares, and the region count of
  the right page and its change.

THE TEST. The model, threshold and penalty are method_features' (logistic regression, L2 1.0, threshold 0.5),
without the capture-time gap (the owner's "not a very reliable clue"), with and without the on-device embeddings.
Development boxes: leave-one-collection-out, each box predicted by a fit on the other two, pooled. Lincoln and
CREST: a fit on all three development boxes, without embeddings (they are not computed on the public pages). The
locked test boxes are not used: this is still a model being tuned. Review load is the owner's bar: per box, the
fewest least-confident gaps that must be reviewed (taking the truth's decision) for 98% of pages to sit in an
exact document.
"""
from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path

import numpy as np

import data
import features as F
import layout as LY
import method_features as MF
from score import PHOTO, derived, score_labels

RESULTS = data.HERE.parent.parent / "segbench-results"
OUT_MD, OUT_JSON = RESULTS / "features-cues.md", RESULTS / "features-cues.json"

# entity_probe.py's patterns, as measured there.
SAL = re.compile(r"^\s*(dear\b|my dear\b|gentlemen\b|dear sirs?\b|sirs?\s*[:,]|madam|to\s*:|memorandum|memo\b|"
                 r"honorable|hon\.|the honorable|mr\.? president|your excellency|messrs)", re.I)
CLO = re.compile(r"(sincerely|cordially|yours (very )?truly|very truly yours|yours (sincerely|faithfully|respectfully)|"
                 r"respectfully( yours| submitted)?|faithfully yours|with (best|kind|warm|all good) (regards|wishes)|"
                 r"best (regards|wishes)|affectionately|as ever|yours,|yours ever|\benc(l|los)?[s.]|\bcc\s*:|/s/|"
                 r"kind regards|warm regards|with love)", re.I)
EDGE_LINES = 12
MIN_HEADER = 6      # alphanumeric characters a line needs before it can be called a running header

LETTER_FEATURES = ("g_salutation", "g_closing", "g_both", "g_running_header")
GROUPS = {"doc_title": "title", "paragraph_title": "title", "figure_title": "title", "header": "header",
          "footer": "footer", "footnote": "footer", "vision_footnote": "footer", "text": "text",
          "content": "text", "abstract": "text", "reference": "text", "reference_content": "text",
          "aside_text": "text", "number": "number", "image": "image", "chart": "image", "table": "table",
          "seal": "seal"}
GROUP_ORDER = ("title", "header", "footer", "text", "number", "image", "table", "seal", "other")
LAYOUT_FEATURES = ("lay_next_title_top", "lay_next_doc_title", "lay_next_text_only", "lay_prev_seal",
                   "lay_next_seal", "lay_prev_image", "lay_next_image", "lay_next_table", "lay_hist_l1",
                   "lay_log_regions_next", "lay_region_change")
TOP_FIFTH = 200     # page coordinates run 0-1000


def _lines(text):
    return [l for l in (text or "").splitlines() if l.strip()]


def _norm(line: str) -> str:
    return re.sub(r"[^a-z0-9]", "", line.lower())


def letter_features(a: str | None, b: str | None) -> list[float]:
    head_a = {_norm(l) for l in _lines(a)[:EDGE_LINES]}
    head_b, foot_a = _lines(b)[:EDGE_LINES], _lines(a)[-EDGE_LINES:]
    repeated = [l for l in head_b if len(_norm(l)) >= MIN_HEADER and _norm(l) in head_a]
    sal = any(SAL.match(l) and l not in repeated for l in head_b)
    clo = any(CLO.search(l) for l in foot_a)
    return [float(sal), float(clo), float(sal and clo), float(bool(repeated))]


def _groups(regions: list[dict]) -> list[str]:
    return [GROUPS.get(r["label"], "other") for r in regions]


def layout_features(ra: list[dict], rb: list[dict]) -> list[float]:
    ga, gb = _groups(ra), _groups(rb)
    ha = np.array([ga.count(g) for g in GROUP_ORDER], float)
    hb = np.array([gb.count(g) for g in GROUP_ORDER], float)
    l1 = float(np.abs(ha / max(1, ha.sum()) - hb / max(1, hb.sum())).sum())
    top = any(g in ("title", "header") and r["bbox"][0] < TOP_FIFTH for r, g in zip(rb, gb))
    return [float(top), float(any(r["label"] == "doc_title" for r in rb)),
            float(bool(gb) and set(gb) <= {"text", "number", "footer"}),
            float("seal" in ga), float("seal" in gb), float("image" in ga), float("image" in gb),
            float("table" in gb), l1, math.log1p(len(rb)), abs(math.log1p(len(ra)) - math.log1p(len(rb)))]


def extra_matrix(col) -> np.ndarray:
    """(pages-1) x (letter + layout) columns, one row per gap, LETTER_FEATURES then LAYOUT_FEATURES."""
    texts = [col.text(i) for i in range(len(col.pages))]
    regions = LY.read(col.name)
    missing = [p.n for p in col.pages if regions is None or p.n not in regions]
    if missing:
        raise RuntimeError(f"{col.name}: no layout for pages {missing[:5]}…; run layout.py first")
    rows = []
    for i in range(len(col.pages) - 1):
        ra, rb = regions[col.pages[i].n], regions[col.pages[i + 1].n]
        rows.append(letter_features(texts[i], texts[i + 1]) + layout_features(ra, rb))
    return np.array(rows, float)


N_LETTER, N_LAYOUT = len(LETTER_FEATURES), len(LAYOUT_FEATURES)
EXTRAS = {"none": [], "letter": list(range(N_LETTER)), "layout": list(range(N_LETTER, N_LETTER + N_LAYOUT)),
          "letter+layout": list(range(N_LETTER + N_LAYOUT))}


# --- evaluation -----------------------------------------------------------------------------------

def design(X_base, X_extra, emb: bool, extra: str) -> np.ndarray:
    return np.hstack([X_base[:, MF.columns(False, emb)], X_extra[:, EXTRAS[extra]]])


def pages_exact(labels, pred) -> float:
    return derived(score_labels(labels, pred))["pages_in_exact_doc"]


def review_load(labels, p, mask, y, bar: float = 0.98) -> int:
    """Fewest least-confident document gaps to review (taking the truth) for ``bar`` of pages exact."""
    gaps = [i for i in range(len(mask)) if mask[i]]
    order = sorted(gaps, key=lambda i: max(p[i], 1 - p[i]))
    q = p.copy()
    for k in range(len(order) + 1):
        if pages_exact(labels, MF.labels_from_probs(labels, q)) >= bar:
            return k
        if k < len(order):
            q[order[k]] = y[order[k]]
    return len(order)


def evaluate(cols: dict, preds: dict) -> dict:
    """Pooled figures over the boxes in ``preds`` (name -> P(new) per gap)."""
    total, loss, n, review, gaps = None, 0.0, 0, 0, 0
    per_box = {}
    for name, p in preds.items():
        col, (mask, y) = cols[name], MF.doc_gaps(cols[name].labels)
        c = score_labels(col.labels, MF.labels_from_probs(col.labels, p), name)
        total = c if total is None else total + c
        loss += MF.log_loss(y[mask], p[mask]) * mask.sum()
        n += mask.sum()
        r = review_load(col.labels, p, mask, y)
        review, gaps = review + r, gaps + int(mask.sum())
        per_box[name] = {"pages_exact": derived(c)["pages_in_exact_doc"], "review": r, "gaps": int(mask.sum())}
    m = derived(total)
    return {"pages_exact": m["pages_in_exact_doc"], "false_splits": m["false_splits"],
            "false_merges": m["false_merges"], "kappa": m["kappa"], "pq": m["pq"], "mndd": m["mndd"],
            "log_loss": loss / n, "review_gaps": review, "doc_gaps": gaps, "per_box": per_box}


def run(public_root: Path) -> dict:
    dev = {}
    for name in data.DEV:
        col, X, mask, y = MF.collection_xy(name)
        dev[name] = (col, X, extra_matrix(col), mask, y)
    data.CACHE_DIR = public_root / "cache"
    import public_segmentation as P
    pub = {}
    for box in ("lincoln", "crest"):
        col = P.load(box, public_root)[0]
        X = F.collection_features(col, with_images=True, with_embeddings=False)
        mask, y = MF.doc_gaps(col.labels)
        pub[col.name] = (col, X, extra_matrix(col), mask, y)
    cols = {k: v[0] for k, v in {**dev, **pub}.items()}

    out = {"dev": {}, "public": {}, "weights": {}}
    for emb in (False, True):
        for extra in EXTRAS:
            key = f"{'emb' if emb else 'base'}+{extra}"
            preds = {}
            for held in data.DEV:
                train = [n for n in data.DEV if n != held]
                Xt = np.vstack([design(dev[n][1], dev[n][2], emb, extra)[dev[n][3]] for n in train])
                yt = np.concatenate([dev[n][4][dev[n][3]] for n in train])
                model = MF.Logistic().fit(Xt, yt)
                preds[held] = model.predict_proba(design(dev[held][1], dev[held][2], emb, extra))
            out["dev"][key] = evaluate(cols, preds)
            if not emb:
                Xa = np.vstack([design(dev[n][1], dev[n][2], False, extra)[dev[n][3]] for n in data.DEV])
                ya = np.concatenate([dev[n][4][dev[n][3]] for n in data.DEV])
                model = MF.Logistic().fit(Xa, ya)
                out["public"][key] = {name: evaluate(cols, {name: model.predict_proba(design(v[1], v[2], False, extra))})
                                      for name, v in pub.items()}
                if extra == "letter+layout":
                    names = [F.FEATURES[i] for i in MF.columns(False, False)] + list(LETTER_FEATURES + LAYOUT_FEATURES)
                    out["weights"] = dict(zip(names, (round(float(w), 3) for w in model.coef)))
    # How often the new cues fire, over the development boxes' document gaps, and their precision there.
    fires = {}
    for j, fname in enumerate(LETTER_FEATURES + LAYOUT_FEATURES[:8]):
        on = bound = total_b = 0
        for name in data.DEV:
            _, _, E, mask, y = dev[name]
            hit = E[mask][:, j] > 0.5
            on += int(hit.sum())
            bound += int((hit & (y[mask] > 0.5)).sum())
            total_b += int((y[mask] > 0.5).sum())
        fires[fname] = {"fires": on, "on_boundaries": bound, "boundaries": total_b}
    out["fires"] = fires
    return out


def _p(x):
    return "—" if x is None else f"{100 * x:.1f}%"


def render(r: dict) -> str:
    L = ["# Letter cues and layout regions in the feature model — W46.fix-seg-scorers", "",
         "Made by `scripts/segbench/features_cues.py` (definitions in its docstring) from cached Apple Vision text "
         "and the PP-DocLayoutV3 pass of `layout.py`; no calls. Development boxes leave-one-collection-out, pooled; "
         "Lincoln and CREST from a fit on all three development boxes. Review = least-confident document gaps "
         "reviewed for 98% of pages in an exact document, summed over boxes.", "",
         "## Development boxes (Dean, Deaver, Herrnstein), held out in turn", "",
         "| model | pages exact | Dean / Deaver / Herrnstein | false splits | false merges | kappa | PQ | MNDD | "
         "log loss | review for 98% |",
         "|---|---|---|---|---|---|---|---|---|---|"]
    for key, m in r["dev"].items():
        boxes = " / ".join(_p(m["per_box"][n]["pages_exact"]) for n in data.DEV)
        L.append(f"| {key} | {_p(m['pages_exact'])} | {boxes} | {m['false_splits']} | {m['false_merges']} | "
                 f"{m['kappa']:.3f} | {m['pq']:.3f} | {m['mndd']} | {m['log_loss']:.3f} | "
                 f"{m['review_gaps']} of {m['doc_gaps']} ({_p(m['review_gaps'] / m['doc_gaps'])}) |")
    for name in ("Lincoln", "CREST"):
        L += ["", f"## {name}, fitted on the development boxes, no embeddings", "",
              "| model | pages exact | false splits | false merges | kappa | PQ | MNDD | log loss | review for 98% |",
              "|---|---|---|---|---|---|---|---|---|"]
        for key, boxes in r["public"].items():
            m = boxes[name]
            L.append(f"| {key} | {_p(m['pages_exact'])} | {m['false_splits']} | {m['false_merges']} | "
                     f"{m['kappa']:.3f} | {m['pq']:.3f} | {m['mndd']} | {m['log_loss']:.3f} | "
                     f"{m['review_gaps']} of {m['doc_gaps']} ({_p(m['review_gaps'] / m['doc_gaps'])}) |")
    L += ["", "## How often the new cues fire (development document gaps)", "",
          "| cue | fires | on a true boundary | precision | recall |", "|---|---|---|---|---|"]
    for k, f in r["fires"].items():
        prec = f["on_boundaries"] / f["fires"] if f["fires"] else None
        L.append(f"| {k} | {f['fires']} | {f['on_boundaries']} | {_p(prec)} | {_p(f['on_boundaries'] / f['boundaries'])} |")
    L += ["", "## Standardised weights of the new columns (base+letter+layout, fit on all three development boxes)", "",
          "| column | weight |", "|---|---|"]
    for k in LETTER_FEATURES + LAYOUT_FEATURES:
        L.append(f"| {k} | {r['weights'][k]:+.3f} |")
    return "\n".join(L) + "\n"


def main(argv) -> int:
    if len(argv) != 2 or argv[0] != "--public-root":
        print(__doc__)
        return 2
    r = run(Path(argv[1]))
    OUT_JSON.write_text(json.dumps(r, indent=1) + "\n")
    OUT_MD.write_text(render(r))
    print(OUT_MD.read_text())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
