#!/usr/bin/env python3
"""The accepted known issues that hid a session's decision, for the owner's review (2026-11-19).

Source: execution-plans/processing-review/17-accepted-review.json. Each entry is a KNOWN_ISSUES.md bullet marked
accepted whose reason hides a choice no owner call covers. The sheet shows the plain layer (title, what, reason,
other, rec_why) and folds the technical pointer (where) under each item; the page is for a non-technical reader
(owner, 2026-11-19, as in the withheld-review sheet).

  python3 ops/review/accepted_review_sheet.py sheet               # REHEARSAL/accepted-review/index.html
  python3 ops/review/accepted_review_sheet.py fold ANSWERS.json   # the owner's answers, one line each
  ... --data FILE --out DIR                                       # another round (17b: the questions he left open)

An entry may carry "choices" ({key: label}) to replace the three standard answers' wording, a fourth answer
included, and "rec_text" for its recommendation line; its "rec" is still change, keep or later, which places it.
A data file may carry "opening" for the sheet's first paragraph.

No model runs and no network: a reading page. Answers save in the browser and download as JSON; each item has a notes
box (typing in it never picks an answer); nothing changes until a session folds the answers.
"""
import argparse
import html
import re
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'execution-plans/processing-review/17-accepted-review.json'
OUT = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/accepted-review'
KEY = 'accepted-review-20261119'
CHOICES = {'change': 'Change it as suggested',
           'keep': 'Keep it as it is. This becomes my decision and is not asked again',
           'later': 'Not sure yet: check what is open and ask me again'}
REC = {'change': 'change it', 'keep': 'keep it as it is', 'later': 'check first, then ask again'}
SECTIONS = [
    ('change', 'Recommended: change it',
     'Each of these leaves users worse off for a reason that does not hold up, or for a choice you were not asked '
     'about. Each one you confirm becomes a piece of work.'),
    ('later', 'Recommended: check first',
     'One fact needs checking before the choice is clear. A session checks it and asks you again.'),
    ('keep', 'Recommended: keep as it is',
     'These were choices too, but each has a sound reason. Read down the list, answer any you disagree with, then '
     'use the button for the rest.'),
]
NEED = ['id', 'app', 'rec', 'seconds', 'title', 'what', 'reason', 'other', 'rec_why', 'where']
LABELS = {'what': 'What happens', 'reason': 'The reason it was accepted', 'other': 'The other way'}


def load():
    d = json.loads(DATA.read_text())
    ids = [e['id'] for e in d['entries']]
    if len(ids) != len(set(ids)):
        sys.exit('duplicate entry ids')
    for e in d['entries']:
        missing = [k for k in NEED if not e.get(k)]
        if missing or e['rec'] not in CHOICES:
            sys.exit(f"{e.get('id')}: missing {missing} or bad rec {e.get('rec')!r}")
    rank = {k: i for i, (k, _, _) in enumerate(SECTIONS)}
    d['entries'].sort(key=lambda e: rank[e['rec']])   # stable: JSON order within a section
    return d


