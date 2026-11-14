"""place-hands.py — the hand placer (W42.int-s5-hands): a handwritten page's reading placed on its own lines.

    python3 -I place-hands.py <image> <reading.txt> <out.json> --model <McCATMuS.mlmodel> [--device cpu|mps]

The route `05-placement.md` §3 names `hand-blla-ctc`, as W46.place-hands measured it (`scripts/segbench/place_hands.py`,
`place_ctc`, and `place_hands_cost.py`'s one-process worker, whose steps these are): kraken 7.1.1's blla finds the
written lines; McCATMuS recognises each line once, keeping its CTC output; the reading's lines are matched to runs of
the found lines by character error, two ways (`s1`, one found line a reading line; `s8`, a reading line over up to 8
found lines, for a reader that reflows); each matched run's text is force-aligned on the run's CTC output, so a reading
line over several written lines is split where the ink says; and the matcher whose alignment is the surer (`conf`, ties
to `s1`) is kept. The page's confidence is the mean aligned-character score over the reading's characters, an unaligned
character counting 0. The 0.67 gate is the caller's (`HandPlacer.gate`).

Writes {"lines": [{"text", "box": [x, y, w, h]}], "confidence", "span", "detected", "reading_lines", "fallback_lines",
"seconds": {...}, "peak_rss": bytes}: every found line that holds text, its box normalised to the image (top-left
origin), the box the lab writer lays one run over (`place_hands_lines.py`'s `lab` writer). Runs offline; reads nothing
but its arguments and kraken's own blla model.
"""
import argparse
import json
import math
import os
import re
import resource
import sys
import time

FRAC = 0.78          # place_truth.BASELINE_FRAC: the share of a line's height above its baseline
SPANS = (1, 8)       # the two matchers
SPAN_COST = 0.05     # per extra found line a reading line covers, so one-to-one wins a tie
SKIP = 0.6           # a reading or found line left unmatched (place_hands.SKIP['text'])


def clean(text):
    """A reading as its lines: markdown and markup off, empty and rule lines dropped (place_hands.clean)."""
    out = []
    for ln in text.splitlines():
        ln = re.sub(r'<[^>]+>', ' ', ln)
        ln = re.sub(r'\[illegible\]', ' ', ln, flags=re.I)
        ln = re.sub(r'^\s*(#+|>|[-*+]\s)\s*', '', ln)
        ln = ln.replace('**', '').replace('__', '').replace('|', ' ')
        ln = ' '.join(ln.split())
        if ln and not re.fullmatch(r'[-=:_ ]+', ln):
            out.append(ln)
    return out


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(hyp, ref):
    return levenshtein(hyp, ref) / max(1, len(ref))


def polylen(pts):
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(pts, pts[1:]))


def area(poly):
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1]))) / 2


def bbox(pts):
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


def found_lines(res, W, H):
    """blla's lines in pixels, with each one's length, height (boundary area over baseline length) and box."""
    out = []
    for ln in res.lines:
        if not ln.baseline:
            continue
        bl = [(float(x), float(y)) for x, y in ln.baseline]
        bd = [(float(x), float(y)) for x, y in ln.boundary] if ln.boundary else None
        x, y, w, h = bbox(bd or bl)
        L = polylen(bl)
        hh = (area(bd) / L) if bd and L > 0 else h
        out.append({'baseline': bl, 'boundary': bd, 'len': max(L, 1.0), 'h': max(hh, 4.0),
                    'box': [x / W, y / H, w / W, h / H]})
    return out


