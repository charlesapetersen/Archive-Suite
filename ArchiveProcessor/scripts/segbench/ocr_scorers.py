"""W46.fix-ocr-scorers. The OCR scorer additions of the processing review (gap audit section 4, item 9).

Pure functions over text (and, for the mark-region check, pixel arrays). No network, no file access: the drivers
that read cached readings live in ocr_rescore.py. Callers normalise text the way their bench already does and pass
the result in; nothing here changes how NES is computed.

- added_rewritten: D-enhancement section 6.4. A word-level Levenshtein alignment of reading against truth; added
  words are insertions, rewritten words are substitutions whose reading word is more than one edit from its truth
  word. Both are rates over truth words.
- restoration_only: words in OCR(enhanced) absent from the truth and from OCR(raw) (6.4), per 1,000 reading words.
- suspect_words: the reference-free two-reader check (6.4): words of one reading that no other reader's reading of
  the same page contains. reseed_instability is the same for two runs of one restorer.
- mark_region_check: ink lost inside each mark box between the raw and the enhanced image (6.4).
- cmer: HIPE-OCRepair's cMER, (S+D+I)/(H+S+D+I) over characters, case- and punctuation-insensitive (C claim 26).
- newsbench: NewsBench's overall (1 - CER), chrF, bowF1 and gap = bowF1 - overall, ported from its score.py
  (github nealcaren/newsbench, MIT, at 2372b6b6c63e71c7eb43e34ef655c8f5c4f1620b) so the figures match its table.
- reading_order_edit: OmniDocBench's reading-order edit, the normalised edit distance between the truth's block
  order and the order the matched blocks take in the reading (E claim 11). Truth blocks are its paragraphs or lines.
- preservation: 2510.06743's historical-character preservation and archaic-insertion checks (C claim 36), for long
  s and the Fraktur ligatures on L2 and L8.
- strip_markup: the markup-aware diagnostic for native Markdown routes (open sweep of 2026-10-19).
"""
from __future__ import annotations

import collections
import re

from rapidfuzz.distance import Levenshtein

# ---- word alignment ---------------------------------------------------------------------------------------------


LOCAL_CELLS = 250_000  # largest unmatched stretch (truth words x reading words) re-paired by the weighted pass


def _pair(t: list[str], r: list[str]) -> tuple[int, int, list[tuple[str, str]]]:
    """Weighted alignment of one unmatched stretch: insert and delete cost 1, a substitution 1 plus the pair's
    normalised character distance, so a stretch's near-misses pair with each other rather than in whatever order
    a unit-cost alignment happened to break its ties. Returns (inserted, deleted, substitution pairs)."""
    a, b = len(t), len(r)
    if not a or not b or a * b > LOCAL_CELLS:
        k = min(a, b)
        return b - k, a - k, list(zip(t[:k], r[:k]))
    nd = Levenshtein.normalized_distance
    prev = [float(j) for j in range(b + 1)]
    back = [[2] * (b + 1)]
    for i in range(1, a + 1):
        cur, row = [float(i)] + [0.0] * b, [1] + [0] * b
        for j in range(1, b + 1):
            s, d, n = prev[j - 1] + 1 + nd(t[i - 1], r[j - 1]), prev[j] + 1, cur[j - 1] + 1
            cur[j], row[j] = min((s, 0), (d, 1), (n, 2))
        prev = cur
        back.append(row)
    i, j, ins, dels, subs = a, b, 0, 0, []
    while i or j:
        m = back[i][j] if i and j else (1 if i else 2)
        if m == 0:
            subs.append((t[i - 1], r[j - 1])); i -= 1; j -= 1
        elif m == 1:
            dels += 1; i -= 1
        else:
            ins += 1; j -= 1
    return ins, dels, subs


