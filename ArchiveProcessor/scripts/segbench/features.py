"""Per-boundary features for the on-device feature model (W36.seg-features, checkpoint 1).

One row per gap between page i and page i+1 of a collection. Three families:

* TEXT, from the cached Apple Vision OCR (data.ocr_cache_path): page-number cues at the top
  and bottom of both pages, letter/memo opening cues and a date line near the top of page
  i+1, closing/signature cues at the end of page i, sentence run-on across the gap, TF-IDF
  cosine similarity of the two pages (words, fitted on the collection's own pages, no
  labels), length ratio, near-blank flags.
* IMAGE, from small thumbnails made once under the bench cache (outside git): paper colour
  and its difference, aspect ratio and orientation change, ink density difference.
* TIME: the EXIF capture gap in log seconds, ONE feature (the owner: timestamps "will not be
  a very reliable clue"); ``TIME_FEATURES`` names it so a model can be run without it.

Nothing here reads labels; the caller decides which gaps are document gaps. Page text and
images never leave the cache directory.
"""
from __future__ import annotations

import datetime as dt
import json
import math
import re
from pathlib import Path

import numpy as np

import data

# --- text cues ----------------------------------------------------------------------------

_MONTHS = ("january|february|march|april|may|june|july|august|september|october|november|december|"
           "jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec")
_PAGE_NUM_LINE = re.compile(
    r"^\s*(?:[-–—]\s*(\d{1,3})\s*[-–—]|page\s+(\d{1,3})(?:\s+of\s+(\d{1,3}))?|p\.\s*(\d{1,3})|(\d{1,3}))\s*\.?\s*$",
    re.I)
_PAGE_OF = re.compile(r"\bpage\s+(\d{1,3})\s+of\s+(\d{1,3})\b", re.I)
_SALUTATION = re.compile(r"^\s*(dear|my dear|gentlemen|ladies and gentlemen|sir|madam|dear sir)\b", re.I)
_MEMO = re.compile(r"^\s*(memorandum|memo\b|to\s*:|from\s*:|subject\s*:|re\s*:|date\s*:|"
                   r"office memorandum|inter-?office)", re.I)
_DATE_LINE = re.compile(
    rf"(\b({_MONTHS})\.?\s+\d{{1,2}},?\s+(1[89]\d\d|20\d\d)\b)|(\b\d{{1,2}}\s+({_MONTHS})\.?,?\s+(1[89]\d\d|20\d\d)\b)|"
    rf"(\b\d{{1,2}}/\d{{1,2}}/(\d\d|\d{{4}})\b)", re.I)
_CLOSING = re.compile(r"^\s*(sincerely|yours (very )?(truly|sincerely|faithfully)|very (truly|sincerely) yours|"
                      r"cordially|respectfully|best (regards|wishes)|with (best|kind|warm) (regards|wishes)|"
                      r"regards|faithfully yours|affectionately|love,?$|as ever|cheers)\b", re.I)
_ENCL = re.compile(r"^\s*\(?\s*(enclosures?|encl\.?|enc\.|cc\s*:|c\.c\.|bcc|attachment)", re.I)
_WORD = re.compile(r"[a-z]{2,}")

HEAD_LINES = 6     # "near the top"
TAIL_LINES = 6     # "near the bottom"
OPEN_LINES = 15    # opening cues (letterhead can push the salutation down)
BLANK_CHARS = 25   # fewer alphanumeric characters than this is near-blank


def lines_of(text: str | None) -> list[str]:
    return [l for l in (text or "").splitlines() if l.strip()]


def page_number(lines: list[str]) -> int | None:
    """A bare page-number line (``-2-``, ``Page 2``, ``Page 2 of 5``, ``p. 2``, ``2``) among the lines."""
    for l in lines:
        m = _PAGE_NUM_LINE.match(l)
        if m:
            v = next(g for g in m.groups() if g is not None)
            n = int(v)
            if 1 <= n <= 300:
                return n
    return None


