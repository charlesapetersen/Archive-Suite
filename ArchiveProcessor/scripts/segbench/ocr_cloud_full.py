#!/usr/local/bin/python3
"""W41.ocr-panel-cloud: the full 99-original cloud panel, as the owner approved it on 2026-10-15.

  ocr_cloud_full.py prepare             # freeze the 99 originals; seed the pilot's ledger, catalogs and paid replies
  ocr_cloud_mistral.py --full DRIVER    # Mistral's own OCR endpoint, through the app's MistralClient
  ocr_cloud_full.py paid                # the OpenRouter routes, under the item's paid cap
  ocr_cloud_full.py sub claude|gpt5.6-sol|gpt5.6-luna   # the subscription routes (claude -p, codex exec)
  ocr_cloud_full.py report

Owner, second walkthrough 2026-10-15: Claude Sonnet 5.5 through `claude -p`; the OpenAI models through `codex
exec` where Codex offers that exact model (Sol and Luna; GPT-5.4 Mini is not offered, so it stays on OpenRouter).
$9 paid cap for the OpenRouter routes plus Mistral OCR, on top of the $0.312211 pilot. The pilot's ledger is
copied in whole, so CAP below is the item's total. Raw material stays in CACHE, outside git.
"""
from __future__ import annotations
import argparse
import concurrent.futures as cf
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time

import ocr_cloud as C
import ocr_panel as P
import ocr_truth as T

CACHE = Path(os.environ.get('OCR_CLOUD_FULL_CACHE',
                            Path.home() / 'Library/Caches/ArchiveSuiteRehearsal/ocr-panel-cloud'))
PILOT = C.CACHE
PILOT_SPENT = 0.312211
CAP = 9.31  # $9 approved + the pilot, rounded down
PAGES = 99
MISTRAL_RESERVE = PAGES * .004  # held apart from every chat reservation, as in the pilot
# GPT-5.6 Luna is the owner's OpenRouter fallback: Codex answered "Your workspace is out of credits" on the
# first full-run call, 2026-10-15. It keeps the pilot's exact route. GPT-5.6 Sol has no fallback.
PAID = {k: C.MODELS[k] for k in ('gemini3.1-pro', 'gemini3.5-flash', 'gemini3.8-flash', 'gemini3.5-flash-lite',
                                 'gpt5.4-mini', 'mistral-medium3.5', 'mistral-large4', 'qwen3.5-397b',
                                 'qwen3-vl-235b', 'gpt5.6-luna')}
# Added to the full panel only, never the pilot (owner, 2026-10-15): Qwen3.8 Flash-Next, whose 185 GB of weights cannot
# fit a FarmShare node. Alibaba is its one provider (precision unpublished); reasoning off. Called once, 2026-10-15.
ADDED = {'qwen3.8-flash': ('qwen/qwen3.8-flash', 'alibaba', None, 'off', None)}
PAID.update(ADDED)
CODEX_BIN = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
CLAUDE_BIN = '/Users/cp1/.local/bin/claude'
USAGE_SH = Path(__file__).resolve().parents[3] / 'ops/autonomous/usage-window.sh'
# route: (harness, model, effort). Codex's lowest effort for both is low; claude -p takes no effort flag.
SUB = {'claude-sonnet5.5': ('claude', 'claude-sonnet-5-5', None),
       'gpt5.6-sol': ('codex', 'gpt-5.6-sol', 'low'),
       'gpt5.6-luna': ('codex', 'gpt-5.6-luna', 'low')}
CLAUDE_GUARD = 85  # stop the claude route before it eats the end of the shared five-hour window
CALL_TIMEOUT_S = 900
_base_manifest = P.manifest


class UsageLimit(RuntimeError):
    pass


def manifest():
    m = _base_manifest()
    jobs = m['jobs']
    if (m.get('cap') != CAP or m.get('subscription') != json.loads(json.dumps(SUB)) or len(jobs) != PAGES
            or len({j['page'] for j in jobs}) != PAGES
            or any(j['scale'] != 'original' or j['id'] != j['page'] + '-original' for j in jobs)):
        raise SystemExit('not the approved full panel: 99 originals, approved routes and cap')
    return m


def configure():
    P.CACHE, P.MODELS, P.CAP = CACHE, PAID, CAP - MISTRAL_RESERVE
    P.body, P.manifest, P.endpoint, P.reservation = C.body, manifest, C.endpoint, C.reservation
    P.estimate = lambda: print(f'Item accounted ${P.spent():.6f} of ${CAP} (chat; OCR held apart)')
    os.environ['OCR_PANEL_CONCURRENCY'] = os.environ.get('OCR_PANEL_CONCURRENCY', '4')


