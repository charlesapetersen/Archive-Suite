"""W46.fix-place-truth — the placement truth set (F-placement §6.2, 10-gap-audit §4 fix 5).

Four groups, one JSON per page in STORE (private: the owner's text and the public pages' text stay off the repo,
as the bench corpus does), plus a PAGE-XML copy of each and a text-free summary in segbench-results:

  owner-typed  40 typewritten or printed pages of the owner's 96, drawn by a fixed seed in the 96's kind mix.
  owner-hand   every handwritten or mixed truth page (21: the 96's 18 and the three outside it).
  L2-bentham   the bench corpus's 20 Bentham pages (L2), word and line polygons from tranScriptorium's PAGE GT.
  N6           the bench corpus's 40 Devanagari pages, line boxes and baselines from their ALTO/PAGE.

The owner pages' boxes are DRAFTED: each truth word is aligned with Apple Vision's word boxes
(`vision-words.json`, top-left normalised [x, y, w, h], `.accurate`), as `locate.py` aligned disputed spans. A
word's `status` says where its box came from: `vision` (same word), `vision-sub` (Vision read it differently,
one for one), `split` (its box is a share of Vision words read as a different count), `missing` (Vision has no
word there: draw it in the tool). Lines follow Vision's lines; a line's baseline is drafted at BASELINE_FRAC of
its words' height. The transcript is the truth text, broken where the drafted lines break.

Usage: python3 place_truth.py build    # writes STORE and the summary
       python3 place_truth.py summary  # prints the summary only
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'corpus'))

TRUTH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-truth'
BENCH = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/bench-corpus'
FROZEN = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/bench-corpus-frozen'
STORE = Path.home() / 'Library/Application Support/ArchiveSuiteRehearsal/place-truth'
RESULTS = HERE.parent.parent / 'segbench-results'
MANIFEST = RESULTS / 'bench-corpus/manifest.jsonl'
SCORED = RESULTS / 'ocr-pages.csv'

SEED = 'W46.fix-place-truth'
N_TYPED = 40
BASELINE_FRAC = 0.78  # of a Vision word box's height, top down: where the baseline sits in a box with descenders


def norm(t: str) -> str:
    return re.sub(r'[^0-9a-z]', '', t.lower())


def seeded(items, key=lambda x: x):
    return sorted(items, key=lambda x: hashlib.sha256(f'{SEED}:{key(x)}'.encode()).hexdigest())


def image_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)],
                         capture_output=True, text=True, check=True).stdout
    w = int(re.search(r'pixelWidth: (\d+)', out).group(1))
    h = int(re.search(r'pixelHeight: (\d+)', out).group(1))
    return w, h


# ---------------------------------------------------------------- owner pages: draft from Vision's words

def vision_lines(vw) -> list[int]:
    """A line number for each Vision word, in Vision's reading order: a new line where the next word starts left
    of the previous one, leaves its height band, or jumps a column-sized gap."""
    out, line = [], 0
    for i, w in enumerate(vw):
        if i:
            p = vw[i - 1]
            pcy, cy = p[2] + p[4] / 2, w[2] + w[4] / 2
            h = max(p[4], w[4])
            gap = w[1] - (p[1] + p[3])
            if w[1] < p[1] or abs(cy - pcy) > 0.5 * h or gap > max(0.06, 4 * h):
                line += 1
        out.append(line)
    return out


def union(boxes):
    x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes); y1 = max(b[1] + b[3] for b in boxes)
    return [x0, y0, x1 - x0, y1 - y0]


def clamp(b):
    x0, y0 = max(0.0, b[0]), max(0.0, b[1])
    x1, y1 = min(1.0, b[0] + b[2]), min(1.0, b[1] + b[3])
    return [x0, y0, max(0.0, x1 - x0), max(0.0, y1 - y0)]


def share(truth_toks, vwords, vlines):
    """Boxes for `truth_toks` read by Vision as a different number of words: each truth word takes the stretch
    of Vision's characters its own length claims, sliced horizontally inside a Vision word; a stretch that
    crosses lines keeps its larger part."""
    chars = []  # (vision index, offset in that word, word length)
    for k, w in enumerate(vwords):
        n = max(1, len(w[0]))
        chars += [(k, j, n) for j in range(n)]
    total_t = sum(max(1, len(t)) for t in truth_toks)
    out, pos = [], 0
    for t in truth_toks:
        a = pos * len(chars) / total_t
        pos += max(1, len(t))
        b = pos * len(chars) / total_t
        span = chars[int(a):max(int(a) + 1, int(round(b)))]
        by_line = {}
        for k, j, n in span:
            by_line.setdefault(vlines[k], []).append((k, j, n))
        part = max(by_line.values(), key=len)
        pieces = []
        for k in sorted({k for k, _, _ in part}):
            js = [j for kk, j, _ in part if kk == k]
            n = max(1, len(vwords[k][0]))
            x, y, w, h = vwords[k][1:5]
            lo, hi = min(js) / n, (max(js) + 1) / n
            pieces.append([x + lo * w, y, (hi - lo) * w, h])
        out.append((union(pieces), vlines[part[0][0]]))
    return out


def draft_owner(page: str, text: str, vw) -> tuple[list[dict], list[dict]]:
    toks = text.split()
    vlines = vision_lines(vw)
    tn = [norm(t) for t in toks]
    vn = [norm(w[0]) for w in vw]
    words = [{'text': t, 'box': None, 'line': None, 'status': 'missing'} for t in toks]
    for t, w in zip(toks, words):
        if t.startswith('[') and 'illegible' in t.lower():
            w['status'] = 'illegible'
    sm = difflib.SequenceMatcher(None, tn, vn, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == 'equal' or (op == 'replace' and i2 - i1 == j2 - j1):
            for k in range(i2 - i1):
                v = vw[j1 + k]
                if words[i1 + k]['status'] == 'illegible':
                    continue
                words[i1 + k].update(box=list(v[1:5]), line=vlines[j1 + k],
                                     status='vision' if op == 'equal' else 'vision-sub')
        elif op == 'replace':
            idx = [i for i in range(i1, i2) if words[i]['status'] != 'illegible']
            if not idx:
                continue
            for i, (box, ln) in zip(idx, share([toks[i] for i in idx], vw[j1:j2], vlines[j1:j2])):
                words[i].update(box=box, line=ln, status='split')
    # Unplaced words take the line of the placed word before them (or after, at the top of the page).
    last = next((w['line'] for w in words if w['line'] is not None), 0)
    for w in words:
        if w['line'] is None:
            w['line'] = last
        last = w['line']
    # Renumber lines in order of first appearance, so line ids follow the transcript.
    order = {}
    for w in words:
        order.setdefault(w['line'], len(order))
    for w in words:
        w['line'] = order[w['line']]
        if w['box']:
            w['box'] = [round(v, 5) for v in clamp(w['box'])]
    lines = []
    for ln in range(len(order)):
        ws = [w for w in words if w['line'] == ln]
        boxed = [w['box'] for w in ws if w['box']]
        line = {'id': ln, 'text': ' '.join(w['text'] for w in ws), 'box': None, 'baseline': None, 'status': 'drafted'}
        if boxed:
            line['box'] = [round(v, 5) for v in union(boxed)]
            pts = []
            for b in sorted(boxed):
                y = round(b[1] + BASELINE_FRAC * b[3], 5)
                pts += [[round(b[0], 5), y], [round(b[0] + b[2], 5), y]]
            line['baseline'] = pts
        lines.append(line)
    return words, lines


def owner_pages():
    """(typed, hand): page ids. Typed from the 96 in its typewritten:printed mix; hand = every handwritten or
    mixed page with a truth file."""
    import csv
    kinds = {r['page']: r['kind'] for r in csv.DictReader(open(SCORED))}
    rows = list(csv.DictReader(open(TRUTH / 'pages.tsv'), delimiter='\t'))
    have = {p.stem for p in (TRUTH / 'truth').glob('p*.txt')}
    tw = seeded([p for p, k in kinds.items() if k == 'typewritten'])
    pr = seeded([p for p, k in kinds.items() if k == 'printed'])
    n_tw = round(N_TYPED * len(tw) / (len(tw) + len(pr)))
    typed = sorted(tw[:n_tw] + pr[:N_TYPED - n_tw])
    hand = sorted(r['page'] for r in rows if r['kind'] in ('handwritten', 'mixed') and r['page'] in have)
    allk = {r['page']: r['kind'] for r in rows}
    return typed, hand, allk, kinds


def build_owner(group, pages, allk, scored):
    vw_all = json.loads((TRUTH / 'vision-words.json').read_text())
    out = []
    for p in pages:
        img = TRUTH / 'pages' / f'{p}.jpg'
        text = (TRUTH / 'truth' / f'{p}.txt').read_text()
        words, lines = draft_owner(p, text, vw_all.get(p, []))
        W, H = image_size(img)
        out.append({'page': p, 'group': group, 'kind': allk.get(p, ''), 'in_96': p in scored,
                    'image': str(img), 'width': W, 'height': H, 'coords': 'normalised, top-left origin',
                    'words': words, 'lines': lines, 'audit': None})
    return out


# ---------------------------------------------------------------- public pages: free geometry

def _local(tag):
    return tag.rsplit('}', 1)[-1]


def _bbox(pts, W, H):
    xs = [x for x, _ in pts]; ys = [y for _, y in pts]
    return [round(min(xs) / W, 5), round(min(ys) / H, 5), round((max(xs) - min(xs)) / W, 5),
            round((max(ys) - min(ys)) / H, 5)]


def line_share(toks, box):
    """Draft word boxes for a line known only as a box: the width shared by character count, a space between."""
    x, y, w, h = box
    units = sum(len(t) for t in toks) + len(toks) - 1
    out, pos = [], 0
    for t in toks:
        out.append([round(x + w * pos / units, 5), y, round(w * len(t) / units, 5), h])
        pos += len(t) + 1
    return out


def bentham_page(xml: Path, img: Path) -> dict:
    """Lines and words from a Bentham PAGE 2010 file, in src_bentham's reading order. Word elements carry no text:
    a line's tokens are given to its Word boxes left to right when the counts agree (3 of the 20 pages have Word
    elements at all); otherwise the line's box is shared out by character count (`line-share`, a draft). PAGE 2010 here has no Baseline: it is derived as the
    lower quartile of the line polygon's y at each word, a drafted line, so READ-BAD on L2 measures against it."""
    import src_bentham as sb
    root = ET.fromstring(xml.read_bytes())
    W, H = image_size(img)
    regions = []
    for reg in root.iter():
        if _local(reg.tag) != 'TextRegion':
            continue
        lines = []
        for ln in reg.iter():
            if _local(ln.tag) != 'TextLine':
                continue
            text = sb.clean(sb._unicode(ln))
            pts = sb._points(ln)
            if not text.strip() or not pts:
                continue
            wboxes = [sb._points(w) for w in ln if _local(w.tag) == 'Word']
            wboxes = sorted((b for b in wboxes if b), key=lambda b: min(x for x, _ in b))
            lines.append((sum(y for _, y in pts) / len(pts), min(x for x, _ in pts), text, pts, wboxes))
        if not lines:
            continue
        lines.sort(key=lambda r: (r[0], r[1]))
        rpts = sb._points(reg) or [(x, 0) for _, x, _, _, _ in lines]
        regions.append((lines[0][0], min(x for x, _ in rpts), lines))
    regions.sort(key=lambda r: (r[0], r[1]))
    words, out_lines = [], []
    for _, _, lines in regions:
        for _, _, text, pts, wboxes in lines:
            ln = len(out_lines)
            toks = text.split()
            ok = len(toks) == len(wboxes)
            shares = None if ok else line_share(toks, _bbox(pts, W, H))
            for k, t in enumerate(toks):
                words.append({'text': t, 'box': _bbox(wboxes[k], W, H) if ok else shares[k], 'line': ln,
                              'status': 'page-xml' if ok else 'line-share'})
            xs = sorted({x for x, _ in pts})
            base = []
            for b in (wboxes or [pts]):
                bx0, bx1 = min(x for x, _ in b), max(x for x, _ in b)
                col = sorted(y for x, y in pts if bx0 <= x <= bx1) or sorted(y for _, y in pts)
                y = col[int(0.75 * (len(col) - 1))]
                base += [[round(bx0 / W, 5), round(y / H, 5)], [round(bx1 / W, 5), round(y / H, 5)]]
            out_lines.append({'id': ln, 'text': text, 'box': _bbox(pts, W, H),
                              'baseline': base if xs else None, 'status': 'page-xml, baseline derived'})
    return {'words': words, 'lines': out_lines, 'width': W, 'height': H}