def page_of(text: str | None) -> tuple[int, int] | None:
    m = _PAGE_OF.search(text or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def text_cues(text: str | None) -> dict:
    """Cues of ONE page. Used for both sides of a gap."""
    ls = lines_of(text)
    head, tail = ls[:HEAD_LINES], ls[-TAIL_LINES:]
    alnum = sum(ch.isalnum() for ch in (text or ""))
    first = ls[0].strip() if ls else ""
    last = ls[-1].strip() if ls else ""
    po = page_of("\n".join(head + tail))
    return {
        "pn_top": page_number(head),
        "pn_bottom": page_number(tail),
        "page_of": po,
        "salutation": any(_SALUTATION.match(l) for l in ls[:OPEN_LINES]),
        "memo": sum(bool(_MEMO.match(l)) for l in ls[:OPEN_LINES]) >= 1,
        "date_top": any(_DATE_LINE.search(l) for l in head),
        "closing": any(_CLOSING.match(l) for l in ls[-10:]),
        "enclosure": any(_ENCL.match(l) for l in tail),
        "starts_lower": bool(first) and first[0].islower(),
        "ends_open": bool(last) and (last[-1].isalpha() and last[-1].islower() or last[-1] in ",;-"),
        "chars": alnum,
        "blank": alnum < BLANK_CHARS,
    }


# --- TF-IDF cosine ----------------------------------------------------------------------

def tokens(text: str | None) -> list[str]:
    return _WORD.findall((text or "").lower())


def tfidf_matrix(texts: list[str | None]) -> np.ndarray:
    """L2-normalised TF-IDF rows (sublinear tf, smoothed idf) over the given pages' words."""
    docs = [tokens(t) for t in texts]
    vocab: dict[str, int] = {}
    for d in docs:
        for w in d:
            vocab.setdefault(w, len(vocab))
    m = np.zeros((len(docs), max(1, len(vocab))), dtype=np.float32)
    for i, d in enumerate(docs):
        for w in d:
            m[i, vocab[w]] += 1
    df = (m > 0).sum(axis=0)
    idf = np.log((1 + len(docs)) / (1 + df)) + 1.0
    m = np.where(m > 0, 1 + np.log(np.maximum(m, 1)), 0) * idf
    norms = np.linalg.norm(m, axis=1, keepdims=True)
    return m / np.where(norms == 0, 1, norms)


def adjacent_cosine(texts: list[str | None]) -> list[float]:
    m = tfidf_matrix(texts)
    return [float(m[i] @ m[i + 1]) for i in range(len(texts) - 1)]


# --- image statistics -------------------------------------------------------------------

IMG_PX = 256


def image_stats(path: Path) -> dict:
    """Paper colour (median RGB of the brighter half of the central crop), ink density (share
    of central-crop pixels much darker than the paper), width and height of the image."""
    from PIL import Image
    with Image.open(path) as im:
        im = im.convert("RGB")
        w, h = im.size
        a = np.asarray(im, dtype=np.float32)
    ch, cw = a.shape[0], a.shape[1]
    crop = a[int(ch * .2):int(ch * .8), int(cw * .2):int(cw * .8)].reshape(-1, 3)
    lum = crop @ np.array([.299, .587, .114], dtype=np.float32)
    bright = crop[lum >= np.median(lum)]
    paper = np.median(bright, axis=0)
    paper_lum = float(paper @ np.array([.299, .587, .114]))
    ink = float((lum < paper_lum - 60).mean())
    return {"paper": [float(x) for x in paper], "ink": ink, "w": w, "h": h}


def _image_cache(name: str) -> Path:
    return data.CACHE_DIR / "features" / f"image-{IMG_PX}-{name}.json"


def collection_image_stats(col) -> list[dict | None]:
    """Image statistics for every page, computed once from a thumbnail and cached outside git."""
    f = _image_cache(col.name)
    cache = json.loads(f.read_text()) if f.exists() else {}
    changed = False
    out = []
    for p in col.pages:
        key = str(p.n)
        if key not in cache:
            th = data.thumbnail(col.name, p, max_px=IMG_PX)
            cache[key] = image_stats(th) if th else None
            changed = True
        out.append(cache[key])
    if changed:
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(cache))
    return out


# --- capture time -----------------------------------------------------------------------

