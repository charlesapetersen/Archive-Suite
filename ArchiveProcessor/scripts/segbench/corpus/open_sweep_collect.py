#!/usr/bin/env python3
"""Bounded non-LLM collector: retrieve recorded jobs, never submit or retry inference."""
from pathlib import Path
import datetime
import json
import os
import subprocess
import sys
import time


def main():
    local, remote = Path(sys.argv[1]), sys.argv[2]
    ssh = ['/usr/bin/ssh', '-S', '/Users/cp1/.ssh/cm-farmshare', '-o', 'ControlMaster=no',
           '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ProxyCommand=false',
           'cp1@login.farmshare.stanford.edu']
    jobs = json.loads((local / 'jobs.json').read_text())
    marker = local / 'collection-started'
    with marker.open('x') as f:
        f.write(str(os.getpid()))
    state = {'phase': 'waiting', 'jobs': jobs, 'retrieved': [], 'states': {}}
    def mark():
        state['utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        tmp = local / 'collection-status.part'
        tmp.write_text(json.dumps(state, indent=2) + '\n')
        tmp.replace(local / 'collection-status.json')
    def pull(source, target):
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/usr/bin/rsync', '-a', '--timeout=60', '-e', ' '.join(ssh[:-1]),
                        ssh[-1] + ':' + source, str(target) + '/'], check=True, timeout=900)
    terminal = {'COMPLETED', 'FAILED', 'CANCELLED', 'TIMEOUT', 'OUT_OF_MEMORY', 'NODE_FAIL', 'PREEMPTED', 'BOOT_FAIL', 'DEADLINE'}
    try:
        for _ in range(960):  # 48 hours; no model/API/daemon usage
            cmd = 'sacct -n -X -P -j ' + ','.join(str(j['job']) for j in jobs.values()) + ' --format=JobIDRaw,State,ExitCode'
            raw = subprocess.run(['/opt/homebrew/bin/gtimeout', '--foreground', '-k', '3', '15', *ssh, cmd],
                                 text=True, capture_output=True, check=True, timeout=20).stdout
            states = {a[0]: a[1:3] for line in raw.splitlines() if (a := line.split('|'))}
            state['states'] = states
            for key, job in jobs.items():
                if key == 'setup' or key in state['retrieved']:
                    continue
                s = states.get(str(job['job']), [])
                if s and s[0].split()[0] in terminal:
                    pull(remote + '/' + key, local / 'outputs')
                    state['retrieved'].append(key)
            mark()
            if len(state['retrieved']) == len(jobs) - 1:
                pull(remote + '/logs/', local / 'remote-logs')
                state['phase'] = 'raw_collected_review_pending'
                mark()
                return
            time.sleep(180)
        raise RuntimeError('48-hour bound reached; inspect saved states before explicit recovery')
    except Exception as exc:
        state.update(phase='needs_inspection', error=str(exc))
        mark()
        raise


if __name__ == '__main__':
    main()
