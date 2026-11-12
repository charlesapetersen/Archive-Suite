"""W46.rotation-routes' report: every route's answers scored on the same turned pages, per set and stratum, with the
cascades built from the same answers (no new calls). Writes segbench-results/rotation-routes.md and .json; the
ArchiveOCRBench page reads the .json. Run by `rotation_routes.py report`."""
from __future__ import annotations

import collections
import json
import math
import platform
import subprocess

import rotation_routes as RR

GROUPS = ('owner96', 'L1', 'L4', 'L7', 'N1', 'N4', 'N5')
GROUP_NAMES = {'owner96': "the owner's 96", 'L1': 'L1 English handwriting', 'L4': 'L4 ledgers and tables',
               'L7': 'L7 charters', 'N1': 'N1 Arabic', 'N4': 'N4 Hebrew', 'N5': 'N5 Chinese print'}
ROUTE_NAMES = {
    'vision': 'Local Vision (RotationDetector, as shipped)',
    'llm1': 'llmSingle: Gemini 3.7 Flash, one comparative call',
    'llm1+v': 'llmSingle as the app runs it (Vision when the call abstains)',
    'llm3': 'llmMajority: Gemini 3.7 Flash, three orderings, most votes',
    'tesseract': 'Tesseract 5 OSD (--psm 0)',
    'paddle': 'PP-LCNet_x1_0_doc_ori (PaddleX)',
    'mlx-qwen3vl-8b-compare': 'Qwen3-VL 8B 4-bit, comparative prompt',
    'mlx-qwen3vl-8b-single': 'Qwen3-VL 8B 4-bit, one-image prompt',
    'mlx-qwen35-2b-compare': 'Qwen3.5 2B 4-bit, comparative prompt',
    'mlx-qwen35-2b-single': 'Qwen3.5 2B 4-bit, one-image prompt',
}
LICENCES = {
    'vision': 'Apple Vision framework (macOS, on device)',
    'tesseract': 'Apache-2.0 (Tesseract 5; osd.traineddata, tessdata)',
    'paddle': 'Apache-2.0 (PaddleX / PP-LCNet_x1_0_doc_ori weights)',
    'mlx-qwen3vl-8b': 'Apache-2.0 (Qwen3-VL-8B-Instruct; mlx-community 4-bit conversion)',
    'mlx-qwen35-2b': 'Apache-2.0 (Qwen3.5-2B; mlx-community 4-bit conversion)',
    'gemini': 'proprietary, Stanford AI API gateway (real money)',
}


VERDICT = """**Local Vision is right on 99.0% of the 96's turns and is never wrong there, but the 96 are its development
set.** RotationDetector's policy was chosen on these 384 turns (W40.fix-processor-rotation-axis, 342 → 380), and the
96 were drawn through a 20-word Vision filter, so they hold no page where Vision's text, and its rotation vote, is
weakest. By page it is 95 of 96 right at all four turns (p034 abstains at all four); zero wrong pages bounds its page
error at 3.8%, not 1.0%. The held-out owner figure (below, W46.rotation-heldout) is the one a rule cites.
__HELDOUT_VERDICT__ These figures are against the owner's own turns for the five box pages every route, Gemini
included, agrees the box stores turned (W46.rotation-setapart-sheet): four are stored turned as the routes say (two
magazine pages upside down, two clippings sideways), and the fifth, SC0122 002, is a folder whose tab label reads upright
as stored, so every route is wrong on it at all four turns (a page identified as a folder is oriented to the folder's
own text, not to a cut-off sheet inside it). Vision's other two wrong pages are wrong at one turn (a clipping's flip, a
near-blank cover's axis); it abstains on 7 pages, five of them pages the 20-word filter took out of the 96. So "never
wrong" is the development set's figure, not a population one, and Vision's abstentions gather on exactly the pages the
filter removed. The profile rules hold up held out: the free rule (Vision checked by PP-LCNet, else flag) is wrong on 2
of 119 pages (that cover at one turn, the folder) and flags 14, nine of them filter-replaced; the cloud rule is wrong on 3
of 119, the folder and the two near-blank covers on which Gemini gives one constant wrong answer, with 45 calls for 476
turns. PP-LCNet alone is weaker held out (10 wrong pages of 119, seven of them filter-replaced), and Tesseract is not a
route (57 wrong).

Its four misses on the 96 are abstentions (p034's two axes). It is also safe on L1 English handwriting and L4 ledgers (93.8% and 97.5%, abstentions only). It
gives a confident **wrong axis** on charters (36 of L7's 80 turns), abstains on much of Hebrew (34 of 80) and Chinese
(24 of 80), and is 67.7% over the six public strata.

**llmSingle is the most accurate single route.** That is the app's comparative prompt, here on Gemini 3.7 Flash
through the gateway. It is 100% on the 96 and 97.3% on the public strata as stored (two pages the set may store
turned are among its misses; the "without" figure is an upper bound chosen by its own answers, below). It costs $0.0037 and about 6 s of round trip a page. Its misses are those two
Arabic pages at every turn, two Chinese turns, one charter flip and one Hebrew axis.

**llmMajority buys nothing measurable.** On its 432 turns it is right on one turn llmSingle missed, and on none of
the 96's, at three times the price and the time. The Settings label "most accurate" has no support. No three-way
tie occurred, but the app breaks a tie by Swift's Dictionary hash order, which changes every launch.

**PP-LCNet_x1_0_doc_ori complements Vision.** It is open (Apache-2.0), about 7 MB and 0.02 s a page, and scores
99.2% on the 96 (three flips). Its errors fall where Vision's do not: it flips Hebrew (73 of 80), so it must never
be used alone on right-to-left pages. When Vision and PP-LCNet agree they are right on 640 of 650 turns, and on every
agreed turn of the 96, L1 and L4. **Tesseract's OSD is the weakest route** (62.7%, 171 flips) and is not recommended.

**The small local vision models are not a rotation route.** With the one-image prompt both Qwen models are at chance
(29% and 37%), answering "upright" for most turns. Qwen3.5 2B is at chance with the comparative prompt too (24.5%).
Qwen3-VL 8B with the comparative prompt reaches 78.1% (82.3% on the 24 of the 96 it read), at 7.4 s a page and a
6.9 GB peak, which is worse than Vision on the owner's pages. Without the app's "Image A:" labels between the
images, the 8B was at chance in the pilot as well.

**Cascades, from the same answers.** "Vision and PP-LCNet agree, else llmSingle" is 100% on the 96 and sends 7 of
its 384 turns to the model. Overall it is 97.9% at $0.0010 a page, about a quarter of llmSingle's price. On the
public strata it trails llmSingle by five turns of 480 (paired: 1 against 6), mostly charters the two local routes
agree on wrongly. "Vision; llmSingle where Vision abstains" is also 100% on the 96, but only 55% on charters,
because Vision is wrong there rather than silent.

**The rule this supports, for Phase 4.** No default is changed here.
- *On-this-Mac or free profile:* Vision checked by PP-LCNet. Where they disagree or Vision abstains, leave the page
  as it is and flag it. On the 96 (the development set) that is 0 wrong and 7 of 384 turns flagged, 2 of 96 pages;
  __HELDOUT_FREE__ on L1 and L4, 0 wrong and 10 of 160 flagged.
  The small local VLMs are no substitute. For charter, Hebrew or Chinese collections it flags most pages (L7 66 of
  80, N4 78 of 80); such a collection needs the cloud rule.
- *Cloud profile, Latin-script modern material (the owner's kind):* Vision and PP-LCNet agree, else llmSingle. It
  matches llmSingle's 100% on the 96 with 7 calls instead of 384; __HELDOUT_CLOUD__
- *Cloud profile, charters and non-Latin scripts:* llmSingle on every page (L7 98.8%, N1 88.8% as stored, N4 98.8%,
  N5 97.5%).
- *llmMajority:* retire it or relabel it, and make its tie-break deterministic (W46.rotation-majority-fix).
- *The default:* today it is llmSingle. But `LLMRotationDetector.hasRoute` is false for the gateway, so a gateway
  user's LLM modes silently run Vision, and PP-LCNet is not in the app (it needs a Core ML conversion). Whether the
  default becomes the agreement rule, and the gateway's rotation route, are filed as W46.rotation-default, behind
  Phase 4."""
