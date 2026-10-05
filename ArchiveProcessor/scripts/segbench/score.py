"""Score a segmentation against the ground truth (W36.seg-bench).

Every metric in execution-plans/segmentation/00-plan.md Part 2 "Metrics". Definitions:

* Segments are built from per-page labels exactly as the app's DocumentSegmenter does
  (Tagging/DocumentSegmenter.swift): a Box or Folder page is its own segment and closes any
  open document; New opens a document; Cont joins the open document, or opens one if none is
  open (start of stream, or straight after a photo).
* DOCUMENTS are the truth's non-photo segments; DOCUMENT PAGES are pages labelled New/Cont.
* HEADLINE, pages in an exact document: the share of document pages whose truth document
  appears, with exactly the same page set, as a predicted segment.
* Boundary metrics are over DOCUMENT GAPS only — consecutive pairs where both pages are
  document pages in the truth — so the trivial boundaries beside box/folder photos do not
  inflate them. A FALSE SPLIT is a predicted boundary where the truth continues; a FALSE MERGE
  is a missed truth boundary. Precision, recall and F1 are over truth boundaries.
* Pk and WindowDiff (Beeferman 1999; Pevzner & Hearst 2002) use the whole stream, photos as
  segments, k = half the mean truth segment length (at least 1). Lower is better.
* FOLDERS PERFECTLY SEGMENTED: a folder is a maximal run of document pages between photo pages
  (or stream ends); it is perfect when every truth document in it is exact.
* EDITS PER 100 PAGES: page labels the owner must change to make the prediction equal the truth,
  after canonicalising an orphan Cont (one with no open document) to New, per 100 pages.
* Box/folder photos are scored apart: truth photo pages given the exact label, document pages
  wrongly called a photo, and Box/Folder confused with each other.

Pooled figures sum the counts over collections (Pk/WindowDiff pool their windows), so a
pooled percentage is page- or item-weighted, not a mean of per-collection percentages.
"""
from __future__ import annotations

from dataclasses import dataclass, field

PHOTO = ("Box", "Folder")
VALID = ("Box", "Folder", "New", "Cont")


def segment_ids(labels: list[str]) -> list[int]:
    """Segment index of each page, the DocumentSegmenter way."""
    ids, cur, open_doc = [], -1, False
    for lab in labels:
        if lab not in VALID:
            raise ValueError(f"invalid label {lab!r}")
        if lab in PHOTO:
            cur += 1
            open_doc = False
        elif lab == "New" or not open_doc:
            cur += 1
            open_doc = True
        ids.append(cur)
    return ids


def canonical(labels: list[str]) -> list[str]:
    """Orphan Cont -> New, so two labellings with the same segmentation compare equal."""
    out, open_doc = [], False
    for lab in labels:
        if lab in PHOTO:
            out.append(lab)
            open_doc = False
        elif lab == "Cont" and not open_doc:
            out.append("New")
            open_doc = True
        else:
            out.append(lab)
            open_doc = True
    return out


def _groups(ids: list[int]) -> dict[int, frozenset]:
    g: dict[int, set] = {}
    for i, s in enumerate(ids):
        g.setdefault(s, set()).add(i)
    return {k: frozenset(v) for k, v in g.items()}


@dataclass
class Counts:
    """Additive counts; percentages are derived so pooling is a plain sum."""
    pages: int = 0
    doc_pages: int = 0
    pages_exact: int = 0
    docs: int = 0
    docs_exact: int = 0
    folders: int = 0
    folders_perfect: int = 0
    gaps: int = 0
    truth_bounds: int = 0
    tp: int = 0
    false_splits: int = 0
    false_merges: int = 0
    edits: int = 0
    photos: int = 0
    photos_exact: int = 0
    photo_type_swaps: int = 0
    photos_missed: int = 0
    false_photos: int = 0
    pk_windows: int = 0
    pk_errors: int = 0
    wd_errors: int = 0
    collections: list = field(default_factory=list)

    def __add__(self, o: "Counts") -> "Counts":
        out = Counts()
        for f in self.__dataclass_fields__:
            setattr(out, f, getattr(self, f) + getattr(o, f))
        return out


def _ratio(a: int, b: int) -> float | None:
    return a / b if b else None


def derived(c: Counts) -> dict:
    p = _ratio(c.tp, c.tp + c.false_splits)
    r = _ratio(c.tp, c.truth_bounds)
    f1 = (2 * p * r / (p + r)) if p is not None and r is not None and (p + r) else None
    return {
        "collections": "+".join(c.collections),
        "pages": c.pages,
        "doc_pages": c.doc_pages,
        "docs": c.docs,
        "pages_in_exact_doc": _ratio(c.pages_exact, c.doc_pages),
        "docs_exact": _ratio(c.docs_exact, c.docs),
        "folders": c.folders,
        "folders_perfect": _ratio(c.folders_perfect, c.folders),
        "false_splits": c.false_splits,
        "false_merges": c.false_merges,
        "boundary_precision": p,
        "boundary_recall": r,
        "boundary_f1": f1,
        "pk": _ratio(c.pk_errors, c.pk_windows),
        "windowdiff": _ratio(c.wd_errors, c.pk_windows),
        "edits_per_100_pages": _ratio(100 * c.edits, c.pages),
        "photos": c.photos,
        "photo_accuracy": _ratio(c.photos_exact, c.photos),
        "photo_type_swaps": c.photo_type_swaps,
        "photos_missed": c.photos_missed,
        "false_photos": c.false_photos,
    }


