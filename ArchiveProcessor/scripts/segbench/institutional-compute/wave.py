#!/usr/bin/env python3
"""W46.cluster-waves. Submit every ready job of a wave as a Slurm dependency chain, from one short login-node step.

  python3 wave.py submit WAVE.json [--profile NAME|FILE] [--only ID ...] [--dry-run]
  python3 wave.py status WAVE.json [--profile NAME|FILE]

Each job of the wave becomes three Slurm jobs, each triggering the next:

  pilot  the same mode, preset and input on its first three items (IC_LIMIT=3), into a separate folder, then a gate:
         every one of those items must have been read (OCR: parsed; seg: answered; text: a reply). A pilot that
         fails cancels the rest of its chain and writes results/<id>/status.json saying why.
  full   the whole run, `--dependency=afterok:<pilot>`. Bulk keeps its shards and its self-requeue (exit 75).
  score  a small CPU job, `--dependency=afterany:<full>`, that waits out any requeued bulk shard, runs the job's own
         `score` command if it has one, and copies the run's small files (summaries, pages.csv, failure and
         escalation logs) into results/<id>/ with a status.json. Transcripts, replies and images stay on scratch.

So only <IC_ROOT>/waves/<wave>/results/ needs to come back to the Mac. The pilot is submitted held and released only
after the whole chain has been accepted, so a refused score job never leaves a GPU job running unwatched.

A job is ready when its input is on the cluster (the pack's index file, a bulk folder with an image, NewsBench) and
it has no chain yet; `submit` sends the ready ones that fit under the profile's submitted-job limit and lists the
rest, so it can be run again after more input arrives or jobs finish. --dry-run prints every ready job's sbatch
commands and never calls Slurm, creates nothing and needs no setup. Exit 3: some job was not sent.

The wave file is JSON (see waves/example.json):
  {"wave": "NAME", "jobs": [{"id": "ID", "mode": "truth|seg|text|news|bulk", "preset": "auto|<preset>",
    "pack": DIR (truth/seg/text) | "in": DIR, "out": DIR?, "shards": N? (bulk),
    "hours": H?, "pilot_hours": 1?, "score_hours": 1?, "env": {"IC_...": "..."}?, "score": [argv]?}]}
Paths may use $IC_ROOT, $USER and $HOME. A score argv may use {full}, {pilot}, {results}, {wave_dir}; it runs from
this kit's directory with $IC_PY in place of a leading "python3".
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import profiles  # noqa: E402

PILOT = 3
MODES = ('truth', 'seg', 'text', 'news', 'bulk')
INDEX = {'truth': 'pack.json', 'seg': 'windows.jsonl', 'text': 'requests.jsonl'}
IMAGES = {'.jpg', '.jpeg', '.png', '.tif', '.tiff', '.webp'}   # cluster_ocr.IMAGES, without importing its deps
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}')
# Set by the wave for each stage; a job's own env may not override them.
RESERVED = {'IC_LIMIT', 'IC_RUNS', 'IC_LABEL', 'IC_IN', 'IC_OUT', 'IC_PACK', 'IC_SHARDS', 'IC_MODE', 'IC_CHAIN'}
SMALL = 20 * 1024 * 1024
SKIP_DIRS = {'replies', 'txt', '_meta', 'images'}
SLURM_ID = re.compile(r'[0-9]+(_[0-9]+)?')


# ---------------------------------------------------------------- the wave file

def load_wave(path, ic_root):
    data = json.loads(Path(path).read_text())
    if not isinstance(data.get('wave'), str) or not NAME.fullmatch(data['wave']):
        raise ValueError('wave: a name of letters, digits, _ . - (at most 64)')
    jobs, seen = data.get('jobs'), set()
    if not isinstance(jobs, list) or not jobs:
        raise ValueError('jobs: a nonempty list')
    env = dict(os.environ, IC_ROOT=ic_root)
    for j in jobs:
        jid = j.get('id')
        if not isinstance(jid, str) or not NAME.fullmatch(jid) or jid in seen:
            raise ValueError(f'job id {jid!r}: a unique name of letters, digits, _ . -')
        seen.add(jid)
        if j.get('mode') not in MODES:
            raise ValueError(f'{jid}: mode must be one of {", ".join(MODES)} (news-layout has no pilot)')
        if not isinstance(j.get('preset'), str) or not NAME.fullmatch(j['preset']):
            raise ValueError(f'{jid}: preset must be auto or a preset name')
        for key in ('pack', 'in', 'out'):
            if key in j:
                j[key] = expand(j[key], env, f'{jid}.{key}')
        if j['mode'] in INDEX and 'pack' not in j:
            raise ValueError(f'{jid}: {j["mode"]} needs "pack"')
        if j['mode'] == 'bulk' and 'in' not in j:
            raise ValueError(f'{jid}: bulk needs "in"')
        if 'shards' in j and (j['mode'] != 'bulk' or type(j['shards']) is not int or j['shards'] < 1):
            raise ValueError(f'{jid}: shards is a positive integer, for bulk only')
        for key in ('hours', 'pilot_hours', 'score_hours'):
            if key in j and (type(j[key]) not in (int, float) or j[key] <= 0):
                raise ValueError(f'{jid}: {key} must be a positive number')
        extra = j.get('env', {})
        if not isinstance(extra, dict) or any(
                not re.fullmatch(r'IC_[A-Z0-9_]+', k) or k in RESERVED or k.startswith('IC_WAVE')
                or not isinstance(v, str) for k, v in extra.items()):
            raise ValueError(f'{jid}: env maps IC_* names (not {", ".join(sorted(RESERVED))} or IC_WAVE_*) to strings')
        score = j.get('score')
        if score is not None and (not isinstance(score, list) or not score
                                  or not all(isinstance(s, str) for s in score)):
            raise ValueError(f'{jid}: score is an argv list of strings')
    return data


def expand(value, env, what):
    if not isinstance(value, str):
        raise ValueError(f'{what}: a path string')
    out = re.sub(r'\$(\w+)|\$\{(\w+)\}', lambda m: env.get(m.group(1) or m.group(2), m.group(0)), value)
    out = os.path.normpath(os.path.expanduser(out))
    if not os.path.isabs(out) or '$' in out or any(ord(c) < 32 for c in out):
        raise ValueError(f'{what}: must expand to an absolute path')
    return out


# ---------------------------------------------------------------- where a job's files live

def wave_dir(ic_root, wave):
    return Path(ic_root) / 'waves' / wave


def stage_dir(wd, job, stage):
    """The folder a stage's driver writes: what job.sbatch makes of IC_RUNS + IC_LABEL (or IC_OUT for bulk)."""
    if job['mode'] == 'bulk':
        return Path(job['out']) if stage == 'full' and job.get('out') else wd / job['id'] / 'bulk' / stage
    return wd / job['id'] / job['mode'] / stage