CARD = """- **Truth.** Constructed, not drafted: each page is taken as upright as stored and turned by a known angle, so
  the right correction is known exactly. The owner's 96 are his frozen originals, upright since W41.ocr-panel-cloud
  (the axis test's set). The public pages are upright as their datasets publish them; no one checked that.
  __SIDEWAYS__ They stay in every figure; the table without them is an upper bound for llmSingle, whose own answers
  chose them. The held-out owner pages are upright as stored, unchecked, except ten the owner turned upright on a
  sheet (W46.rotation-setapart-sheet): __HELDOUT_TURNED__ The owner's turns are the truth for those ten
  (`rotation-heldout-owner.json`, with his rule for folder pages); the as-stored figures are kept beside them.
- **Selection.** The 96 entire, which are RotationDetector's development set: its policy was chosen on these 384
  turns (W40.fix-processor-rotation-axis), so its figure on them is not held out. __DRAW_96__ The held-out set is
  the 19 pages that filter replaced and 100 pages of the three locked segmentation boxes (527 pages, none
  byte-identical to a panel page), drawn by a salted hash of the box and file number; no route's answer chose them.
  The public pages are 20 of each of six strata of the frozen 895, drawn by a salted
  hash of the page id, never by a route's answer or by ABBYY text. The subsets are nested draws by the same hash:
  llmMajority's two further orderings 48 of the 96 and 10 a stratum, the local models 24 and 4.
- **Comparison.** Every route gets the same upright page with the same exact turns (lossless transposes of the same
  decoded image). The comparative routes see the app's own candidates: the turned page downscaled to 800 px and
  encoded at JPEG 0.8, under the app's prompt and labels. Vision gets the full-size turned page, as the app passes
  it. Gemini 3.7 Flash runs at temperature 0 with minimal reasoning. The app's direct-Gemini rotation model is
  gemini-2.5-flash-lite, which is not on the gateway, so 3.7 Flash stands in for it. The local models run greedy
  (temperature 0) with thinking off. Both OCR sets: the owner's 96 and the public strata, in the same run.
- **Noise.** n is turns: 384 on the 96, 80 a public stratum (40 and 16 on the subsets). Exact rates carry 95% Wilson
  intervals. Route pairs are compared turn by turn on the same turns (the paired table). The four turns of a page
  are not independent (a route that fails a page often fails all four turns), so a stratum's interval is narrower
  than its 20 pages justify. The held-out section therefore gives page counts with Wilson intervals (zero wrong pages
  of n bounds the page error, 3.8% at 96) and page-clustered turn intervals, and the same for the 96. Gemini at temperature 0 was run once and no rerun floor was measured, so a gap of a few
  turns between two routes is read as a tie, not a ranking.
- **Scope.** Seconds are wall time inside an unattended engine session, which runs at background QoS. CPU-bound
  steps there can run several times slower than in the app (memory note: the daemon clamp), so read the local
  seconds as ratios between local routes, not as what a user waits. A gateway call's seconds are its network round
  trip. Clean scans and photographs only: no skewed, cropped or mixed-orientation pages beyond what the sets hold
  (p034, the 96's mixed-axes page, is the one the axis test knows). The app's own Gemini, OpenAI and Anthropic
  rotation models were not measured: real money on personal keys, and 3.7 Flash stands in. What a wrong rotation
  costs downstream (an OCR reading of a sideways page) is not measured here. The held-out set ran Vision, PP-LCNet
  and Tesseract on every turn (on macOS 27.2, PaddlePaddle 3.3.1, which reproduced the main run's PP-LCNet labels and
  scores on 48 turns of the 96) and Gemini only on the cloud rule's 45 escalated turns and the stored-turned pages'
  turns (61 calls, $0.23 on the gateway); llmSingle alone, llmMajority and the local VLMs have no held-out figure.
  The locked boxes are three collections (letters, a magazine, clippings), not a draw from the whole corpus."""