def prepare():
    local = json.loads((C.LOCAL / 'manifest.json').read_text())
    if local['prompt'] != P.PROMPT:
        raise SystemExit('local/cloud prompt differs')
    jobs = [j for j in local['jobs'] if j['scale'] == 'original']
    m = {**local, 'jobs': jobs, 'models': PAID, 'subscription': SUB, 'cap': CAP}
    dest = CACHE / 'manifest.json'
    old = json.loads(dest.read_text()) if dest.exists() else None
    if old is not None and not fallback_added(old, json.loads(json.dumps(m))):
        raise SystemExit('full manifest changed; preserve the existing run')
    for j in jobs:
        src = C.LOCAL / 'images' / (j['id'] + '.jpg')
        if P.digest(src.read_bytes()) != j['sha256']:
            raise SystemExit('local frozen image changed')
        target = CACHE / 'images' / src.name
        if target.exists() and target.read_bytes() != src.read_bytes():
            raise SystemExit('full frozen image changed')
    if not (CACHE / 'calls.jsonl').exists():
        seed()
    elif old is not None:
        for key in set(PAID) - set(old['models']):
            copy_pilot_replies(key)
    for j in jobs:
        target = CACHE / 'images' / (j['id'] + '.jpg')
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(C.LOCAL / 'images' / target.name, target)
    P.save(dest, m)
    manifest()
    print(f'Frozen {len(jobs)} originals, {len(PAID)} paid routes, {len(SUB)} subscription routes; '
          f'item ledger ${P.spent():.6f} of ${CAP}')


def seed():
    """Carry the pilot over: its whole ledger (so the cap counts every dollar the item spent), its frozen
    catalogs (the prices every reservation uses), and its paid replies for the routes that stay paid."""
    pilot = [json.loads(l) for l in (PILOT / 'calls.jsonl').read_text().splitlines()]
    if abs(sum(r.get('cost', 0) for r in pilot) - PILOT_SPENT) > 1e-6 or list((PILOT / 'pending').glob('*.json')):
        raise SystemExit('pilot ledger is not the settled $0.312211 one')
    CACHE.mkdir(parents=True, exist_ok=True)
    shutil.copytree(PILOT / 'catalog', CACHE / 'catalog', dirs_exist_ok=True)
    for key in PAID:
        copy_pilot_replies(key)
    tmp = CACHE / 'calls.jsonl.tmp'
    tmp.write_text(''.join(json.dumps({**r, 'pilot': True}) + '\n' for r in pilot))
    tmp.replace(CACHE / 'calls.jsonl')


def copy_pilot_replies(key):
    for f in sorted((PILOT / 'responses' / key).glob('*.json')):
        dest = CACHE / 'responses' / key / f.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dest)


def fallback_added(old, new):
    """The one change a started full run accepts: a paid route added from the pilot's own routes, unchanged,
    that the full run has not yet called. Nothing else in the manifest may move."""
    added = set(new['models']) - set(old['models'])
    called = {r['key'] for r in P.records() if not r.get('pilot')}
    return ({**old, 'models': None} == {**new, 'models': None}
            and all(old['models'][k] == new['models'].get(k) for k in old['models'])
            and all(new['models'][k] == json.loads(json.dumps({**C.MODELS, **ADDED}.get(k))) for k in added)
            and not added & called)


def paid():
    manifest()
    C.validate_ledger()
    P.collect()
    C.validate_ledger()


# ---------------------------------------------------------------- subscription routes

def sub_path(route, job):
    return CACHE / 'sub' / route / (job['id'] + '.json')


def usage_percent():
    out = subprocess.run([str(USAGE_SH)], capture_output=True, text=True, timeout=60).stdout
    m = re.search(r'(\d+)% used', out)
    return int(m.group(1)) if m else None


LIMIT = re.compile(r'usage limit|session limit|hit your limit|rate limit|429|limit reached|out of credits', re.I)


def call_claude(model, wd):
    prompt = 'Read the image file page.jpg in the current folder with the Read tool, then answer.\n\n' + P.PROMPT
    env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE')}
    cmd = [CLAUDE_BIN, '-p', prompt, '--model', model, '--output-format', 'json', '--allowedTools', 'Read',
           '--permission-mode', 'default', '--no-session-persistence']
    r = subprocess.run(cmd, cwd=wd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                       timeout=CALL_TIMEOUT_S)
    try:
        out = json.loads(r.stdout)
    except json.JSONDecodeError:
        msg = (r.stdout + r.stderr)[-600:]
        raise (UsageLimit if LIMIT.search(msg) else RuntimeError)(msg) from None
    if out.get('is_error') or out.get('subtype') != 'success':
        msg = str(out.get('result') or out)[-600:]
        raise (UsageLimit if LIMIT.search(msg) else RuntimeError)(msg)
    u = out.get('usage') or {}
    return out.get('result') or '', {'input_tokens': u.get('input_tokens'),
                                     'cache_read_tokens': u.get('cache_read_input_tokens'),
                                     'cache_write_tokens': u.get('cache_creation_input_tokens'),
                                     'output_tokens': u.get('output_tokens'), 'turns': out.get('num_turns')}


