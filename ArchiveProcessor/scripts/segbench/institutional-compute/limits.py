#!/usr/bin/env python3
"""Read Slurm's real limits on the cluster and write limits.env, which submit.sh fits every job to.

  limits.py [--out limits.env]

Asks Slurm, never the docs: `sinfo` for GPU partitions and their time limits, `sacctmgr` for the QOS limits
(MaxWall, MaxTRESPU gres/gpu, MaxJobsPU, MaxSubmitPU) and the user's associations, `scontrol` for which QOS each
partition allows, then `df`/`quota` for space. The docs (docs.farmshare.stanford.edu/slurm, 2026-10-15) and the
cluster disagree: the cluster reported the `gpu` QOS at gres/gpu=4 and 4 running jobs per user and `normal` at
gres/gpu=1, and GPU nodes in both the `normal` and `gpu` partitions, with `normal` refusing the `gpu` QOS. That is
why this reads Slurm. Parsing is pure functions, tested offline in test_institutional_compute.py.
"""
from __future__ import annotations
import argparse
import os
import re
import shutil
import subprocess
from profiles import load, shell


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ''


def minutes(limit: str) -> int | None:
    """Slurm time 'D-HH:MM:SS', 'HH:MM:SS', 'MM:SS', 'MM' -> minutes. 'infinite'/'UNLIMITED'/'' -> None."""
    limit = limit.strip()
    if not limit or limit.lower() in ('infinite', 'unlimited', 'n/a'):
        return None
    # Slurm's forms: M, M:S, H:M:S, D-H, D-H:M, D-H:M:S. Seconds are dropped.
    days = None
    if '-' in limit:
        d, limit = limit.split('-', 1); days = int(d)
    parts = [int(x) for x in limit.split(':')]
    if days is None:
        h, m = (0, parts[0]) if len(parts) <= 2 else (parts[0], parts[1])
    else:
        h, m = parts[0], (parts[1] if len(parts) > 1 else 0)
    return (days or 0) * 1440 + h * 60 + m


def gpu_partitions(sinfo: str):
    """`sinfo -h -o '%P|%G|%l|%D'` -> [(partition, gpus_per_node, max_minutes)] for partitions with GPUs."""
    out = {}
    for line in sinfo.splitlines():
        f = line.strip().split('|')
        if len(f) < 3:
            continue
        name, gres, limit = f[0].rstrip('*'), f[1], f[2]
        m = re.search(r'gpu(?::[\w.-]+)?:(\d+)', gres)
        if m:
            n = int(m.group(1))
            prev = out.get(name)
            out[name] = (max(n, prev[0]) if prev else n, minutes(limit))
    return [(k, *v) for k, v in out.items()]


def tres_gpu(tres: str) -> int | None:
    m = re.search(r'gres/gpu(?::[\w.-]+)?=(\d+)', tres)
    return int(m.group(1)) if m else None


def qos_table(sacct: str):
    """`sacctmgr -nP show qos format=Name,MaxWall,MaxTRESPU,MaxJobsPU,MaxSubmitPU` -> {name: limits}."""
    q = {}
    for line in sacct.splitlines():
        f = line.strip().split('|')
        if len(f) < 5 or not f[0]:
            continue
        q[f[0]] = {'maxwall': minutes(f[1]), 'gpus_pu': tres_gpu(f[2]),
                   'jobs_pu': int(f[3]) if f[3].isdigit() else None, 'submit_pu': int(f[4]) if f[4].isdigit() else None}
    return q


def user_qos(assoc: str):
    """`sacctmgr -nP show assoc user=$USER format=Partition,QOS` -> set of QOS names the user may use."""
    names = set()
    for line in assoc.splitlines():
        f = line.strip().split('|')
        if len(f) >= 2:
            names |= {x for x in f[1].split(',') if x}
    return names


def partition_qos(scontrol: str):
    """`scontrol -o show partition` -> {partition: set of QOS it allows, or None for ALL}."""
    out = {}
    for line in scontrol.splitlines():
        name = re.search(r'PartitionName=(\S+)', line)
        allow = re.search(r'AllowQos=(\S+)', line)
        if name:
            v = allow.group(1) if allow else 'ALL'
            out[name.group(1)] = None if v.upper() == 'ALL' else {x for x in v.split(',') if x}
    return out