def parse_time(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    for fmt in ("%Y:%m:%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return dt.datetime.strptime(s.strip(), fmt)
        except ValueError:
            pass
    return None


def log_gap(a: str | None, b: str | None) -> float:
    """log(1 + seconds) between two capture times; 0 when either is missing or out of order."""
    ta, tb = parse_time(a), parse_time(b)
    if ta is None or tb is None:
        return 0.0
    s = (tb - ta).total_seconds()
    return math.log1p(s) if s > 0 else 0.0


# --- the boundary feature row -----------------------------------------------------------

TIME_FEATURES = ("log_time_gap",)
FEATURES = (
    "next_pn_top_ge2", "next_pn_top_eq1", "next_pn_any_ge2", "pn_sequence", "next_page_of_ge2",
    "next_page_of_eq1", "prev_page_of_last",
    "next_salutation", "next_memo", "next_date_top",
    "prev_closing", "prev_enclosure", "prev_ends_open", "next_starts_lower",
    "tfidf_cosine", "abs_log_len_ratio", "prev_blank", "next_blank", "log_chars_next",
    "paper_diff", "paper_lum_diff", "aspect_change", "orientation_change", "ink_diff",
    "missing_image",
) + TIME_FEATURES


def pair_features(a: dict, b: dict, cos: float, ia: dict | None, ib: dict | None, gap: float) -> dict:
    """The feature row for the gap between page a and page b (cues from text_cues, image stats
    from image_stats, ``gap`` from log_gap)."""
    num_a = a["pn_top"] or a["pn_bottom"]
    num_b = b["pn_top"] or b["pn_bottom"]
    po_a, po_b = a["page_of"], b["page_of"]
    f = {
        "next_pn_top_ge2": float((b["pn_top"] or 0) >= 2),
        "next_pn_top_eq1": float(b["pn_top"] == 1),
        "next_pn_any_ge2": float((num_b or 0) >= 2),
        "pn_sequence": float(num_a is not None and num_b is not None and num_b == num_a + 1),
        "next_page_of_ge2": float(po_b is not None and po_b[0] >= 2),
        "next_page_of_eq1": float(po_b is not None and po_b[0] == 1),
        "prev_page_of_last": float(po_a is not None and po_a[0] == po_a[1]),
        "next_salutation": float(b["salutation"]),
        "next_memo": float(b["memo"]),
        "next_date_top": float(b["date_top"]),
        "prev_closing": float(a["closing"]),
        "prev_enclosure": float(a["enclosure"]),
        "prev_ends_open": float(a["ends_open"]),
        "next_starts_lower": float(b["starts_lower"]),
        "tfidf_cosine": cos,
        "abs_log_len_ratio": abs(math.log((a["chars"] + 1) / (b["chars"] + 1))),
        "prev_blank": float(a["blank"]),
        "next_blank": float(b["blank"]),
        "log_chars_next": math.log1p(b["chars"]),
        "log_time_gap": gap,
    }
    if ia and ib:
        pa, pb = np.array(ia["paper"]), np.array(ib["paper"])
        w = np.array([.299, .587, .114])
        ra, rb = ia["w"] / ia["h"], ib["w"] / ib["h"]
        f.update({
            "paper_diff": float(np.linalg.norm(pa - pb)),
            "paper_lum_diff": float(abs(pa @ w - pb @ w)),
            "aspect_change": abs(math.log(ra / rb)),
            "orientation_change": float((ra > 1) != (rb > 1)),
            "ink_diff": abs(ia["ink"] - ib["ink"]),
            "missing_image": 0.0,
        })
    else:
        f.update({k: 0.0 for k in ("paper_diff", "paper_lum_diff", "aspect_change",
                                    "orientation_change", "ink_diff")})
        f["missing_image"] = 1.0
    return f


def collection_features(col, with_images: bool = True) -> np.ndarray:
    """Matrix (pages-1) x len(FEATURES), one row per gap i -> i+1, in FEATURES order."""
    texts = [col.text(i) for i in range(len(col.pages))]
    cues = [text_cues(t) for t in texts]
    cos = adjacent_cosine(texts)
    imgs = collection_image_stats(col) if with_images else [None] * len(texts)
    rows = []
    for i in range(len(texts) - 1):
        f = pair_features(cues[i], cues[i + 1], cos[i], imgs[i], imgs[i + 1],
                          log_gap(col.pages[i].captured, col.pages[i + 1].captured))
        rows.append([f[k] for k in FEATURES])
    return np.array(rows, dtype=np.float64).reshape(-1, len(FEATURES))
