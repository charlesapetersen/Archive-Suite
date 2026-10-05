"""Rule cues on the cached Apple Vision text (W36.seg-base).

A transparent, ordered rule list. For each document page the FIRST rule that fires decides
whether the page starts a new document (New) or continues the previous one (Cont); if none
fires, a default decides. Box/folder photo labels are taken from the truth, as the other
baselines do. No capture-time feature (that is W36.seg-features).

The rules, in order (``RULES``):

  blank          the page has fewer than ``blank_chars`` characters of text        -> Cont
  page-one       "Page 1", "Page 1 of N", "- 1 -" in the top 3 lines              -> New
  page-number    a page number of 2 or more in the top 3 lines: "- 2 -", "-2-",
                 "Page 2", "Page 2 of 3", "p. 2", "Pg 2", "P.4"                    -> Cont
  bare-number    a line in the top 2 that is only a number 2..299 (optional ".")   -> Cont
  jump-from      "continued from", "from page 1", "from first page" near the top  -> Cont
  opening        a salutation ("Dear", "Gentlemen", "Sir:") or a memo heading
                 ("MEMORANDUM", "TO:", "FROM:", "SUBJECT:", "RE:") in the top lines -> New
  date-line      a line that is only a date ("March 7, 1960", "5-18-60") in the top -> New
  prev-jump      the previous page ends "continued on next page" / "turn to page"   -> Cont
  prev-closing   the previous page ends with a closing or signature block
                 ("Sincerely", "Very truly yours", typist initials "JD:mm", "cc:",
                 "Enclosure")                                                        -> New
  flows-on       the page's first line begins with a lower-case letter (text runs on
                 from the page before)                                               -> Cont
  (default)      ``default``                                                         -> New or Cont

Free parameters (``GRID``): how many top lines count as "the top" (``top_lines``), how many end
lines of the previous page count as "the end" (``end_lines``), the blank threshold, the default,
and which rules are switched on. They are chosen ONLY leave-one-collection-out over the three
development collections: the prediction for Dean comes from parameters fitted on Deaver and
Herrnstein, and so on. A test collection (``--final``) would get parameters fitted on all three.
The objective is pooled pages in an exact document on the training collections; ties go to the
first grid point, so fewer rules and the smaller thresholds win.

Each boundary's confidence is the training precision of the rule that decided it, so the
method has a risk-coverage curve; it is evidence, not truth.
"""
from __future__ import annotations

import itertools
import re
from dataclasses import dataclass

from score import PHOTO, derived, score_labels

_DASH = r"[-–—=~_]"
_PAGE_ONE = re.compile(rf"^\s*(?:page\s*1(?:\s+of\s+\d+)?|{_DASH}+\s*1\s*{_DASH}+)\s*\.?\s*$", re.I)
_PAGE_N = re.compile(
    rf"(?:^|\s){_DASH}+\s*(\d{{1,3}})\s*{_DASH}*\s*$"            # "- 2 -", "-2-", "= 2 -", "-2"
    rf"|^\s*{_DASH}*\s*(\d{{1,3}})\s*{_DASH}+\s*$"               # "2 -"
    r"|\b(?:page|pg\.?|p\.)\s*(\d{1,3})(?:\s+of\s+\d+)?\b",      # "Page 2", "Page 2 of 3", "P. 3", "P.4"
    re.I)
_BARE = re.compile(r"^\s*(\d{1,3})\s*\.?\s*$")
_JUMP_FROM = re.compile(r"continued\s+from|\bfrom\s+(?:page\s+\d+|first\s+page|page\s+one)\b", re.I)
_OPENING = re.compile(
    r"^\s*(?:(?:my\s+)?dear\b|gentlemen\b|ladies and gentlemen\b|sirs?\s*[:,]|madam\s*[:,]"
    r"|memorandum\b|memo\b|(?:to|from|subject|re)\s*:)", re.I)
_MONTH = (r"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?"
          r"|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?")
_DATE_LINE = re.compile(
    rf"^\s*(?:{_MONTH}\s+\d{{1,2}}\s*[,.]?\s*\d{{4}}|\d{{1,2}}\s+{_MONTH}\s*,?\s*\d{{4}}"
    rf"|{_MONTH}\s*,?\s*\d{{4}}|\d{{1,2}}[-/.]\d{{1,2}}[-/.]\d{{2,4}})\s*[.,]?\s*$", re.I)
_PREV_JUMP = re.compile(r"continued\s+on\s+(?:next\s+page|page)|(?:please\s+)?turn\s+to\s+page"
                        r"|\(over\)|\bover\s*$|\bP\.?\s*T\.?\s*O\b", re.I)
_CLOSING = re.compile(
    r"^\s*(?:(?:very\s+)?(?:sincerely|truly|cordially|faithfully|respectfully|cordial(?:ly)?)\b"
    r"|yours\b|(?:with\s+)?(?:best|kind|warm)\s+(?:wishes|regards)\b|regards\b"
    r"|cc\s*[:.]|c\s*c\s*:|enc(?:l|s)?\b\.?|enclosures?\b|attach(?:ment)?s?\b\.?"
    r"|[A-Z]{2,4}\s*[:/]\s*[a-zA-Z]{1,4}\.?\s*$)", re.I)
_INITIALS = re.compile(r"^\s*[A-Z]{2,4}\s*[:/;]\s*[a-z]{1,4}\.?\s*$")   # "JD:mm", "RJH: afa", "JD/ne"


def lines_of(text: str | None) -> list[str]:
    return [l.strip() for l in (text or "").splitlines() if l.strip()]