def alto_page(xml: Path, img: Path) -> dict:
    """Lines (box, baseline, text) from an ALTO v4 file; its Strings are whole lines, so there are no word boxes."""
    root = ET.fromstring(xml.read_bytes())
    page = next(e for e in root.iter() if _local(e.tag) == 'Page')
    W, H = int(page.get('WIDTH')), int(page.get('HEIGHT'))
    lines, words = [], []
    for tl in root.iter():
        if _local(tl.tag) != 'TextLine':
            continue
        text = ' '.join(s.get('CONTENT', '') for s in tl if _local(s.tag) == 'String').strip()
        if not text:
            continue
        x, y, w, h = (float(tl.get(k)) for k in ('HPOS', 'VPOS', 'WIDTH', 'HEIGHT'))
        base = None
        if tl.get('BASELINE') and ',' in tl.get('BASELINE'):
            base = [[round(float(a) / W, 5), round(float(b) / H, 5)]
                    for a, b in (p.split(',') for p in tl.get('BASELINE').split())]
        ln = len(lines)
        lines.append({'id': ln, 'text': text, 'box': [round(x / W, 5), round(y / H, 5), round(w / W, 5),
                                                       round(h / H, 5)], 'baseline': base, 'status': 'alto'})
        words += [{'text': t, 'box': None, 'line': ln, 'status': 'line-only'} for t in text.split()]
    return {'words': words, 'lines': lines, 'width': W, 'height': H}


