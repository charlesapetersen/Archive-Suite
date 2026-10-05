"""The on-device feature model (W36.seg-features, checkpoint 1): logistic regression on the
per-boundary features of features.py, trained leave-one-collection-out on the development set.

    python method_features.py      # both variants (with and without the time gap) through run.py,
                                   # then the risk-coverage / calibration / weights report

For a held-out development collection the model is fitted on the OTHER two development
collections' document gaps and predicts this one's; it refuses anything else, and it is marked
``tuning`` so the bench's guard refuses Stanton and RG 165. The output confidence of a boundary
is the model's probability of the decision it took, max(p, 1-p), where p = P(new document).

Box/folder photo labels are taken from the truth (``oracle_photos``), as the bench's baselines
do: a gap beside a photo is a boundary by construction (confidence 1), and the page after a
photo opens a document. Only gaps between two document pages are learned and scored.

Fixed choices, none tuned on the held-out collection: features standardised on the training
fold, L2 penalty LAMBDA, decision threshold 0.5.
"""
from __future__ import annotations

import sys

import numpy as np

import data
import features as F
from methods import METHODS, Method, Prediction
from score import PHOTO, boundaries_from_labels, segment_ids

LAMBDA = 1.0   # L2 penalty on standardised weights (sum, not mean, over the training rows)


# --- the classifier -----------------------------------------------------------------------

def sigmoid(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))


class Logistic:
    """L2-regularised logistic regression fitted by Newton's method on standardised inputs.
    The intercept is not penalised; constant columns get weight 0."""

    def __init__(self, lam: float = LAMBDA, iters: int = 50):
        self.lam, self.iters = lam, iters

    def fit(self, X: np.ndarray, y: np.ndarray) -> "Logistic":
        X = np.asarray(X, float)
        y = np.asarray(y, float)
        self.mu = X.mean(axis=0)
        sd = X.std(axis=0)
        self.sd = np.where(sd > 1e-12, sd, 1.0)
        Z = np.hstack([np.ones((len(X), 1)), (X - self.mu) / self.sd])
        w = np.zeros(Z.shape[1])
        pen = np.full(Z.shape[1], self.lam)
        pen[0] = 0.0
        for _ in range(self.iters):
            p = sigmoid(Z @ w)
            g = Z.T @ (p - y) + pen * w
            H = (Z * (p * (1 - p))[:, None]).T @ Z + np.diag(pen) + 1e-9 * np.eye(len(w))
            step = np.linalg.solve(H, g)
            w -= step
            if np.max(np.abs(step)) < 1e-8:
                break
        self.w = w
        return self

    @property
    def coef(self) -> np.ndarray:
        """Weights on the standardised features (comparable across features)."""
        return self.w[1:]

    def predict_proba(self, X: np.ndarray) -> np.ndarray:
        Z = (np.asarray(X, float) - self.mu) / self.sd
        return sigmoid(self.w[0] + Z @ self.w[1:])


def log_loss(y, p) -> float:
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


# --- data for one collection ----------------------------------------------------------------

_CACHE: dict[str, tuple] = {}


def doc_gaps(labels: list[str]) -> tuple[np.ndarray, np.ndarray]:
    """(mask over gaps that lie between two document pages, truth boundary at each gap)."""
    ids = segment_ids(labels)
    mask = np.array([labels[i] not in PHOTO and labels[i + 1] not in PHOTO for i in range(len(labels) - 1)])
    y = np.array([ids[i] != ids[i + 1] for i in range(len(labels) - 1)], dtype=float)
    return mask, y


def collection_xy(name: str):
    """(collection, full gap feature matrix, document-gap mask, truth boundaries), memoised."""
    if name not in _CACHE:
        col = data.load(name)
        X = F.collection_features(col)
        mask, y = doc_gaps(col.labels)
        _CACHE[name] = (col, X, mask, y)
    return _CACHE[name]


def columns(with_time: bool) -> list[int]:
    return [i for i, k in enumerate(F.FEATURES) if with_time or k not in F.TIME_FEATURES]


def fit_fold(held_out: str, with_time: bool) -> Logistic:
    cols = columns(with_time)
    train = [n for n in data.DEV if n != held_out]
    X = np.vstack([collection_xy(n)[1][collection_xy(n)[2]][:, cols] for n in train])
    y = np.concatenate([collection_xy(n)[3][collection_xy(n)[2]] for n in train])
    return Logistic().fit(X, y)