def score_labels(truth: list[str], pred: list[str], name: str = "") -> Counts:
    if len(truth) != len(pred):
        raise ValueError(f"{name}: {len(pred)} predicted labels for {len(truth)} pages")
    n = len(truth)
    t_ids, p_ids = segment_ids(truth), segment_ids(pred)
    t_groups, p_sets = _groups(t_ids), set(_groups(p_ids).values())
    c = Counts(pages=n, collections=[name] if name else [])
    is_doc = [lab not in PHOTO for lab in truth]

    # Documents and the headline.
    exact_pages: set[int] = set()
    for s, pages in t_groups.items():
        if truth[min(pages)] in PHOTO:
            continue
        c.docs += 1
        c.doc_pages += len(pages)
        if pages in p_sets:
            c.docs_exact += 1
            c.pages_exact += len(pages)
            exact_pages |= pages

    # Folders: maximal runs of document pages.
    i = 0
    while i < n:
        if not is_doc[i]:
            i += 1
            continue
        j = i
        while j < n and is_doc[j]:
            j += 1
        c.folders += 1
        if all(k in exact_pages for k in range(i, j)):
            c.folders_perfect += 1
        i = j

    # Boundaries over document gaps.
    for i in range(n - 1):
        if not (is_doc[i] and is_doc[i + 1]):
            continue
        c.gaps += 1
        tb = t_ids[i] != t_ids[i + 1]
        pb = p_ids[i] != p_ids[i + 1]
        c.truth_bounds += tb
        c.tp += tb and pb
        c.false_splits += pb and not tb
        c.false_merges += tb and not pb

    # Edits: page labels to change.
    c.edits = sum(a != b for a, b in zip(canonical(truth), canonical(pred)))

    # Box/folder photos, apart.
    for t, p in zip(truth, pred):
        if t in PHOTO:
            c.photos += 1
            c.photos_exact += t == p
            c.photo_type_swaps += p in PHOTO and p != t
            c.photos_missed += p not in PHOTO
        elif p in PHOTO:
            c.false_photos += 1

    # Pk / WindowDiff over the whole stream.
    if n > 1:
        k = max(1, round(n / len(t_groups) / 2))
        tb_all = [int(t_ids[i] != t_ids[i + 1]) for i in range(n - 1)]
        pb_all = [int(p_ids[i] != p_ids[i + 1]) for i in range(n - 1)]
        for i in range(n - k):
            c.pk_windows += 1
            c.pk_errors += (t_ids[i] == t_ids[i + k]) != (p_ids[i] == p_ids[i + k])
            c.wd_errors += sum(tb_all[i:i + k]) != sum(pb_all[i:i + k])
    return c


def boundaries_from_labels(labels: list[str]) -> list[str]:
    ids = segment_ids(labels)
    return ["new" if ids[i] != ids[i + 1] else "continue" for i in range(len(labels) - 1)]


def check_prediction(pred) -> None:
    """A method's per-boundary decisions must agree with the segmentation its labels imply."""
    implied = boundaries_from_labels(pred.labels)
    if len(pred.boundaries) != len(implied):
        raise ValueError(f"{len(pred.boundaries)} boundaries for {len(pred.labels)} pages")
    for i, (b, want) in enumerate(zip(pred.boundaries, implied)):
        if b["decision"] not in ("new", "continue"):
            raise ValueError(f"boundary {i}: decision {b['decision']!r}")
        if b["decision"] != want:
            raise ValueError(f"boundary {i} says {b['decision']} but the labels imply {want}")


def risk_coverage(truth: list[str], pred) -> list[tuple[float, int, int]] | None:
    """For a method that gives confidences: over document gaps, sorted most-confident first,
    (threshold, accepted, errors among accepted) at each distinct confidence. None if the
    method gives no confidences. Review load = gaps - accepted."""
    confs = [b.get("confidence") for b in pred.boundaries]
    if all(x is None for x in confs):
        return None
    t_ids, p_ids = segment_ids(truth), segment_ids(pred.labels)
    rows = []
    for i, b in enumerate(pred.boundaries):
        if truth[i] in PHOTO or truth[i + 1] in PHOTO:
            continue
        wrong = (t_ids[i] != t_ids[i + 1]) != (p_ids[i] != p_ids[i + 1])
        rows.append((b.get("confidence") or 0.0, wrong))
    rows.sort(key=lambda r: -r[0])
    out, acc, err = [], 0, 0
    for idx, (conf, wrong) in enumerate(rows):
        acc += 1
        err += wrong
        if idx + 1 == len(rows) or rows[idx + 1][0] != conf:
            out.append((conf, acc, err))
    return out


# --- the test-set guard ------------------------------------------------------------------

class TestSetGuard(RuntimeError):
    pass


def guard(method, names, final: bool) -> None:
    """Test collections are scored only with --final, and never for a method still tuning."""
    from data import TEST
    test = [n for n in names if n in TEST]
    if not test:
        return
    if getattr(method, "tuning", True):
        raise TestSetGuard(f"method {method.name!r} is marked as tuning; it may not be scored on {test}")
    if not final:
        raise TestSetGuard(f"{test} are the held-out test collections; pass --final to score them (once per finalist)")