def cmd_sheet(_):
    d = load()
    esc = html.escape
    total = len(d['entries'])
    mins = max(1, round(sum(e['seconds'] for e in d['entries']) / 60))
    body, groups, n = [], {}, 0
    for key, head, lead in SECTIONS:
        mine = [e for e in d['entries'] if e['rec'] == key]
        groups[key] = [e['id'] for e in mine]
        if not mine:
            continue
        body.append(f'<h2 class="sec">{esc(head)} <span class="n">{len(mine)} items</span></h2>'
                    f'<p class="lead">{esc(lead)}</p>')
        for e in mine:
            n += 1
            lab = dict(LABELS, **d.get('labels', {}))
            rows = [(lab['what'], e['what']), (lab['reason'], e['reason']), (lab['other'], e['other'])]
            dl = ''.join(f'<dt>{esc(k)}</dt><dd>{esc(v)}</dd>' for k, v in rows)
            opts = ''.join(
                f'<label class="{"pick" if k == e["rec"] else ""}"><input type="radio" name="{e["id"]}" value="{k}"> '
                f'{esc(v)}' + (' <span class="tag">recommended</span>' if k == e['rec'] else '') + '</label>'
                for k, v in (e.get('choices') or CHOICES).items())
            body.append(
                f'<section class="item" id="{e["id"]}"><p class="grp">{n} of {total} · {esc(e["app"])}</p>'
                f'<h3>{esc(e["title"])}</h3><dl>{dl}</dl>'
                f'<p class="rec"><b>Recommendation: {esc(e.get("rec_text") or REC[e["rec"]])}.</b> {esc(e["rec_why"])}</p>'
                f'<div class="opts">{opts}</div>'
                f'<textarea data-id="{e["id"]}" placeholder="Notes (optional): a condition, a different fix, or your '
                f'reason"></textarea><details class="tech"><summary>Where this is written</summary>'
                f'<p><code>{esc(e["id"])}</code> · {esc(e["where"])}</p></details></section>')
        if key == 'keep':
            body.append('<p class="all"><button id="keepall">Keep as it is every item in this group I have not '
                        'answered</button> <span id="keepn"></span></p>')
    page = PAGE
    if d.get('opening'):
        page = re.sub(r'<p>Each app keeps a list.*?minutes\.</p>', lambda _: '<p>' + esc(d['opening']) + ' It takes about '
                      '__MIN__ minutes.</p>', page, count=1, flags=re.S)
    nc, nl, nk = (len(groups[k]) for k in ('change', 'later', 'keep'))
    sorted_p = ('<p>They are sorted by recommendation: %d to change, %d to check first, and %d to keep, which can be '
                'confirmed together with one button.</p>' % (nc, nl, nk)) if nl or nk else ''
    page = page.replace('__SORTED__', sorted_p)
    page = (page.replace('__N__', str(total)).replace('__MIN__', str(mins))
            .replace('__NC__', str(len(groups['change']))).replace('__NL__', str(len(groups['later'])))
            .replace('__NK__', str(len(groups['keep']))).replace('__ITEMS__', ''.join(body))
            .replace('__EXCL__', ''.join(f'<li>{esc(x)}</li>' for x in d['excluded']))
            .replace('__INTRO__', esc(d['intro']))
            .replace('__IDS__', json.dumps([e['id'] for e in d['entries']]))
            .replace('__KEEP__', json.dumps(groups['keep'])))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'index.html').write_text(page.replace("'accepted-review-20261119'", json.dumps(KEY))
                                    .replace("'accepted-review-answers.json'", json.dumps(KEY + '-answers.json')))
    print(OUT / 'index.html', total, 'entries, about', mins, 'min')


def cmd_fold(a):
    d = load()
    ans = json.loads(Path(a.answers).read_text())
    notes = ans.get('_notes', {})
    for i, e in enumerate(d['entries'], 1):
        pick = ans.get(e['id'])
        names = e.get('choices') or REC
        line = f"{i}. {e['id']} ({e['app']}): " + ((pick + ' = ' + names[pick]) if pick in names else pick or 'UNANSWERED')
        if pick and pick != e['rec']:
            line += f" (recommended: {REC[e['rec']]})"
        if notes.get(e['id']):
            line += f" — note: {notes[e['id']]}"
        print(line)
    if notes.get('_general'):
        print('General note:', notes['_general'])


