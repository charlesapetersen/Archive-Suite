"""The dating scorer changes of the W46 gap audit (execution-plans/processing-review/10-gap-audit.md §4 fix 9,
"Dating"; B-dating.md §3-4). Pure functions over plain rows, no I/O, so every cached answer and every later run
(W46.date-traceable, W46.date-enclosure, W46.date-image) is scored the same way. date_truth.py applies them.

A row is a dict with at least:
  truth   {"year": int, "du": bool} or {"decade": int, "du": bool}   the owner's tags (date_tagging.truth_of)
  y       int or None    the reply's year (None: no usable year)
  parsed  bool           the reply parsed as the app parses it (date_tagging.app_parse)
  du_pred bool           the reply set `Date Uncertain`
and, where the scorer needs it, `cls` (the structural class A, A', B, C, D or "in text") and `lo`/`hi` (a stated
interval; a point answer is lo = hi = y).

What each scorer answers:
  invalid_rate        replies with no usable year (unparsed, or parsed without a four-digit year), beside accuracy
  tolerance_curve     share within k years for k = 0..K (B33's tolerance curve); exact is k = 0, within-one k = 1
  interval_distance   the HDC distance from the truth interval (0 inside it), for owner-inferred years
  du_error_rates      `Date Uncertain` as two error rates, since a constant "certain" scores 80% on agreement
  evidence_check      a cited neighbour or quote checked against the context the model was given
  conformal           split-conformal coverage, width and Winkler score by stratum, with swapped halves
"""
import math
import random
import re

MIN_CALIBRATION = 15        # B47: at least 15 calibration points per group; a stratum needs two halves of it
YEAR_RX = re.compile(r"\b(1[5-9]\d\d|20\d\d)\b")
DATE_RX = re.compile(r"\b(1[5-9]\d\d|20\d\d)\b|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|"
                     r"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.? \d{1,2}\b", re.I)


def truth_interval(truth, tolerance=0):
    """(lo, hi) of the owner's tag: a decade is its ten years; a year is itself, widened by `tolerance` when the
    owner's year is an estimate (year+DU) and the caller wants it scored as one."""
    if "decade" in truth:
        return truth["decade"], truth["decade"] + 9
    return truth["year"] - tolerance, truth["year"] + tolerance


def interval_distance(y, lo, hi):
    """HDC's distance from the label interval: 0 inside [lo, hi], else years to the nearer end; None if no year."""
    if y is None:
        return None
    return max(0, lo - y, y - hi)


def invalid_rate(rows):
    """[invalid, n]: replies that give the app no year (an unparsed reply, or one without a four-digit year)."""
    return [sum(1 for r in rows if not r["parsed"] or r["y"] is None), len(rows)]


def tolerance_curve(rows, kmax=5, tolerance=0):
    """[[hits, n] for k in 0..kmax]: replies within k years of the truth interval. No year counts as a miss, so
    the denominator is every row and the invalid rate cannot flatter it."""
    out = []
    for k in range(kmax + 1):
        hit = 0
        for r in rows:
            d = interval_distance(r["y"], *truth_interval(r["truth"], tolerance))
            hit += d is not None and d <= k
        out.append([hit, len(rows)])
    return out


def mean_distance(rows, tolerance=0):
    """(mean HDC distance over rows with a year, rows with a year)."""
    ds = [interval_distance(r["y"], *truth_interval(r["truth"], tolerance)) for r in rows]
    ds = [d for d in ds if d is not None]
    return (sum(ds) / len(ds) if ds else None), len(ds)


def du_error_rates(rows):
    """The two `Date Uncertain` errors: owner-certain rows the reply flags uncertain, and owner-uncertain rows the
    reply flags certain, each as [errors, n]. Decade rows are left out (a decade tag is its own uncertainty)."""
    certain = [r for r in rows if "year" in r["truth"] and not r["truth"]["du"]]
    uncertain = [r for r in rows if "year" in r["truth"] and r["truth"]["du"]]
    return {"certain_flagged_uncertain": [sum(1 for r in certain if r["du_pred"]), len(certain)],
            "uncertain_flagged_certain": [sum(1 for r in uncertain if not r["du_pred"]), len(uncertain)]}