def page2013(xml: Path, img: Path) -> dict:
    """Lines (box, baseline, text) from a PAGE 2013+ file with `points` attributes, in document order."""
    root = ET.fromstring(xml.read_bytes())
    page = next(e for e in root.iter() if _local(e.tag) == 'Page')
    W, H = int(page.get('imageWidth')), int(page.get('imageHeight'))
    lines, words = [], []
    parse = lambda s: [tuple(int(float(v)) for v in p.split(',')) for p in s.split()]
    for tl in root.iter():
        if _local(tl.tag) != 'TextLine':
            continue
        coords = next((c for c in tl if _local(c.tag) == 'Coords'), None)
        base = next((c for c in tl if _local(c.tag) == 'Baseline'), None)
        eq = [u for c in tl if _local(c.tag) == 'TextEquiv' for u in c if _local(u.tag) == 'Unicode']
        text = (eq[0].text or '').strip() if eq else ''
        if not text or coords is None:
            continue
        ln = len(lines)
        lines.append({'id': ln, 'text': text, 'box': _bbox(parse(coords.get('points')), W, H),
                      'baseline': [[round(x / W, 5), round(y / H, 5)] for x, y in parse(base.get('points'))]
                      if base is not None else None, 'status': 'page-xml'})
        words += [{'text': t, 'box': None, 'line': ln, 'status': 'line-only'} for t in text.split()]
    return {'words': words, 'lines': lines, 'width': W, 'height': H}


