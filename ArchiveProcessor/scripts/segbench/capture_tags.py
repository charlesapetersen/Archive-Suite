"""W46.fix-capture-tags. Every saved route's NES on the 96 truth pages, read by capture-defect tag; no calls.

  python3 -I capture_tags.py [--ladder <ocr-panel-local/scores.csv>]

Reads segbench-results/capture-tags.json (the per-page tags: drafted from the images by one model, audited and
tagged again blind by a second, disagreements settled by a third look; how, in its "method") and segbench-results/
ocr-pages.csv (every route's NES on every page), and writes segbench-results/capture-tags.md.

The loss for a tag is paired within its stratum: for each tagged page, its NES minus the mean NES of the pages of
the same kind and the same source class (phone original, or the PDF's processed image) that do not carry that tag,
on the same route; a page whose stratum has no such page is left out and counted. Tags co-occur (90 of the 96
carry at least one), so a tag's loss includes whatever its companions cost; "any" is against the untagged pages.
Rows the provider failed (error, provider-error, interrupted) are not capture effects and are dropped; loops
(length) and refusals stay, scored 0.
The private ladder scores, when given, add the NES drop from original to half and quarter for tagged against
untagged ladder pages. Only page ids, tags and numbers are written; nothing needs the network or money.
"""
from __future__ import annotations
import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path
from statistics import mean, median

RESULTS = Path(__file__).resolve().parents[2] / 'segbench-results'
TAGS, PAGES, OUT = RESULTS / 'capture-tags.json', RESULTS / 'ocr-pages.csv', RESULTS / 'capture-tags.md'
PROVIDER_FAILURES = {'error', 'provider-error', 'interrupted'}
MIN_TAGGED = 3  # below this a tag's loss is listed as too few pages, not as a number


def load_tags(path=TAGS):
    data = json.loads(Path(path).read_text())
    return data['attributes'], {p['page']: p for p in data['pages']}


def load_scores(path=PAGES):
    """route -> page -> NES in points; page -> kind. Provider failures are dropped."""
    scores, kinds = defaultdict(dict), {}
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            kinds[row['page']] = row['kind']
            if row['ok'] != 'True' and row['finish'] in PROVIDER_FAILURES:
                continue
            scores[row['route']][row['page']] = float(row['nes']) * 100
    return scores, kinds


def stratum(page, kinds):
    return kinds.get(page['page'], ''), 'original' if page['source'] == 'original' else 'pdf image'


def level(page, attrs, attr):
    return max(page[a] for a in attrs) if attr == 'any' else page[attr]


def paired_loss(route_scores, tags, kinds, attrs, attr, at_least=1):
    """Mean over tagged pages of (page NES - mean NES of the stratum's pages without this tag), and the pages used.
    For 'any' the comparison pages carry no tag at all."""
    clean = defaultdict(list)
    for p in tags.values():
        if p['page'] in route_scores and not level(p, attrs, attr):
            clean[stratum(p, kinds)].append(route_scores[p['page']])
    diffs = [route_scores[p['page']] - mean(clean[stratum(p, kinds)]) for p in tags.values()
             if p['page'] in route_scores and level(p, attrs, attr) >= at_least and clean.get(stratum(p, kinds))]
    return (mean(diffs) if diffs else None), len(diffs)


def analyse(attrs, tags, scores, kinds):
    """attr (and 'any') -> pages tagged, severe, unpaired, per-route (loss, n), median over routes, routes worse."""
    out = {}
    for attr in attrs + ['any']:
        tagged = [p for p in tags.values() if level(p, attrs, attr) >= 1]
        clean_strata = {stratum(p, kinds) for p in tags.values() if not level(p, attrs, attr)}
        per_route = {r: paired_loss(s, tags, kinds, attrs, attr) for r, s in sorted(scores.items())}
        severe = [paired_loss(s, tags, kinds, attrs, attr, 2)[0] for s in scores.values()]
        losses = [v for v, _ in per_route.values() if v is not None]
        sev = [v for v in severe if v is not None]
        out[attr] = {
            'tagged': len(tagged), 'severe': sum(level(p, attrs, attr) >= 2 for p in tags.values()),
            'unpaired': sum(stratum(p, kinds) not in clean_strata for p in tagged),
            'per_route': per_route, 'median': median(losses) if losses else None,
            'severe_median': median(sev) if sev else None,
            'worse': sum(v < 0 for v in losses), 'routes': len(losses),
        }
    return out


def ladder(path, tags, attrs):
    """attr -> (tagged pages, mean drop original->half, ->quarter, untagged pages, their drops), pooled over routes."""
    by = defaultdict(dict)
    with open(path, newline='') as f:
        for row in csv.DictReader(f):
            if row['attempted'] == 'True':
                by[(row['key'], row['page'])][row['scale']] = float(row['nes'] or 0) * 100
    drops = defaultdict(lambda: {'half': [], 'quarter': []})
    for (route, page), s in by.items():
        if 'original' in s and page in tags:
            for scale in ('half', 'quarter'):
                if scale in s:
                    drops[page][scale].append(s['original'] - s[scale])
    pages = sorted(drops)
    out = {}
    for attr in attrs:
        t = [p for p in pages if tags[p][attr]]
        u = [p for p in pages if not tags[p][attr]]
        def m(ps, scale):
            xs = [x for p in ps for x in drops[p][scale]]
            return mean(xs) if xs else None
        out[attr] = (len(t), m(t, 'half'), m(t, 'quarter'), len(u), m(u, 'half'), m(u, 'quarter'))
    return pages, out