def call_codex(model, effort, wd):
    import method_window_cues as WC
    prompt = 'The image attached is a photograph of the page. Answer from the image; do not run commands.\n\n' + P.PROMPT
    ans = wd / 'answer.txt'
    cmd = [CODEX_BIN, 'exec', '--skip-git-repo-check', '-s', 'read-only', '-m', model,
           '-c', f'model_reasoning_effort="{effort}"', '-C', str(wd), '-o', str(ans), '-i', str(wd / 'page.jpg'), '-']
    env = {k: v for k, v in os.environ.items() if not k.startswith('CODEX_') or k == 'CODEX_HOME'}
    r = subprocess.run(cmd, cwd=wd, env=env, input=prompt, capture_output=True, text=True, timeout=CALL_TIMEOUT_S)
    if r.returncode != 0 or not ans.exists():
        m = re.search(r'^ERROR: .*$', r.stdout + r.stderr, re.M)
        msg = m.group(0) if m else (r.stdout + r.stderr)[-600:]
        raise (UsageLimit if LIMIT.search(msg) else RuntimeError)(f'codex exit {r.returncode}: {msg}')
    return ans.read_text(), {'usage': WC.codex_usage(r.stdout + r.stderr)}


def subscription(route, concurrency=3):
    """One reading per page. A harness error (no answer at all) is tried once more; an answer that does not parse
    is a failed reading, never re-asked, like the paid routes. A usage limit stops the route, page left open."""
    if route not in SUB:
        raise SystemExit('unknown subscription route')
    harness, model, effort = SUB[route]
    m = manifest()
    todo = [j for j in m['jobs'] if not sub_path(route, j).exists()]
    print(f'{route}: {PAGES - len(todo)} cached, {len(todo)} to read', flush=True)
    stop, count, lock = threading.Event(), [0], threading.Lock()

    def one(job):
        if stop.is_set():
            return
        if harness == 'claude':
            with lock:
                count[0] += 1
                check = count[0] % 10 == 1
            if check and (usage_percent() or 0) >= CLAUDE_GUARD:
                stop.set(); print(f'{route}: five-hour window at {CLAUDE_GUARD}%+; stopping', flush=True); return
        image = CACHE / 'images' / (job['id'] + '.jpg')
        if P.digest(image.read_bytes()) != job['sha256']:
            raise SystemExit('image changed: ' + job['id'])
        errors = []
        for attempt in range(2):
            wd = CACHE / 'sub-work' / route / job['id']
            shutil.rmtree(wd, ignore_errors=True); wd.mkdir(parents=True)
            shutil.copyfile(image, wd / 'page.jpg')
            t0 = time.time()
            try:
                raw, meta = call_claude(model, wd) if harness == 'claude' else call_codex(model, effort, wd)
            except UsageLimit as e:
                stop.set(); print(f'{route}: usage limit, stopping: {str(e)[-200:]}', flush=True); return
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                errors.append(str(e)[-300:]); continue
            got = T.parse_draft(raw)
            P.save(sub_path(route, job), {'meta': {**meta, 'route': route, 'harness': harness, 'model': model,
                                                   'effort': effort, 'wall_s': round(time.time() - t0, 1),
                                                   'harness_errors': errors, 'status': 'ok' if got else 'failed',
                                                   't': time.time()},
                                          'parsed': got, 'raw': raw})
            print(f"{route} {job['id']} {'ok' if got else 'failed'} {time.time() - t0:.0f}s", flush=True)
            return
        P.save(sub_path(route, job), {'meta': {'route': route, 'harness': harness, 'model': model, 'effort': effort,
                                               'harness_errors': errors, 'status': 'failed', 't': time.time()},
                                      'parsed': None, 'raw': ''})
        print(f"{route} {job['id']} failed: harness error twice", flush=True)

    with cf.ThreadPoolExecutor(concurrency) as ex:
        list(ex.map(one, todo))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=['prepare', 'paid', 'sub', 'report'])
    ap.add_argument('route', nargs='?')
    a = ap.parse_args()
    configure()
    if a.command == 'prepare':
        prepare()
    elif a.command == 'paid':
        paid()
    elif a.command == 'sub':
        subscription(a.route, int(os.environ.get('OCR_SUB_CONCURRENCY', 3)))
    else:
        import ocr_cloud_full_report
        ocr_cloud_full_report.report()


if __name__ == '__main__':
    main()