def build_public():
    rows = [json.loads(l) for l in open(MANIFEST)]
    out = []
    for r in rows:
        if r['stratum'] == 'L2' and r['source'] == 'bentham':
            stem = r['page_id'].split('/')[-1]
            xml = BENCH / 'raw/bentham/BenthamDatasetR0-GT/PAGE' / f'{stem}.xml'
            img = FROZEN / 'L2' / f'bentham__{stem}.jpg'
            d = bentham_page(xml, img)
            group = 'L2-bentham'
        elif r['stratum'] == 'N6':
            book, name = r['page_id'].split('/')
            img = FROZEN / 'N6' / f'devanagari__{book}_{name}.jpg'
            if not img.exists():
                img = next(FROZEN.glob(f'N6/devanagari__{book}*{name}.jpg'))
            xml = BENCH / 'raw/devanagari/alto' / book / f'{name}.xml'
            d = alto_page(xml, img) if b'<alto' in xml.read_bytes()[:2000] else page2013(xml, img)
            group = 'N6'
        else:
            continue
        out.append({'page': r['page_id'], 'group': group, 'kind': r['kind'], 'in_96': False, 'image': str(img),
                    'coords': 'normalised, top-left origin', 'audit': None, **d})
    return out


# ---------------------------------------------------------------- PAGE-XML and the summary

