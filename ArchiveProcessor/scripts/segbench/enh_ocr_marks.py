#!/usr/local/bin/python3
"""W46.enh-ocr-input-marks. The enhancement methods of W46.enh-ocr-input on the marks set, with the mark-region
ink check: whether any method may touch the reading copy without losing the hand on the page.

  V=~/Library/Caches/ArchiveSuiteRehearsal/enh-ocr-input/venv/bin/python
  python3 ops/autonomous/heavy-run.py run -- $V enh_ocr_marks.py arms   # jpeg, shading, GCDRNet, SBB on the 40
  $V enh_ocr_marks.py report                                            # segbench-results/enh-ocr-marks.{md,json}
  python3 enh_ocr_marks.py report --saved   # the report again from the rows in enh-ocr-marks.json (no images)

Pages: the marks set's 40-page owner core (W46.fix-marks-set-score's freeze, after W46.fix-marks-sheet-feedback's
recheck), read from the derived record `marks-set-reconciled.json` names; the images are the marks scan's 2400 px
JPEGs, the copies every model read. Boxes: every mark the owner kept on those pages (rough draft boxes plus one
owner box; [x0, y0, x1, y1] fractions of the image). The ink check needs regions, not complete detector truth, so
the 8 pages excluded from detector truth for box completeness or relationships are measured too and the 32
detector pages are also reported alone; the unit of every interval is the page, so a box that contains others is
not counted twice in a page figure.

Arms, each from the raw image at its size (enh_ocr_arms.py; the same code and weights as W46.enh-ocr-input):
  jpeg      the raw image decoded and saved again at JPEG 90, as every arm is saved: the re-encoding floor.
  shading   the contrast-only control (a gain field).
  gcdrnet   GCDRNet, content-removing.
  sbb       SBB binarisation, black on white.
DocRes (appearance, deshadow) needs a cluster GPU; whether to run it here is the report's Scope.

The ink check, per box, against raw. A pixel is ink where some channel is darker than its own background
(enh_ocr_arms.background, DocRes's shading estimate) by more than T: darkness = 1 - min over channels of
pixel / background. T = 0.30 (clear ink) and 0.15 (faint ink: pencil, a light stamp). For each box:
  kept      the share of raw's ink pixels still ink in the arm (survival);
  contrast  the arm's mean darkness over raw's ink pixels, as a share of raw's;
  colour    the share of raw's coloured ink (channel spread over background above 0.15) still coloured;
  added     ink in the arm where raw had none, as a share of raw's ink.
A box is lost when under half its ink survives. The control for each page is the same figures outside every box
(the print, mostly), so `kept - print kept` says whether a method removes marks more than it removes print. Colour
is also paired by page against the `jpeg` floor (`colour_vs_floor`, the pages with coloured ink in both), since the
floor went through the same JPEG 90 save and chroma subsampling cancels in the pairing.

Images and pixel data stay in CACHE (the owner's material); committed results hold page ids and numbers only. No
network, no money, no model reads a page.
"""
from __future__ import annotations
import argparse
import json
import os
import random
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = HERE.parents[1] / 'segbench-results'
SCAN = Path.home() / '.local/state/archive-autonomous/artifacts/marks-scan-20261029'
ENH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/enh-ocr-input'   # W46.enh-ocr-input's src, weights, venvs
CACHE = Path(os.environ.get('ENH_MARKS_CACHE', Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/enh-ocr-marks'))
RECONCILED = RESULTS / 'marks-set-reconciled.json'
REPORT, DATA = RESULTS / 'enh-ocr-marks.md', RESULTS / 'enh-ocr-marks.json'
ARMS = ('jpeg', 'shading', 'gcdrnet', 'sbb')
THRESHOLDS = (0.30, 0.15)
COLOUR = 0.15
LOST = 0.5
MIN_INK = 50   # a box with fewer raw ink pixels at T has no ink to lose at that T and is left out at it


def record():
    """(derived record dict, its root): the pages, marks and detector flags after the recheck."""
    root = Path(json.loads(RECONCILED.read_text())['reconciled_root'])
    return json.loads((root / 'reconciled.json').read_text()), root


def pages():
    return sorted(record()[0]['pages'])


def raw_image(p):
    return SCAN / 'images' / f'{p}.jpg'


def arm_image(arm, p):
    return CACHE / 'images' / arm / f'{p}.jpg'


def arms():
    """jpeg and shading here; GCDRNet and SBB in W46.enh-ocr-input's venvs, through its own runners."""
    import numpy as np
    from PIL import Image
    import enh_ocr_arms as A
    import enh_ocr_input as E
    ids = pages()
    link = CACHE / 'raw-links'
    link.mkdir(parents=True, exist_ok=True)
    for p in ids:
        if not (link / f'{p}.jpg').exists():
            (link / f'{p}.jpg').symlink_to(raw_image(p))
        with Image.open(raw_image(p)) as im:
            img = np.asarray(im.convert('RGB'))
        for arm, make in (('jpeg', lambda x: x), ('shading', A.shading)):
            if not arm_image(arm, p).exists():
                E.save_jpeg(make(img), arm_image(arm, p))
    subprocess.run([str(ENH / 'venv/bin/python'), str(HERE / 'enh_ocr_arms.py'), 'gcdrnet', str(ENH), str(link),
                    str(CACHE / 'images'), *ids], check=True)
    subprocess.run([str(ENH / 'venv-tf/bin/python'), '-c', E.SBB, str(ENH), str(link), str(CACHE / 'images'), *ids],
                   check=True)
    print('jpeg, shading, gcdrnet, sbb ->', CACHE / 'images')


def darkness(img):
    """(darkness, spread) per pixel, floats in [0, 1]: how far the darkest channel falls below its background, and
    how far the channels' background-relative values spread (coloured ink)."""
    import numpy as np
    import enh_ocr_arms as A
    bg = np.maximum(A.background(img).astype(np.float32), 1.0)
    rel = np.clip(img.astype(np.float32) / bg, 0.0, 1.0)
    return 1.0 - rel.min(axis=2), rel.max(axis=2) - rel.min(axis=2)


def box_pixels(box, shape):
    h, w = shape
    x0, y0, x1, y1 = box
    return (slice(max(0, int(y0 * h)), min(h, int(round(y1 * h)))),
            slice(max(0, int(x0 * w)), min(w, int(round(x1 * w)))))


def measure(raw, enh, t, mask=None):
    """The ink check for one region: raw and enh are (darkness, spread) arrays cut to it, mask an optional boolean
    array of the pixels that count. None when raw has under MIN_INK ink pixels there."""
    import numpy as np
    rd, rs = raw
    ed, es = enh
    ink = rd > t
    if mask is not None:
        ink &= mask
    n = int(ink.sum())
    if n < MIN_INK:
        return None
    ein = ed > t
    col = ink & (rs > COLOUR)
    nc = int(col.sum())
    added = ein & ~(rd > t)
    if mask is not None:
        added &= mask
    return dict(ink=n, kept=float((ein & ink).sum() / n), contrast=float(ed[ink].mean() / rd[ink].mean()),
                colour=float(((es > COLOUR) & col).sum() / nc) if nc >= MIN_INK else None,
                added=float(added.sum() / n))


def page_rows(p, marks):
    """Per arm, threshold: the boxes' checks and the outside-the-boxes control for one page."""
    import numpy as np
    from PIL import Image
    with Image.open(raw_image(p)) as im:
        raw = darkness(np.asarray(im.convert('RGB')))
    shape = raw[0].shape
    outside = np.ones(shape, bool)
    for m in marks:
        ys, xs = box_pixels(m['box'], shape)
        outside[ys, xs] = False
    out = {}
    for arm in ARMS:
        with Image.open(arm_image(arm, p)) as im:
            a = np.asarray(im.convert('RGB'))
        if a.shape[:2] != shape:
            raise SystemExit(f'{arm}/{p}: {a.shape[:2]} is not the raw image\'s {shape}')
        enh = darkness(a)
        for t in THRESHOLDS:
            boxes = []
            for i, m in enumerate(marks):
                ys, xs = box_pixels(m['box'], shape)
                r = measure((raw[0][ys, xs], raw[1][ys, xs]), (enh[0][ys, xs], enh[1][ys, xs]), t)
                if r:
                    boxes.append(dict(r, mark=i + 1, cls=m['cls'], overlaps=m['overlaps']))
            out[f'{arm}@{t:.2f}'] = dict(boxes=boxes, print=measure(raw, enh, t, outside))
    return out


def run_checks(saved=False):
    """(record, rows): measured from the images, or with saved=True the rows the last report wrote (the images
    are rebuildable scratch and may be gone)."""
    rec, _ = record()
    if saved:
        return rec, json.loads(DATA.read_text())['rows']
    rows = {}
    for p in pages():
        rows[p] = page_rows(p, rec['pages'][p]['marks'])
        print('ink', p, flush=True)
    return rec, rows


def colour_vs_floor(rows, ids, key, floor):
    """Page mean colour at arm@T less the jpeg floor's at the same T, over pages with coloured ink in both; 10,000
    bootstrap draws over pages."""
    diff = []
    for p in ids:
        a = [b['colour'] for b in rows[p][key]['boxes'] if b['colour'] is not None]
        j = [b['colour'] for b in rows[p][floor]['boxes'] if b['colour'] is not None]
        if a and j:
            diff.append(statistics.fmean(a) - statistics.fmean(j))
    b = boot(diff, n=10000)
    return b and dict(b, below=sum(x < 0 for x in diff))


def boot(xs, n=4000, seed=7):
    """Mean and 95% percentile bootstrap interval over pages."""
    if not xs:
        return None
    rnd = random.Random(seed)
    ms = sorted(statistics.fmean(rnd.choices(xs, k=len(xs))) for _ in range(n))
    return dict(n=len(xs), mean=statistics.fmean(xs), lo=ms[int(0.025 * n)], hi=ms[int(0.975 * n) - 1])


def summarise(rec, rows, ids, key, pick=lambda b: True):
    """Over pages ids at arm@T: page means of box kept, kept minus the page's print kept (paired), contrast, colour,
    added; the lost-box count; all boxes pooled."""
    kept, diff, contrast, colour, added = [], [], [], [], []
    lost = total = 0
    lost_pages = []
    for p in ids:
        r = rows[p][key]
        bs = [b for b in r['boxes'] if pick(b)]
        if not bs:
            continue
        if any(b['kept'] < LOST for b in bs):
            lost_pages.append(p)
        k = statistics.fmean(b['kept'] for b in bs)
        kept.append(k)
        if r['print']:
            diff.append(k - r['print']['kept'])
        contrast.append(statistics.fmean(b['contrast'] for b in bs))
        cs = [b['colour'] for b in bs if b['colour'] is not None]
        if cs:
            colour.append(statistics.fmean(cs))
        added.append(statistics.fmean(b['added'] for b in bs))
        lost += sum(b['kept'] < LOST for b in bs)
        total += len(bs)
    prints = [rows[p][key]['print']['kept'] for p in ids if rows[p][key]['print']]
    return dict(kept=boot(kept), kept_minus_print=boot(diff), contrast=boot(contrast), colour=boot(colour),
                added=boot(added), print_kept=boot(prints), lost=lost, boxes=total, lost_pages=lost_pages)


def fmt(b, pct=True):
    if not b:
        return '–'
    f = (lambda v: f'{100 * v:.1f}') if pct else (lambda v: f'{v:+.3f}')
    return f"{f(b['mean'])} ({f(b['lo'])} to {f(b['hi'])})"


def report(saved=False):
    rec, rows = run_checks(saved)
    ids = sorted(rows)
    det = [p for p in ids if rec['pages'][p]['detector_evaluable']]
    hand = ('annotation', 'marginal_note', 'signature_initials')
    subsets = {'all 40 pages': (ids, lambda b: True), 'detector pages (32)': (det, lambda b: True),
               'handwriting classes': (ids, lambda b: b['cls'] in hand),
               'stamps': (ids, lambda b: b['cls'] == 'stamp'),
               'boxes clear of print': (ids, lambda b: not b['overlaps'])}
    out = dict(protocol='enh-ocr-marks-v1', pages=len(ids), detector_pages=len(det),
               boxes=sum(len(rec['pages'][p]['marks']) for p in ids), arms=list(ARMS),
               thresholds=list(THRESHOLDS), lost_below=LOST, min_ink=MIN_INK, summary={}, rows=rows)
    for t in THRESHOLDS:
        for arm in ARMS:
            key = f'{arm}@{t:.2f}'
            out['summary'][key] = {name: summarise(rec, rows, s, key, pick) for name, (s, pick) in subsets.items()}
            out['summary'][key]['colour_vs_floor'] = colour_vs_floor(rows, ids, key, f'jpeg@{t:.2f}')
    DATA.write_text(json.dumps(out, indent=1, sort_keys=True) + '\n')

    S = out['summary']
    L = ['# Enhancement on the marks set: does the hand survive?', '',
         'W46.enh-ocr-input-marks. The marks arm of W46.enh-ocr-input (`execution-plans/processing-review/'
         '10-gap-audit.md` §5 item 11): the enhancement methods run on the marks set\'s 40-page owner core, and the '
         'ink inside every mark box the owner kept checked against the raw image. It decides whether any method may '
         'touch the reading copy. Script `scripts/segbench/enh_ocr_marks.py`; per-box figures `enh-ocr-marks.json`.',
         '', f"{out['pages']} pages ({out['detector_pages']} of them detector truth), {out['boxes']} kept mark boxes. "
         'Each figure is a mean over pages with a 95% bootstrap interval over pages. *Kept*: the share of the raw '
         'image\'s ink pixels in a box that are still ink. *Kept − print*: the same page\'s box figure less its '
         'figure outside every box (mostly print), paired by page: below zero means the method takes marks more '
         'than print. *Lost*: boxes with under half their ink left. *Contrast*: mean darkness kept on raw\'s ink. '
         '*Colour*: coloured ink still coloured. *Added*: new ink in the box, as a share of raw\'s ink. `jpeg` is the '
         'raw image saved again as every arm is: the floor.', '']
    for t in THRESHOLDS:
        L += [f'## Ink darker than its background by {t:.2f}' + (' (clear ink)' if t >= 0.3 else ' (faint ink included)'),
              '', '| Arm | Kept % | Kept − print | Lost boxes | Contrast % | Colour % | Added % | Print kept % |',
              '|---|---|---|---:|---|---|---|---|']
        for arm in ARMS:
            s = S[f'{arm}@{t:.2f}']['all 40 pages']
            L.append(f"| {arm} | {fmt(s['kept'])} | {fmt(s['kept_minus_print'], False)} | {s['lost']} of "
                     f"{s['boxes']} ({len(s['lost_pages'])} page{'' if len(s['lost_pages']) == 1 else 's'}) | {fmt(s['contrast'])} | {fmt(s['colour'])} | {fmt(s['added'])} | "
                     f"{fmt(s['print_kept'])} |")
        L += ['', 'Kept % by subset:', '', '| Arm | ' + ' | '.join(n for n in subsets if n != 'all 40 pages') + ' |',
              '|---|' + '---|' * (len(subsets) - 1)]
        for arm in ARMS:
            ss = S[f'{arm}@{t:.2f}']
            L.append(f'| {arm} | ' + ' | '.join(f"{fmt(ss[n]['kept'])}, lost {ss[n]['lost']}/{ss[n]['boxes']}"
                                               for n in subsets if n != 'all 40 pages') + ' |')
        L.append('')
    g = lambda arm, t, f='kept': S[f'{arm}@{t:.2f}']['all 40 pages'][f]
    pc = lambda b: f"{100 * b['mean']:.1f}%"
    sbb_blank = [p for p in ids if (rows[p]['sbb@0.30']['print'] or {}).get('kept', 1) < 0.2]
    a40 = S['jpeg@0.15']['all 40 pages']
    with_boxes = a40['kept']['n']
    with_colour, colour_boxes = a40['colour']['n'], sum(b['colour'] is not None for p in ids
                                                        for b in rows[p]['jpeg@0.15']['boxes'])
    cv = lambda arm, t: S[f'{arm}@{t:.2f}']['colour_vs_floor']
    pts = lambda b: f"{100 * b['mean']:+.1f} colour points ({100 * b['lo']:+.1f} to {100 * b['hi']:+.1f})"
    L += ['## Verdict', '',
          '**Only the contrast-only control may touch the reading copy; the content-removing methods may not.** '
          f"Shading division keeps {pc(g('shading', 0.15))} of the faint-inclusive ink in the mark boxes against "
          f"the re-encoding floor's {pc(g('jpeg', 0.15))}, loses no box at either threshold, and takes marks no "
          'more than print, but it greys the marks\' colour: paired by page against the floor, '
          f"{pts(cv('shading', 0.15))} with faint ink and {pts(cv('shading', 0.30))} clear, on the "
          f"{with_colour} pages and {colour_boxes} boxes with coloured ink ({cv('shading', 0.15)['below']} of the "
          f"{with_colour} pages below the floor). GCDRNet keeps clear ink "
          f"({pc(g('gcdrnet', 0.30))}) but erases faint ink: {pc(g('gcdrnet', 0.15))} kept, "
          f"{g('gcdrnet', 0.15, 'lost')} of {g('gcdrnet', 0.15, 'boxes')} boxes lost on "
          f"{len(g('gcdrnet', 0.15, 'lost_pages'))} pages (three stamps, a signature and two marginal notes), and "
          f"greys colour like shading ({pts(cv('gcdrnet', 0.15))} with faint ink). Its loss is no worse on marks than on the page's "
          "faint print: it erases faint ink wherever it is. SBB keeps "
          f"{pc(g('sbb', 0.15))} of faint ink, loses {g('sbb', 0.15, 'lost')} boxes on "
          f"{len(g('sbb', 0.15, 'lost_pages'))} pages and every mark's colour by construction (coloured ink and "
          'typed print become the same black), and on '
          f"{len(sbb_blank)} page{'s' if len(sbb_blank) != 1 else ''} ({', '.join(sbb_blank) or 'none'}) it "
          "kept under a fifth of the print's ink as well. Its positive kept-minus-print is that print loss, not a "
          'gain for the marks. With W46.enh-ocr-input (no method helps any reader as OCR input), the rule '
          'for the app: the reading copy and the OCR input both stay the raw image; a gain-only shading division is '
          'the one method that may be offered for viewing, and it greys about a fifth of a mark\'s colour there; a '
          'content-removing method never replaces the '
          'stored page.', '',
          '## Measurement card', '',
          '- **Truth.** The marks set\'s owner core after the 2026-11-04 recheck (`marks-set-reconciled.md`): the '
          'owner kept or rejected every candidate mark, its class and whether it touches print; the boxes are rough '
          'draft boxes from Gemini 3.7 Flash and Qwen3-VL 8B plus one owner box, not tight geometry. The ink '
          'itself is measured, not judged: no person or model read a page for this item.',
          '- **Selection.** The frozen two-phase draw\'s 40-page core (16 A-core, 24 B-core), drawn before any '
          'enhancement method existed for these pages; no method or ABBYY text chose a page. Descriptive, no '
          'population weights (W46.marks-sampling-support). The 8 pages excluded from detector truth are in the '
          'measure (their boxes are regions, whatever their completeness) and the 32 detector pages are shown alone.',
          '- **Comparison.** Every arm from the same 2400 px JPEG the models read, at its size, saved at JPEG 90 '
          'like the `jpeg` floor; the same ink function, thresholds and boxes for every arm; the code and weights '
          'of W46.enh-ocr-input.',
          f"- **Noise.** n = {with_boxes} pages: the {out['boxes']} boxes lie on {with_boxes} of the {out['pages']} "
          f"pages (the rest have no kept mark), and {with_colour} of those have coloured ink "
          f"({colour_boxes} boxes); boxes are nested in pages and the bootstrap resamples pages. The `jpeg` arm is "
          'the floor: re-encoding alone moves 2-3% of ink pixels across a threshold and no box. A box figure '
          'within the floor is no change. The floor keeps only about 80% of the coloured ink (JPEG chroma '
          'subsampling), but every arm went through the same JPEG 90 save, so the colour loss is read paired by '
          'page against the floor: shading\'s and GCDRNet\'s intervals stay below zero, a resolved loss, not '
          'noise. Whether the colour measure itself reads divided images differently was not tested.',
          '- **Scope.** Ink survival, not legibility: a mark can keep its pixels and still read worse, and no reader '
          'transcribed the marks here. Rough boxes include print where a mark touches it (the clear-of-print '
          'subset is the purer figure). DocRes appearance and deshadow were not run: they need a cluster GPU, '
          'neither helped any reader in W46.enh-ocr-input and the app ships no enhancement, so their marks arm '
          'decides nothing now and is filed behind W46.nice-to-have (W46.enh-ocr-input-marks-docres). Gemini 3.7 '
          'Flash has read the enhanced images since (W46.enh-ocr-input-paid, `enh-ocr-input.md` '
          '§gemini3.7-flash-gw: no arm helps it, shading and SBB hurt), but that measures its text, not the '
          "marks' ink, so it changes nothing here.", '']
    REPORT.write_text('\n'.join(L) + '\n')
    print('->', REPORT, DATA)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('cmd', choices=('arms', 'report'))
    ap.add_argument('--saved', action='store_true', help='report: from the rows in enh-ocr-marks.json, no images')
    a = ap.parse_args()
    arms() if a.cmd == 'arms' else report(a.saved)


if __name__ == '__main__':
    sys.path.insert(0, str(HERE))
    main()
