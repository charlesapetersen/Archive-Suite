#!/usr/bin/env python3
"""W46.fix-ocr-scorers. The CHAOS-style altered-word probe (C-ocr claim 41, test 10) on 20 typed owner pages.

  uv run --offline --with pillow --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python chaos_probe.py make            # the altered images, their manifest and truths, in CACHE only
  python3 chaos_probe.py vision             # Apple Vision on them (the panel's Vision binary), $0
  uv run ... python chaos_probe.py score    # every reading found -> segbench-results/chaos-probe.md + .json

HunyuanOCR-1.5's CHAOS-Bench alters one character in two or three words of a page and asks how many readers copy
what is printed rather than "correct" it to the word they expect. Here: 20 typewritten pages of the owner's 96
(seeded draw), three words each. A word qualifies when Apple Vision's word box (ocr-truth/vision-words.json) reads
exactly a lower-case word of 6-12 letters that the truth holds once. The page is typed in a fixed pitch, so the box
is cut into equal cells; one inner letter's cell is replaced by the same page's glyph of another letter (taken
from a different qualifying word nearest in height, at its own size, aligned on the two words' ink rows), chosen so the altered word is in neither the system
dictionary nor the page. The box is trimmed to its ink and accepted only when its cell boundaries fall in the gaps
between letters; the altered cell is blanked to its paper colour and the donor glyph's ink drawn on it. Every
altered word is checked by eye in the crops `make` writes before readings start.

Each reading is scored per altered word: copied (the reading holds the altered word), corrected (it holds the
original word at that place instead), or other; plus NES against the altered truth. A reader that copies is
reading the page; one that corrects is writing from its expectations, the evidence rule's risk.

Raw images, truths and the word list stay in CACHE/ocr-scorers/chaos/ (the owner's material). The repo gets counts.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]
import ocr_panel as P   # noqa: E402

CACHE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal'
RUN = CACHE / 'ocr-scorers/chaos'
IMAGES = CACHE / 'ocr-panel-local/images'
WORDS = CACHE / 'ocr-truth/vision-words.json'
RESULTS = HERE.parents[1] / 'segbench-results'
SEED = 4641
PAGES, PER_PAGE = 20, 3
VOWELS = 'aeiou'
SWAPS = {**{v: [u for u in VOWELS if u != v] for v in VOWELS},
         **{c: ['r', 'n', 's', 't', 'l', 'c', 'm'] for c in 'bcdfghjklmnpqrstvwxyz'}}


def dictionary() -> set[str]:
    return {w.strip().lower() for w in Path('/usr/share/dict/words').read_text().splitlines()}


def typed_pages() -> list[str]:
    rows = [r for r in P.rows() if r['page'] not in P.AGREEMENT and r['kind'] == 'typewritten'
            and not r['handwritten'] and not r['clippings'] and not r['tables']]
    return sorted(r['page'] for r in rows)


def candidates(page: str, boxes, truth: str):
    """Boxes of lower-case words of 6-12 letters that the truth holds once, set off by spaces on both sides (so the
    box holds no punctuation)."""
    counts = {}
    for w in re.findall(r'[A-Za-z]+', truth):
        counts[w] = counts.get(w, 0) + 1
    spaced = set(re.findall(r'(?:(?<=\s)|^)([a-z]{6,12})(?=\s|$)', truth))
    return [b for b in boxes if b[0] in spaced and counts.get(b[0]) == 1]


def _otsu(g):
    import numpy as np
    hist = np.bincount(g.ravel(), minlength=256).astype(float)
    w = np.cumsum(hist); m = np.cumsum(hist * np.arange(256)); t = m[-1]
    with np.errstate(divide='ignore', invalid='ignore'):
        between = (m[-1] * w / w[-1] - m) ** 2 / (w * (w[-1] - w))
    return int(np.nanargmax(between[:-1]))


def cells(box, im):
    """The word's letter cells, or None when the box does not look fixed-pitch. The box is trimmed to its ink
    columns, cut into len(word) equal cells, and accepted only if the columns on the cell boundaries carry little
    ink against the word's mean (the gaps between typed letters)."""
    import numpy as np
    word, x, y, w, h = box
    W, H = im.size
    x0, y0, x1, y1 = int(x * W), int(y * H), int((x + w) * W), int((y + h) * H)
    if x1 - x0 < 3 * len(word) or y1 - y0 < 6:
        return None
    g = np.asarray(im.convert('L').crop((x0, y0, x1, y1)))
    ink = g < _otsu(g)
    cols = np.nonzero(ink.sum(0) > 0)[0]
    if len(cols) < len(word):
        return None
    a, b = x0 + cols[0], x0 + cols[-1] + 1
    step = (b - a) / len(word)
    prof = ink.sum(0)
    mean = prof[cols[0]:cols[-1] + 1].mean()
    edges = [int(round(cols[0] + i * step)) for i in range(1, len(word))]
    gap = np.mean([prof[max(e - 1, 0):e + 2].min() for e in edges])
    if gap > 0.35 * mean:
        return None
    return [(int(round(a + i * step)), y0, int(round(a + (i + 1) * step)), y1) for i in range(len(word))]


