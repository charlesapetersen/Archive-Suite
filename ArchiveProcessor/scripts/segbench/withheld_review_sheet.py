#!/usr/bin/env python3
"""W47.withheld-review. The features withheld for a quality floor before the owner's rule of 2026-11-18, for his review.

The owner's rule (CLAUDE.md, "Withholding a feature for a quality floor"; 14-owner-calls.md call 13): no feature, field
or route is withheld because a measurement falls short of a floor without his confirmation. This lists the withholdings
already made, from the app, `segbench-results/settings-routes.json`, the stage rules and the DONE entries, leaving out
his own calls and what was dropped for money, licence, safety or memory. The entries are
`execution-plans/processing-review/16-withheld-review.json`; each carries the feature, the floor and where it is
written, the figure, what the user loses, what shipping it would take and a recommendation.

  python3 withheld_review_sheet.py sheet               # REHEARSAL/withheld-review/index.html, sized in minutes
  python3 withheld_review_sheet.py md                  # rewrites 16-withheld-review.md from the JSON
  python3 withheld_review_sheet.py fold ANSWERS.json   # the owner's answers as calls, one line each

No model runs and no network: a reading page. Answers save in the browser and download as JSON; each item has a notes
box (typing in it never picks an answer), and the header says nothing is changed until the answers are folded.
"""
import argparse
import html
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT / 'execution-plans/processing-review/16-withheld-review.json'
MD = ROOT / 'execution-plans/processing-review/16-withheld-review.md'
OUT = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/withheld-review'
CHOICES = {'release': 'Release it (offer it as measured)',
           'label': 'Release it with a label or mark (as recommended)',
           'keep': 'Keep it withheld (record as my call)',
           'later': 'Not now: ask again after the named work'}
REC_WORD = {'release': 'release', 'label': 'release with a label', 'keep': 'keep withheld', 'later': 'ask again later'}
FIELDS = [('where', 'Where the withholding is'), ('floor', 'The floor, and where it is written'),
          ('figure', 'The measured figure'), ('loses', 'What the user loses'),
          ('ship', 'What shipping it would take')]


def load():
    d = json.loads(DATA.read_text())
    ids = [e['id'] for e in d['entries']]
    if len(ids) != len(set(ids)):
        sys.exit('duplicate entry ids in ' + str(DATA))
    for e in d['entries']:
        missing = [k for k, _ in FIELDS + [('feature', ''), ('rec', ''), ('why', ''), ('seconds', '')] if k not in e]
        if missing or e['rec'] not in CHOICES:
            sys.exit(f"{e['id']}: missing {missing} or bad rec {e.get('rec')!r}")
    return d


def minutes(d):
    return max(1, round(sum(e['seconds'] for e in d['entries']) / 60))


def cmd_md(_):
    d = load()
    out = [f"# 16. Features withheld for a quality floor — for the owner's review (W47.withheld-review)", '',
           '*Built from `16-withheld-review.json` by `ArchiveProcessor/scripts/segbench/withheld_review_sheet.py md`; edit '
           'the JSON, not this page.*', '', d['intro'], '',
           f"**{len(d['entries'])} entries, about {minutes(d)} minutes.** Recommendation counts: "
           + ', '.join(f"{REC_WORD[k]} {sum(e['rec'] == k for e in d['entries'])}" for k in CHOICES
                       if any(e['rec'] == k for e in d['entries'])) + '.', '']
    group = None
    for i, e in enumerate(d['entries'], 1):
        if e.get('group') != group:
            group = e.get('group')
            out += [f'## {group}', '']
        out += [f"### {i}. {e['feature']} (`{e['id']}`)", '']
        out += [f'- **{label}:** {e[k]}' for k, label in FIELDS]
        out += [f"- **Recommendation: {REC_WORD[e['rec']]}.** {e['why']}", '']
    out += ['## Left out, and why', ''] + [f'- {x}' for x in d['excluded']] + ['']
    MD.write_text('\n'.join(out))
    print(MD, len(d['entries']), 'entries')


