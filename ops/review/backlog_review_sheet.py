#!/usr/bin/env python3
"""The walkthrough's Backlog entries as one review sheet (owner, 2026-11-20: "create a sheet for my review so I can do
all of these at once. When relevant batch things together like the bugs").

Source: execution-plans/processing-review/18-backlog-review.json. Each item is one backlog entry, or a batch of
suspected bugs answered together, with a plain description, the recommendation and its reason, and its own answers.
Items an earlier owner call already settles are listed in their own section, answered "leave it settled" unless he
reopens one. A sibling of accepted_review_sheet.py, with its own wording.

  python3 ops/review/backlog_review_sheet.py sheet               # REHEARSAL/backlog-review/index.html
  python3 ops/review/backlog_review_sheet.py fold ANSWERS.json   # the owner's answers, one line each

Data: {"opening", "intro", "excluded": [..], "sections": [{"key", "title", "lead"}], "items": [{"id", "section",
"app", "title", "what", "now"?, "list"?: [..], "rec": choice key, "rec_why", "choices": {key: label}, "where",
"seconds"}]}. "list" is a batch's members, shown as a list under the description.

No model runs and no network: a reading page. Answers save in the browser and download as JSON; each item has a
notes box (typing in it never picks an answer); nothing changes until a session folds the answers.
"""
import argparse
import html
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'execution-plans/processing-review/18-backlog-review.json'
OUT = Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/backlog-review'
NEED = ['id', 'section', 'app', 'title', 'what', 'rec', 'rec_why', 'choices', 'where', 'seconds']


def load():
    d = json.loads(DATA.read_text())
    ids = [e['id'] for e in d['items']]
    if len(ids) != len(set(ids)):
        sys.exit('duplicate item ids')
    secs = [s['key'] for s in d['sections']]
    for e in d['items']:
        missing = [k for k in NEED if not e.get(k)]
        if missing or e['rec'] not in e['choices'] or e['section'] not in secs:
            sys.exit(f"{e.get('id')}: missing {missing}, rec {e.get('rec')!r} not a choice, or unknown section")
    return d


def cmd_sheet(_):
    d = load()
    esc = html.escape
    total = len(d['items'])
    entries = sum(len(e.get('list') or [1]) for e in d['items'])
    mins = max(1, round(sum(e['seconds'] for e in d['items']) / 60))
    body, recs, n = [], {}, 0
    for s in d['sections']:
        mine = [e for e in d['items'] if e['section'] == s['key']]
        if not mine:
            continue
        body.append(f'<h2 class="sec">{esc(s["title"])} <span class="n">{len(mine)} items</span></h2>'
                    f'<p class="lead">{esc(s["lead"])}</p>')
        for e in mine:
            n += 1
            recs[e['id']] = e['rec']
            dl = f'<dt>What it is</dt><dd>{esc(e["what"])}</dd>'
            if e.get('list'):
                dl += '<dd><ul class="members">' + ''.join(f'<li>{esc(x)}</li>' for x in e['list']) + '</ul></dd>'
            if e.get('now'):
                dl += f'<dt>Where it stands</dt><dd>{esc(e["now"])}</dd>'
            opts = ''.join(
                f'<label class="{"pick" if k == e["rec"] else ""}"><input type="radio" name="{e["id"]}" value="{k}"> '
                f'{esc(v)}' + (' <span class="tag">recommended</span>' if k == e['rec'] else '') + '</label>'
                for k, v in e['choices'].items())
            body.append(
                f'<section class="item" id="{e["id"]}"><p class="grp">{n} of {total} · {esc(e["app"])}</p>'
                f'<h3>{esc(e["title"])}</h3><dl>{dl}</dl>'
                f'<p class="rec"><b>Recommendation: {esc(e["choices"][e["rec"]])}.</b> {esc(e["rec_why"])}</p>'
                f'<div class="opts">{opts}</div>'
                f'<textarea data-id="{e["id"]}" placeholder="Notes (optional): a condition, an exception, or your '
                f'reason"></textarea><details class="tech"><summary>Where this is written</summary>'
                f'<p><code>{esc(e["id"])}</code> · {esc(e["where"])}</p></details></section>')
        ids = json.dumps([e['id'] for e in mine])
        body.append(f'<p class="all"><button class="takeall" data-ids=\'{esc(ids)}\'>Take the recommendation for '
                    f'every item in this group I have not answered</button> <span class="alln"></span></p>')
    page = (PAGE.replace('__OPEN__', esc(d['opening'])).replace('__N__', str(total)).replace('__E__', str(entries))
            .replace('__MIN__', str(mins)).replace('__ITEMS__', ''.join(body))
            .replace('__EXCL__', ''.join(f'<li>{esc(x)}</li>' for x in d['excluded']))
            .replace('__INTRO__', esc(d['intro'])).replace('__RECS__', json.dumps(recs))
            .replace('__KEY__', json.dumps(DATA.stem)))
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'index.html').write_text(page)
    print(OUT / 'index.html', total, 'items covering', entries, 'entries, about', mins, 'min')