def added_rewritten(truth: list[str], reading: list[str]) -> dict:
    """Counts from one word-level alignment. truth and reading are already-normalised word lists. A unit-cost
    Levenshtein alignment fixes the matched words; each stretch between matches is re-paired by _pair."""
    ins = dels = 0
    subs: list[tuple[str, str]] = []
    ti = ri = 0  # start of the current unmatched stretch
    for op in list(Levenshtein.opcodes(truth, reading)) + [None]:
        if op is None or op.tag == 'equal':
            end_t, end_r = (len(truth), len(reading)) if op is None else (op.src_start, op.dest_start)
            n_ins, n_del, pairs = _pair(truth[ti:end_t], reading[ri:end_r])
            ins, dels, subs = ins + n_ins, dels + n_del, subs + pairs
            if op is not None:
                ti, ri = op.src_end, op.dest_end
    rewritten = sum(1 for t, r in subs if Levenshtein.distance(t, r) > 1)
    n = len(truth)
    return {'truth_words': n, 'reading_words': len(reading), 'inserted': ins, 'deleted': dels,
            'substituted': len(subs), 'rewritten': rewritten,
            'added_rate': ins / n if n else (1.0 if reading else 0.0),
            'rewritten_rate': rewritten / n if n else 0.0}


def _vocab(words) -> set[str]:
    return {w.casefold() for w in words}


def restoration_only(enhanced: list[str], truth: list[str], raw: list[str]) -> dict:
    """Words no reader saw before enhancement and the truth does not hold, with their rate per 1,000 words."""
    known = _vocab(truth) | _vocab(raw)
    found = [w for w in enhanced if w.casefold() not in known]
    return {'words': found, 'per_1000': 1000 * len(found) / len(enhanced) if enhanced else 0.0}


def suspect_words(reading: list[str], others: list[list[str]]) -> dict:
    """Words of `reading` that none of `others` (readings of the same page by other readers) contains."""
    known = set().union(*(_vocab(o) for o in others)) if others else set()
    found = [w for w in reading if w.casefold() not in known]
    return {'words': found, 'rate': len(found) / len(reading) if reading else 0.0}


def reseed_instability(a: list[str], b: list[str]) -> float:
    """Share of aligned word positions that differ between two readings of two seeds of one restorer."""
    ops = Levenshtein.editops(a, b)
    n = max(len(a), len(b))
    return len(ops) / n if n else 0.0


# ---- mark-region check ------------------------------------------------------------------------------------------


def mark_region_check(raw, enhanced, boxes, ink_below: int = 128, max_loss: float = 0.3) -> list[dict]:
    """raw, enhanced: 2-D greyscale arrays (numpy, 0-255) of one size. boxes: (x0, y0, x1, y1) pixel boxes.
    A box whose ink-pixel count (pixels darker than ink_below) falls by more than max_loss is a removed mark."""
    import numpy as np
    raw, enhanced = np.asarray(raw), np.asarray(enhanced)
    if raw.shape != enhanced.shape:
        raise ValueError(f'image sizes differ: {raw.shape} vs {enhanced.shape}')
    out = []
    for x0, y0, x1, y1 in boxes:
        r = raw[y0:y1, x0:x1].astype(np.int16)
        e = enhanced[y0:y1, x0:x1].astype(np.int16)
        ink_r, ink_e = int((r < ink_below).sum()), int((e < ink_below).sum())
        loss = (ink_r - ink_e) / ink_r if ink_r else 0.0
        out.append({'box': (x0, y0, x1, y1), 'mad': float(np.abs(r - e).mean()) if r.size else 0.0,
                    'ink_raw': ink_r, 'ink_enhanced': ink_e, 'ink_loss': loss, 'removed': loss > max_loss})
    return out


# ---- cMER (HIPE-OCRepair) ---------------------------------------------------------------------------------------

_CMER_DROP = re.compile(r'[^\w\s]|_')


def _cmer_norm(s: str) -> str:
    return re.sub(r'\s+', ' ', _CMER_DROP.sub('', s.casefold())).strip()