BENCH_META = '216 pages × 4 turns, and 119 held-out owner pages for the local routes · Gemini through the gateway, the rest free on the Mac (W46.rotation-routes)'
BENCH_NOTE = ("Each upright page turned 0, 90, 180 and 270 degrees; a route is right when it gives the turn that "
              "makes it upright. Wrong axis = sideways, flip = upside down, abstain = no answer. The gateway's Gemini "
              "3.7 Flash runs the app's comparative which-of-four prompt (llmSingle one call, llmMajority three, on a "
              "108-page half); the local models ran on a 48-page subset. Vision is right on 99.0% of the owner's turns "
              "and never wrong there, but wrong-axis on charters; llmSingle is 100% on the 96 and 97.3% on the public "
              "strata; Vision and PP-LCNet agreeing, else llmSingle, is 100% on the 96 with 7 of 384 turns sent to "
              "the model, but the 96 are the shipped detector's development set: __HELDOUT_NOTE__ The small local "
              "models are at chance with a one-image prompt; Qwen3-VL 8B with the app's comparative prompt is 78.1%, "
              "below Vision on the owner's pages. Seconds were taken inside an unattended session "
              "(background QoS), so compare them, don't quote them. Detail: ArchiveProcessor/segbench-results/"
              "rotation-routes.md.")


def wilson(k, n, z=1.96):
    if not n:
        return (None, None)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (round(100 * (c - h), 1), round(100 * (c + h), 1))


def outcome(found, turn):
    w = RR.want(turn)
    if found is None:
        return 'abstain'
    if found == w:
        return 'exact'
    return 'axis' if found % 180 != w % 180 else 'flip'


def load():
    pages = {p['id']: p for p in RR.page_list()}
    keys = [(i, t) for i in pages for t in RR.TURNS]
    a = {}
    for name in ('vision', 'tesseract', 'paddle', 'mlx-qwen3vl-8b-compare', 'mlx-qwen3vl-8b-single',
                 'mlx-qwen35-2b-compare', 'mlx-qwen35-2b-single'):
        d = RR.done(name)
        if d:
            a[name] = d
    o = [RR.done(f'gw-order{i}') for i in range(3)]
    if o[0]:
        a['llm1'] = o[0]
        if 'vision' in a:
            a['llm1+v'] = {k: (r if r['found'] is not None else {**a['vision'][k], 'cost': r['cost']})
                           for k, r in o[0].items() if k in a['vision']}
    ties = {}
    if o[1] and o[2]:
        m = {}
        for k in o[0]:
            if k in o[1] and k in o[2]:
                votes = [x[k]['found'] for x in o if x[k]['found'] is not None]
                cost = sum(x[k]['cost'] for x in o)
                secs = sum(x[k]['seconds'] for x in o)   # the app asks the orderings in turn; wall time adds
                if not votes:
                    m[k] = {'found': None, 'cost': cost, 'seconds': secs}
                    continue
                c = collections.Counter(votes)
                top = max(c.values())
                best = [v for v in votes if c[v] == top]
                # The app takes Dictionary.max, whose pick among tied counts follows hash order (random per launch).
                # Scored here as the first ordering's answer among the tied; ties are counted and reported.
                if len(set(best)) > 1:
                    ties[k] = sorted(set(best))
                m[k] = {'found': best[0], 'cost': cost, 'seconds': secs, 'votes': votes}
        a['llm3'] = m
    return pages, keys, a, ties


def score(pages, ans, keys):
    rows = collections.Counter()
    secs, cost = [], []
    for k in keys:
        r = ans.get(k)
        if r is None:
            continue
        rows[outcome(r['found'], k[1])] += 1
        rows['n'] += 1
        secs.append(r.get('seconds') or 0)
        cost.append(r.get('cost') or 0)
    n = rows['n']
    lo, hi = wilson(rows['exact'], n)
    return {'n': n, 'exact': rows['exact'], 'axis': rows['axis'], 'flip': rows['flip'], 'abstain': rows['abstain'],
            'pct': round(100 * rows['exact'] / n, 1) if n else None, 'lo': lo, 'hi': hi,
            'seconds': round(sum(secs) / n, 3) if n else None,
            'usd_per_page': round(sum(cost) / n, 5) if n else None}


def cascades(a):
    """Routes built from answers already in hand: the first route answers, later ones only where it abstains (or,
    for the agreement rule, where the two first routes disagree). Cost and seconds count only the calls made."""
    out = {}

    def chain(name, steps, agree=None):
        if not all(s in a for s in steps) or (agree and not all(s in a for s in agree)):
            return
        m = {}
        for k in a[steps[0]]:
            if not all(k in a[s] for s in steps) or (agree and not all(k in a[s] for s in agree)):
                continue
            cost = secs = 0.0
            found = None
            if agree:
                x, y = (a[s][k] for s in agree)
                secs += (x.get('seconds') or 0) + (y.get('seconds') or 0)
                if x['found'] is not None and x['found'] == y['found']:
                    m[k] = {'found': x['found'], 'cost': 0.0, 'seconds': secs, 'escalated': False}
                    continue
            esc = False
            for i, s in enumerate(steps):
                r = a[s][k]
                cost += r.get('cost') or 0
                secs += r.get('seconds') or 0
                if i:
                    esc = True
                if r['found'] is not None:
                    found = r['found']
                    break
            m[k] = {'found': found, 'cost': cost, 'seconds': secs, 'escalated': esc or bool(agree)}
        out[name] = m

    chain('vision>llm1', ['vision', 'llm1'])
    chain('vision>qwen3vl-compare', ['vision', 'mlx-qwen3vl-8b-compare'])
    chain('vision>paddle', ['vision', 'paddle'])
    chain('vision=paddle>llm1', ['llm1', 'vision'], agree=['vision', 'paddle'])
    chain('vision=paddle>llm3', ['llm3', 'vision'], agree=['vision', 'paddle'])
    chain('vision=qwen3vl>llm1', ['llm1', 'vision'], agree=['vision', 'mlx-qwen3vl-8b-compare'])
    chain('vision=paddle>qwen3vl', ['mlx-qwen3vl-8b-compare', 'vision'], agree=['vision', 'paddle'])
    if 'vision' in a and 'paddle' in a:   # free: where the two disagree or Vision abstains, no turn (flag for review)
        out['vision=paddle>flag'] = {k: {'found': v['found'] if v['found'] == a['paddle'][k]['found'] else None,
                                         'cost': 0.0, 'seconds': v['seconds'] + a['paddle'][k]['seconds'],
                                         'escalated': v['found'] is None or v['found'] != a['paddle'][k]['found']}
                                     for k, v in a['vision'].items() if k in a['paddle']}
    return out