def dp_match(n_read, n_det, cost, skip, span):
    """Monotone matching of reading lines to runs of consecutive found lines (place_hands.dp_match)."""
    INF = float('inf')
    D = [[INF] * (n_det + 1) for _ in range(n_read + 1)]
    B = [[None] * (n_det + 1) for _ in range(n_read + 1)]
    D[0][0] = 0.0
    for i in range(n_read + 1):
        for j in range(n_det + 1):
            d = D[i][j]
            if d == INF:
                continue
            if i < n_read:
                for k in range(1, min(span, n_det - j) + 1):
                    c = d + cost(i, j, k) + SPAN_COST * (k - 1)
                    if c < D[i + 1][j + k]:
                        D[i + 1][j + k], B[i + 1][j + k] = c, (i, j, k)
                if d + skip < D[i + 1][j]:
                    D[i + 1][j], B[i + 1][j] = d + skip, (i, j, 0)
            if j < n_det and d + skip < D[i][j + 1]:
                D[i][j + 1], B[i][j + 1] = d + skip, (i, j, -1)
    out, i, j = {}, n_read, n_det
    while B[i][j]:
        pi, pj, k = B[i][j]
        if k > 0:
            out[pi] = (pj, k)
        i, j = pi, pj
    return out


def split_by_length(text, lens):
    """A reading line's words shared out over consecutive lines by their lengths (place_hands.split_by_length)."""
    toks = text.split()
    total = sum(len(w) + 1 for w in toks)
    bounds, acc = [], 0.0
    for L in lens:
        acc += L / sum(lens)
        bounds.append(acc)
    out, pos = [[] for _ in lens], 0
    for w in toks:
        f = pos / total
        out[next((k for k, b_ in enumerate(bounds) if f < b_), len(lens) - 1)].append(w)
        pos += len(w) + 1
    return [' '.join(x) for x in out]


def ctc_char_spans(net, logits_list, text, pad):
    """Each character of `text` as (line, start, end) by CTC forced alignment over the runs' joined frames, and the
    aligned characters' scores; None when the lines are too short for the text (place_hands.ctc_char_spans, whose
    note explains why the emission is the log of kraken's logits, which are already probabilities)."""
    import torch
    from kraken.tasks.align import get_trellis, backtrack, merge_repeats
    keep = [k for k, c in enumerate(text) if c in net.codec.c2l]
    if not keep:
        return None
    sub = ''.join(text[k] for k in keep)
    labels = net.codec.encode(sub).long()
    parts = [lg.detach().float().cpu().squeeze() for lg in logits_list]
    lens = [x.shape[-1] for x in parts]
    if len(labels) != len(sub) or sum(lens) < 2 * len(labels):
        return None
    emission = torch.cat(parts, dim=-1).clamp_min(1e-12).log().T
    segs = merge_repeats(backtrack(get_trellis(emission, labels), emission, labels), sub)
    if len(segs) != len(sub):
        return None
    starts = [sum(lens[:n]) for n in range(len(lens))]

    def where(f):
        n = max(k for k, s0 in enumerate(starts) if s0 <= f)
        T = lens[n]
        local = f - starts[n]
        return n, max(0.0, min(1.0, (local * net.net_scale - pad) / max(1.0, T * net.net_scale - 2 * pad)))
    spans = [None] * len(text)
    for k, sg in zip(keep, segs):
        n, s0 = where(sg.start)
        n1, s1 = where(max(sg.start, sg.end - 1))
        spans[k] = (n, s0, s1 if n1 == n else 1.0)
    for k in range(len(text)):
        if spans[k] is None:
            prev = next((spans[i] for i in range(k - 1, -1, -1) if spans[i]), (0, 0.0, 0.0))
            spans[k] = (prev[0], prev[2], prev[2])
    return spans, [sg.score for sg in segs]