def _norm(s):
    """Spacing- and case-tolerant form for quote matching: ABBYY spaces letters ("w e lcom e")."""
    return re.sub(r"\s+", "", s or "").lower()


def _norm_text(s):
    """_norm without hyphens, for finding a quote in a text: a line-end break ("bureau-\\ncrats") is not in a
    model's quote, and a real hyphen that falls at a line end ("March-\\nApril") is."""
    return re.sub(r"[-­‐‑]", "", _norm(s))


def _quote_in(quote, text):
    """Whether the quote is in the text. A quote the model shortened with "..." passes when every part is in the
    text, in order."""
    t, at = _norm_text(text), 0
    for part in (p for p in (_norm_text(p) for p in re.split(r"\.\.\.|…", quote)) if p):
        at = t.find(part, at)
        if at < 0:
            return False
        at += len(part)
    return True


# Letters OCR puts for a digit ("196L", "19gS"), after _norm's lowercasing. Never a digit for a digit: "1938" for
# 1988 is a different year as written, whatever the scan did.
OCR_DIGIT = {"0": "o", "1": "il|!]", "2": "z", "5": "s$", "6": "gb", "8": "b", "9": "gq"}
_MONTH = (r"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|"
          r"oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?")
_MONTH_NOT_MAY = _MONTH.replace("may|", "")
_YY_END = r"(?! ?\d|[\d'’]|s\b)"    # not "1958" or "19 23", not "the 80's" or "'80s"


def _damaged(ys, s):
    """Whether s (a _norm'ed quote) carries the four-digit year ys with OCR letters for some of its digits: one
    letter anywhere, or two when the first two digits are printed. The run is not part of a longer number."""
    for i in range(len(s) - 3):
        if (i and s[i - 1].isdigit()) or (i + 4 < len(s) and s[i + 4].isdigit()):
            continue
        w = s[i:i + 4]
        subs = [k for k in range(4) if w[k] != ys[k]]
        if subs and all(w[k] in OCR_DIGIT.get(ys[k], "") for k in subs) and (
                len(subs) == 1 or (len(subs) == 2 and w[:2] == ys[:2])):
            return True
    return False


def year_in_quote(year, quote):
    """How a quote carries the year, or None. "four digits"; "two digits", only inside a date form (9/24/58,
    20.2.76, 27 Oct 82, Dec. 70, '40, 1983-84), in any century, since the quote cannot say which; "ocr damage"
    (196L for 1961). Bare digits, "May 13" or "the 80's" carry no year. W46.date-evidence-check."""
    ys, s = str(year), _norm(quote)
    if ys in s:
        return "four digits"
    q, yy = re.sub(r"\s+", " ", quote or "").lower(), ys[2:]
    forms = [rf"(?<!\d)\d{{1,2}} ?[/.-] ?\d{{1,2}} ?[/.-] ?'?{yy}{_YY_END}",            # 9/24/58, 12.9-81
             rf"(?<!\d)\d{{1,2}}(?:st|nd|rd|th)? ?{_MONTH},? ?['’]?{yy}{_YY_END}",  # 27 Oct 82, 20 Mar. '40
             rf"{_MONTH} ?\d{{1,2}}(?:st|nd|rd|th)?, ?['’]?{yy}{_YY_END}",          # May 13, 72 (the comma is needed)
             rf"(?<![\d'’])['’‘]{yy}{_YY_END}",                                      # '40, Dec. '70
             rf"(?<!\d){ys[:2]}\d\d ?[-–/] ?{yy}{_YY_END}"]                             # 1983-84
    if int(yy) > 31:
        forms.append(rf"{_MONTH_NOT_MAY},? ?{yy}{_YY_END}")                          # Dec. 70: not a day, not "May 40"
    if any(re.search(f, q) for f in forms):
        return "two digits"
    if _damaged(ys, s):
        return "ocr damage"
    return None