PAGE = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Accepted issues review</title>
<style>
body{font:17px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;max-width:44em;margin:0 auto 4em;padding:0 1.1em;
color:#1f2328;background:#fafaf8}
#bar{position:sticky;top:0;z-index:2;background:#fafaf8;padding:.6em 0;border-bottom:1px solid #d0d0c8;display:flex;
gap:.8em;align-items:center;flex-wrap:wrap;font-size:.92em}#bar b{flex:1 1 auto}
button{font:inherit;padding:.3em .8em;border:1px solid #888;border-radius:6px;background:#fff;cursor:pointer}
h1{font-size:1.5em;margin:1em 0 .3em}.intro p{margin:.5em 0}
table{border-collapse:collapse;margin:.6em 0}td{padding:.3em .8em .3em 0;vertical-align:top;border-top:1px solid #e3e3dc}
td:first-child{font-weight:600;white-space:nowrap}
.box{background:#fff;border:1px solid #d0d0c8;border-radius:8px;padding:.5em 1em;margin:1em 0}.box h2{font-size:1em;margin:.4em 0}
h2.sec{font-size:1.25em;margin:2.2em 0 .1em;padding-top:.6em;border-top:3px solid #1f2328}
h2.sec .n{font-weight:400;color:#666;font-size:.8em}.lead{margin:.2em 0 1em;color:#444}
.item{background:#fff;border:1px solid #c4c4bc;border-left:6px solid #c4c4bc;border-radius:8px;padding:.7em 1.1em 1em;
margin:1.1em 0}.item.done{border-left-color:#2a9d6a}
.grp{color:#666;margin:0;font-size:.82em}h3{font-size:1.12em;margin:.1em 0 .5em;line-height:1.3}
dl{margin:0}dt{font-weight:600;margin-top:.6em;font-size:.82em;text-transform:uppercase;letter-spacing:.04em;color:#555}
dd{margin:.1em 0 0}.rec{background:#f1efe4;padding:.6em .8em;border-radius:6px;margin:.9em 0 .6em}
.opts label{display:block;padding:.28em .5em;border-radius:6px;cursor:pointer}.opts label:hover{background:#f3f3ee}
.opts label.pick{font-weight:600}.tag{font-weight:400;font-size:.78em;background:#1f2328;color:#fff;border-radius:4px;
padding:.05em .45em;margin-left:.3em}
textarea{width:100%;box-sizing:border-box;min-height:2.8em;margin-top:.5em;font:inherit;font-size:.92em;padding:.4em;
border:1px solid #c4c4bc;border-radius:6px}
details.tech{margin-top:.6em;font-size:.82em;color:#555}details.tech summary{cursor:pointer}
.all{margin:1.2em 0;padding:.8em 1em;background:#f1efe4;border-radius:8px}#keepn{color:#555;font-size:.9em}
</style>
<div id="bar"><b>Accepted issues: your call</b><span id="prog"></span>
<button id="next">Next unanswered</button><button id="dl">Download answers</button></div>
<div class="intro"><h1>Accepted issues that were really decisions</h1>
<p>Each app keeps a list of known issues, and every entry is marked queued, accepted or asked. A session marked these
__N__ accepted, giving a reason that made them sound settled or outside the suite's control. Each is really a choice
about what users get, and none was put to you. This sheet asks you to confirm or overturn each one. It takes about
__MIN__ minutes.</p>
__SORTED__
<div class="box"><h2>What each answer sets in motion</h2><table>
<tr><td>Change it</td><td>A piece of work is queued to make the change.</td></tr>
<tr><td>Keep it</td><td>It stays as it is, recorded as your decision, and is not asked again.</td></tr>
<tr><td>Ask me again</td><td>The open question is checked, and you are asked again with the answer.</td></tr></table>
<p>Answering changes nothing by itself. Answers save in this browser as you go. When you are done, press Download
answers and tell a session; it records each answer as your call and queues the work.</p></div></div>
__ITEMS__
<h2 class="sec">Anything else</h2>
<section class="item"><textarea data-id="_general" placeholder="A general note, or another accepted issue you want
looked at"></textarea></section>
<details class="tech"><summary>What this sheet leaves out, and how the list was made</summary>
<p>__INTRO__</p><ul>__EXCL__</ul></details>
<script>const IDS=__IDS__,KEEP=__KEEP__;const KEY='accepted-review-20261119';
let A={};try{A=JSON.parse(localStorage.getItem(KEY)||'{}')}catch(e){}A._notes=A._notes||{};
const save=()=>{try{localStorage.setItem(KEY,JSON.stringify(A))}catch(e){}prog()};
function prog(){const n=IDS.filter(i=>A[i]).length;document.getElementById('prog').textContent=n+' of '+IDS.length+' answered';
IDS.forEach(i=>document.getElementById(i).classList.toggle('done',!!A[i]));
const k=KEEP.filter(i=>!A[i]).length,kn=document.getElementById('keepn'),ka=document.getElementById('keepall');
if(kn)kn.textContent=k?k+' not yet answered':'all answered';if(ka)ka.disabled=!k;document.getElementById('next').disabled=n===IDS.length}
document.querySelectorAll('input[type=radio]').forEach(r=>{if(A[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{A[r.name]=r.value;save()})});
document.querySelectorAll('textarea').forEach(t=>{t.value=A._notes[t.dataset.id]||'';t.addEventListener('keydown',e=>e.stopPropagation());
t.addEventListener('input',()=>{if(t.value)A._notes[t.dataset.id]=t.value;else delete A._notes[t.dataset.id];save()})});
const kb=document.getElementById('keepall');if(kb)kb.onclick=()=>{KEEP.filter(i=>!A[i]).forEach(i=>{A[i]='keep';
document.querySelector('input[name="'+i+'"][value="keep"]').checked=true});save()};
document.getElementById('next').onclick=()=>{const i=IDS.find(i=>!A[i]);
if(i)document.getElementById(i).scrollIntoView({behavior:'smooth',block:'center'})};
document.getElementById('dl').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(
[JSON.stringify(A,null,1)],{type:'application/json'}));a.download='accepted-review-answers.json';a.click()};prog();</script>
"""


def main(argv=None):
    global DATA, OUT, KEY
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--data', help='the data file (default 17-accepted-review.json)')
    p.add_argument('--out', help='the output folder (default REHEARSAL/accepted-review)')
    s = p.add_subparsers(dest='cmd', required=True)
    s.add_parser('sheet').set_defaults(f=cmd_sheet)
    f = s.add_parser('fold')
    f.add_argument('answers')
    f.set_defaults(f=cmd_fold)
    a = p.parse_args(argv)
    if a.data:
        DATA = Path(a.data).resolve()
    if a.out:
        OUT = Path(a.out).expanduser()
    KEY = 'accepted-review-20261119' if DATA.name == '17-accepted-review.json' else DATA.stem
    a.f(a)


if __name__ == '__main__':
    main()