def labels_from_probs(truth_labels: list[str], p_new: np.ndarray, threshold: float = 0.5) -> list[str]:
    """Photo pages keep their truth label; a document page after a photo (or first) is New;
    otherwise New when P(new) at the gap before it is at least the threshold."""
    out = []
    for j, lab in enumerate(truth_labels):
        if lab in PHOTO:
            out.append(lab)
        elif j == 0 or truth_labels[j - 1] in PHOTO:
            out.append("New")
        else:
            out.append("New" if p_new[j - 1] >= threshold else "Cont")
    return out


class FeatureModel(Method):
    tuning = True
    oracle_photos = True

    def __init__(self, with_time: bool):
        self.with_time = with_time
        self.name = "features-lr" if with_time else "features-lr-notime"
        self.description = ("logistic regression on text, image" + (" and capture-time-gap" if with_time else "")
                            + " features of each boundary, leave-one-collection-out over the development set "
                            "(fitted on the other two); photo labels from the truth")
        self.last: dict[str, np.ndarray] = {}

    def predict(self, collection) -> Prediction:
        if collection.name not in data.DEV:
            raise ValueError(f"{self.name}: leave-one-collection-out is defined on the development set only")
        _, X, mask, _ = collection_xy(collection.name)
        model = fit_fold(collection.name, self.with_time)
        p = model.predict_proba(X[:, columns(self.with_time)])
        self.last[collection.name] = p
        labels = labels_from_probs(collection.labels, p)
        bounds = []
        for i, d in enumerate(boundaries_from_labels(labels)):
            if mask[i]:
                bounds.append({"decision": d, "confidence": float(max(p[i], 1 - p[i])),
                               "cue": f"p(new)={p[i]:.3f}"})
            else:
                bounds.append({"decision": d, "confidence": 1.0, "cue": "photo (oracle)"})
        return Prediction(labels, bounds)


FEATURE_METHODS = {m.name: m for m in (FeatureModel(True), FeatureModel(False))}
METHODS.update(FEATURE_METHODS)


# --- the report: risk-coverage, calibration, weights ----------------------------------------

DIAGNOSTIC_FEATURES = ("next_salutation", "prev_closing", "next_pn_any_ge2", "next_date_top", "tfidf_cosine",
                       "next_starts_lower", "orientation_change", "paper_diff", "log_time_gap")
THRESHOLDS = (0.99, 0.98, 0.95, 0.9, 0.85, 0.8, 0.7, 0.6, 0.5)


def held_out_probs(with_time: bool) -> dict[str, tuple[np.ndarray, np.ndarray, int]]:
    """Per development collection: (P(new) on its document gaps, truth on them, pages)."""
    out = {}
    for n in data.DEV:
        col, X, mask, y = collection_xy(n)
        p = fit_fold(n, with_time).predict_proba(X[:, columns(with_time)])
        out[n] = (p[mask], y[mask], len(col.pages))
    return out


def risk_coverage_rows(p: np.ndarray, y: np.ndarray, pages: int) -> list[tuple]:
    """(threshold, accepted, coverage, errors among accepted, error rate, review per 100 pages)."""
    conf = np.maximum(p, 1 - p)
    wrong = (p >= 0.5) != (y > 0.5)
    rows = []
    for t in THRESHOLDS:
        acc = conf >= t
        a = int(acc.sum())
        e = int(wrong[acc].sum())
        rows.append((t, a, a / len(p), e, (e / a) if a else None, 100 * (len(p) - a) / pages))
    return rows


def best_at_coverage(p, y, min_cov=0.5):
    """Lowest error rate among the most-confident k gaps, over every k with k/n >= min_cov."""
    conf = np.maximum(p, 1 - p)
    order = np.argsort(-conf, kind="stable")
    wrong = ((p >= 0.5) != (y > 0.5))[order]
    cum = np.cumsum(wrong)
    k = np.arange(1, len(p) + 1)
    ok = k / len(p) >= min_cov
    rate = cum / k
    i = int(np.argmin(np.where(ok, rate, np.inf)))
    return k[i] / len(p), float(rate[i]), int(cum[i]), int(k[i])


def calibration(p, y, bins=10) -> list[tuple]:
    out = []
    for b in range(bins):
        lo, hi = b / bins, (b + 1) / bins
        m = (p >= lo) & ((p < hi) if b < bins - 1 else (p <= hi))
        out.append((lo, hi, int(m.sum()), float(p[m].mean()) if m.any() else None,
                    float(y[m].mean()) if m.any() else None))
    return out