def choose(parts, qos, allowed, allow_qos=None):
    """Pick the GPU partition and QOS PAIR that lets one user run the most GPUs, counting only a QOS the user's
    associations list AND the partition allows (FarmShare's `normal` partition has GPU nodes too, but allows only
    the normal/long/interactive/dev QOS, so `normal` + `gpu` is refused with "Invalid qos specification").
    Ties go to more GPUs per node, a QOS named like the partition, then the longer wall time.
    `allow_qos` is partition_qos()'s map; a partition missing from it is taken to allow every QOS."""
    if not parts:
        raise SystemExit('no partition with GPUs in sinfo; is this a Slurm login node?')
    allow_qos = allow_qos or {}
    if not allowed:
        print('WARNING: no QOS list for this user from sacctmgr; submitting without --qos')
    pairs = []
    for part in parts:
        ok = allow_qos.get(part[0])
        for n in qos:
            if n in allowed and (qos[n]['gpus_pu'] or 0) > 0 and (ok is None or n in ok):
                pairs.append((part, n))
    if pairs:
        part, best = max(pairs, key=lambda pn: (qos[pn[1]]['gpus_pu'] or 0, pn[0][1], pn[1] == pn[0][0],
                                                 min(w for w in (pn[0][2], qos[pn[1]]['maxwall'], 10**9) if w)))
    else:
        # If Slurm would not say, name no QOS: sbatch then uses the partition's default, which is always allowed,
        # where guessing one could be refused.
        part, best = max(parts, key=lambda p: (p[1], p[2] or 0)), None
    q = qos.get(best, {})
    walls = [w for w in (part[2], q.get('maxwall')) if w]
    gpus_pu = q.get('gpus_pu') or part[1]
    return {'IC_PARTITION': part[0], 'IC_QOS': best or '', 'IC_GPUS_PER_NODE': part[1],
            'IC_MAXWALL_MIN': min(walls) if walls else 1440, 'IC_MAXGPU_PU': gpus_pu,
            'IC_MAXJOBS_PU': q.get('jobs_pu') or gpus_pu, 'IC_MAXSUBMIT_PU': q.get('submit_pu') or 32}


def scratch_dir():
    user = os.environ.get('USER', '')
    for d in (os.environ.get('SCRATCH'), f'/scratch/users/{user}', f'/scratch/{user}'):
        if d and os.path.isdir(d) and os.access(d, os.W_OK):
            return d
    return ''


def constrain(profile, parts, qos, allowed, allow_qos):
    """Validate the chosen partition/QOS and lower the profile caps using live Slurm limits; never auto-switch."""
    matching = [p for p in parts if p[0] == profile['IC_PARTITION']]
    if not matching:
        raise ValueError('profile partition has no GPUs in sinfo')
    part = matching[0]
    name = profile['IC_QOS']
    if name:
        if name not in qos or name not in allowed:
            raise ValueError('profile QOS is not listed for this user; ask research computing to verify the association')
        allowed_here = allow_qos.get(part[0])
        if allowed_here is not None and name not in allowed_here:
            raise ValueError('profile QOS is not allowed on its partition')
    q = qos.get(name, {})
    observed = {'IC_GPUS_PER_NODE': part[1], 'IC_MAXWALL_MIN': min(w for w in
                (part[2], q.get('maxwall'), profile['IC_MAXWALL_MIN']) if w),
                'IC_MAXGPU_PU': q.get('gpus_pu'), 'IC_MAXJOBS_PU': q.get('jobs_pu'),
                'IC_MAXSUBMIT_PU': q.get('submit_pu')}
    return {k: min(profile[k], v) if v is not None else profile[k] for k, v in observed.items()}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--out', default='limits.env'); ap.add_argument('--profile', required=True); a = ap.parse_args()
    sinfo = run(['sinfo', '-h', '-o', '%P|%G|%l|%D'])
    qos = run(['sacctmgr', '-nP', 'show', 'qos', 'format=Name,MaxWall,MaxTRESPU,MaxJobsPU,MaxSubmitPU'])
    assoc = run(['sacctmgr', '-nP', 'show', 'assoc', f"user={os.environ.get('USER', '')}", 'format=Partition,QOS'])
    parts_qos = run(['scontrol', '-o', 'show', 'partition'])
    print('--- sinfo\n' + sinfo + '--- qos\n' + qos + '--- associations\n' + assoc + '--- partitions\n' + parts_qos)
    profile = load(a.profile)
    s = constrain(profile, gpu_partitions(sinfo), qos_table(qos), user_qos(assoc), partition_qos(parts_qos))
    for d in (os.environ.get('HOME'), profile['IC_SCRATCH']):
        if d:
            print('--- space', d, '\n' + run(['df', '-h', d]))
    if shutil.which('quota'):
        print('--- quota\n' + run(['quota', '-s']))
    with open(a.out, 'w') as f:
        f.write(shell(s))
    print(open(a.out).read(), end='')
    if not profile['IC_SCRATCH']:
        print('WARNING: no writable scratch found; set IC_SCRATCH in', a.out, 'before downloading models')


if __name__ == '__main__':
    main()