def evidence_check(year, evidence, context):
    """Whether a reply's cited evidence supports the year it gives.

    evidence: {"neighbour": id, "quote": str} citing a document in the context, or {"quote": str} citing this
    document's own text (neighbour "self"), or {"region": str} naming text read off a located image region;
    None or {} when the reply cites nothing.
    context: {id: text} of every document the model was given, "self" included.

    Returns (verdict, reason). verdict is "valid", "unsupported" (evidence given but it fails) or "none" (no
    evidence). A right year with failed evidence is unsupported, which is CiteVQA's attribution hallucination.
    The quote is found spacing-, case- and hyphen-tolerantly, "..." elisions allowed, and carries the year as
    `year_in_quote` reads it; a valid reason names how when it is not four digits ("(two digits)", "(ocr damage)")."""
    if not evidence:
        return "none", "no evidence cited"
    if year is None:
        return "unsupported", "no year to support"
    if "region" in evidence and "quote" not in evidence:
        reg = evidence.get("region") or ""
        how = year_in_quote(year, reg)
        if not (DATE_RX.search(reg) or how):
            return "unsupported", "cited region has no date string"
        if not how:
            return "unsupported", "cited region's date is not the year given"
        return "valid", "cited region carries the year" + ("" if how == "four digits" else f" ({how})")
    nb = evidence.get("neighbour", "self")
    if nb not in context:
        return "unsupported", "cited document is not in the context given"
    quote = evidence.get("quote") or ""
    if not quote.strip():
        return "unsupported", "no quote"
    if not _quote_in(quote, context[nb]):
        return "unsupported", "quote is not in the cited document's text"
    how = year_in_quote(year, quote)
    if not how:
        return "unsupported", "quote does not carry the year given"
    return "valid", "quote found in the cited document and carries the year" + ("" if how == "four digits"
                                                                                  else f" ({how})")


def winkler(lo, hi, y, alpha):
    """Winkler interval score: width plus 2/alpha times the miss distance."""
    s = hi - lo
    if y < lo:
        s += 2 / alpha * (lo - y)
    elif y > hi:
        s += 2 / alpha * (y - hi)
    return s


def _quantile(scores, alpha):
    """The ceil((1-alpha)(n+1))-th smallest score (FermiEval's rule); inf when that rank passes n."""
    n = len(scores)
    k = math.ceil((1 - alpha) * (n + 1))
    if k > n:
        return math.inf
    return sorted(scores)[k - 1]


def conformal(rows, alpha=0.1, seed=46, min_cal=MIN_CALIBRATION):
    """Split-conformal widening of each row's interval (lo, hi; a point answer has lo = hi = y), calibrated on one
    random half and tested on the other, then the halves swapped; the two test halves are pooled.

    The truth is the owner's year (decade rows use the decade's middle year, 5 in). Nonconformity is
    max(lo - y, y - hi). A row with no year cannot be widened into an interval: it counts as uncovered and is left
    out of the width and the Winkler score, and is reported as `no_year`.

    Returns None when either half would have fewer than `min_cal` rows (B47's 15 per group), else
    {n, q (per half), coverage [covered, tested], width (mean), winkler (mean), no_year}."""
    if len(rows) < 2 * min_cal:
        return None
    rng = random.Random(seed)
    idx = list(range(len(rows)))
    rng.shuffle(idx)
    halves = (idx[: len(idx) // 2], idx[len(idx) // 2:])

    def truth(r):
        return r["truth"]["year"] if "year" in r["truth"] else r["truth"]["decade"] + 5

    def score(r):
        if r.get("lo") is None or r.get("hi") is None:
            return math.inf
        return max(r["lo"] - truth(r), truth(r) - r["hi"])

    covered = tested = no_year = 0
    widths, wink, qs = [], [], []
    for cal, test in (halves, halves[::-1]):
        q = _quantile([score(rows[i]) for i in cal], alpha)
        qs.append(q)
        for i in test:
            r = rows[i]
            tested += 1
            if r.get("lo") is None or r.get("hi") is None:
                no_year += 1
                continue
            lo, hi = r["lo"] - q, r["hi"] + q
            covered += lo <= truth(r) <= hi
            if math.isfinite(q):
                widths.append(hi - lo)
                wink.append(winkler(lo, hi, truth(r), alpha))
    return {"n": len(rows), "alpha": alpha, "q": qs, "coverage": [covered, tested],
            "width": sum(widths) / len(widths) if widths else None,
            "winkler": sum(wink) / len(wink) if wink else None, "no_year": no_year}