def permutation_importance(with_time: bool, repeats: int = 20, seed: int = 0) -> np.ndarray:
    """Rise in pooled held-out log loss when one feature's column is shuffled within the
    held-out collection (the fold models are fixed). One value per used feature."""
    rng = np.random.default_rng(seed)
    cols = columns(with_time)
    base_p, ys, folds = [], [], []
    for n in data.DEV:
        _, X, mask, y = collection_xy(n)
        m = fit_fold(n, with_time)
        Xh = X[mask][:, cols]
        folds.append((m, Xh))
        base_p.append(m.predict_proba(Xh))
        ys.append(y[mask])
    y_all = np.concatenate(ys)
    base = log_loss(y_all, np.concatenate(base_p))
    imp = np.zeros(len(cols))
    for j in range(len(cols)):
        rises = []
        for _ in range(repeats):
            ps = []
            for m, Xh in folds:
                Xp = Xh.copy()
                Xp[:, j] = rng.permutation(Xp[:, j])
                ps.append(m.predict_proba(Xp))
            rises.append(log_loss(y_all, np.concatenate(ps)) - base)
        imp[j] = float(np.mean(rises))
    return imp


def _pct(v):
    return "—" if v is None else f"{100 * v:.1f}%"


def _headline(rows):
    return {r["collections"].replace("POOLED ", "pooled "): r for r in rows}


