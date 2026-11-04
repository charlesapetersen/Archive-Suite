#!/usr/local/bin/python3
"""W46.capture-ladder-paid. Gemini 3.7 Flash through the Stanford AI API gateway on W46.capture-ladder's images.

  V=/usr/local/bin/python3                    # needs requests
  $PACK_V capture_ladder_gateway.py pack      # the 480 ladder images this script needs, where missing (private venv)
  $V capture_ladder_gateway.py probe          # one reading and one verdict, to check the requests and the ledger
  $V capture_ladder_gateway.py run            # the readings, then the verdicts
  $V capture_ladder_gateway.py spent
  $ENH_V capture_ladder.py report             # then adds Gemini and its verdicts to capture-ladder.md / .json

Two arms, both on images capture_ladder.py make regenerates byte-identical to the Sherlock manifest (checked here
against its sha256 before any upload):

  reading   PAGES (48 of the 96) at the worst setting of each of the eight defects (the four Augraphy defaults,
            motion 31 px, defocus sigma 5, tilt 20 degrees, JPEG 60), plus motion 17 px and defocus sigma 3, the two
            rungs where the three readers part (Vision -38 and -15, the open readers -8 to -12 and -2 to -3). The
            request is gateway_gemini's (the cloud panel's prompt, temperature 0, low reasoning, 8,192 tokens). The
            plain image is not read again: it is byte for byte the image W46.fix-ocr-scorers-paid read
            (gateway-gemini/panel/<page>-original.json), checked by hash.
  verdict   Gemini's own judgement of the capture, VERDICT_PROMPT, on every image the reading arm covers and the
            plain image of the same 48 (11 x 48 = 528): a quality score 1-5, retake yes/no and a defect list from a
            fixed vocabulary. Scored against the applied defect (the tag) and against each reader's loss on that
            image. On these 48 pages Gemini's loss is known as well as the three readers'.

PAGES are chosen without any reader's result: the 96 ordered by source, kind and a seeded key, every other one taken,
so each source and kind keeps about half its pages. Money: this item's ledger is CACHE/calls.jsonl, CAP its whole
spend, counted at the 3.8 list price gateway_gemini takes as a ceiling (the gateway's own figure counts when larger);
every call checks the cap first. Images and replies stay in CACHE (the owner's material); committed results hold
page ids and numbers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

import gateway_gemini as G  # noqa: E402

ROUTE = G.LABEL
CACHE = G.REHEARSAL / 'capture-ladder-gateway'
# The item's whole spend, under the $7 rule: filed at about $2.00; the two middle blur rungs and the verdicts on
# all 528 were added, and the probe put the whole at about $3 (a reading cut at 8,192 tokens costs about $0.03).
CAP = 4.50
SET = 'capture-ladder'
WORST = ('aug-ShadowCast', 'aug-LightingGradient', 'aug-ReflectedLight', 'aug-LowLightNoise', 'motion-31',
         'defocus-5', 'tilt-20', 'jpeg-60')
MIDDLE = ('motion-17', 'defocus-3')
VARIANTS = WORST + MIDDLE
VERDICT_DEFECTS = ('motion_blur', 'out_of_focus', 'glare', 'shadow', 'uneven_lighting', 'dark_or_noisy', 'tilted',
                   'compression_artifacts', 'cut_off')
# The defect each ladder variant applies, in the verdict's vocabulary; 'blur' accepts either blur word.
TAG = {'aug-ShadowCast': 'shadow', 'aug-LightingGradient': 'uneven_lighting', 'aug-ReflectedLight': 'glare',
       'aug-LowLightNoise': 'dark_or_noisy', 'motion-31': 'motion_blur', 'motion-17': 'motion_blur',
       'defocus-5': 'out_of_focus', 'defocus-3': 'out_of_focus', 'tilt-20': 'tilted', 'jpeg-60': 'compression_artifacts'}
BLUR = {'motion_blur', 'out_of_focus'}
VERDICT_PROMPT = (
    'This is a phone photograph of one page from an archive, taken so that the page can be transcribed by OCR. '
    'Judge only the photograph\'s capture quality, not the document\'s own condition: faded ink, stains, '
    'creases, handwriting or a carbon copy belong to the document, not the capture.\n\n'
    'Reply with one JSON object and nothing else:\n'
    '{"quality": an integer 1-5 (5: every word as readable as on a flatbed scan; 3: most words readable with '
    'effort; 1: most words cannot be read), '
    '"retake": true if a second photograph would let noticeably more words be read, else false, '
    '"defects": a list of zero or more of ' + json.dumps(list(VERDICT_DEFECTS)) + ', '
    '"worst": the one listed defect that costs the most words, or "none"}')


def _own_ledger():
    G.CACHE, G.CAP = CACHE, CAP


def pages():
    """48 of the 96: ordered by source, kind and a seeded key, every other one; no reader's result is used."""
    import capture_ladder as C
    rows = C.scored_pages()
    rng = random.Random('46/capture-ladder-paid')
    keyed = sorted(rows, key=lambda r: (r['source'] == 'original', r['kind'], rng.random(), r['page']))
    return sorted(r['page'] for r in keyed[::2])


