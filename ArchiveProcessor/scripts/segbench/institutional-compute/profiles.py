#!/usr/bin/env python3
"""Validated Slurm cluster profiles. Emits shell-quoted assignments; never executes profile contents."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex

HERE = Path(__file__).resolve().parent


def load(path):
    p = Path(path)
    if not p.is_file():
        p = HERE / 'profiles' / (str(path) + '.json')
    raw = p.read_bytes()
    data = json.loads(raw)
    if data.get('scheduler') != 'slurm':
        raise ValueError('this kit supports Slurm only (PBS/LSF need a submission and limits adapter)')
    name = data.get('name', '')
    if not isinstance(name, str) or not name.strip() or any(ord(c) < 32 for c in name) or len(name) > 100:
        raise ValueError('name must be a nonempty, single-line cluster display name (at most 100 characters)')
    slurm, gpu, runtime, paths = (data[k] for k in ('slurm', 'gpu', 'runtime', 'paths'))
    if not isinstance(runtime['modules'], list):
        raise ValueError('runtime.modules must be a list of module names')
    if not isinstance(gpu['name'], str) or not gpu['name'].strip() or any(ord(c) < 32 for c in gpu['name']):
        raise ValueError('gpu.name must be a nonempty single-line name')
    out = {'CLUSTER_NAME': name.strip(), 'IC_PROFILE': str(p.resolve()),
           'IC_PROFILE_SHA256': hashlib.sha256(raw).hexdigest(),
           'IC_PARTITION': slurm['partition'], 'IC_QOS': slurm['qos'], 'IC_ACCOUNT': slurm['account'],
           'IC_GPU_NAME': gpu['name'], 'IC_GPU_GRES_TYPE': gpu['gres_type'],
           'IC_CUDA_MODE': runtime['cuda_mode'], 'IC_CUDA_HOME': os.path.expandvars(runtime['cuda_home']),
           'IC_MODULES': ' '.join(runtime['modules'])}
    for key in ('IC_PARTITION', 'IC_QOS', 'IC_ACCOUNT', 'IC_GPU_GRES_TYPE'):
        if not isinstance(out[key], str) or (out[key] and not re.fullmatch(r'[A-Za-z0-9_.-]+', out[key])):
            raise ValueError(f'{key}: use a scheduler identifier, not shell syntax')
    if not out['IC_PARTITION']:
        raise ValueError('slurm.partition is required')
    if out['IC_CUDA_MODE'] not in ('pip-toolkit', 'modules'):
        raise ValueError('runtime.cuda_mode must be pip-toolkit or modules')
    if any(not isinstance(m, str) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_./+-]*', m) for m in runtime['modules']):
        raise ValueError('runtime.modules must contain module names')
    for field, key in [('wall_minutes', 'IC_MAXWALL_MIN'), ('max_gpus_per_user', 'IC_MAXGPU_PU'),
                       ('max_running_jobs', 'IC_MAXJOBS_PU'), ('max_submitted_jobs', 'IC_MAXSUBMIT_PU')]:
        out[key] = slurm[field]
    out['IC_GPUS_PER_NODE'], out['IC_GPU_MEMORY_GB'] = gpu['per_node'], gpu['memory_gb']
    for key in ('IC_MAXWALL_MIN', 'IC_MAXGPU_PU', 'IC_MAXJOBS_PU', 'IC_MAXSUBMIT_PU',
                'IC_GPUS_PER_NODE', 'IC_GPU_MEMORY_GB'):
        if type(out[key]) is not int or out[key] <= 0:
            raise ValueError(f'{key} must be a positive integer')
    if out['IC_GPU_MEMORY_GB'] < 24:
        raise ValueError('presets require at least 24 GB per GPU')
    cuda = out['IC_CUDA_HOME']
    if cuda and (not os.path.isabs(cuda) or '$' in cuda or any(ord(c) < 32 for c in cuda)):
        raise ValueError('runtime.cuda_home must be empty or expand to an absolute path')
    for field, key in [('scratch', 'IC_SCRATCH'), ('storage', 'IC_STORAGE')]:
        value = os.path.expanduser(os.path.expandvars(paths[field]))
        if not os.path.isabs(value) or '$' in value or any(ord(c) < 32 for c in value):
            raise ValueError(f'paths.{field} must expand to an absolute path (set its environment variables first)')
        out[key] = value
    out['IC_ROOT'] = str(Path(out['IC_SCRATCH']) / 'institutional-compute')
    return out


def shell(values):
    return ''.join(f'export {k}={shlex.quote(str(v))}\n' for k, v in values.items())


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('profile'); a = ap.parse_args()
    try:
        print(shell(load(a.profile)), end='')
    except (OSError, ValueError, KeyError, TypeError) as e:
        ap.error(str(e))


if __name__ == '__main__':
    main()