def cmer(ref: str, hyp: str) -> float:
    """(S+D+I)/(H+S+D+I) over characters after casefolding and dropping punctuation. Bounded by 1, unlike CER."""
    r, h = _cmer_norm(ref), _cmer_norm(hyp)
    if not r and not h:
        return 0.0
    ops = Levenshtein.editops(r, h)
    c = collections.Counter(o.tag for o in ops)
    s, d, i = c['replace'], c['delete'], c['insert']
    hits = len(r) - s - d
    return (s + d + i) / (hits + s + d + i)


# ---- NewsBench (ported from its score.py, MIT) ------------------------------------------------------------------

_nb_norm = lambda s: re.sub(r'[^0-9a-z]', '', s.lower())
_nb_norm_sp = lambda s: re.sub(r'\s+', ' ', re.sub(r'[^0-9a-z ]', ' ', s.lower())).strip()
_nb_tok = re.compile(r'[0-9a-z]+')


def _nb_cer(ref: str, hyp: str) -> float:
    r, h = _nb_norm(ref), _nb_norm(hyp)
    if not r:
        return 0.0 if not h else 1.0
    return Levenshtein.distance(r, h) / len(r)


def _ngrams(s, n):
    return collections.Counter(s[i:i + n] for i in range(len(s) - n + 1)) if len(s) >= n else collections.Counter()


def _nb_chrf(ref: str, hyp: str, nmax: int = 6, beta: float = 2.0) -> float:
    r, h = _nb_norm_sp(ref), _nb_norm_sp(hyp)
    if not r and not h:
        return 1.0
    ps, rs = [], []
    for n in range(1, nmax + 1):
        cr, ch = _ngrams(r, n), _ngrams(h, n)
        match = sum((cr & ch).values())
        if sum(ch.values()):
            ps.append(match / sum(ch.values()))
        if sum(cr.values()):
            rs.append(match / sum(cr.values()))
    if not ps or not rs:
        return 0.0
    p, rr = sum(ps) / len(ps), sum(rs) / len(rs)
    b2 = beta * beta
    return (1 + b2) * p * rr / (b2 * p + rr) if (b2 * p + rr) else 0.0


def _nb_bow_f1(ref: str, hyp: str) -> float:
    rw, hw = _nb_tok.findall(ref.lower()), _nb_tok.findall(hyp.lower())
    if not rw:
        return 1.0 if not hw else 0.0
    overlap = sum((collections.Counter(rw) & collections.Counter(hw)).values())
    p = overlap / len(hw) if hw else 0.0
    r = overlap / len(rw)
    return 2 * p * r / (p + r) if (p + r) else 0.0


def newsbench(ref: str, hyp: str) -> dict:
    """NewsBench's per-page figures. Its table pools CER over pages (character-weighted); see newsbench_pool."""
    r = _nb_norm(ref)
    edits = Levenshtein.distance(r, _nb_norm(hyp)) if r else 0
    ov = 1 - _nb_cer(ref, hyp)
    bow = _nb_bow_f1(ref, hyp)
    return {'overall': ov, 'chrF': _nb_chrf(ref, hyp), 'bowF1': bow, 'gap': bow - ov,
            'edits': edits, 'chars': len(r)}


def newsbench_pool(pages: list[dict]) -> dict:
    """NewsBench's table row: overall from pooled edits over pooled characters, chrF and bowF1 as page means."""
    if not pages:
        return {}
    chars = sum(p['chars'] for p in pages)
    ov = 1 - (sum(p['edits'] for p in pages) / chars) if chars else 0.0
    bow = sum(p['bowF1'] for p in pages) / len(pages)
    return {'overall': ov, 'chrF': sum(p['chrF'] for p in pages) / len(pages), 'bowF1': bow, 'gap': bow - ov,
            'pages': len(pages)}


# ---- reading order (OmniDocBench) -------------------------------------------------------------------------------