def results_dir(wd, jid):
    return wd / 'results' / jid


def ready(job, ic_root):
    """None when the job's input is on this machine, else what is missing."""
    mode = job['mode']
    if mode in INDEX:
        f = Path(job['pack']) / INDEX[mode]
        return None if f.is_file() else f'no {f}'
    if mode == 'news':
        return None if (Path(ic_root) / 'newsbench').is_dir() else f'no {ic_root}/newsbench (setup-layout.sh)'
    src = Path(job['in'])
    if not src.is_dir():
        return f'no {src}'
    return None if any(p.suffix.lower() in IMAGES for p in src.rglob('*')) else f'no images under {src}'


# ---------------------------------------------------------------- settings: profile, setup, limits

def read_env_file(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        parts = shlex.split(line)
        if len(parts) == 2 and parts[0] == 'export' and '=' in parts[1]:
            k, v = parts[1].split('=', 1); out[k] = v
    return out


def settings(profile, dry):
    """The selected profile's values, plus setup's runtime and live limits for a real submission (as submit.sh)."""
    active = read_env_file(HERE / 'compute.env') if (HERE / 'compute.env').is_file() else {}
    values = {k: str(v) for k, v in profiles.load(profile or active.get('IC_PROFILE') or 'farmshare').items()}
    if not dry:
        if active.get('IC_PROFILE') != values['IC_PROFILE'] or active.get('IC_PROFILE_SHA256') != values['IC_PROFILE_SHA256']:
            raise SystemExit('run setup.sh --profile for this profile revision first')
        if not (HERE / 'limits.env').is_file():
            raise SystemExit('run setup.sh first')
        values.update(active); values.update(read_env_file(HERE / 'limits.env'))
    return values


def cpu_args(cfg, minutes, name):
    """The score job's sbatch arguments: the profile's CPU partition, no GPU."""
    if not cfg.get('IC_CPU_PARTITION'):
        raise SystemExit('the profile has no slurm.cpu_partition, which a wave needs for its score jobs')
    a = [f'--partition={cfg["IC_CPU_PARTITION"]}', '--cpus-per-task=2', '--mem=8G',
         f'--time={min(minutes, int(cfg["IC_MAXWALL_MIN"]))}', f'--job-name=ic-wave-{name}',
         f'--output={cfg["IC_ROOT"]}/logs/%x-%j.out']
    if cfg.get('IC_CPU_QOS'):
        a.append(f'--qos={cfg["IC_CPU_QOS"]}')
    if cfg.get('IC_ACCOUNT'):
        a.append(f'--account={cfg["IC_ACCOUNT"]}')
    return a


def queued():
    """This user's queued job count, array tasks expanded (Slurm counts each task against MaxSubmitPU)."""
    r = subprocess.run(['squeue', '-h', '-r', '-u', os.environ.get('USER', ''), '-o', '%i'],
                       capture_output=True, text=True, check=True)
    return len(r.stdout.split())


def in_queue(ids):
    if not ids:
        return set()
    r = subprocess.run(['squeue', '-h', '-o', '%A', '-j', ','.join(ids)], capture_output=True, text=True)
    return set(r.stdout.split()) & set(ids) if r.returncode == 0 else set()


# ---------------------------------------------------------------- submit

def stage_env(job, wd, stage):
    env = dict(job.get('env', {}))
    env.update(IC_WAVE_DIR=str(wd / job['id']), IC_WAVE_STAGE=stage, IC_WAVE_JOB=job['id'],
               IC_RUNS=str(wd / job['id']), IC_LABEL=stage, IC_LIMIT=str(PILOT) if stage == 'pilot' else '')
    return env


def stage_cmd(job, wd, stage, profile, after, dry):
    cmd = ['bash', str(HERE / 'submit.sh'), '--profile', profile, job['mode'], job['preset'], '--parsable']
    if job['mode'] in INDEX:
        cmd += ['--pack', job['pack']]
    if job['mode'] == 'bulk':
        cmd += ['--in', job['in'], '--out', str(stage_dir(wd, job, stage)),
                '--shards', '1' if stage == 'pilot' else str(job.get('shards', 1))]
    hours = job.get('pilot_hours', 1) if stage == 'pilot' else job.get('hours')
    if hours is not None:
        cmd += ['--hours', str(hours)]
    cmd += ['--hold'] if stage == 'pilot' else ['--after', after]
    return cmd + (['--dry-run'] if dry else [])


def sbatch_id(stdout):
    """`sbatch --parsable` prints "ID" or "ID;cluster" as its last line."""
    last = (stdout.strip().splitlines() or [''])[-1].split(';')[0].strip()
    if not SLURM_ID.fullmatch(last):
        raise RuntimeError(f'no job ID in sbatch output: {stdout.strip()[-200:]!r}')
    return last


def submit_job(job, cfg, wd, profile, dry):
    """Pilot (held), full, score; then release the pilot. Returns the chain record."""
    ids = {}
    base = dict(os.environ, **{k: v for k, v in cfg.items()})
    try:
        for stage, after in (('pilot', None), ('full', 'pilot')):
            cmd = stage_cmd(job, wd, stage, profile, ids.get(after, f'<{after}>') if after else None, dry)
            r = subprocess.run(cmd, env=dict(base, **stage_env(job, wd, stage)), capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(f'{stage}: {r.stderr.strip() or r.stdout.strip()}')
            if dry:
                print(f'  {stage}: {r.stdout.strip().splitlines()[-1]}')
            else:
                ids[stage] = sbatch_id(r.stdout)
        score = ['sbatch', '--parsable', '--export=ALL', *cpu_args(cfg, int(job.get('score_hours', 1) * 60), 'score'),
                 f'--dependency=afterany:{ids.get("full", "<full>")}', str(HERE / 'wave.sbatch')]
        if dry:
            print('  score: ' + ' '.join(shlex.quote(s) for s in score))
            return None
        env = dict(base, IC_WAVE_DIR=str(wd / job['id']), IC_WAVE_STAGE='score', IC_WAVE_JOB=job['id'], IC_DIR=str(HERE))
        r = subprocess.run(score, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f'score: {r.stderr.strip() or r.stdout.strip()}')
        ids['score'] = sbatch_id(r.stdout)
        chain = {'wave': str(wd.name), 'job': job, 'cluster': cfg['CLUSTER_NAME'], 'ids': ids,
                 'shards': job.get('shards', 1) if job['mode'] == 'bulk' else 1, 'submitted': time.time()}
        write(wd / job['id'] / 'chain.json', chain)
        subprocess.run(['scontrol', 'release', ids['pilot']], check=True, capture_output=True, text=True)
        return chain
    except (RuntimeError, subprocess.CalledProcessError, OSError) as e:
        if ids:   # never leave half a chain: a held pilot, or a full run nothing scores
            subprocess.run(['scancel', *ids.values()], capture_output=True)
        (wd / job['id'] / 'chain.json').unlink(missing_ok=True)
        raise RuntimeError(f'{job["id"]}: {getattr(e, "stderr", None) or e}') from None


def cmd_submit(a):
    cfg = settings(a.profile, a.dry_run)
    profile = a.profile or cfg['IC_PROFILE']
    wave = load_wave(a.wave, cfg['IC_ROOT'])
    wd = wave_dir(cfg['IC_ROOT'], wave['wave'])
    jobs = [j for j in wave['jobs'] if not a.only or j['id'] in a.only]
    if a.only and len(jobs) != len(set(a.only)):
        raise SystemExit(f'--only names a job not in the wave: {sorted(set(a.only) - {j["id"] for j in jobs})}')
    room = None if a.dry_run else int(cfg['IC_MAXSUBMIT_PU']) - queued()
    print(f'wave {wave["wave"]} on {cfg["CLUSTER_NAME"]}: {wd}', flush=True)
    sent = skipped = 0
    for job in jobs:
        if not a.dry_run and (wd / job['id'] / 'chain.json').exists():
            print(f'{job["id"]}: already submitted (wave.py status)'); continue
        missing = ready(job, cfg['IC_ROOT'])
        if missing:
            print(f'{job["id"]}: not ready, {missing}'); skipped += 1; continue
        need = 2 + (job.get('shards', 1) if job['mode'] == 'bulk' else 1)
        if room is not None and need > room:
            print(f'{job["id"]}: not sent, needs {need} queue places and {room} are free; run again later')
            skipped += 1; continue
        print(f'{job["id"]}: {job["mode"]} {job["preset"]}', flush=True)
        if not a.dry_run:
            for d in ('state', 'logs'):
                (wd / job['id'] / d).mkdir(parents=True, exist_ok=True)
            (Path(cfg['IC_ROOT']) / 'logs').mkdir(parents=True, exist_ok=True)
        try:
            chain = submit_job(job, cfg, wd, profile, a.dry_run)
        except RuntimeError as e:
            print(f'  refused, nothing left queued: {e}', file=sys.stderr, flush=True); skipped += 1; continue
        if chain:
            room -= need; sent += 1
            print('  ' + ' -> '.join(f'{k} {v}' for k, v in chain['ids'].items()))
    if not a.dry_run:
        print(f'{sent} chain(s) sent, {skipped} not; results come back in {wd / "results"}')
    return 3 if skipped else 0


def cmd_status(a):
    cfg = settings(a.profile, True)
    wave = load_wave(a.wave, cfg['IC_ROOT'])
    wd = wave_dir(cfg['IC_ROOT'], wave['wave'])
    for job in wave['jobs']:
        status, chain = results_dir(wd, job['id']) / 'status.json', wd / job['id'] / 'chain.json'
        if status.exists():
            s = json.loads(status.read_text())
            print(f'{job["id"]}: {s["status"]}' + (f' ({s["reason"]})' if s.get('reason') else ''))
        elif chain.exists():
            ids = json.loads(chain.read_text())['ids']
            print(f'{job["id"]}: running, ' + ', '.join(f'{k} {v}' for k, v in ids.items()))
        else:
            print(f'{job["id"]}: not submitted')


# ---------------------------------------------------------------- inside the jobs

def write(path, obj):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp'); tmp.write_text(json.dumps(obj, indent=1)); tmp.replace(path)


def chain_of(jdir):
    return json.loads((Path(jdir) / 'chain.json').read_text())


def answered(job, d):
    """Items the stage's driver read successfully in folder d, by the driver's own record."""
    mode, d = job['mode'], Path(d)
    if mode in ('truth', 'news'):
        return sum(1 for f in (d / 'replies').glob('*.json') if json.loads(f.read_text())['meta'].get('status') == 'ok')
    if mode == 'bulk':   # a side file is written only with a parsed transcript
        return sum(1 for _ in (d / '_meta').rglob('*.json')) if (d / '_meta').is_dir() else 0
    rows = [json.loads(x) for x in (d / 'answers.jsonl').read_text().splitlines() if x.strip()] \
        if (d / 'answers.jsonl').exists() else []
    return sum(1 for r in rows if (r.get('status') == 'ok' if mode == 'seg' else bool(r.get('raw'))))


def items(job, ic_root):
    mode = job['mode']
    if mode in ('seg', 'text'):
        return sum(1 for x in (Path(job['pack']) / INDEX[mode]).read_text().splitlines() if x.strip())
    if mode == 'truth':
        return len(json.loads((Path(job['pack']) / 'pack.json').read_text())['jobs'])
    if mode == 'news':
        return max(0, len((Path(ic_root) / 'newsbench' / 'newsbench.csv').read_text().strip().splitlines()) - 1)
    return sum(1 for p in Path(job['in']).rglob('*') if p.suffix.lower() in IMAGES and p.is_file())


def cmd_gate(a):
    """The pilot's gate, run by job.sbatch after the pilot's driver exits 0. Nonzero fails the chain."""
    chain = chain_of(a.job_dir)
    job = chain['job']
    want = min(PILOT, items(job, os.environ['IC_ROOT']))
    got = answered(job, stage_dir(Path(a.job_dir).parent, job, 'pilot'))
    verdict = f'pilot gate: {got} of {want} items read'
    print(verdict)
    if want == 0 or got < want:
        (Path(a.job_dir) / 'gate.txt').write_text(verdict)   # for the failure report job.sbatch asks for next
        raise SystemExit(1)


def finish(jdir, status, reason=None):
    """Results for the Mac: status.json and the run's small files, never transcripts, replies or images."""
    jdir = Path(jdir); chain = chain_of(jdir); job = chain['job']; wd = jdir.parent
    res = results_dir(wd, job['id'])
    for stage in ('pilot', 'full'):
        src = stage_dir(wd, job, stage)
        if not src.is_dir():
            continue
        for f in src.rglob('*'):
            rel = f.relative_to(src)
            if (f.is_file() and not f.is_symlink() and not SKIP_DIRS & set(rel.parts[:-1])
                    and f.suffix in ('.json', '.jsonl', '.csv', '.md', '.tsv') and f.stat().st_size <= SMALL):
                (res / stage / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(f, res / stage / rel)
    states = {p.name: p.read_text().strip() for p in sorted((jdir / 'state').glob('*'))} if (jdir / 'state').is_dir() else {}
    write(res / 'status.json', {'wave': chain['wave'], 'job': job['id'], 'mode': job['mode'], 'preset': job['preset'],
                                'cluster': chain['cluster'], 'ids': chain['ids'], 'states': states,
                                'status': status, 'reason': reason, 't': time.time()})


def cmd_fail(a):
    """A failed pilot: cancel the rest of the chain, then report."""
    chain = chain_of(a.job_dir)
    rest = [chain['ids'][k] for k in ('full', 'score') if k in chain['ids']]
    r = subprocess.run(['scancel', *rest], capture_output=True, text=True)
    gate = Path(a.job_dir) / 'gate.txt'
    reason = (gate.read_text() + '; ' if gate.exists() else '') + a.reason
    reason += ('' if r.returncode == 0 else f'; scancel {" ".join(rest)} failed: {r.stderr.strip()}')
    finish(a.job_dir, 'pilot-failed', reason)
    print(f'pilot failed ({reason}); cancelled {" ".join(rest)}')


def parse_state(text):
    """job.sbatch writes 'rc=N job=ID' and, for a requeued bulk shard, 'requeued NEWID'."""
    rc = re.search(r'\brc=(\d+)', text); new = re.search(r'\brequeued (\S+)', text)
    return (int(rc.group(1)) if rc else None), (new.group(1) if new else None)


def cmd_score(a):
    """The score job: exit 75 with the job IDs to wait for, after writing them to score-wait; else report."""
    jdir = Path(a.job_dir); chain = chain_of(jdir); job = chain['job']
    wait, bad = [], []
    for task in range(chain['shards']):
        f = jdir / 'state' / f'full-{task}'
        rc, new = parse_state(f.read_text()) if f.exists() else (None, None)
        if new:
            if new in in_queue([new]):
                wait.append(new); continue
            rc, new = parse_state(f.read_text())   # it may have finished between the read and the queue check
            if new:
                bad.append(f'shard {task}: requeued job {new} left the queue without reporting'); continue
        if rc is None:
            bad.append(f'shard {task}: no exit recorded (killed, or never ran)')
        elif rc != 0:
            bad.append(f'shard {task}: exit {rc}')
    if wait:
        if int(os.environ.get('IC_SCORE_ROUND', '0')) >= int(os.environ.get('IC_CHAIN_MAX', '30')) + 1:
            finish(jdir, 'failed', f'still requeued after {os.environ.get("IC_SCORE_ROUND")} rounds: {" ".join(wait)}')
            return 1
        (jdir / 'score-wait').write_text(':'.join(wait))
        print(f'waiting for requeued shard job(s) {" ".join(wait)}')
        return 75
    if bad:
        finish(jdir, 'failed', '; '.join(bad)); return 1
    if job.get('score'):
        wd = jdir.parent
        subs = {'full': stage_dir(wd, job, 'full'), 'pilot': stage_dir(wd, job, 'pilot'),
                'results': results_dir(wd, job['id']), 'wave_dir': wd}
        argv = list(job['score'])
        for k, v in subs.items():   # literal placeholders only, so an inline program may use braces
            argv = [x.replace('{' + k + '}', str(v)) for x in argv]
        if argv[0] == 'python3':
            argv[0] = os.environ.get('IC_PY', sys.executable)
        subs['results'].mkdir(parents=True, exist_ok=True)
        r = subprocess.run(argv, cwd=HERE)
        if r.returncode != 0:
            finish(jdir, 'score-failed', f'score command exit {r.returncode}'); return 1
    finish(jdir, 'ok')
    return 0


def cmd_score_args(a):
    """For wave.sbatch's resubmission: the score job's sbatch arguments, one per line."""
    cfg = {k: os.environ.get(k, '') for k in ('IC_CPU_PARTITION', 'IC_CPU_QOS', 'IC_ACCOUNT', 'IC_MAXWALL_MIN', 'IC_ROOT')}
    job = chain_of(a.job_dir)['job']
    print('\n'.join(cpu_args(cfg, int(job.get('score_hours', 1) * 60), 'score')))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('submit'); p.add_argument('wave'); p.add_argument('--profile')
    p.add_argument('--only', nargs='+'); p.add_argument('--dry-run', action='store_true')
    p = sub.add_parser('status'); p.add_argument('wave'); p.add_argument('--profile')
    for name in ('gate', 'score', 'score-args'):
        sub.add_parser(name).add_argument('job_dir')
    p = sub.add_parser('fail'); p.add_argument('job_dir'); p.add_argument('reason')
    a = ap.parse_args()
    try:
        fn = {'submit': cmd_submit, 'status': cmd_status, 'gate': cmd_gate, 'fail': cmd_fail,
              'score': cmd_score, 'score-args': cmd_score_args}[a.cmd]
        sys.exit(fn(a) or 0)
    except (OSError, ValueError, KeyError) as e:
        sys.exit(f'wave.py {a.cmd}: {e}')


if __name__ == '__main__':
    main()