def _rows(im, box):
    import numpy as np
    g = np.asarray(im.convert('L').crop(box))
    return (g < _otsu(g)).sum(1).astype(float)


def replace_glyph(im, target, donor, target_word, donor_word):
    """Blank the target cell to its paper colour and draw the donor glyph's ink on it at the page's own size. The
    donor is aligned vertically by the shift that best matches the two words' ink-row profiles (their baselines and
    x-heights), and centred horizontally in its cell."""
    import numpy as np
    from PIL import Image
    tx0, ty0, tx1, ty1 = target
    tw, th = tx1 - tx0, ty1 - ty0
    pad = th // 2
    tp = _rows(im, (target_word[0], ty0 - pad, target_word[2], ty1 + pad))
    best, shift = -1.0, 0
    for k in range(-(th // 4), th // 4 + 1):  # a small shift: a larger one finds the next line
        dp = _rows(im, (donor_word[0], ty0 - pad + (donor[1] - ty0) + k, donor_word[2], ty1 + pad + (donor[1] - ty0) + k))
        n = min(len(tp), len(dp))
        c = float(np.dot(tp[:n] / (tp[:n].sum() or 1), dp[:n] / (dp[:n].sum() or 1)))
        if c > best:
            best, shift = c, k
    dcx = (donor[0] + donor[2]) / 2
    dy0 = donor[1] + shift
    d = im.crop((int(round(dcx - tw / 2)), dy0, int(round(dcx - tw / 2)) + tw, dy0 + th))
    region = np.asarray(im.crop(target)).astype(float)
    lum = region.mean(2)
    paper = np.median(region[lum >= np.percentile(lum, 60)], axis=0)
    da = np.asarray(d).astype(float)
    dl = da.mean(2)
    t = _otsu(dl.astype(np.uint8))
    dpaper = np.median(da[dl >= t], axis=0) if (dl >= t).any() else paper
    alpha = np.clip((dpaper.mean() - dl) / max(dpaper.mean() - dl.min(), 1), 0, 1)[..., None]
    out = paper * (1 - alpha) + (da - dpaper + paper) * alpha
    im.paste(Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)), (tx0, ty0))