def manifest():
    import capture_ladder as C
    out = {}
    for line in (C.CLUSTER / 'pages.jsonl').read_text().splitlines():
        if line.strip():
            r = json.loads(line); out[r['id']] = r['sha256']
    return out


def image_bytes(variant, page, shas):
    """The ladder image, refused unless it is the one the Sherlock readers read (or, for raw, the panel's)."""
    import capture_ladder as C
    b = C.image(variant, page).read_bytes()
    want = shas.get(f'{variant}/{page}') if variant != 'raw' else _panel_sha(page)
    if hashlib.sha256(b).hexdigest() != want:
        raise SystemExit(f'{variant}/{page}: the image is not the one the other readers read')
    return b


def _panel_sha(page):
    _, panel = G.panel_manifest()
    return next(j['sha256'] for j in panel if j['page'] == page)


def reply_path(variant, page):
    return CACHE / 'replies' / variant / (page + '.json')


def verdict_path(variant, page):
    return CACHE / 'verdicts' / variant / (page + '.json')


def raw_reply(page):
    """The plain image's reading from W46.fix-ocr-scorers-paid, after checking the prompt is the panel's."""
    import ocr_panel as P
    m, panel = G.panel_manifest()
    if m['prompt'] != P.PROMPT:
        raise ValueError('the cloud panel prompt is not ocr_panel.PROMPT')
    j = next(j for j in panel if j['page'] == page)
    f = G.REHEARSAL / 'gateway-gemini' / 'panel' / (j['id'] + '.json')
    return json.loads(f.read_text()) if f.exists() else None


def pack():
    """The ladder images this script's jobs need (10 variants x 48 pages), regenerated where missing with
    capture_ladder.make_image under the private venv (augraphy 8.2.6, numpy 2.5.4, opencv 5.0.0.93, pillow 13.0.0)
    and every one checked against the Sherlock manifest. A whole `capture_ladder.py make` builds 16 x 99 and the
    Augraphy variants take 10-20 s an image; this builds a third of that. Prints the count still wrong, if any."""
    import capture_ladder as C
    shas = manifest(); args = dict(C.variants()); bad = []
    for n, (v, p) in enumerate(reading_jobs(), 1):
        dst = C.image(v, p)
        C.make_image(v, args[v], p, dst)
        if hashlib.sha256(dst.read_bytes()).hexdigest() != shas[f'{v}/{p}']:
            bad.append(f'{v}/{p}')
        if n % 48 == 0:
            print(v, 'done', flush=True)
    print(f'pack: {n} images, {len(bad)} differ from the Sherlock manifest', bad[:10], flush=True)
    return bad