def fmt(x, signed=True):
    return '' if x is None else (f'{x:+.1f}' if signed else f'{x:.1f}')


def report(attrs, tags, kinds, res, method, ladder_res=None, agreement=None, reading=''):
    lines = ['# W46.fix-capture-tags — capture-defect tags on the 96, and every saved route\'s NES by tag', '',
             method, '', *([reading, ''] if reading else []),
             f'{len(tags)} pages tagged; {sum(not any(p[a] for a in attrs) for p in tags.values())} carry no tag. '
             f'Loss is in NES points, tagged page minus the pages of its kind and source class without that tag, on the '
             f'same route (negative = the tag costs words; "any" is against the pages with no tag). Tags co-occur, so '
             f'a tag\'s loss carries some of its companions\'. "routes worse" counts routes whose paired loss is below zero; '
             f'a tag on fewer than {MIN_TAGGED} paired pages is listed without a number.', '',
             '## Per tag, over all routes', '',
             '| tag | pages | severe | unpaired | median loss | median loss, severe only | routes worse |',
             '|---|---:|---:|---:|---:|---:|---:|']
    order = sorted(attrs, key=lambda a: (res[a]['median'] is None, res[a]['median'] or 0))
    for a in order + ['any']:
        r = res[a]
        n_paired = max((n for _, n in r['per_route'].values()), default=0)
        few = n_paired < MIN_TAGGED
        lines.append(f"| {a} | {r['tagged']} | {r['severe']} | {r['unpaired']} | "
                     f"{'too few' if few else fmt(r['median'])} | {fmt(r['severe_median']) if not few else ''} | "
                     f"{'' if few else str(r['worse']) + '/' + str(r['routes'])} |")
    if agreement:
        lines += ['', '## How far the two taggers agreed (presence, before the third look)', '',
                  '| tag | drafted and audited | blind | pages agreeing | kappa |', '|---|---:|---:|---:|---:|']
        lines += [f"| {a} | {agreement[a]['drafted']} | {agreement[a]['blind']} | {agreement[a]['agree']} | "
                  f"{agreement[a]['kappa']:.2f} |" for a in attrs]
    lines += ['', '## Per route, the tags with enough pages', '']
    shown = [a for a in order if max((n for _, n in res[a]['per_route'].values()), default=0) >= MIN_TAGGED]
    lines += ['| route | ' + ' | '.join(shown) + ' | any |', '|---|' + '---:|' * (len(shown) + 1)]
    for route in sorted(res['any']['per_route']):
        cells = [fmt(res[a]['per_route'][route][0]) for a in shown + ['any']]
        lines.append(f'| {route} | ' + ' | '.join(cells) + ' |')
    by_kind = defaultdict(lambda: defaultdict(int))
    for p in tags.values():
        k = stratum(p, kinds)
        by_kind[k]['pages'] += 1
        for a in attrs:
            by_kind[k][a] += p[a] >= 1
    lines += ['', '## Where the tags fall (pages carrying each tag, by kind and source class)', '',
              '| kind | source | pages | ' + ' | '.join(attrs) + ' |', '|---|---|' + '---:|' * (len(attrs) + 1)]
    for k in sorted(by_kind):
        lines.append(f'| {k[0]} | {k[1]} | {by_kind[k]["pages"]} | ' +
                     ' | '.join(str(by_kind[k][a]) for a in attrs) + ' |')
    if ladder_res:
        pages, lr = ladder_res
        lines += ['', f'## The resolution ladder ({len(pages)} pages), drop from the original by tag', '',
                  'Mean NES drop (original minus the smaller copy), pooled over the local panel\'s routes. Small '
                  'groups; read as a direction only.', '',
                  '| tag | tagged pages | half | quarter | untagged pages | half | quarter |',
                  '|---|---:|---:|---:|---:|---:|---:|']
        for a in attrs:
            nt, th, tq, nu, uh, uq = lr[a]
            if nt:
                lines.append(f'| {a} | {nt} | {fmt(th, False)} | {fmt(tq, False)} | {nu} | {fmt(uh, False)} | '
                             f'{fmt(uq, False)} |')
    return '\n'.join(lines) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ladder', type=Path)
    args = ap.parse_args()
    attrs, tags = load_tags()
    meta = json.loads(TAGS.read_text())
    scores, kinds = load_scores()
    res = analyse(attrs, tags, scores, kinds)
    lad = ladder(args.ladder, tags, attrs) if args.ladder else None
    OUT.write_text(report(attrs, tags, kinds, res, meta['method'], lad, meta.get('agreement'),
                          meta.get('reading', '')))
    print(OUT.read_text())


if __name__ == '__main__':
    main()