def report(headlines: dict[str, list[dict]]) -> tuple[str, str]:
    """(the full report markdown, the SUMMARY.md section)."""
    md = ["# features-lr — risk-coverage, calibration and weights (development set, leave-one-collection-out)", "",
          "W36.seg-features checkpoint 1. Logistic regression (L2, lambda "
          f"{LAMBDA}, standardised features, threshold 0.5, none tuned) on per-boundary text, image and "
          "capture-time features; each development collection is predicted by a model fitted on the other two. "
          "Measured on Dean, Deaver, Herrnstein; tuned on nothing but the fixed choices above; Stanton and RG 165 "
          "not touched. Photo labels from the truth. Only gaps between two document pages are counted. "
          "551 pages (about 480 document gaps, two collections per fit) is little data: per-collection numbers "
          "move by several points with one or two boundaries, and the weights below are not stable across folds.",
          ""]
    summary = ["", "## W36.seg-features checkpoint 1 — on-device feature model (development set, leave-one-collection-out)", "",
               "Logistic regression on rule cues, TF-IDF similarity, length, blank, paper colour, ink, aspect and "
               "capture-time features; each development collection predicted by a model fitted on the other two "
               "(Stanton and RG 165 untouched; photo labels from the truth). 551 pages is little data. "
               "Embedding features (image and text) are checkpoint 2. Detail: features-lr-report.md.", "",
               "| variant | collection | pages in exact doc | false splits | false merges | boundary F1 | "
               "error rate at the best >=50% coverage | Brier |",
               "|---|---|---:|---:|---:|---:|---:|---:|"]
    for with_time in (True, False):
        name = "features-lr" if with_time else "features-lr-notime"
        label = "with the time gap" if with_time else "without the time gap"
        probs = held_out_probs(with_time)
        hl = _headline(headlines[name])
        md += [f"## {name} ({label})", "",
               "| collection | pages in exact doc | false splits | false merges | boundary F1 | log loss | Brier |",
               "|---|---:|---:|---:|---:|---:|---:|"]
        groups = list(probs.items()) + [("pooled", (np.concatenate([v[0] for v in probs.values()]),
                                                    np.concatenate([v[1] for v in probs.values()]),
                                                    sum(v[2] for v in probs.values())))]
        for key, (p, y, _) in groups:
            r = next(v for k, v in hl.items() if k == key or k.startswith(key))
            f1 = "—" if r["boundary_f1"] is None else f"{r['boundary_f1']:.3f}"
            brier = float(np.mean((p - y) ** 2))
            md.append(f"| {key} | {_pct(r['pages_in_exact_doc'])} | {r['false_splits']} | {r['false_merges']} | "
                      f"{f1} | {log_loss(y, p):.3f} | {brier:.3f} |")
            cov, rate, e, k = best_at_coverage(p, y)
            summary.append(f"| {label} | {key} | {_pct(r['pages_in_exact_doc'])} | {r['false_splits']} | "
                           f"{r['false_merges']} | {f1} | {_pct(rate)} ({e}/{k}, coverage {_pct(cov)}) | {brier:.3f} |")
        md += ["", "Risk-coverage: a boundary is auto-accepted when the model's confidence in its decision, "
               "max(p, 1-p), is at least the threshold; the rest go to review.", ""]
        for key, (p, y, pages) in groups:
            md += [f"**{key}** ({len(p)} document gaps)", "",
                   "| threshold | accepted | coverage | errors among accepted | error rate | review per 100 pages |",
                   "|---:|---:|---:|---:|---:|---:|"]
            for t, a, c, e, er, rv in risk_coverage_rows(p, y, pages):
                md.append(f"| {t:.2f} | {a} | {_pct(c)} | {e} | {_pct(er)} | {rv:.1f} |")
            cov, rate, e, k = best_at_coverage(p, y)
            md += ["", f"Best error rate at coverage of at least 50%: {_pct(rate)} ({e} of the {k} most "
                   f"confident gaps, coverage {_pct(cov)}); the cut is chosen on these same predictions, so this "
                   "is optimistic.", ""]
        p_all, y_all = groups[-1][1][0], groups[-1][1][1]
        md += ["Calibration (pooled held-out predictions, P(new document) in ten equal-width bins):", "",
               "| P(new) bin | gaps | mean predicted | observed share new |", "|---|---:|---:|---:|"]
        for lo, hi, n, mp, ob in calibration(p_all, y_all):
            md.append(f"| {lo:.1f}–{hi:.1f} | {n} | {'—' if mp is None else f'{mp:.3f}'} | "
                      f"{'—' if ob is None else f'{ob:.3f}'} |")
        cols = columns(with_time)
        names = [F.FEATURES[c] for c in cols]
        coefs = np.array([fit_fold(n, with_time).coef for n in data.DEV])
        imp = permutation_importance(with_time)
        order = np.argsort(-imp)
        md += ["", "Weights: standardised logistic weights per fold (positive = favours a new document; the "
               "fold is named by its held-out collection) and permutation importance (rise in pooled held-out "
               "log loss when the feature is shuffled within the held-out collection; mean of 20 shuffles). "
               "Sorted by importance.", "",
               "| feature | importance | weight (Dean out) | weight (Deaver out) | weight (Herrnstein out) |",
               "|---|---:|---:|---:|---:|"]
        for j in order:
            md.append(f"| {names[j]} | {imp[j]:.4f} | " + " | ".join(f"{coefs[f, j]:+.2f}" for f in range(3)) + " |")
        md.append("")
        if with_time:
            t = names.index("log_time_gap")
            rank = int(np.where(order == t)[0][0]) + 1
            md += [f"The time gap ranks {rank} of {len(names)} by importance ({imp[t]:.4f}); the largest is "
                   f"{names[order[0]]} ({imp[order[0]]:.4f}).", ""]
            summary_time = (f"With the time gap, it ranks {rank} of {len(names)} features by permutation importance; "
                            f"the strongest is {names[order[0]]}.")
        else:
            top = ", ".join(names[j] for j in order[:5])
            summary_top = f"Top features without the time gap: {top}."
    md += ["## Why the held-out collections differ", "",
           "Mean of selected features at true boundaries (new) and true continuations (cont), per collection. "
           "A feature that separates the classes in only one collection cannot be learned when that collection "
           "is held out: the model is fitted on the other two.", "",
           "| feature | " + " | ".join(f"{n} new | {n} cont" for n in data.DEV) + " |",
           "|---|" + "---:|---:|" * len(data.DEV)]
    for k in DIAGNOSTIC_FEATURES:
        j = F.FEATURES.index(k)
        cells = []
        for n in data.DEV:
            _, X, mask, y = collection_xy(n)
            Xm, ym = X[mask], y[mask]
            cells += [f"{Xm[ym == 1, j].mean():.3f}", f"{Xm[ym == 0, j].mean():.3f}"]
        md.append(f"| {k} | " + " | ".join(cells) + " |")
    md.append("")
    summary += ["", summary_time + " " + summary_top,
                "", "Reading (as of the 2026-10-05 run): the pooled figures are pulled down by Deaver, mostly newspaper "
                "clippings. Its boundaries carry none of the letter cues the other two collections teach (salutation, "
                "closing), and the features that do separate them there (TF-IDF similarity, a lower-case first line, "
                "orientation change) are flat in Dean and Herrnstein, so the model fitted on those two calls nearly "
                "every Deaver gap a continuation. Two collections per fit cannot teach a third document type. The "
                "'best >=50% coverage' column picks its cut on the same held-out predictions, so it is optimistic; "
                "the threshold rows in the report are the fixed-cut view."]
    return "\n".join(md) + "\n", "\n".join(summary) + "\n"


def main() -> int:
    import run
    headlines = {}
    for name in FEATURE_METHODS:
        rows = run.run(name, list(data.DEV), False)
        run.write(name, list(data.DEV), rows)
        headlines[name] = rows
    full, section = report(headlines)
    (run.RESULTS / "features-lr-report.md").write_text(full)
    (run.RESULTS / "features-lr.summary-section.md").write_text(section)
    run.write_summary()
    print(section)
    return 0


if __name__ == "__main__":
    # Run through the imported module so run.py's METHODS and this share one feature cache.
    from method_features import main as _main
    sys.exit(_main())
