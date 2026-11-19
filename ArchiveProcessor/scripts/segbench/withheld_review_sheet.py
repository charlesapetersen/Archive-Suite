#!/usr/bin/env python3
"""W47.withheld-review. The features withheld for a quality floor before the owner's rule of 2026-11-18, for his review.

The owner's rule (CLAUDE.md, "Withholding a feature for a quality floor"; 14-owner-calls.md call 13): no feature, field
or route is withheld because a measurement falls short of a floor without his confirmation. This lists the withholdings
already made, from the app, `segbench-results/settings-routes.json`, the stage rules and the DONE entries, leaving out
his own calls and what was dropped for money, licence, safety or memory. The entries are
`execution-plans/processing-review/16-withheld-review.json`. Each carries two layers:

  the technical record   feature, where, floor, figure, loses, ship, why: paths, tags and intervals, for a session
  the owner's reading    plain, what, tested, released, wait (on an "ask again later" entry), plain_why: no paths,
                         tags or model shorthand, figures rounded, written for a reader who does not know the bench

The sheet shows the owner's reading and keeps the technical record folded under each item (owner, 2026-11-19: the
sheet is for a non-technical reader and carries only what the decision needs). A change to a figure is made in both.

  python3 withheld_review_sheet.py sheet               # REHEARSAL/withheld-review/index.html, sized in minutes
  python3 withheld_review_sheet.py md                  # rewrites 16-withheld-review.md from the JSON
  python3 withheld_review_sheet.py fold ANSWERS.json   # the owner's answers as calls, one line each

Order and numbers are the same in all three: by recommendation (release, ask again later, keep withheld), then the
JSON's order. The keep group has one button that takes the recommendation for every item in it still unanswered.

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
# What the owner reads beside each radio button. The values and their meaning are CHOICES'.
SHEET_CHOICES = {'release': 'Release it',
                 'label': 'Release it, with a note telling users how it tested',
                 'keep': 'Keep it held back. This becomes my decision and is not asked again',
                 'later': 'Ask me again after more testing'}
REC_WORD = {'release': 'release', 'label': 'release with a label', 'keep': 'keep withheld', 'later': 'ask again later'}
SHEET_REC = {'release': 'release it', 'label': 'release it, with a note on how it tested',
             'keep': 'keep it held back', 'later': 'ask again after more testing'}
FIELDS = [('where', 'Where the withholding is'), ('floor', 'The floor, and where it is written'),
          ('figure', 'The measured figure'), ('loses', 'What the user loses'),
          ('ship', 'What shipping it would take')]
PLAIN = ['plain', 'what', 'tested', 'released', 'plain_why']
# Sheet sections, in order: (key, the recs in it, heading, the line under the heading).
SECTIONS = [
    ('release', ('release', 'label'), 'Recommended: release',
     'These tested well enough to offer, most of them with a note that tells users how well. Each one you release '
     'becomes a piece of work to build.'),
    ('later', ('later',), 'Recommended: wait for one more test',
     'These have no fair or sufficient test yet. Each stays held back for now, the named test is queued, and you are '
     'asked again with the new figures.'),
    ('keep', ('keep',), 'Recommended: keep held back',
     'Each of these did worse than what the app already does, or made no difference. Read down the list, answer any '
     'you disagree with, then use the button for the rest.'),
]


def load():
    d = json.loads(DATA.read_text())
    ids = [e['id'] for e in d['entries']]
    if len(ids) != len(set(ids)):
        sys.exit('duplicate entry ids in ' + str(DATA))
    for e in d['entries']:
        need = [k for k, _ in FIELDS] + PLAIN + ['feature', 'rec', 'why', 'seconds']
        missing = [k for k in need if not e.get(k)]
        if missing or e['rec'] not in CHOICES:
            sys.exit(f"{e['id']}: missing {missing} or bad rec {e.get('rec')!r}")
        if (e['rec'] == 'later') != bool(e.get('wait')):
            sys.exit(f"{e['id']}: 'wait' goes with rec 'later' and with nothing else")
    # One order for the sheet, the page and the fold, so "item 7" is the same item in each.
    rank = {r: i for i, (_, recs, _, _) in enumerate(SECTIONS) for r in recs}
    d['entries'].sort(key=lambda e: rank[e['rec']])
    return d


def minutes(d):
    return max(1, round(sum(e['seconds'] for e in d['entries']) / 60))


def cmd_md(_):
    d = load()
    out = [f"# 16. Features withheld for a quality floor — for the owner's review (W47.withheld-review)", '',
           '*Built from `16-withheld-review.json` by `ArchiveProcessor/scripts/segbench/withheld_review_sheet.py md`; edit '
           'the JSON, not this page. This page is the technical record; the sheet shows the same entries in plain '
           'words, in the same order and with the same numbers.*', '', d['intro'], '',
           f"**{len(d['entries'])} entries, about {minutes(d)} minutes.** Recommendation counts: "
           + ', '.join(f"{REC_WORD[k]} {sum(e['rec'] == k for e in d['entries'])}" for k in CHOICES
                       if any(e['rec'] == k for e in d['entries'])) + '.', '']
    n = 0
    for _, recs, head, _ in SECTIONS:
        out += [f'## {head}', '']
        for e in (e for e in d['entries'] if e['rec'] in recs):
            n += 1
            out += [f"### {n}. {e['feature']} (`{e['id']}`)", '',
                    f"- **Stage:** {e.get('group', '')}. **On the sheet:** {e['plain']}"]
            out += [f'- **{label}:** {e[k]}' for k, label in FIELDS]
            out += [f"- **Recommendation: {REC_WORD[e['rec']]}.** {e['why']}", '']
    out += ['## Left out, and why', ''] + [f'- {x}' for x in d['excluded']] + ['']
    MD.write_text('\n'.join(out))
    print(MD, len(d['entries']), 'entries')


def cmd_sheet(_):
    d = load()
    OUT.mkdir(parents=True, exist_ok=True)
    esc = html.escape
    body, groups, n = [], {}, 0
    for key, recs, head, lead in SECTIONS:
        mine = [e for e in d['entries'] if e['rec'] in recs]
        groups[key] = [e['id'] for e in mine]
        body.append(f'<h2 class="sec" id="sec-{key}">{esc(head)} <span class="n">{len(mine)} items</span></h2>'
                    f'<p class="lead">{esc(lead)}</p>')
        for e in mine:
            n += 1
            rows = [('What it is', e['what']), ('How it tested', e['tested']), ('If you release it', e['released'])]
            if e.get('wait'):
                rows.append(('What it would wait for', e['wait']))
            plain = ''.join(f'<dt>{esc(k)}</dt><dd>{esc(v)}</dd>' for k, v in rows)
            tech = ''.join(f'<dt>{esc(lbl)}</dt><dd>{esc(e[k])}</dd>' for k, lbl in FIELDS)
            opts = ''.join(
                f'<label class="{"pick" if k == e["rec"] else ""}"><input type="radio" name="{e["id"]}" value="{k}"> '
                f'{esc(v)}' + (' <span class="tag">recommended</span>' if k == e['rec'] else '') + '</label>'
                for k, v in SHEET_CHOICES.items())
            body.append(
                f'<section class="item" id="{e["id"]}"><p class="grp">{n} of {len(d["entries"])} · '
                f'{esc(e.get("group", ""))}</p><h3>{esc(e["plain"])}</h3><dl>{plain}</dl>'
                f'<p class="rec"><b>Recommendation: {esc(SHEET_REC[e["rec"]])}.</b> {esc(e["plain_why"])}</p>'
                f'<div class="opts">{opts}</div>'
                f'<textarea data-id="{e["id"]}" placeholder="Notes (optional): a condition, different wording for '
                f'the note to users, or your reason"></textarea>'
                f'<details class="tech"><summary>Technical record (files, exact figures)</summary>'
                f'<p><b>{esc(e["feature"])}</b> · <code>{e["id"]}</code></p><dl>{tech}</dl>'
                f'<p><b>Recommendation: {esc(REC_WORD[e["rec"]])}.</b> {esc(e["why"])}</p></details></section>')
        if key == 'keep':
            body.append('<p class="all"><button id="keepall">Keep held back every item in this group I have not '
                        'answered</button> <span id="keepn"></span></p>')
    excl = ''.join(f'<li>{esc(x)}</li>' for x in d['excluded'])
    counts = {k: len(v) for k, v in groups.items()}
    page = (SHEET_HTML.replace('__N__', str(len(d['entries']))).replace('__MIN__', str(minutes(d)))
            .replace('__NREL__', str(counts['release'])).replace('__NLATER__', str(counts['later']))
            .replace('__NKEEP__', str(counts['keep']))
            .replace('__INTRO__', esc(d['intro'])).replace('__ALSO__', esc(d.get('also', '')))
            .replace('__PLAINEXCL__', esc(d.get('plain_excluded', '')))
            .replace('__ITEMS__', ''.join(body)).replace('__EXCL__', excl)
            .replace('__KEEP__', json.dumps(groups['keep']))
            .replace('__IDS__', json.dumps([e['id'] for e in d['entries']])))
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


SHEET_HTML = r"""<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Features held back: your call</title>
<style>
body{font:17px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;max-width:44em;margin:0 auto 4em;padding:0 1.1em;
color:#1f2328;background:#fafaf8}
#bar{position:sticky;top:0;z-index:2;background:#fafaf8;padding:.6em 0;border-bottom:1px solid #d0d0c8;display:flex;
gap:.8em;align-items:center;flex-wrap:wrap;font-size:.92em}#bar b{flex:1 1 auto}
button{font:inherit;padding:.3em .8em;border:1px solid #888;border-radius:6px;background:#fff;cursor:pointer}
h1{font-size:1.5em;margin:1em 0 .3em}.intro p{margin:.5em 0}
table{border-collapse:collapse;margin:.6em 0}td{padding:.3em .8em .3em 0;vertical-align:top;border-top:1px solid #e3e3dc}
td:first-child{font-weight:600;white-space:nowrap}
.box{background:#fff;border:1px solid #d0d0c8;border-radius:8px;padding:.5em 1em;margin:1em 0}
.box h2{font-size:1em;margin:.4em 0}
h2.sec{font-size:1.25em;margin:2.2em 0 .1em;padding-top:.6em;border-top:3px solid #1f2328}
h2.sec .n{font-weight:400;color:#666;font-size:.8em}.lead{margin:.2em 0 1em;color:#444}
.item{background:#fff;border:1px solid #c4c4bc;border-left:6px solid #c4c4bc;border-radius:8px;padding:.7em 1.1em 1em;
margin:1.1em 0}.item.done{border-left-color:#2a9d6a}
.grp{color:#666;margin:0;font-size:.82em}h3{font-size:1.12em;margin:.1em 0 .5em;line-height:1.3}
dl{margin:0}dt{font-weight:600;margin-top:.6em;font-size:.82em;text-transform:uppercase;letter-spacing:.04em;color:#555}
dd{margin:.1em 0 0}
.rec{background:#f1efe4;padding:.6em .8em;border-radius:6px;margin:.9em 0 .6em}
.opts label{display:block;padding:.28em .5em;border-radius:6px;cursor:pointer}.opts label:hover{background:#f3f3ee}
.opts label.pick{font-weight:600}.tag{font-weight:400;font-size:.78em;background:#1f2328;color:#fff;border-radius:4px;
padding:.05em .45em;margin-left:.3em}
textarea{width:100%;box-sizing:border-box;min-height:2.8em;margin-top:.5em;font:inherit;font-size:.92em;padding:.4em;
border:1px solid #c4c4bc;border-radius:6px}
details.tech{margin-top:.6em;font-size:.82em;color:#555}details.tech summary{cursor:pointer}
details.tech dt{text-transform:none;letter-spacing:0;font-size:1em}
.all{margin:1.2em 0;padding:.8em 1em;background:#f1efe4;border-radius:8px}#keepn{color:#555;font-size:.9em}
.end{margin-top:2.5em}
</style>
<div id="bar"><b>Features held back: your call</b><span id="prog"></span>
<button id="next">Next unanswered</button><button id="dl">Download answers</button></div>
<div class="intro">
<h1>Features held back: your call on each</h1>
<p>On 18 November you ruled that nothing is held back from the app for scoring too low unless you confirm it. Before
that rule, sessions had already held back __N__ things on their own judgement. This sheet asks you to confirm or
overturn each one. It takes about __MIN__ minutes.</p>
<p>They are sorted by what is recommended, so that your time goes where the answer is open: __NREL__ to release,
__NLATER__ that need one more test first, and __NKEEP__ to keep held back, which did worse than what the app already
does and can be confirmed together with one button.</p>
<div class="box"><h2>What each answer sets in motion</h2><table>
<tr><td>Release it</td><td>A piece of work is queued to build it into the app as an option.</td></tr>
<tr><td>Release it, with a note</td><td>The same, and the app tells users how well it tested, so they can judge
whether to use it.</td></tr>
<tr><td>Keep it held back</td><td>It stays out of the app. It is recorded as your decision and not asked again.</td></tr>
<tr><td>Ask me again</td><td>It stays out for now. The test named in the item is queued, and you are asked again when
it has figures.</td></tr></table>
<p>Answering changes nothing in the app by itself. Answers save in this browser as you go. When you are done, press
Download answers and tell a session; it records each answer as your call and queues the work.</p></div>
<div class="box"><h2>Reading the figures</h2>
<p>Reading scores are out of 100 and higher is better. As a guide, Apple Vision scores about 84 on your pages and the
best cloud reader about 97.</p>
<p>"Your 96 pages" are the 96 pages of your own material whose text you checked by hand. Other sets are public test
pages.</p>
<p>A tie means the difference is too small to tell apart from chance on that many pages.</p>
<p>The readers named: Apple Vision is built into the Mac, free and fast, and weak on handwriting. LightOnOCR is a
free download that reads handwriting. Gemini is Google's paid cloud model. A "large open model" is free to run but
needs a cluster or a large Mac.</p></div></div>
__ITEMS__
<h2 class="sec end">Anything else</h2>
<p class="lead">__ALSO__</p>
<section class="item"><textarea data-id="_general" placeholder="A general note, or something held back that this
sheet missed"></textarea></section>
<details class="tech"><summary>What this sheet leaves out, and how the list was compiled</summary>
<p>__PLAINEXCL__</p><p>__INTRO__</p><ul>__EXCL__</ul></details>
<script>const IDS=__IDS__,KEEP=__KEEP__;const KEY='w47-withheld-review';
const A=JSON.parse(localStorage.getItem(KEY)||'{}');A._notes=A._notes||{};
const save=()=>{localStorage.setItem(KEY,JSON.stringify(A));prog()};
function prog(){const n=IDS.filter(i=>A[i]).length;document.getElementById('prog').textContent=n+' of '+IDS.length+' answered';
IDS.forEach(i=>document.getElementById(i).classList.toggle('done',!!A[i]));
const k=KEEP.filter(i=>!A[i]).length;document.getElementById('keepn').textContent=k?k+' not yet answered':'all answered';
document.getElementById('keepall').disabled=!k;document.getElementById('next').disabled=n===IDS.length}
document.querySelectorAll('input[type=radio]').forEach(r=>{if(A[r.name]===r.value)r.checked=true;
r.addEventListener('change',()=>{A[r.name]=r.value;save()})});
document.querySelectorAll('textarea').forEach(t=>{t.value=A._notes[t.dataset.id]||'';t.addEventListener('keydown',e=>e.stopPropagation());
t.addEventListener('input',()=>{if(t.value)A._notes[t.dataset.id]=t.value;else delete A._notes[t.dataset.id];save()})});
document.getElementById('keepall').onclick=()=>{KEEP.filter(i=>!A[i]).forEach(i=>{A[i]='keep';
document.querySelector('input[name="'+i+'"][value="keep"]').checked=true});save()};
document.getElementById('next').onclick=()=>{const i=IDS.find(i=>!A[i]);
if(i)document.getElementById(i).scrollIntoView({behavior:'smooth',block:'center'})};
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