def place(rl, dl, recs, recog, net, pad, span):
    """One matcher: {found index: text} and the page's confidence (place_hands.place_ctc's `place`)."""
    memo = {}

    def cost(i, j, k):
        if (i, j, k) not in memo:
            memo[(i, j, k)] = min(1.0, cer(' '.join(recog.get(j + n, '') for n in range(k)), rl[i]))
        return memo[(i, j, k)]
    m = dp_match(len(rl), len(dl), cost, SKIP, span)
    assigned, fallback, conf = {}, 0, []
    for i, (j, k) in m.items():
        text, run = rl[i], range(j, j + k)
        got = None
        if all(recs.get(n) is not None and recs[n].logits is not None for n in run):
            got = ctc_char_spans(net, [recs[n].logits for n in run], text, pad)
        if got is None:
            fallback += 1
            for n, chunk in zip(run, split_by_length(text, [dl[n]['len'] for n in run])):
                if chunk:
                    assigned[n] = chunk
            continue
        spans, scores = got
        conf += scores
        for mt in re.finditer(r'\S+', text):
            n0 = spans[mt.start()][0]
            assigned[j + n0] = (assigned.get(j + n0, '') + ' ' + mt.group()).strip()
    n_chars = sum(len(r.replace(' ', '')) for r in rl)
    return {'assigned': assigned, 'confidence': sum(conf) / max(1, n_chars), 'fallback': fallback, 'span': span}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('reading')
    ap.add_argument('out')
    ap.add_argument('--model', required=True)
    ap.add_argument('--device', default='cpu')
    a = ap.parse_args()
    seconds = {}
    t0 = time.time()
    from PIL import Image
    from kraken.configs import RecognitionInferenceConfig, SegmentationInferenceConfig
    from kraken.containers import BaselineLine, Segmentation
    from kraken.kraken import SEGMENTATION_DEFAULT_MODEL
    from kraken.lib.util import open_image
    from kraken.tasks import ForcedAlignmentTaskModel, SegmentationTaskModel
    seconds['import'] = time.time() - t0
    rl = clean(open(a.reading, encoding='utf-8').read())
    t0 = time.time()
    seg_model = SegmentationTaskModel.load_model(SEGMENTATION_DEFAULT_MODEL)
    net = ForcedAlignmentTaskModel.load_model(a.model).net
    cfg = RecognitionInferenceConfig(accelerator=a.device)
    cfg.return_logits = True
    cfg.return_line_image = True
    net.prepare_for_inference(cfg)
    seconds['load'] = time.time() - t0
    t0 = time.time()
    im = open_image(a.image)
    W, H = im.size
    res = seg_model.predict(im=im, config=SegmentationInferenceConfig(accelerator=a.device))
    dl = found_lines(res, W, H)
    seconds['blla'] = time.time() - t0
    out = {'lines': [], 'confidence': 0.0, 'span': 1, 'detected': len(dl), 'reading_lines': len(rl),
           'fallback_lines': 0, 'seconds': seconds}
    if dl and rl:
        t0 = time.time()

        def kline(d):
            bd = d['boundary'] or [(x, y - FRAC * d['h']) for x, y in d['baseline']] + \
                [(x, y + (1 - FRAC) * d['h']) for x, y in d['baseline'][::-1]]
            return BaselineLine(id=None, baseline=[tuple(map(int, p)) for p in d['baseline']],
                                boundary=[tuple(map(int, p)) for p in bd])
        usable = [j for j, d in enumerate(dl) if len(d['baseline']) >= 2]
        seg = Segmentation(type='baselines', imagename=a.image, text_direction='horizontal-lr',
                           script_detection=False, lines=[kline(dl[j]) for j in usable])
        recs = dict(zip(usable, net.predict(im=Image.open(a.image), segmentation=seg)))
        recog = {j: r.prediction for j, r in recs.items()}
        seconds['recognise'] = time.time() - t0
        t0 = time.time()
        one, many = (place(rl, dl, recs, recog, net, cfg.padding, sp) for sp in SPANS)
        pick = many if many['confidence'] > one['confidence'] + 1e-9 else one
        seconds['align'] = time.time() - t0
        out.update(confidence=pick['confidence'], span=pick['span'], fallback_lines=pick['fallback'],
                   lines=[{'text': pick['assigned'][j], 'box': dl[j]['box']}
                          for j in range(len(dl)) if pick['assigned'].get(j)])
    # ru_maxrss is bytes on macOS
    out['peak_rss'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    tmp = a.out + '.part'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False)
    os.replace(tmp, a.out)


if __name__ == '__main__':
    sys.exit(main())