def truth_blocks(truth: str) -> list[str]:
    """Paragraphs where the truth has blank lines, else its lines; blocks under three words are dropped."""
    parts = re.split(r'\n\s*\n', truth) if re.search(r'\n\s*\n', truth) else truth.split('\n')
    return [p for p in (_nb_norm_sp(x) for x in parts) if len(p.split()) >= 3]


def reading_order_edit(truth: str, hyp: str, min_score: float = 60.0) -> dict | None:
    """Each truth block is located in the reading (best-matching span, consumed so two blocks cannot claim one
    span); blocks matched under min_score (rapidfuzz partial ratio, 0-100) are left out, as OmniDocBench scores
    order over matched blocks only. The figure is the edit distance between the truth order of the matched
    blocks and the order of their spans in the reading, over the number matched. None under two blocks."""
    from rapidfuzz.fuzz import partial_ratio_alignment
    blocks = truth_blocks(truth)
    if len(blocks) < 2:
        return None
    text = _nb_norm_sp(hyp)
    mask = [False] * len(text)
    found = []
    for idx in sorted(range(len(blocks)), key=lambda i: -len(blocks[i])):
        if not text:
            break
        a = partial_ratio_alignment(blocks[idx], text)
        if a is None or a.score < min_score or any(mask[a.dest_start:a.dest_end]):
            continue
        for k in range(a.dest_start, a.dest_end):
            mask[k] = True
        found.append((a.dest_start, idx))
    if len(found) < 2:
        return {'blocks': len(blocks), 'matched': len(found), 'edit': None}
    order = [idx for _, idx in sorted(found)]
    return {'blocks': len(blocks), 'matched': len(found),
            'edit': Levenshtein.distance(sorted(order), order) / len(order)}


# ---- historical characters (2510.06743) -------------------------------------------------------------------------

HISTORICAL = frozenset('ſﬀﬁﬂﬃﬄﬅﬆꝛ')


def preservation(truth: str, hyp: str, chars: frozenset = HISTORICAL) -> dict:
    """kept: of the truth's historical characters, how many the reading has (per character, as a multiset).
    inserted: historical characters in the reading beyond the truth's count (the archaic-insertion signal)."""
    t = collections.Counter(c for c in truth if c in chars)
    h = collections.Counter(c for c in hyp if c in chars)
    kept = sum((t & h).values())
    return {'truth': sum(t.values()), 'reading': sum(h.values()), 'kept': kept,
            'inserted': sum((h - t).values())}


# ---- markup-aware diagnostic ------------------------------------------------------------------------------------

_MARKUP = [
    (re.compile(r'!\[[^\]]*\]\([^)]*\)'), ' '),                    # image placeholders
    (re.compile(r'<img[^>]*>', re.I), ' '),
    (re.compile(r'</?(?:td|th)[^>]*>', re.I), ' '),                # table cells become word breaks
    (re.compile(r'</?[a-z][a-z0-9]*(?:\s[^<>]*)?/?>', re.I), ' '),  # any other HTML tag
    (re.compile(r'^\s{0,3}#{1,6}\s+', re.M), ''),                  # headings
    (re.compile(r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$', re.M), ''),  # pipe-table rules
    (re.compile(r'\*\*(.+?)\*\*|__(.+?)__', re.S), r'\1\2'),        # bold
    (re.compile(r'\$\$?([^$]*)\$\$?'), r'\1'),                     # LaTeX delimiters
]
_HAS_MARKUP = re.compile(r'^\s{0,3}#{1,6}\s|\*\*|</?[a-z][a-z0-9]*[\s>/]|!\[|^\s*\|.*\|\s*$|\$', re.I | re.M)


def has_markup(text: str) -> bool:
    return bool(_HAS_MARKUP.search(text))


def strip_markup(text: str) -> str:
    for pat, rep in _MARKUP:
        text = pat.sub(rep, text)
    return text