def cmd_fold(a):
    d = load()
    ans = json.loads(Path(a.answers).read_text())
    notes = ans.get('_notes', {})
    for i, e in enumerate(d['items'], 1):
        pick = ans.get(e['id'])
        line = f"{i}. {e['id']} ({e['app']}): " + (f"{pick} = {e['choices'][pick]}" if pick in e['choices']
                                                   else pick or 'UNANSWERED')
        if pick and pick != e['rec']:
            line += f" (recommended: {e['rec']})"
        if notes.get(e['id']):
            line += f" — note: {notes[e['id']]}"
        print(line)
    if notes.get('_general'):
        print('General note:', notes['_general'])


PAGE = """<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Backlog review</title>
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
dd{margin:.1em 0 0}ul.members{margin:.4em 0;padding-left:1.2em}ul.members li{margin:.25em 0}
.rec{background:#f1efe4;padding:.6em .8em;border-radius:6px;margin:.9em 0 .6em}
.opts label{display:block;padding:.28em .5em;border-radius:6px;cursor:pointer}.opts label:hover{background:#f3f3ee}
.opts label.pick{font-weight:600}.tag{font-weight:400;font-size:.78em;background:#1f2328;color:#fff;border-radius:4px;
padding:.05em .45em;margin-left:.3em}
textarea{width:100%;box-sizing:border-box;min-height:2.8em;margin-top:.5em;font:inherit;font-size:.92em;padding:.4em;
border:1px solid #c4c4bc;border-radius:6px}
details.tech{margin-top:.6em;font-size:.82em;color:#555}details.tech summary{cursor:pointer}
.all{margin:1.2em 0;padding:.8em 1em;background:#f1efe4;border-radius:8px}.alln{color:#555;font-size:.9em}
</style>
<div id="bar"><b>Backlog review</b><span id="prog"></span>
<button id="next">Next unanswered</button><button id="dl">Download answers</button></div>
<div class="intro"><h1>The rest of the backlog, in one sheet</h1>
<p>__OPEN__</p>
<p>There are __N__ items covering __E__ entries. Suspected bugs are batched by app and kind, so one answer covers a
batch; use its notes box to take one out. It takes about __MIN__ minutes.</p>
<div class="box"><h2>What each answer sets in motion</h2><table>
<tr><td>Queue it</td><td>An engine item is filed and runs in its turn.</td></tr>
<tr><td>Behind nice-to-have</td><td>Filed, but waits behind the nice-to-have gate with the other end-of-project work.</td></tr>
<tr><td>Keep as a wish</td><td>Stays on its list, unqueued, recorded as your call.</td></tr>
<tr><td>Drop or close</td><td>Removed from its list, recorded as your call.</td></tr></table>
<p>Answering changes nothing by itself. Answers save in this browser as you go. When you are done, press Download
answers and tell a session; it records each answer as your call and files the work.</p></div></div>
__ITEMS__
<h2 class="sec">Anything else</h2>
<section class="item"><textarea data-id="_general" placeholder="A general note"></textarea></section>
<details class="tech"><summary>What this sheet leaves out, and how the list was made</summary>
<p>__INTRO__</p><ul>__EXCL__</ul></details>
<script>const RECS=__RECS__,IDS=Object.keys(RECS);const KEY=__KEY__;
let A={};try{A=JSON.parse(localStorage.getItem(KEY)||'{}')}catch(e){}A._notes=A._notes||{};
const save=()=>{try{localStorage.setItem(KEY,JSON.stringify(A))}catch(e){}prog()};
function prog(){const n=IDS.filter(i=>A[i]).length;document.getElementById('prog').textContent=n+' of '+IDS.length+' answered';
IDS.forEach(i=>document.getElementById(i).classList.toggle('done',!!A[i]));
document.querySelectorAll('.takeall').forEach(b=>{const left=JSON.parse(b.dataset.ids).filter(i=>!A[i]).length;
b.disabled=!left;b.nextElementSibling.textContent=left?left+' not yet answered':'all answered'});
document.getElementById('next').disabled=n===IDS.length}
document.querySelectorAll('input[type=radio]').forEach(r=>{if(A[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{A[r.name]=r.value;save()})});
document.querySelectorAll('textarea').forEach(t=>{t.value=A._notes[t.dataset.id]||'';t.addEventListener('keydown',e=>e.stopPropagation());
t.addEventListener('input',()=>{if(t.value)A._notes[t.dataset.id]=t.value;else delete A._notes[t.dataset.id];save()})});
document.querySelectorAll('.takeall').forEach(b=>b.onclick=()=>{JSON.parse(b.dataset.ids).filter(i=>!A[i]).forEach(i=>{
A[i]=RECS[i];document.querySelector('input[name="'+i+'"][value="'+RECS[i]+'"]').checked=true});save()});
document.getElementById('next').onclick=()=>{const i=IDS.find(i=>!A[i]);
if(i)document.getElementById(i).scrollIntoView({behavior:'smooth',block:'center'})};
document.getElementById('dl').onclick=()=>{const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(
[JSON.stringify(A,null,1)],{type:'application/json'}));a.download=KEY+'-answers.json';a.click()};prog();</script>
"""


def main(argv=None):
    global DATA, OUT
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--data', help='the data file (default 18-backlog-review.json)')
    p.add_argument('--out', help='the output folder (default REHEARSAL/backlog-review)')
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
    a.f(a)


if __name__ == '__main__':
    main()