CASCADE_NAMES = {
    'vision>llm1': 'Vision; llmSingle where Vision abstains',
    'vision>qwen3vl-compare': 'Vision; Qwen3-VL 8B comparative where Vision abstains ($0)',
    'vision>paddle': 'Vision; PP-LCNet where Vision abstains ($0)',
    'vision=paddle>llm1': 'Vision and PP-LCNet agree, else llmSingle (Vision if it abstains)',
    'vision=paddle>llm3': 'Vision and PP-LCNet agree, else llmMajority (Vision if it abstains)',
    'vision=qwen3vl>llm1': 'Vision and Qwen3-VL comparative agree, else llmSingle (Vision if it abstains)',
    'vision=paddle>qwen3vl': 'Vision and PP-LCNet agree, else Qwen3-VL 8B comparative ($0)',
    'vision=paddle>flag': 'Vision and PP-LCNet agree, else leave the page and flag it ($0)',
}


def paired(a, x, y, keys):
    """Exact-or-not on the turns both routes answered or abstained on: x right & y wrong, x wrong & y right."""
    b = c = 0
    for k in keys:
        if k in a[x] and k in a[y]:
            ex = a[x][k]['found'] == RR.want(k[1])
            ey = a[y][k]['found'] == RR.want(k[1])
            b += ex and not ey
            c += ey and not ex
    return b, c


def offset(ans, pid):
    """The one non-zero offset a route gives at all four turns of a page (each answer = right answer + offset), else None."""
    got = [ans.get((pid, t)) for t in RR.TURNS]
    if any(g is None or g['found'] is None for g in got):
        return None
    ds = {(g['found'] - RR.want(t)) % 360 for g, t in zip(got, RR.TURNS)}
    return ds.pop() if len(ds) == 1 and 0 not in ds else None


def stored_sideways(pages, a):
    """Public pages the dataset may store turned: Gemini (llmSingle) and at least one local route of another family
    each give the same non-zero offset at all four turns. A sensitivity only: the pages stay in every headline figure,
    since dropping them is a choice made by tested routes."""
    out = {}
    for pid, p in pages.items():
        if p['set'] != 'public' or 'llm1' not in a:
            continue
        g = offset(a['llm1'], pid)
        if g is None:
            continue
        agree = [r for r in ('vision', 'paddle', 'tesseract') if r in a and offset(a[r], pid) == g]
        if agree:
            out[pid] = {'offset': g, 'routes': ['llm1'] + agree}
    return out