def cmd_sheet(_):
    d = load()
    OUT.mkdir(parents=True, exist_ok=True)
    items = []
    for i, e in enumerate(d['entries'], 1):
        rows = ''.join(f'<dt>{html.escape(lbl)}</dt><dd>{html.escape(e[k])}</dd>' for k, lbl in FIELDS)
        opts = ''.join(
            f'<label><input type="radio" name="{e["id"]}" value="{k}"> {html.escape(v)}'
            + (' <b>(recommended)</b>' if k == e['rec'] else '') + '</label>' for k, v in CHOICES.items())
        items.append(
            f'<section class="item" id="{e["id"]}"><h2>{i}. {html.escape(e["feature"])}</h2>'
            f'<p class="grp">{html.escape(e.get("group", ""))} · <code>{e["id"]}</code></p><dl>{rows}</dl>'
            f'<p class="rec">Recommendation: <b>{html.escape(REC_WORD[e["rec"]])}</b>. {html.escape(e["why"])}</p>'
            f'<div class="opts">{opts}</div>'
            f'<textarea data-id="{e["id"]}" placeholder="Notes (optional): a condition, a different label, '
            f'or why"></textarea></section>')
    excl = ''.join(f'<li>{html.escape(x)}</li>' for x in d['excluded'])
    page = (SHEET_HTML.replace('__N__', str(len(d['entries']))).replace('__MIN__', str(minutes(d)))
            .replace('__INTRO__', html.escape(d['intro'])).replace('__ITEMS__', ''.join(items))
            .replace('__EXCL__', excl).replace('__IDS__', json.dumps([e['id'] for e in d['entries']])))
    (OUT / 'index.html').write_text(page)
    print(OUT / 'index.html', len(d['entries']), 'entries, about', minutes(d), 'min')


def cmd_fold(args):
    d = load()
    ans = json.loads(Path(args.answers).read_text())
    notes = ans.get('_notes', {})
    for i, e in enumerate(d['entries'], 1):
        a = ans.get(e['id'])
        line = f"{i}. {e['feature']} ({e['id']}): " + (CHOICES[a] if a in CHOICES else 'UNANSWERED')
        if a and a != e['rec']:
            line += f" (recommended: {REC_WORD[e['rec']]})"
        if notes.get(e['id']):
            line += f" — note: {notes[e['id']]}"
        print(line)
    if notes.get('_general'):
        print('General note:', notes['_general'])


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><title>Features withheld for a quality floor</title>
<style>body{font:15px/1.45 -apple-system,sans-serif;max-width:60em;margin:1.5em auto;padding:0 1em;color:#222}
.item{border:2px solid #999;border-radius:8px;padding:.6em 1em;margin:1.2em 0}.item.done{border-color:#2a7}
h2{font-size:1.1em;margin:.2em 0}.grp{color:#666;margin:0 0 .4em}dl{margin:0}dt{font-weight:600;margin-top:.3em}
dd{margin:0 0 0 1em}.rec{background:#f4f4ee;padding:.4em .6em;border-radius:4px}.opts label{display:block}
textarea{width:100%;min-height:3.2em;margin-top:.4em;font:inherit}#bar{position:sticky;top:0;background:#fff;
padding:.4em 0;border-bottom:1px solid #ccc}</style>
<div id="bar"><b>Features withheld for a quality floor</b> · __N__ items, about __MIN__ min · <span id="prog"></span>
· <button id="dl">download answers</button></div>
<p>__INTRO__</p><p>Each box is one withholding made before your rule of 18 November. Pick one answer; the notes box is
optional and never picks an answer. Answers save in this browser. Nothing in the app changes until a session folds
the downloaded answers into 14-owner-calls.md and files an item for each feature you release.</p>
__ITEMS__
<section class="item"><h2>Anything else</h2><textarea data-id="_general" placeholder="A general note, or a
withholding this list missed"></textarea></section>
<details><summary>Left out of the list, and why</summary><ul>__EXCL__</ul></details>
<script>const IDS=__IDS__;const KEY='w47-withheld-review';
const A=JSON.parse(localStorage.getItem(KEY)||'{}');A._notes=A._notes||{};
const save=()=>{localStorage.setItem(KEY,JSON.stringify(A));prog()};
function prog(){const n=IDS.filter(i=>A[i]).length;document.getElementById('prog').textContent=n+' of '+IDS.length+' answered';
IDS.forEach(i=>document.getElementById(i).classList.toggle('done',!!A[i]))}
document.querySelectorAll('input[type=radio]').forEach(r=>{if(A[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{A[r.name]=r.value;save()})});
document.querySelectorAll('textarea').forEach(t=>{t.value=A._notes[t.dataset.id]||'';t.addEventListener('keydown',e=>e.stopPropagation());
t.addEventListener('input',()=>{if(t.value)A._notes[t.dataset.id]=t.value;else delete A._notes[t.dataset.id];save()})});
document.getElementById('dl').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(
[JSON.stringify(A,null,1)],{type:'application/json'}));a.download='withheld-review-answers.json';a.click()};prog();</script>
"""


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    s = p.add_subparsers(dest='cmd', required=True)
    s.add_parser('sheet').set_defaults(f=cmd_sheet)
    s.add_parser('md').set_defaults(f=cmd_md)
    f = s.add_parser('fold')
    f.add_argument('answers')
    f.set_defaults(f=cmd_fold)
    a = p.parse_args(argv)
    a.f(a)


if __name__ == '__main__':
    main()
