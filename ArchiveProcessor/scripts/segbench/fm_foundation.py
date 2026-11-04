#!/usr/bin/env python3
"""W46.r1-foundation. The macOS 27 on-device Foundation Model as a free first reader (processing review, H test 9).

  python3 fm_foundation.py build                      # compile fm_ocr.swift and fm_text.swift into BIN
  python3 fm_foundation.py jobs                       # job lists: the 99 panel originals, the 100 Latin pages, Deaver
  python3 ops/autonomous/heavy-run.py run -- BIN/segbench-fm-ocr STORE/ocr96.tsv     # then ocr100.tsv
  python3 ops/autonomous/heavy-run.py run -- BIN/segbench-fm-text STORE/seg-deaver.tsv
  python3 ops/autonomous/heavy-run.py run -- BIN/segbench-fm-text STORE/seg-deaver-guided.tsv --guided
  uv run --offline --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy \
      python fm_foundation.py report                  # -> segbench-results/r1-foundation.{json,md}

FIXED BEFORE ANY ANSWER:
- Model: SystemLanguageModel on this Mac (M3 Pro, 18 GB, macOS 27.2, Apple Intelligence on), on-device only;
  Private Cloud Compute is never called. Greedy sampling, a fresh session per page or window, guardrails
  permissiveContentTransformations (Apple's setting for transforming the user's own content; the stock guardrail
  refused the first pilot page). OCR output is capped at 4,096 tokens, so a page reaching it is a loop ("length").
- OCR prompt: plain transcription instructions (fm_ocr.swift), answer scored whole, as LightOnOCR is on the panel;
  the panel's KIND/TEXT reply format is not asked of a 3B model.
- The 96: the panel's 99 frozen originals (2,400 px JPEG q90), scored on the 96 accuracy pages with the panel's
  score(); failed or cut-off readings score empty, as on the panel.
- The 100 Latin pages: 25 a stratum from the four Latin-script strata (L5-L8) of the 440 reference pages, not from
  the 895's nine strata, drawn with random.Random(SEED) from the ids sorted (SEED keeps its first wording, '100 of
  the 895', so that the draw is unchanged); the reference images (corpus/routes.py prepare). Latin only because Apple
  Vision, the disagreement partner, has cached readings only for the 440's Latin-script pages
  (routes.VISION_SCRIPTS). Scored with the panel's score() at each page's stratum.
- Disagreement: NES between this model's text and Apple Vision's on the same page (0 when either failed), as
  ocr_logprob.add_agreement; AUC (Mann-Whitney) for picking out this model's NES < 70, < 90 and failures, and
  Vision's own NES < 70 and < 90 (the routing question: does disagreement flag the page Vision got wrong?).
- Apple Vision's text is the macOS 27.2 re-read (W46.vision-27-reread: ocr-panel-local/vision-27.2 and
  bench-corpus/routes/vision-27.2), so both readers ran on one OS build. Switched after the 96 were read; Vision's
  text does not depend on this model's answers.
- Segmentation: Deaver (149 pages, one development box), K = 3 text-only windows, the exact prompt
  seg_window_gateway's k3-t arm sent Gemini 3.7 Flash (JSON schema in the prompt, no JSON mode on-device), its
  parser and combiner; a failed window votes 0.5. Compared paired with Gemini 3.7's k3-t and k3-it on Deaver,
  bootstrap over truth documents (seg_window_gateway.bootstrap).
- ADDED AFTER THE FIRST REPLIES (so not fixed before any answer): the guided arm. The first plain windows came back
  echoing the schema's own wrapper ({"type": "OBJECT", "properties": ...}), which the parser cannot read, so a
  second arm drops the pasted schema and uses guided generation (a @Generable type with the schema's fields and
  enums), which is how an app would call this model. Both arms are reported.
- ADDED AFTER THE 96 WERE READ (23ad3536), so also post hoc: the 'loops cut' score (cut_loop, applied only to the
  pages that hit the cap; an answered page keeps its whole text), the per-group scores and intervals on the pages it
  answered, and the AUCs on answered pages only. No interval is given on fewer than ten pages.
- The image-token probe (--tokens): seven long sides on three pages of different shapes, portrait, landscape and
  tall narrow (PROBE_PAGES).
No money, no network. Page images, text and replies stay in STORE and the panel cache, outside git.
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import subprocess
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE / 'corpus')]

TAG = 'W46.r1-foundation'
STORE = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal' / TAG
BIN = STORE / 'bin'
RESULTS = HERE.parents[1] / 'segbench-results'
SEED = 'W46.r1-foundation/100-of-895'   # the draw's seed, kept as first written; the pages are the 440's L5-L8
LATIN = ('L5', 'L6', 'L7', 'L8')
PER_STRATUM = 25
BOX = 'Deaver'
ARM = 'k3-t'
VISION = 'vision-27.2'   # W46.vision-27-reread's macOS 27.2 readings, the OS this model ran on
MIN_CI = 10   # no interval on fewer pages
PROBE_PAGES = ('p002', 'p057', 'p010')   # panel originals: portrait 1793x2400, landscape 2400x1793, tall 804x2400


def ocr_dir(name):
    return STORE / name


# --- build and jobs -------------------------------------------------------------------------------

def cmd_build(_):
    BIN.mkdir(parents=True, exist_ok=True)
    for src, out in (('fm_ocr.swift', 'segbench-fm-ocr'), ('fm_text.swift', 'segbench-fm-text')):
        subprocess.run(['swiftc', '-parse-as-library', '-O', str(HERE / src), '-o', str(BIN / out)], check=True)
    print('built', BIN)


def panel_jobs():
    import ocr_panel as P
    return [j for j in P.manifest()['jobs'] if j['scale'] == 'original']


def draw_100():
    import routes as R
    jobs = sorted((j for j in R.manifest()['jobs'] if j['stratum'] in LATIN), key=lambda j: j['id'])
    rng = random.Random(SEED)
    out = []
    for s in LATIN:
        pool = [j for j in jobs if j['stratum'] == s]
        out += sorted(rng.sample(pool, PER_STRATUM), key=lambda j: j['id'])
    return out


def seg_units():
    import seg_window_gateway as SG
    col = SG.load(BOX)
    return col, SG.units(col, ARM)


SCHEMA_LINE = 'Return only one JSON object matching this schema:\n'
SEG_ARMS = {   # arm: (prompts, replies, job list)
    'on-device k3-t': (STORE / 'seg-prompts', STORE / 'seg-replies', STORE / 'seg-deaver.tsv'),
    'on-device k3-t guided': (STORE / 'seg-prompts-guided', STORE / 'seg-replies-guided', STORE / 'seg-deaver-guided.tsv'),
}


def seg_prompt(col, a, b, arm):
    """(request key, prompt text). The plain arm is Gemini 3.7's k3-t prompt word for word, its JSON schema pasted at
    the end; the guided arm drops that pasted schema, since guided generation (fm_text.swift --guided) imposes the
    same fields and enums, and keeps every other word."""
    import seg_window_gateway as SG
    body, key, nums = SG.request(col, a, b, ARM)
    text = body['messages'][0]['content'][0]['text']
    if arm.endswith('guided'):
        if text.count(SCHEMA_LINE) != 1:
            raise ValueError(f'{col.name} {nums[0]}-{nums[-1]}: the schema line is not unique')
        text = text[:text.index(SCHEMA_LINE)].rstrip() + '\n'
    return key, text


def cmd_jobs(_):
    import ocr_panel as P
    import routes as R
    import seg_window_gateway as SG
    STORE.mkdir(parents=True, exist_ok=True)
    (STORE / 'ocr96.tsv').write_text(''.join(
        f"{P.CACHE / 'images' / (j['id'] + '.jpg')}\t{ocr_dir('ocr96') / (j['id'] + '.txt')}\n" for j in panel_jobs()))
    (STORE / 'ocr100.tsv').write_text(''.join(
        f"{R.RUN / 'images' / (j['id'] + '.jpg')}\t{ocr_dir('ocr100') / (j['id'] + '.txt')}\n" for j in draw_100()))
    col, us = seg_units()
    for arm, (pdir, rdir, tsv) in SEG_ARMS.items():
        pdir.mkdir(exist_ok=True)
        lines = []
        for a, b in us:
            key, text = seg_prompt(col, a, b, arm)
            (pdir / f'{key}.txt').write_text(text)
            lines.append(f"{pdir / (key + '.txt')}\t{rdir / (key + '.txt')}\n")
        tsv.write_text(''.join(lines))
    print(f'jobs: {len(panel_jobs())} panel originals, {len(draw_100())} Latin pages (L5-L8 of the 440), {len(lines)} {BOX} windows')


# --- report ---------------------------------------------------------------------------------------

def reading(d, jid):
    """(sidecar, text or None). A page with no sidecar was not attempted; a failed or capped one reads None."""
    side = d / (jid + '.txt.json')
    if not side.exists():
        return None, None
    meta = json.loads(side.read_text())
    txt = d / (jid + '.txt')
    return meta, (txt.read_text() if meta.get('ok') and txt.exists() else None)


def cut_loop(text):
    """A looped reading cut where it starts repeating: at the third appearance of any line (after stripping). The
    secondary 'loops cut' figure, what a repetition stop in an app could keep; the primary figure scores loops empty.
    Applied only to readings that hit the cap (looped_text); a page the model finished is scored whole."""
    seen, out = Counter(), []
    for line in text.splitlines():
        k = line.strip()
        seen[k] += 1
        if k and seen[k] >= 3:
            break
        out.append(line)
    return '\n'.join(out)


def looped_text(d, jid, meta, text):
    """The 'loops cut' reading: a finished page's own text, a capped page's text cut at its loop, else empty."""
    if text is not None:
        return text
    f = d / (jid + '.txt')
    return cut_loop(f.read_text()) if meta and meta.get('failure') == 'length' and f.exists() else ''


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))] if xs else 0


def boot_mean(d, rounds=10000, seed=0):
    rng = random.Random(seed)
    ms = sorted(statistics.fmean(rng.choice(d) for _ in d) for _ in range(rounds))
    return statistics.fmean(d), ms[int(.025 * rounds)], ms[int(.975 * rounds) - 1]


def ocr_rows():
    import ocr_panel as P
    import ocr_panel_score as S
    import routes as R
    kinds = {r['page']: r['kind'] for r in P.rows()}
    rows = []
    for j in panel_jobs():
        if j['page'] in P.AGREEMENT:
            continue
        truth = (P.TRUTH / 'truth' / (j['page'] + '.txt')).read_text()
        meta, text = reading(ocr_dir('ocr96'), j['id'])
        vf = P.CACHE / VISION / (j['id'] + '.txt')
        vis = vf.read_text() if vf.exists() else None
        rows.append({'set': '96', 'page': j['id'], 'group': kinds[j['page']], 'meta': meta, 'text': text, 'vision': vis,
                     'fm': S.score(truth, text or ''), 'vs': S.score(truth, vis or ''),
                     'cut': S.score(truth, looped_text(ocr_dir('ocr96'), j['id'], meta, text))})
    truth = {R.job_id(r): r for r in R.frozen()}
    for j in draw_100():
        t = Path(truth[j['id']]['truth']).read_text()
        meta, text = reading(ocr_dir('ocr100'), j['id'])
        vf = R.RUN / VISION / (j['id'] + '.txt')
        vis = vf.read_text() if vf.exists() else None
        rows.append({'set': '100', 'page': j['id'], 'group': j['stratum'], 'meta': meta, 'text': text, 'vision': vis,
                     'fm': S.score(t, text or '', j['stratum']), 'vs': S.score(t, vis or '', j['stratum']),
                     'cut': S.score(t, looped_text(ocr_dir('ocr100'), j['id'], meta, text), j['stratum'])})
    for r in rows:
        r['ok'] = r['text'] is not None
        r['vok'] = r['vision'] is not None
        r['agree'] = S.score(r['vision'], r['text'])['nes'] if r['ok'] and r['vok'] else 0.0
    return rows


def auc_table(rr):
    from ocr_logprob import auc
    risk = [1 - r['agree'] for r in rr]
    labels = {'this model NES < 70': [not r['ok'] or r['fm']['nes'] < .70 for r in rr],
              'this model NES < 90': [not r['ok'] or r['fm']['nes'] < .90 for r in rr],
              'this model failed': [not r['ok'] for r in rr],
              'Apple Vision NES < 70': [r['vs']['nes'] < .70 for r in rr],
              'Apple Vision NES < 90': [r['vs']['nes'] < .90 for r in rr]}
    return {k: {'positives': sum(v), 'auc': auc(risk, v)} for k, v in labels.items()}


def ocr_summary(rows):
    out = {}
    for s in ('96', '100'):
        rr = [r for r in rows if r['set'] == s]
        done = [r for r in rr if r['meta']]
        if not done:
            continue
        metas = [r['meta'] for r in done]
        d = [r['fm']['nes'] - r['vs']['nes'] for r in done]
        both = [r['fm']['nes'] - r['vs']['nes'] for r in done if r['ok']]
        m, lo, hi = boot_mean(d)
        groups = {}
        for g in sorted({r['group'] for r in done}):
            gg = [r for r in done if r['group'] == g]
            ga = [r for r in gg if r['ok']]
            groups[g] = {'n': len(gg), 'ok': len(ga), 'fm_nes': statistics.fmean(r['fm']['nes'] for r in gg),
                         'fm_nes_answered': statistics.fmean(r['fm']['nes'] for r in ga) if ga else None,
                         'vision_nes': statistics.fmean(r['vs']['nes'] for r in gg),
                         'vision_nes_answered': statistics.fmean(r['vs']['nes'] for r in ga) if ga else None,
                         'diff_answered': boot_mean([r['fm']['nes'] - r['vs']['nes'] for r in ga]) if len(ga) >= MIN_CI else None}
        out[s] = {'n': len(rr), 'attempted': len(done), 'ok': sum(r['ok'] for r in done),
                  'failures': dict(Counter(r['meta'].get('failure') for r in done if not r['ok'])),
                  'fm_nes': statistics.fmean(r['fm']['nes'] for r in done),
                  'fm_nes_answered': statistics.fmean(r['fm']['nes'] for r in done if r['ok']) if any(r['ok'] for r in done) else 0,
                  'vision_nes': statistics.fmean(r['vs']['nes'] for r in done),
                  'fm_nes_loops_cut': statistics.fmean(r['cut']['nes'] for r in done),
                  'vision_ok': sum(r['vok'] for r in done),
                  'diff': {'mean': m, 'lo': lo, 'hi': hi},
                  'diff_answered': statistics.fmean(both) if both else None,
                  'fm_better': sum(x > .005 for x in d), 'fm_worse': sum(x < -.005 for x in d),
                  'seconds': {'median': statistics.median(x['seconds'] for x in metas),
                              'mean': statistics.fmean(x['seconds'] for x in metas), 'p90': pct([x['seconds'] for x in metas], .9),
                              'max': max(x['seconds'] for x in metas), 'total': sum(x['seconds'] for x in metas)},
                  'input_tokens': {'median': statistics.median(x.get('input_tokens', 0) for x in metas),
                                   'min': min(x.get('input_tokens', 0) for x in metas), 'max': max(x.get('input_tokens', 0) for x in metas)},
                  'image_tokens': sorted(Counter(x.get('image_tokens') for x in metas).items()),
                  'output_tokens': {'median': statistics.median(x.get('output_tokens', 0) for x in metas),
                                    'max': max(x.get('output_tokens', 0) for x in metas)},
                  'sent_px': sorted(Counter(f"{x.get('sent_w')}x{x.get('sent_h')}" for x in metas).most_common(3)),
                  'groups': groups, 'auc': auc_table(done), 'auc_answered': auc_table([r for r in done if r['ok']])}
    return out


def seg_summary():
    import seg_window_gateway as SG
    import seg_window_modality as SM
    import method_window as W
    from score import score_labels, derived
    col, us = seg_units()
    failed = Counter()
    metas = {arm: [] for arm in SEG_ARMS}

    def judge_for(arm):
        rdir = SEG_ARMS[arm][1]

        def judge_fm(c, a, b):
            body, key, nums = SG.request(c, a, b, ARM)
            side = rdir / (key + '.txt.json')
            if not side.exists():
                raise RuntimeError(f'{arm}: {BOX} window {nums[0]}-{nums[-1]} not read yet')
            meta = json.loads(side.read_text())
            metas[arm].append(meta)
            if meta.get('ok'):
                try:
                    return SG.parse((rdir / (key + '.txt')).read_text(), nums, False)
                except Exception:
                    meta['failure'] = 'unparsed'
            failed[arm] += 1
            return SM._seg()[1].neutral(nums)
        return judge_fm

    preds, incomplete = {}, []
    for arm in SEG_ARMS:
        try:
            preds[arm] = W.assemble(col, SM.combine_units(col, us, judge_for(arm)), True).labels
        except RuntimeError as e:
            incomplete.append(str(e))
    if not preds:
        return {'incomplete': '; '.join(incomplete)}
    for arm in ('k3-t', 'k3-it'):
        preds[f'Gemini 3.7 {arm}'] = W.assemble(col, SM.combine_units(col, SG.units(col, arm), SG.judge_for(arm, failed)),
                                                True).labels
    rows, per_page = {}, {}
    for name, labels in preds.items():
        c = score_labels(col.labels, labels, BOX)
        m = derived(c)
        per_page[name] = [bool(v) for v in SG.exact_pages(col.labels, labels)]
        rows[name] = {'pages': c.doc_pages, 'pages_exact': m['pages_in_exact_doc'], 'boundary_f1': m['boundary_f1'],
                      'false_splits': c.false_splits, 'false_merges': c.false_merges}
    docs = SG.documents(col)
    paired = {f'{arm} − {g}': SG.bootstrap(per_page[arm], per_page[g], docs)
              for arm in SEG_ARMS if arm in per_page for g in ('Gemini 3.7 k3-t', 'Gemini 3.7 k3-it')}
    runs = {arm: {'failed_windows': failed[arm],
                  'failures': dict(Counter(m.get('failure') for m in ms if not m.get('ok') or m.get('failure'))),
                  'seconds': {'median': statistics.median(m['seconds'] for m in ms), 'total': sum(m['seconds'] for m in ms)},
                  'input_tokens': {'median': statistics.median(m.get('input_tokens', 0) for m in ms),
                                   'max': max(m.get('input_tokens', 0) for m in ms)}}
            for arm, ms in metas.items() if arm in preds}
    return {'box': BOX, 'windows': len(us), 'runs': runs, 'rows': rows, 'paired': paired, 'incomplete': incomplete}


def cmd_report(_):
    rows = ocr_rows()
    o = {'tag': TAG, 'model': 'SystemLanguageModel (on-device), macOS 27.2 (26B123), Apple M3 Pro 18 GB',
         'ocr': ocr_summary(rows), 'segmentation': seg_summary()}
    o['image_tokens_by_size'] = {pg: json.loads((STORE / f'image-tokens-{pg}.json').read_text())
                                 for pg in PROBE_PAGES if (STORE / f'image-tokens-{pg}.json').exists()}
    (RESULTS / 'r1-foundation.json').write_text(json.dumps(o, indent=1, default=str) + '\n')
    write_md(o)
    print(json.dumps({s: {k: v for k, v in x.items() if k in ('attempted', 'ok', 'fm_nes', 'vision_nes')}
                      for s, x in o['ocr'].items()}, indent=1))


def p(x):
    return f'{100 * x:.1f}'


def write_md(o):
    from ocr_card import card, TRUTH_96, NOISE_96
    L = [f'# {TAG} — the macOS 27 on-device model as a free first reader', '',
         'Reproduce: `ArchiveProcessor/scripts/segbench/fm_foundation.py` (its header has every step and every setting '
         'fixed before the first answer). Model: Apple\'s on-device `SystemLanguageModel` on macOS 27.2, on the '
         'M3 Pro with 18 GB; Private Cloud Compute never called. No money, no network. Page text stays in the cache.', '']
    L += FINDINGS + ['']
    names = {'96': 'The owner\'s 96', '100': '100 Latin pages of the 440 reference set (25 from each of L5-L8)'}
    L += ['## OCR', '', '| set | read / n | NES % (failures empty) | NES % answered | NES %, loops cut (post hoc) | Apple Vision NES % (27.2) | '
          'difference from Vision, points (95% interval) | failures |', '|---|---:|---:|---:|---:|---:|---:|---|']
    for s, x in o['ocr'].items():
        d = x['diff']
        L.append(f"| {names[s]} | {x['ok']}/{x['attempted']} of {x['n']} | {p(x['fm_nes'])} | {p(x['fm_nes_answered'])} | "
                 f"{p(x['fm_nes_loops_cut'])} | {p(x['vision_nes'])} | {100*d['mean']:+.1f} ({100*d['lo']:+.1f} to {100*d['hi']:+.1f}) | "
                 f"{', '.join(f'{k} {v}' for k, v in x['failures'].items()) or 'none'} |")
    for s, x in o['ocr'].items():
        L += ['', f'### {names[s]}: by group', '', 'The columns on the pages it read, and their intervals, were added after '
              'the 96 were read (post hoc); no interval under ten pages.', '',
              '| group | n | read | on-device NES % | Vision NES % | on-device NES %, '
              'pages it read | Vision NES %, the same pages | difference on those pages (95% interval) |',
              '|---|---:|---:|---:|---:|---:|---:|---:|']
        q = lambda v: '–' if v is None else p(v)
        ci = lambda d: '–' if d is None else f"{100*d[0]:+.1f} ({100*d[1]:+.1f} to {100*d[2]:+.1f})"
        L += [f"| {g} | {v['n']} | {v['ok']} | {p(v['fm_nes'])} | {p(v['vision_nes'])} | {q(v['fm_nes_answered'])} | "
              f"{q(v['vision_nes_answered'])} | {ci(v['diff_answered'])} |" for g, v in x['groups'].items()]
    L += ['', '## Speed and tokens', '', '| set | seconds a page, median / mean / 90th / max | total minutes | input tokens '
          '(image + prompt), median (min-max) | image tokens (tokenCount) | output tokens, median / max |',
          '|---|---:|---:|---:|---:|---:|']
    for s, x in o['ocr'].items():
        sc, it = x['seconds'], x['input_tokens']
        L.append(f"| {names[s]} | {sc['median']:.1f} / {sc['mean']:.1f} / {sc['p90']:.1f} / {sc['max']:.1f} | {sc['total']/60:.0f} | "
                 f"{it['median']:.0f} ({it['min']}-{it['max']}) | {', '.join(f'{k} on {v}' for k, v in x['image_tokens'])} | "
                 f"{x['output_tokens']['median']:.0f} / {x['output_tokens']['max']} |")
    if o['image_tokens_by_size']:
        L += ['', 'Image tokens against the size sent (owner pages of three shapes, `tokenCount(for: Attachment)` and the '
              'session\'s own input count for a five-token reply; the long side is downsampled to at most the size named, '
              'never enlarged):', '', '| page | long side px | sent | tokenCount | session input tokens |',
              '|---|---:|---|---:|---:|']
        L += [f"| {pg} | {r['side']} | {r['w']}x{r['h']} | {r['tokenCount']} | {r['input']} |"
              for pg, rr in o['image_tokens_by_size'].items() for r in rr]
    L += ['', '## Disagreement with Apple Vision as a routing signal', '',
          'Risk = 1 − NES(on-device text, Vision text), 0 agreement when either failed. AUC 0.5 is chance. On all pages '
          'a failure is the worst risk by construction, so "this model failed" is 1.00 by definition; the answered-only '
          'columns drop the failures and are the honest test of the signal; they were added after the 96 were read '
          '(post hoc).', '',
          '| set | label | positives, all | AUC, all pages | positives, answered | AUC, answered pages |', '|---|---|---:|---:|---:|---:|']
    f2 = lambda v: '–' if v['auc'] is None else format(v['auc'], '.2f')
    for s, x in o['ocr'].items():
        L += [f"| {s} | {k} | {v['positives']} | {f2(v)} | {x['auc_answered'][k]['positives']} | {f2(x['auc_answered'][k])} |"
              for k, v in x['auc'].items()]
    sg = o['segmentation']
    L += ['', f'## Text-only segmentation on {BOX}', '']
    if 'rows' not in sg:
        L += [f"Incomplete: {sg['incomplete']}"]
    else:
        L += [f"{sg['windows']} K = 3 text-only windows. The plain arm sends Gemini 3.7's k3-t prompt word for word, "
              "its JSON schema pasted at the end; the guided arm drops the pasted schema and uses the framework's guided "
              "generation into the same fields and enums. A failed or unparsed window votes 0.5.", '']
        L += [f"- {arm}: {r['failed_windows']} failed ({', '.join(f'{k} {v}' for k, v in r['failures'].items()) or 'none'}); "
              f"{r['seconds']['median']:.1f} s a window (median), {r['seconds']['total']/60:.0f} min in all; input "
              f"{r['input_tokens']['median']:.0f} tokens a window (max {r['input_tokens']['max']})." for arm, r in sg['runs'].items()]
        L += [f"- Incomplete: {x}" for x in sg['incomplete']]
        L += ['',
              '| route | pages in an exact document % | boundary F1 % | false splits | false merges |', '|---|---:|---:|---:|---:|']
        L += [f"| {k} | {p(v['pages_exact'])} | {p(v['boundary_f1'])} | {v['false_splits']} | {v['false_merges']} |"
              for k, v in sg['rows'].items()]
        L += ['', 'Paired, pages in an exact document, bootstrap over truth documents:', '']
        L += [f"- {k}: {100*v['delta']:+.1f} points ({100*v['lo']:+.1f} to {100*v['hi']:+.1f}), {v['pages']} pages"
              for k, v in sg['paired'].items()]
    L += ['', *card(
        TRUTH_96 + ' The 100 Latin pages carry their public sets\' own transcriptions (corpus/README), scored at each '
        'page\'s stratum. Deaver\'s segmentation truth is the bench\'s development-box truth (data.py). No drafter is '
        'scored here.',
        'The 96 are every accuracy page; the 100 are a seeded draw, 25 from each of the 440 reference set\'s four '
        'Latin-script strata (L5-L8, where Vision\'s readings are cached; not the 895\'s nine strata), made before any '
        'reading (SEED in the script); Deaver is the development box seg_window_gateway already read at K = 3. None chosen by a '
        'route\'s reading or by ABBYY text.',
        'Apple Vision on the same images (the shipped free reader), its macOS 27.2 re-read (W46.vision-27-reread), so '
        'both readers ran on the same OS build; for segmentation, Gemini 3.7 Flash\'s k3-t and '
        'k3-it on the same windows and prompt. The on-device model gets a plain transcription prompt where the panel\'s '
        'routes get the KIND/TEXT prompt; that difference is the route as an app would call it, and is named here.',
        f'n = 96 and 100 pages, paired bootstrap intervals on the page differences. {NOISE_96} Greedy decoding on one '
        'Mac; one reading of each page. Segmentation n = one box (149 pages), intervals over its truth documents.',
        'One Mac, one OS build, one prompt; the 100 are Latin script only, from L5-L8 of the 440; text-only segmentation '
        'on one box, not the three. The loops-cut score, the answered-page groups and intervals and the answered-page '
        'AUCs were added after the 96 were read. Apple may change the model with an OS update, so these figures are for '
        'macOS 27.2 (26B123), both readers.')]
    (RESULTS / 'r1-foundation.md').write_text('\n'.join(L) + '\n')


FINDINGS = [   # written from the measured results; the figures are in the tables below
    '## Findings', '',
    '- **Not a first reader.** On the owner\'s 96 it scores 42.4 NES against Apple Vision\'s 83.1 on the same images, '
    'both read on macOS 27.2 (-40.7 points, interval -49.0 to -32.5). A third of the pages (33 of 96) run into a '
    'repetition loop and reach the 4,096-token cap; cutting each of those loops where it starts (post hoc) recovers '
    '4.4 points (46.8). Where it finishes a page it still trails Vision on typed (-20.4, -27.9 to -13.5) and printed '
    '(-25.4, -40.6 to -11.4) pages.',
    '- **Handwriting is the one lead, and it is a tie.** On the 13 handwritten pages it finished it reads 67.5 against '
    'Vision\'s 61.5 (+5.9, interval -3.8 to +15.8). Those 13 are chosen by the model itself finishing, and the '
    'answered-page comparison was added after the 96 were read, so this is a lead for a test with a loop stop, not a '
    'result.',
    '- **Worse on the 100 Latin pages (the 440 reference set\'s L5-L8, medieval and early-modern hands).** 10.6 NES '
    'against Vision\'s 40.9 (-30.2, -35.7 to -24.9); 55 of 100 loop to the cap. Where it finished, it trails on L8 '
    '(53.9 against 74.4, -20.5, -28.5 to -13.4) and ties on L7, where both readers fail (9.7 against 13.9, -4.2, -8.8 '
    'to +0.4); L5 and L6 have too few finished pages (4 and 7) for an interval.',
    '- **The image is seen at a fixed small size.** On three page shapes, the token count stops growing at 768 px on '
    'the long side: 131 tokens for a 3:4 portrait and a 4:3 landscape page, 163 for a tall 1:3 page, the same at '
    '2,400 px (512 px gives 195 and 131, 256 px 67 and 35). Sending more than 768 px buys nothing, so a resolution arm '
    'above that is moot. A page takes 9.5 s at the median on the 96 (mean 32 s) and about 80 s when it loops; on the '
    '100, 77 s at the median (one page, read in session 1, took 4,240 s, cause not recorded; it is why the mean there is 93 s).',
    '- **Disagreement flags its own bad pages, and Vision\'s only weakly.** On the 96 its disagreement with Vision '
    'picks out its own pages under 70 NES at AUC 0.93 (answered pages, post hoc); Vision\'s own pages under 70 at 0.82 '
    'and under 90 at 0.75 on those answered pages, and at 0.59 and 0.51 over all 96, because its loops (zero agreement) '
    'fall mostly on pages Vision reads well. As a free routing voter beside Vision it is weak, and its loops make it '
    'noisy.',
    '- **No text-only segmentation voter.** On Deaver, Gemini 3.7\'s k3-t prompt word for word gives replies that copy '
    'the pasted schema\'s wrapper (139 of 149 unparsable); with guided generation into the same fields, 132 parse but '
    'score 33.3% of pages in an exact document against Gemini 3.7\'s 93.6% (-60.3 points), 49 false splits: no better '
    'than the failed windows\' 0.5 votes.',
    '- **Guardrails.** The stock guardrail refused an owner page on the pilot; permissiveContentTransformations was used '
    'throughout, and still refused 3 of 149 segmentation windows.',
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name, fn in (('build', cmd_build), ('jobs', cmd_jobs), ('report', cmd_report)):
        sub.add_parser(name).set_defaults(fn=fn)
    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