def make():
    from PIL import Image
    rng = random.Random(SEED)
    words = json.loads(WORDS.read_text())
    lexicon = dictionary()
    pool = [p for p in typed_pages() if p in words]
    rng.shuffle(pool)
    for sub in ('images', 'truth', 'crops'):
        (RUN / sub).mkdir(parents=True, exist_ok=True)
        for f in (RUN / sub).iterdir():
            f.unlink()
    manifest, alterations = [], []
    for page in pool:
        if len(manifest) == PAGES:
            break
        truth = (P.TRUTH / 'truth' / f'{page}.txt').read_text()
        im = Image.open(IMAGES / f'{page}-original.jpg').convert('RGB')
        cand = [(b, c) for b in candidates(page, words[page], truth) if (c := cells(b, im))]
        if len(cand) < PER_PAGE + 2:
            continue
        donors = {}  # letter -> (cell, word extent) from qualifying words: the page's own pitch and type
        for b, cs in cand:
            for ch, c in zip(b[0], cs):
                donors.setdefault(ch, []).append((c, (cs[0][0], cs[0][1], cs[-1][2], cs[-1][3])))
        page_words = {w.lower() for w in re.findall(r'[A-Za-z]+', truth)}
        done, new_truth, used = [], truth, set()
        for b, cs in rng.sample(cand, len(cand)):
            if len(done) == PER_PAGE:
                break
            word = b[0]
            for i in rng.sample(range(1, len(word) - 1), len(word) - 2):
                options = [d for d in SWAPS.get(word[i], []) if d in donors
                           and (alt := word[:i] + d + word[i + 1:]) not in lexicon and alt not in page_words]
                if not options:
                    continue
                d = rng.choice(options)
                alt = word[:i] + d + word[i + 1:]
                # the donor nearest in height on the page, so lighting and scale match
                donor = min((c for c in donors[d] if c[0] not in cs and c[0] not in used),
                            key=lambda c: abs(c[0][1] - cs[i][1]), default=None)
                if donor is None:
                    continue
                replace_glyph(im, cs[i], donor[0], (cs[0][0], cs[0][1], cs[-1][2], cs[-1][3]), donor[1])
                used.add(cs[i])
                new_truth = re.sub(rf'(?<![A-Za-z]){word}(?![A-Za-z])', alt, new_truth, count=1)
                pad = 12
                im.crop((cs[0][0] - pad, cs[0][1] - pad, cs[-1][2] + pad, cs[-1][3] + pad)).save(
                    RUN / 'crops' / f'{page}-{alt}.png')
                done.append({'page': page, 'original': word, 'altered': alt, 'position': i})
                break
        if len(done) < PER_PAGE:
            continue
        out = RUN / 'images' / f'{page}.jpg'
        im.save(out, quality=95)
        (RUN / 'truth' / f'{page}.txt').write_text(new_truth)
        manifest.append({'id': page, 'image': str(out), 'sha256': hashlib.sha256(out.read_bytes()).hexdigest(),
                         'stratum': 'S0', 'source': 'chaos20'})
        alterations += done
    (RUN / 'chaos20.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in manifest))
    (RUN / 'alterations.json').write_text(json.dumps(alterations, indent=1))
    print(f'{len(manifest)} pages, {len(alterations)} altered words -> {RUN}')


def vision():
    tsv = RUN / 'vision-jobs.tsv'
    (RUN / 'readings/apple-vision').mkdir(parents=True, exist_ok=True)
    rows = [json.loads(x) for x in (RUN / 'chaos20.jsonl').read_text().splitlines()]
    tsv.write_text(''.join(f"{r['image']}\t{RUN / 'readings/apple-vision' / (r['id'] + '.txt')}\n" for r in rows))
    subprocess.run([str(P.T.OCR_BIN), str(tsv)], check=True)


def verdict(reading_words: list[str], original: str, altered: str, expected: int = 0) -> str:
    """copied: the reading holds the altered word. corrected: it holds the original word more often than the
    altered truth does (expected: the original's count in the altered truth, any case), so it put the expected word
    back. other: neither."""
    low = [w.lower() for w in reading_words]
    if altered in low:
        return 'copied'
    if low.count(original) > expected:
        return 'corrected'
    return 'other'


def readings():
    """{route: {page: text}} from RUN/readings/<route>/<page>.txt and the cluster's collected records."""
    import farmshare_expanded_report as X
    import farmshare_results as F
    out = {}
    base = RUN / 'readings'
    for d in sorted(base.iterdir()) if base.is_dir() else []:
        if d.is_dir() and any(d.glob('*.txt')):
            out[d.name] = {f.stem: f.read_text() for f in d.glob('*.txt')}
    cluster = RUN / 'cluster'
    modes = json.loads((cluster / 'modes.json').read_text()) if (cluster / 'modes.json').exists() else {}
    for label, spec in modes.items():
        folder = cluster / spec['folder']
        if folder.is_dir():
            recs = F.read_records(folder)
            out[label] = {p: X.reading(r, spec['mode']) for p, r in recs.items()}
    return out


def score():
    import ocr_panel_score as S
    rows = [json.loads(x) for x in (RUN / 'chaos20.jsonl').read_text().splitlines()]
    alts = json.loads((RUN / 'alterations.json').read_text())
    # words whose pasted letter failed the eye check of make's crops are left out (the page stays in the run)
    check = json.loads((RUN / 'eye-check.json').read_text()) if (RUN / 'eye-check.json').exists() else {}
    rejected = check.get('rejected', {})
    made = len(alts)
    alts = [a for a in alts if a['altered'] not in rejected]
    result = []
    for route, texts in sorted(readings().items()):
        counts = {'copied': 0, 'corrected': 0, 'other': 0, 'unread': 0}
        nes = []
        for r in rows:
            text = texts.get(r['id'], '')
            truth = (RUN / 'truth' / f"{r['id']}.txt").read_text()
            nes.append(S.score(truth, text)['nes'])
            ws = S.tokens(S.normal(text))
            tw = S.tokens(S.normal(truth))
            for a in (a for a in alts if a['page'] == r['id']):
                counts[verdict(ws, a['original'], a['altered'], tw.count(a['original'])) if text else 'unread'] += 1
        n = sum(counts.values())
        result.append({'route': route, 'pages': sum(1 for r in rows if texts.get(r['id'])), 'words': n, **counts,
                       'recall': counts['copied'] / n if n else None, 'nes': sum(nes) / len(nes)})
    out = {'pages': len(rows), 'altered_words': len(alts), 'made': made, 'rejected_by_eye': len(rejected),
           'routes': result}
    (RESULTS / 'chaos-probe.json').write_text(json.dumps(out, indent=1))
    L = ['# The CHAOS-style altered-word probe on 20 typed owner pages (W46.fix-ocr-scorers)', '',
         f'{len(rows)} typewritten pages of the owner\'s 96, {made} words altered by one letter, of which '
         f'{len(rejected)} failed the eye check of their crops and are left out, so {len(alts)} are scored '
         '(`scripts/segbench/chaos_probe.py`; images, truths and the word list are private, in the cache). '
         '**recall** is the share of altered words the reading reproduces as printed (CHAOS-Bench\'s measure); '
         '**corrected** means the reading has the original, expected word instead. NES is against the altered '
         'truth.', '',
         '| route | pages read | copied (recall) | corrected | other | unread | NES |', '|---|---:|---:|---:|---:|---:|---:|']
    for r in sorted(result, key=lambda r: -(r['recall'] or 0)):
        L.append(f"| {r['route']} | {r['pages']} | {r['copied']} ({100 * r['recall']:.0f}%) | {r['corrected']} | "
                 f"{r['other']} | {r['unread']} | {100 * r['nes']:.1f} |")
    (RESULTS / 'chaos-probe.md').write_text('\n'.join(L) + '\n')
    print('\n'.join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('command', choices=['make', 'vision', 'score'])
    {'make': make, 'vision': vision, 'score': score}[ap.parse_args().command]()


if __name__ == '__main__':
    main()