def page_xml(p: dict) -> str:
    W, H = p['width'], p['height']

    def pts(b):
        x, y, w, h = b
        return ' '.join(f'{round(a * W)},{round(c * H)}' for a, c in ((x, y), (x + w, y), (x + w, y + h), (x, y + h)))

    ns = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15'
    root = ET.Element('PcGts', xmlns=ns)
    meta = ET.SubElement(root, 'Metadata')
    ET.SubElement(meta, 'Creator').text = 'W46.fix-place-truth place_truth.py'
    pg = ET.SubElement(root, 'Page', imageFilename=Path(p['image']).name, imageWidth=str(W), imageHeight=str(H))
    reg = ET.SubElement(pg, 'TextRegion', id='r0')
    boxes = [l['box'] for l in p['lines'] if l['box']]
    ET.SubElement(reg, 'Coords', points=pts(union(boxes)) if boxes else '0,0 1,0 1,1 0,1')
    for l in p['lines']:
        tl = ET.SubElement(reg, 'TextLine', id=f"l{l['id']}", custom=f"status:{l['status']}")
        ET.SubElement(tl, 'Coords', points=pts(l['box']) if l['box'] else '0,0 1,0 1,1 0,1')
        if l['baseline']:
            ET.SubElement(tl, 'Baseline', points=' '.join(f'{round(x * W)},{round(y * H)}' for x, y in l['baseline']))
        for k, w in enumerate(x for x in p['words'] if x['line'] == l['id']):
            if not w['box']:
                continue
            we = ET.SubElement(tl, 'Word', id=f"l{l['id']}w{k}", custom=f"status:{w['status']}")
            ET.SubElement(we, 'Coords', points=pts(w['box']))
            ET.SubElement(ET.SubElement(we, 'TextEquiv'), 'Unicode').text = w['text']
        ET.SubElement(ET.SubElement(tl, 'TextEquiv'), 'Unicode').text = l['text']
    ET.indent(root)
    return '<?xml version="1.0" encoding="UTF-8"?>\n' + ET.tostring(root, encoding='unicode') + '\n'


def summarise(pages: list[dict]) -> dict:
    groups = {}
    for p in pages:
        g = groups.setdefault(p['group'], {'pages': 0, 'words': 0, 'lines': 0, 'baselines': 0, 'status': {},
                                           'lines_per_page': []})
        g['pages'] += 1
        g['words'] += len(p['words'])
        g['lines'] += len(p['lines'])
        g['baselines'] += sum(1 for l in p['lines'] if l['baseline'])
        g['lines_per_page'].append(len(p['lines']))
        for w in p['words']:
            g['status'][w['status']] = g['status'].get(w['status'], 0) + 1
    for g in groups.values():
        g['median_lines_per_page'] = median(g.pop('lines_per_page'))
    per_page = [{'page': p['page'], 'group': p['group'], 'kind': p['kind'], 'in_96': p['in_96'],
                 'words': len(p['words']), 'lines': len(p['lines']),
                 'missing': sum(1 for w in p['words'] if w['status'] == 'missing'),
                 'audit': (p.get('audit') or {}).get('verdict')} for p in pages]
    return {'groups': groups, 'pages': per_page}


def write(pages):
    STORE.mkdir(parents=True, exist_ok=True)
    (STORE / 'xml').mkdir(exist_ok=True)
    for p in pages:
        name = p['page'].replace('/', '__')
        old = STORE / f'{name}.json'
        if old.exists():  # never clobber a corrected or audited page with a fresh draft
            prev = json.loads(old.read_text())
            if prev.get('corrected') or prev.get('audit'):
                p = prev
        (STORE / f'{name}.json').write_text(json.dumps(p, ensure_ascii=False, indent=1))
        (STORE / 'xml' / f'{name}.xml').write_text(page_xml(p))


def load_all() -> list[dict]:
    return [json.loads(f.read_text()) for f in sorted(STORE.glob('*.json'))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('cmd', choices=['build', 'summary'])
    a = ap.parse_args()
    if a.cmd == 'build':
        typed, hand, allk, scored = owner_pages()
        pages = build_owner('owner-typed', typed, allk, scored) + build_owner('owner-hand', hand, allk, scored)
        pages += build_public()
        write(pages)
    s = summarise(load_all())
    (RESULTS / 'place-truth.json').write_text(json.dumps(s, indent=1) + '\n')
    print(json.dumps(s['groups'], indent=1))


if __name__ == '__main__':
    main()