def reading_jobs():
    return [(v, p) for v in VARIANTS for p in pages()]


def verdict_jobs():
    return [(v, p) for v in ('raw', *VARIANTS) for p in pages()]


def run_readings(todo):
    _own_ledger()
    m, _ = G.panel_manifest()
    shas = manifest()
    G.run(SET, [(f'{v}/{p}', image_bytes(v, p, shas), reply_path(v, p)) for v, p in todo], m['prompt'])


def run_verdicts(todo):
    _own_ledger()
    shas = manifest()
    jobs = [(f'{v}/{p}', image_bytes(v, p, shas), verdict_path(v, p)) for v, p in todo]
    with ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda j: (j[0], G.call(SET + '-verdict', j[0], j[1], VERDICT_PROMPT, j[2])), jobs))
    bad = [i for i, r in res if parse_verdict(r) is None]
    print(f'verdicts: {len(res) - len(bad)}/{len(res)} parsed, ${G.spent():.4f} spent in all; unparsed: {bad}')


def parse_verdict(reply):
    """{'quality': 1-5, 'retake': bool, 'defects': set, 'worst': str} or None for a reply that does not parse."""
    raw = (reply or {}).get('raw')
    if not raw:
        return None
    m = re.search(r'\{.*\}', raw, re.S)
    try:
        d = json.loads(m.group(0)) if m else None
    except json.JSONDecodeError:
        return None
    if not isinstance(d, dict):
        return None
    q = d.get('quality')
    if not isinstance(q, (int, float)) or not 1 <= q <= 5:
        return None
    defects = d.get('defects') if isinstance(d.get('defects'), list) else []
    return {'quality': int(round(q)), 'retake': d.get('retake') is True,
            'defects': {x for x in defects if x in VERDICT_DEFECTS},
            'worst': d.get('worst') if d.get('worst') in VERDICT_DEFECTS else 'none'}


def status_of(meta, parsed):
    if meta.get('http') != 200:
        return 'error'
    if meta.get('finish') == 'length':
        return 'cap'
    return 'ok' if parsed else 'blank'


def readings():
    """{(variant, page): (text, status)} for raw and every reading variant; None if any is still unread.
    A failed, capped or unparsed reply is an empty reading and stays in the denominator."""
    out = {}
    for v, p in [('raw', p) for p in pages()] + reading_jobs():
        f = reply_path(v, p)
        reply = raw_reply(p) if v == 'raw' else (json.loads(f.read_text()) if f.exists() else None)
        if reply is None:
            return None
        parsed = G.parsed(reply)
        out[v, p] = (parsed['text'] if parsed else '', status_of(reply.get('meta') or {}, parsed))
    return out


def verdicts():
    """{(variant, page): parsed verdict or None}; None if any verdict is still missing."""
    out = {}
    for v, p in verdict_jobs():
        f = verdict_path(v, p)
        if not f.exists():
            return None
        out[v, p] = parse_verdict(json.loads(f.read_text()))
    return out


def spent():
    _own_ledger()
    return G.spent()


def billed():
    _own_ledger()
    return {s: G.billed([r for r in G.ledger() if r['set'] == s]) for s in (SET, SET + '-verdict')}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('cmd', choices=['pack', 'probe', 'run', 'readings', 'verdicts', 'spent'])
    cmd = ap.parse_args().cmd
    if cmd == 'pack':
        sys.exit(1 if pack() else 0)
    if cmd == 'probe':
        run_readings(reading_jobs()[:1]); run_verdicts(verdict_jobs()[:1])
    if cmd in ('run', 'readings'):
        run_readings(reading_jobs())
    if cmd in ('run', 'verdicts'):
        run_verdicts(verdict_jobs())
    _own_ledger()
    print(f'${spent():.4f} of ${CAP} spent on this item ({G.billed_note(G.ledger())})')


if __name__ == '__main__':
    main()