def _page_number(line: str) -> int | None:
    m = _PAGE_N.search(line)
    if not m:
        return None
    return int(next(g for g in m.groups() if g))


def fires(lines: list[str], prev: list[str] | None, top_lines: int, end_lines: int,
          blank_chars: int) -> list[tuple[str, str]]:
    """Every rule that fires for a page, in rule order, as (rule, decision)."""
    out = []
    chars = sum(len(l) for l in lines)
    top3, top = lines[:3], lines[:top_lines]
    if chars < blank_chars:
        out.append(("blank", "Cont"))
    if any(_PAGE_ONE.match(l) for l in top3):
        out.append(("page-one", "New"))
    nums = [n for n in (_page_number(l) for l in top3) if n is not None]
    if any(2 <= n < 300 for n in nums):
        out.append(("page-number", "Cont"))
    if any((m := _BARE.match(l)) and 2 <= int(m.group(1)) < 300 for l in lines[:2]):
        out.append(("bare-number", "Cont"))
    if any(_JUMP_FROM.search(l) for l in top):
        out.append(("jump-from", "Cont"))
    if any(_OPENING.match(l) for l in top):
        out.append(("opening", "New"))
    if any(_DATE_LINE.match(l) for l in top):
        out.append(("date-line", "New"))
    if prev is not None:
        end = prev[-end_lines:]
        if any(_PREV_JUMP.search(l) for l in end):
            out.append(("prev-jump", "Cont"))
        if any(_CLOSING.match(l) or _INITIALS.match(l) for l in end):
            out.append(("prev-closing", "New"))
    if lines and lines[0][:1].islower():
        out.append(("flows-on", "Cont"))
    return out


RULES = ("blank", "page-one", "page-number", "bare-number", "jump-from", "opening", "date-line",
         "prev-jump", "prev-closing", "flows-on")


@dataclass(frozen=True)
class Params:
    top_lines: int
    end_lines: int
    blank_chars: int
    default: str
    rules: tuple

    def describe(self) -> str:
        off = [r for r in RULES if r not in self.rules]
        return (f"top {self.top_lines} lines, end {self.end_lines} lines, blank < {self.blank_chars} chars, "
                f"default {self.default}; off: {', '.join(off) if off else 'none'}")


TOP_LINES = (3, 5, 8)
END_LINES = (3, 6)
BLANK_CHARS = (0, 20, 60)
DEFAULTS = ("New", "Cont")
# Rule switches: every rule may be dropped, but the subsets are tried smallest-change first so a
# tie keeps the full list.
SWITCHABLE = RULES


def _rule_sets():
    for k in range(len(SWITCHABLE) + 1):
        for off in itertools.combinations(SWITCHABLE, k):
            yield tuple(r for r in RULES if r not in off)


def decide(fired: list[tuple[str, str]], params: Params) -> tuple[str, str]:
    for rule, decision in fired:
        if rule in params.rules:
            return decision, rule
    return params.default, "default"


def _features(collection, top_lines, end_lines, blank_chars):
    """Per page: (truth label, rules fired) for one setting of the text thresholds."""
    out, prev = [], None
    for i, lab in enumerate(collection.labels):
        lines = lines_of(collection.text(i))
        if lab in PHOTO:
            out.append((lab, None))
            prev = None          # the page before a document's first page is a photo: no "end"
        else:
            out.append((lab, fires(lines, prev, top_lines, end_lines, blank_chars)))
            prev = lines
    return out


def predict_labels(feats, params: Params) -> tuple[list[str], list[str]]:
    labels, deciders = [], []
    for lab, fired in feats:
        if fired is None:
            labels.append(lab)
            deciders.append("photo (oracle)")
        else:
            d, rule = decide(fired, params)
            labels.append(d)
            deciders.append(rule)
    return labels, deciders


def fit(train) -> tuple[Params, dict]:
    """Best Params on the training collections (pooled pages in an exact document), and each
    rule's precision on them as a decider under those Params."""
    best, best_score = None, -1.0
    for tl, el, bc in itertools.product(TOP_LINES, END_LINES, BLANK_CHARS):
        feats = {c.name: _features(c, tl, el, bc) for c in train}
        for default in DEFAULTS:
            for rules in _rule_sets():
                p = Params(tl, el, bc, default, rules)
                total = None
                for c in train:
                    cnt = score_labels(c.labels, predict_labels(feats[c.name], p)[0])
                    total = cnt if total is None else total + cnt
                s = derived(total)["pages_in_exact_doc"] or 0.0
                if s > best_score + 1e-12:
                    best, best_score = p, s
    stats = rule_stats([(c.labels, *predict_labels(_features(c, best.top_lines, best.end_lines,
                                                              best.blank_chars), best)) for c in train])
    return best, stats


def rule_stats(runs) -> dict:
    """Per deciding rule over document gaps: hits and correct decisions. ``runs`` is a list of
    (truth labels, predicted labels, deciding rule per page)."""
    from score import canonical
    stats: dict[str, list[int]] = {}
    for truth, pred, deciders in runs:
        t = canonical(truth)
        for i in range(1, len(truth)):
            if truth[i] in PHOTO or truth[i - 1] in PHOTO:
                continue
            s = stats.setdefault(deciders[i], [0, 0])
            s[0] += 1
            s[1] += pred[i] == t[i]
    return stats


def precision(stats: dict, rule: str, prior: float = 0.5) -> float:
    hits, ok = stats.get(rule, (0, 0))
    return (ok + prior) / (hits + 1)  # one pseudo-count so an unseen rule is not certain