def report():
    pages, keys, a, ties = load()
    sideways = stored_sideways(pages, a)
    routes = dict(a)
    casc = cascades(a)
    routes.update(casc)
    names = {**ROUTE_NAMES, **CASCADE_NAMES}
    by_group = {g: [k for k in keys if pages[k[0]]['stratum'] == g] for g in GROUPS}
    public = [k for k in keys if pages[k[0]]['set'] == 'public']
    table = {}
    for r, ans in routes.items():
        table[r] = {'all': score(pages, ans, keys), 'public': score(pages, ans, public),
                    **{g: score(pages, ans, by_group[g]) for g in GROUPS}}
        if r in casc:
            table[r]['escalated'] = sum(bool(v.get('escalated')) for v in ans.values())
            for g, ks in (('owner96', by_group['owner96']), ('public', public)):
                got = [ans[k] for k in ks if k in ans]
                table[r][f'escalated_{g}'] = [sum(bool(v.get('escalated')) for v in got), len(got)]
    peaks = {}
    for r in a:
        if r.startswith('mlx-'):
            peaks[r] = max(v.get('peak_gb') or 0 for v in a[r].values())
    gw = RR.gw()
    led = [x for x in gw.ledger()]
    spend = gw.billed(led)
    misses = collections.defaultdict(list)
    for r in ('vision', 'llm1', 'llm3', 'paddle', 'tesseract'):
        if r in a:
            for k, v in sorted(a[r].items()):
                o = outcome(v['found'], k[1])
                if o != 'exact':
                    misses[r].append(f"{k[0]}@{k[1]}:{o}")
    pairs = {}
    for x, y in (('llm1', 'vision'), ('llm3', 'llm1'), ('paddle', 'vision'), ('mlx-qwen3vl-8b-compare', 'vision'),
                 ('vision=paddle>llm1', 'vision'), ('vision=paddle>llm1', 'llm1')):
        if x in routes and y in routes:
            for g, ks in (('owner96', by_group['owner96']), ('public', public)):
                pairs[f'{x} vs {y} · {g}'] = paired(routes, x, y, ks)
    kept = [k for k in public if k[0] not in sideways]
    for r in table:
        table[r]['public_upright'] = score(pages, routes[r], kept)
    data = {'stored_sideways': sideways, 'item': 'W46.rotation-routes', 'pages': {g: len(by_group[g]) // 4 for g in GROUPS},
            'turns_per_page': 4, 'routes': {r: {'name': names.get(r, r), **table[r]} for r in table},
            'majority_ties': {f'{k[0]}@{k[1]}': v for k, v in sorted(ties.items())},
            'mlx_peak_gb': peaks, 'gateway_spend': spend, 'licences': LICENCES,
            'tesseract': RR.tesseract_version(), 'machine': f"{platform.machine()} {platform.mac_ver()[0]}",
            'misses': {r: v for r, v in misses.items()}, 'paired': {k: list(v) for k, v in pairs.items()}}
    data['heldout'] = heldout_data(pages, a, casc)
    if data['heldout']:
        for r, v in data['heldout']['routes'].items():
            data['routes'][r].update(v['bench'])
    data['bench_meta'] = BENCH_META
    data['bench_note'] = fill(BENCH_NOTE, data)
    data['item'] = 'W46.rotation-routes, W46.rotation-heldout'
    (RR.RESULTS / 'rotation-routes.json').write_text(json.dumps(data, indent=1) + '\n')
    (RR.RESULTS / 'rotation-routes.md').write_text(md(data, fill(VERDICT, data), fill(CARD, data)))
    print(json.dumps({r: (table[r]['all'], table[r]['owner96']['pct'], table[r]['public']['pct']) for r in table}, indent=0))


# ---------------------------------------------------------------------------------------------- held out

HELDOUT_GROUPS = ('replaced', 'Sasha', 'IllustratedReview', 'SC0122')
HELDOUT_NAMES = {'replaced': "the 19 pages the 96's draw replaced (Vision read under 20 words)",
                 'Sasha': 'Young, Sasha (handwritten letters)', 'IllustratedReview': 'Stanford Illustrated Review (magazine)',
                 'SC0122': 'SC0122 News Service (clippings)', 'boxes': 'the 100 locked-box pages',
                 'heldout': 'all 119 held-out pages'}
HELDOUT_ROUTES = ('vision', 'paddle', 'tesseract', 'vision>paddle', 'vision=paddle>flag', 'vision=paddle>llm1')
LOCAL = ('vision', 'paddle', 'tesseract')


def page_figures(ans, pids):
    """By page: right at all four turns; wrong (an axis or a flip) at any turn; flagged (an abstention, or an escalated
    turn of a rule) at any turn. Zero wrong pages of n bounds the page error rate by Wilson's upper end."""
    n = right = wrong = flagged = 0
    for pid in pids:
        got = [ans.get((pid, t)) for t in RR.TURNS]
        if any(g is None for g in got):
            continue
        o = [outcome(g['found'], t) for g, t in zip(got, RR.TURNS)]
        n += 1
        right += all(x == 'exact' for x in o)
        wrong += any(x in ('axis', 'flip') for x in o)
        flagged += any(x == 'abstain' or g.get('escalated') for x, g in zip(o, got))
    return {'n': n, 'right': right, 'wrong': wrong, 'flagged': flagged, 'right_ci': wilson(right, n),
            'wrong_ci': wilson(wrong, n), 'flagged_ci': wilson(flagged, n)}


def clustered(ans, pids, what, reps=2000, seed=46):
    """A turn rate with a page-clustered 95% interval: the pages resampled with replacement, each bringing its four
    turns (a route that fails a page tends to fail all four). Degenerate at a zero count; the page Wilson bound is the
    one to read there."""
    import random
    per = []
    for pid in pids:
        got = [ans.get((pid, t)) for t in RR.TURNS]
        if any(g is None for g in got):
            continue
        per.append(sum(what(g, t) for g, t in zip(got, RR.TURNS)))
    if not per:
        return None
    n = 4 * len(per)
    rng = random.Random(seed)
    boot = sorted(sum(rng.choice(per) for _ in per) / n for _ in range(reps))
    return {'k': sum(per), 'n': n, 'pct': round(100 * sum(per) / n, 1),
            'lo': round(100 * boot[int(0.025 * reps)], 1), 'hi': round(100 * boot[int(0.975 * reps) - 1], 1)}


def turn_figures(ans, pids):
    exact = lambda g, t: g['found'] == RR.want(t)
    wrong = lambda g, t: outcome(g['found'], t) in ('axis', 'flip')
    flag = lambda g, t: g['found'] is None or bool(g.get('escalated'))
    return {'exact': clustered(ans, pids, exact), 'wrong': clustered(ans, pids, wrong),
            'flagged': clustered(ans, pids, flag)}


def load_heldout():
    """The held-out answers (rotation_routes.py --set heldout) and the rules built from them. The cloud rule asks
    llmSingle only where Vision and PP-LCNet disagree or Vision abstains (gateway-escalations); its answer, else
    Vision's, is the rule's."""
    RR.use_set('heldout')
    try:
        pages = {p['id']: p for p in RR.page_list()}
        a = {r: RR.done(r) for r in LOCAL if RR.done(r)}
        llm = RR.done('gw-order0')
        spend = RR.gw().billed(RR.gw().ledger()) if llm else None
    finally:
        RR.use_set('main')
    a['_llm'] = llm
    if 'vision' in a and 'paddle' in a:
        c = cascades(a)
        a['vision>paddle'] = c['vision>paddle']
        a['vision=paddle>flag'] = c['vision=paddle>flag']
        esc = {k for k, v in a['vision=paddle>flag'].items() if v['escalated']}
        if llm and all(k in llm for k in esc):
            m = {}
            for k, v in a['vision'].items():
                if k not in a['paddle']:
                    continue
                if k in esc:
                    r = llm[k]
                    m[k] = {'found': r['found'] if r['found'] is not None else v['found'], 'cost': r['cost'],
                            'seconds': v['seconds'] + a['paddle'][k]['seconds'] + r['seconds'], 'escalated': True}
                else:
                    m[k] = {'found': v['found'], 'cost': 0.0, 'seconds': v['seconds'] + a['paddle'][k]['seconds'],
                            'escalated': False}
            a['vision=paddle>llm1'] = m
    return pages, a, spend


def stored_turned(pages, a, llm=None):
    """Held-out pages two routes of different families agree are stored turned: the same non-zero offset at all four
    turns (Gemini counts where it was asked every turn of the page). Reported apart, never dropped: they stay in every figure, and the table without them is labelled as
    chosen by the routes it scores."""
    out = {}
    for pid in pages:
        offs = {r: offset(a[r], pid) for r in LOCAL if r in a}
        if llm and all((pid, t) in llm for t in RR.TURNS):   # Gemini, where it was asked every turn
            offs['llm1'] = offset(llm, pid)
        got = collections.Counter(v for v in offs.values() if v is not None)
        for off, c in got.items():
            if c >= 2:
                out[pid] = {'offset': off, 'routes': sorted(r for r, v in offs.items() if v == off)}
    return out


OWNER_HELDOUT = RR.RESULTS / 'rotation-heldout-owner.json'   # W46.rotation-setapart-sheet: the owner's turns


def owner_offsets():
    """The stored turn of each held-out page the owner checked (W46.rotation-setapart-sheet), else {}."""
    if not OWNER_HELDOUT.exists():
        return {}
    return {p: o % 360 for p, o in json.loads(OWNER_HELDOUT.read_text())['offsets'].items()}


def rebase(ans, owner):
    """A route's answers against the owner's truth: on a page stored turned by o, the right answer at turn t is
    want(t) + o, so subtracting o from each answer leaves outcome() and every figure the same in form."""
    return {k: ({**v, 'found': (v['found'] - owner[k[0]]) % 360} if owner.get(k[0]) and v['found'] is not None else v)
            for k, v in ans.items()}


def heldout_data(main_pages, main_a, main_casc):
    pages, a, spend = load_heldout()
    llm = a.pop('_llm')
    if not a:
        return None
    groups = {g: [p for p in pages if pages[p]['stratum'] == g] for g in HELDOUT_GROUPS}
    groups['boxes'] = [p for p in pages if pages[p]['set'] == 'boxes']
    groups['heldout'] = list(pages)
    turned = stored_turned(pages, a, llm)
    owner = owner_offsets()
    for pid, v in turned.items():   # Gemini, another family, on every turn of these pages (gateway-escalations)
        if all((pid, t) in llm for t in RR.TURNS):
            v['gemini'] = offset(llm, pid) or 0
        if pid in owner:
            v['owner'] = owner[pid]
    routes = {}
    for r in HELDOUT_ROUTES:
        if r not in a:
            continue
        t = rebase(a[r], owner)      # the figures are against the owner's truth; as stored is kept beside them
        routes[r] = {g: {'pages': page_figures(t, ps), 'turns': turn_figures(t, ps)} for g, ps in groups.items()}
        routes[r]['as_stored'] = {'pages': page_figures(a[r], list(pages)), 'turns': turn_figures(a[r], list(pages))}
        routes[r]['bench'] = {g: score(pages, t, [(p, x) for p in ps for x in RR.TURNS])
                              for g, ps in (('heldout', list(pages)), ('heldout_boxes', groups['boxes']),
                                            ('heldout_replaced', groups['replaced']))}
        routes[r]['misses'] = [f"{k[0]}@{k[1]}:{outcome(v['found'], k[1])}" for k, v in sorted(t.items())
                               if outcome(v['found'], k[1]) in ('axis', 'flip')]
    own = [p for p in main_pages if main_pages[p]['set'] == 'owner96']
    main_routes = {**main_a, **main_casc}
    owner96 = {r: {'pages': page_figures(main_routes[r], own), 'turns': turn_figures(main_routes[r], own)}
               for r in ('vision', 'paddle', 'tesseract', 'llm1', 'vision>paddle', 'vision=paddle>flag', 'vision=paddle>llm1')
               if r in main_routes}
    return {'pages': {g: len(ps) for g, ps in groups.items()}, 'stored_turned': turned, 'routes': routes,
            'owner96': owner96, 'escalations': len(RR_escalated(a)), 'gateway_spend': spend,
            'owner_checked': len(owner),
            'owner_rule': json.loads(OWNER_HELDOUT.read_text())['rule'] if OWNER_HELDOUT.exists() else None}


def RR_escalated(a):
    return [k for k, v in a.get('vision=paddle>flag', {}).items() if v['escalated']]


def pct(k, n):
    return f"{100 * k / n:.1f}%" if n else '—'


def page_cell(f):
    if not f or not f['n']:
        return '—'
    return (f"{f['right']}/{f['n']} right, {f['wrong']} wrong (≤{f['wrong_ci'][1]}%), "
            f"{f['flagged']} flagged")


def turn_cell(t):
    e = t['exact']
    if not e:
        return '—'
    return f"{e['k']}/{e['n']} ({e['pct']:.1f}%, {e['lo']}–{e['hi']}); {t['wrong']['k']} wrong, {t['flagged']['k']} flagged"


def heldout_md(h, names):
    if not h:
        return []
    R = h['routes']
    out = ['', '## Held out: owner pages the detector was not tuned on (W46.rotation-heldout)', '',
           "RotationDetector's policy was chosen on the 96's 384 turns (W40.fix-processor-rotation-axis: \"not held-out "
           "population accuracy\"), and the 96 were drawn through a 20-word Vision filter. These pages are neither: the "
           f"{h['pages']['replaced']} pages that filter replaced (covers, photographs, blanks and pages Vision barely read), "
           f"and {h['pages']['boxes']} pages of the three locked segmentation boxes drawn by a salted hash "
           f"({h['pages']['Sasha']} Sasha letters, {h['pages']['IllustratedReview']} Illustrated Review, "
           f"{h['pages']['SC0122']} SC0122 clippings). Same turns, same routes, same scoring as above. A page is right "
           "when all four turns are; wrong when any turn gets a confident wrong answer; flagged when any turn is an "
           "abstention or (for a rule) escalated: for the free rule a flagged page is left for review, for the cloud "
           "rule it is sent to Gemini. Page intervals are Wilson's (the bracket after \"wrong\" is the upper "
           "end); turn intervals are page-clustered (pages resampled with their four turns).", '',
           '| Route | Set | Pages | Turns |', '|---|---|---|---|']
    for r in R:
        for g in ('heldout', 'replaced', 'boxes', 'Sasha', 'IllustratedReview', 'SC0122'):
            out.append(f"| {names[r]} | {HELDOUT_NAMES[g]} | {page_cell(R[r][g]['pages'])} | {turn_cell(R[r][g]['turns'])} |")
    st = h['stored_turned']
    out += ['', f"**Pages two routes agree are stored turned** ({len(st)}): "
            + (', '.join(f"{k} (+{v['offset']}°: {', '.join(x for x in v['routes'] if x != 'llm1')}; Gemini "
                         + ('not asked' if 'gemini' not in v else 'agrees' if v['gemini'] == v['offset'] else
                            'gives no constant correction' if v['gemini'] == 0 else f"+{v['gemini']}°") + ')'
                         for k, v in st.items()) or 'none')
            + ". Gemini 3.7 Flash (llmSingle, through the gateway) was asked every turn of them as a third family. "
            + (f"The owner turned them upright on a sheet (W46.rotation-setapart-sheet, 2026-11-11, with "
               f"{h['owner_checked'] - len(st)} controls every local route reads upright; no control was turned): "
               + ', '.join(f"{k} " + ('agrees' if v['owner'] == v['offset'] else
                                      'upright as stored' if v['owner'] == 0 else f"+{v['owner']}°")
                           for k, v in st.items() if 'owner' in v)
               + f". {h['owner_rule']} The figures above score every held-out page against the owner's turn; "
               "the rest are upright as stored, unchecked. As stored, before his reading:"
               if h.get('owner_checked') else
               "Nobody looked at them. They stay in every figure above, scored as stored."),
            '', '| Route | Pages, as stored | Turns, as stored |', '|---|---|---|']
    for r in R:
        out.append(f"| {names[r]} | {page_cell(R[r]['as_stored']['pages'])} | {turn_cell(R[r]['as_stored']['turns'])} |")
    out += ['', "**The 96 by page, beside the turn figures** (the development set; the same page and clustered-turn "
            "figures as the held-out table):", '', '| Route | Pages | Turns |', '|---|---|---|']
    for r, v in h['owner96'].items():
        out.append(f"| {names[r]} | {page_cell(v['pages'])} | {turn_cell(v['turns'])} |")
    out += ['', '**Held-out wrong turns:** ' + '; '.join(f"{names[r]} ({len(R[r]['misses'])}): "
                                                         + (', '.join(R[r]['misses'][:30]) + (' …' if len(R[r]['misses']) > 30 else '') or 'none')
                                                         for r in R) + '.']
    sp = h['gateway_spend']
    if sp:
        out.append(f"- Held-out gateway arm: {sp['calls']} llmSingle calls on the {h['escalations']} escalated turns, "
                   f"${sp['charged']:.2f} charged (the gateway's own figure ${sp['gateway'] or 0:.2f}); ledger "
                   "`rotation-routes/heldout/calls.jsonl`.")
    return out


def fill(text, data):
    """The generated sentences the static Verdict, card and bench note carry: held-out figures, the stored-turned
    pages with the routes behind each, and the 96's draw rule (ocr_card.DRAW_96)."""
    import ocr_card
    h = data.get('heldout')
    sw = data['stored_sideways']
    sub = {'__DRAW_96__': ocr_card.DRAW_96,
           '__SIDEWAYS__': (f"{len(sw)} public pages get the same non-zero correction at all four turns from Gemini and "
                            "from a local route of another family, so the set probably stores them turned: "
                            + '; '.join(f"{k} (+{v['offset']}°, from {', '.join(ROUTE_NAMES[r].split(':')[0].split(' (')[0] for r in v['routes'])})"
                                        for k, v in sw.items()) + '.') if sw else 'No public page looks stored turned.'}
    if h:
        R = h['routes']
        n = h['pages']['heldout']
        v, vt = R['vision']['heldout']['pages'], R['vision']['heldout']['turns']
        fr, ft = R['vision=paddle>flag']['heldout']['pages'], R['vision=paddle>flag']['heldout']['turns']
        st = h['stored_turned']
        sub['__HELDOUT_VERDICT__'] = (
            f"**Held out** ({n} owner pages: the {h['pages']['replaced']} the filter replaced and {h['pages']['boxes']} "
            f"locked-box pages), Vision is right at all four turns on {v['right']} of {n} pages and wrong at some turn on "
            f"{v['wrong']} (Wilson upper end {v['wrong_ci'][1]}%); by turn {vt['exact']['pct']:.1f}% exact "
            f"({vt['exact']['lo']}–{vt['exact']['hi']}, page-clustered), {vt['wrong']['k']} of {vt['wrong']['n']} wrong, "
            f"{vt['flagged']['k']} abstentions.")
        sub['__HELDOUT_FREE__'] = (
            f"on the {n} held-out owner pages, {fr['wrong']} wrong pages (Wilson upper end {fr['wrong_ci'][1]}%; "
            f"{ft['wrong']['k']} of {ft['wrong']['n']} turns) and {fr['flagged']} of {n} pages flagged "
            f"({ft['flagged']['k']} turns);")
        if 'vision=paddle>llm1' in R:
            cp, ct = R['vision=paddle>llm1']['heldout']['pages'], R['vision=paddle>llm1']['heldout']['turns']
            sub['__HELDOUT_CLOUD__'] = (
                f"on the {n} held-out owner pages it is right on {ct['exact']['k']} of {ct['exact']['n']} turns "
                f"({cp['right']} of {n} pages at all four, {cp['wrong']} wrong) with {h['escalations']} calls.")
        else:
            sub['__HELDOUT_CLOUD__'] = 'its held-out escalations were not asked (no figure).'
        both = sum(v.get('gemini') == v['offset'] for v in st.values())
        mine = sum(v.get('owner') == v['offset'] for v in st.values() if 'owner' in v)
        sub['__HELDOUT_TURNED__'] = (f"{len(st)} of them two routes agree are stored turned (Gemini gives the same "
                                     f"correction on {both} of the {len(st)}"
                                     + (f"; the owner on {mine}" if any('owner' in v for v in st.values()) else '')
                                     + "), and five controls every local route reads upright (none turned)."
                                     if st else "no two routes agree that any is stored turned.")
        sub['__HELDOUT_NOTE__'] = (f"on {n} held-out owner pages Vision is right at all four turns on {v['right']} and "
                                   f"wrong on {v['wrong']}, and Vision with PP-LCNet flagging is wrong on {fr['wrong']} "
                                   f"and flags {fr['flagged']}.")
    else:
        for k in ('__HELDOUT_VERDICT__', '__HELDOUT_FREE__', '__HELDOUT_CLOUD__', '__HELDOUT_TURNED__', '__HELDOUT_NOTE__'):
            sub[k] = ''
    for k, x in sub.items():
        text = text.replace(k, x)
    return text


def cell(s):
    if not s or not s['n']:
        return '—'
    return f"{s['exact']}/{s['n']} ({s['pct']:.1f}%)"


def md(data, verdict, card):
    R = data['routes']
    order = [r for r in ('vision', 'llm1', 'llm1+v', 'llm3', 'paddle', 'tesseract', 'mlx-qwen3vl-8b-compare',
                         'mlx-qwen3vl-8b-single', 'mlx-qwen35-2b-compare', 'mlx-qwen35-2b-single') if r in R]
    casc = [r for r in CASCADE_NAMES if r in R]
    out = ['# Which rotation route to recommend (W46.rotation-routes)', '',
           'Generated by `scripts/segbench/rotation_routes.py report` from the saved answers. Every route answers the '
           'same turns: each upright page turned 0, 90, 180 and 270 degrees clockwise; a route is right when it gives '
           'the clockwise correction that makes the page upright. **Wrong axis** = off by 90 (sideways left on the '
           'page), **flip** = off by 180 (upside down), **abstain** = no answer (the app then leaves the page as it is, '
           'or, for an LLM mode, falls back to Vision).', '', '## Verdict', '', verdict, '',
           '## Every route, all turns', '',
           '| Route | Turns | Exact (95% interval) | Wrong axis | Flip | Abstain | Seconds a page | $ a page |',
           '|---|---|---|---|---|---|---|---|']
    for r in order + casc:
        s = R[r]['all']
        out.append(f"| {R[r]['name']} | {s['n']} | {s['pct']:.1f}% ({s['lo']}–{s['hi']}) | {s['axis']} | {s['flip']} | "
                   f"{s['abstain']} | {s['seconds']:.2f} | {s['usd_per_page']:.4f} |")
    out += ['', 'Seconds are wall time a turned page on this Mac (' + data['machine'] + '); a gateway call\'s seconds '
            'are its round trip, and llmMajority\'s add its three calls as the app asks them in turn. The local models '
            'and llmMajority ran on subsets (Scope, below), so their "all turns" row is their own subset.', '',
            '## By stratum', '', '| Route | ' + ' | '.join(GROUP_NAMES[g] for g in GROUPS) + ' |',
            '|---|' + '---|' * len(GROUPS)]
    for r in order + casc:
        out.append(f"| {R[r]['name']} | " + ' | '.join(cell(R[r][g]) for g in GROUPS) + ' |')
    out += ['', '## Errors by stratum: wrong axis / flip / abstain', '', '| Route | ' + ' | '.join(GROUPS) + ' |',
            '|---|' + '---|' * len(GROUPS)]
    for r in order:
        out.append(f"| {R[r]['name']} | " + ' | '.join(
            (f"{R[r][g]['axis']}/{R[r][g]['flip']}/{R[r][g]['abstain']}" if R[r][g]['n'] else '—') for g in GROUPS) + ' |')
    sw = data['stored_sideways']
    out += ['', '## Pages the public set may store turned', '',
            f"{len(sw)} public pages get the same non-zero correction at all four turns from Gemini and from at least one "
            "local route of another family, so the dataset's own orientation of them is probably not upright: "
            + (', '.join(f"{k} (+{v['offset']}°: {', '.join(v['routes'])})" for k, v in sw.items()) or 'none') + '. '
            'They stay in every figure above. Without them, on the public strata (an upper bound for llmSingle, whose '
            'own constant answers chose these pages, so its "without" figure is not a measurement of it):', '',
            '| Route | Public, as stored | Public, without these pages |', '|---|---|---|']
    for r in order + casc:
        out.append(f"| {R[r]['name']} | {cell(R[r]['public'])} | {cell(R[r]['public_upright'])} |")
    out += ['', '## Cascades, scored from the same answers', '',
            'Escalated = turns the first route did not settle (an abstention, or the two first routes disagreeing). '
            'For the flag rule an escalated turn is left as it is and flagged, scored as an abstention.', '',
            '| Cascade | Turns | Exact | Escalated: the 96 | Escalated: public | $ a page |', '|---|---|---|---|---|---|']
    for r in casc:
        s = R[r]['all']
        e = lambda g: f"{R[r][g][0]}/{R[r][g][1]}"
        out.append(f"| {R[r]['name']} | {s['n']} | {s['pct']:.1f}% ({s['lo']}–{s['hi']}) | {e('escalated_owner96')} | "
                   f"{e('escalated_public')} | {s['usd_per_page']:.4f} |")
    out += ['', '## Paired: turns where one route is right and the other wrong', '', '| Pair · set | first right only | second right only |',
            '|---|---|---|']
    for k, (b, c) in data['paired'].items():
        x, rest = k.split(' vs ')
        y, g = rest.split(' · ')
        out.append(f"| {R[x]['name']} vs {R[y]['name']} · {g} | {b} | {c} |")
    out += ['', '## The misses', '']
    for r, v in data['misses'].items():
        out.append(f"- **{R[r]['name']}** ({len(v)}): " + (', '.join(v[:60]) + (' …' if len(v) > 60 else '') if v else 'none'))
    if data['majority_ties']:
        out.append(f"- **llmMajority ties** ({len(data['majority_ties'])}): three different answers, scored as the first "
                   "ordering's; the app's pick among tied counts follows Swift's Dictionary hash order, which changes "
                   "each launch: " + ', '.join(f'{k} {v}' for k, v in data['majority_ties'].items()))
    sp = data['gateway_spend']
    out += ['', '## Money, time and memory', '',
            f"- Gateway: {sp['calls']} calls, ${sp['charged']:.2f} charged against the cap (estimate ${sp['estimate']:.2f}; "
            f"the gateway's own figure ${sp['gateway'] or 0:.2f} on {sp['gateway_calls']} calls). The ledger is "
            "`rotation-routes/calls.jsonl` in the bench cache.",
            '- Local models\' peak memory (mlx, GB): ' + ', '.join(f"{R[r]['name']} {v}" for r, v in data['mlx_peak_gb'].items()) + '.',
            '- Licences: ' + '; '.join(f'{k}: {v}' for k, v in data['licences'].items()) + '.', '',
            ]
    out += heldout_md(data.get('heldout'), {r: R[r]['name'] for r in R})
    out += ['', '## Measurement card', '', card, '']
    return '\n'.join(out)
