#!/usr/bin/env python3
"""Functional sampler proof: real shells/signals, scratch transports, no VM/network/GUI/real locks."""
from pathlib import Path
import json
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
LIB = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "ops/gui/tart-lib.sh"
PASS = 0


def check(value, label):
    global PASS
    assert value, label
    PASS += 1
    print("PASS", label, flush=True)


def snapshot():
    result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,stat="],
                            capture_output=True, text=True, check=True, timeout=2)
    return {int(pid): (int(parent), int(group), state)
            for pid, parent, group, state in (line.split() for line in result.stdout.splitlines())}


def run_case(root, name, body, *, mode="sample", blocked=True, status=0, fallback=False):
    work = root / name
    work.mkdir()
    env = dict(os.environ, PROOF_DIR=str(work), PROOF_MODE=mode, PROOF_BLOCKED=str(int(blocked)),
               PATH=str(root / "bin") + ":" + os.environ["PATH"])
    driver = work / "driver.sh"
    driver.write_text('''set -euo pipefail
. ''' + shlex.quote(str(LIB)) + '''
export PROOF_OWNER=$$
ready() {
  python3 - "$PROOF_DIR" "$1" <<'READY'
from pathlib import Path
import sys, time
p = Path(sys.argv[1]) / (sys.argv[2] + '.json')
for n in range(300):
    if p.exists(): break
    time.sleep(.01)
else: raise SystemExit('fixture did not become ready: ' + str(p))
READY
}
start() {
  tart_sampler_start 'vm space' "$PROOF_DIR/sampler.tsv" 60 ArchiveReader
  printf '%s\\n' "$TART_SAMPLER_PID" >> "$PROOF_DIR/samplers"
}
''' + body)

    def mask():
        signal.pthread_sigmask(signal.SIG_BLOCK if blocked else signal.SIG_UNBLOCK,
                               {signal.SIGTERM, signal.SIGHUP})

    proc = subprocess.Popen(["bash", str(driver)], env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, preexec_fn=mask, start_new_session=True)
    started = time.monotonic()
    try:
        output = proc.communicate(timeout=14)[0]
        check(proc.returncode == status, f"{name}: exit {status}: {output.strip()}")
        check(time.monotonic() - started < 12, f"{name}: bounded completion")
        check(("TERM grace expired" in output) == fallback, f"{name}: expected TERM/KILL path")
        rows = snapshot()
        for record in work.glob("*.json"):
            data = json.loads(record.read_text())
            check(data["pid"] not in rows or "Z" in rows[data["pid"]][2], f"{name}: {record.stem} stopped")
            check(data["term_blocked"] is False and data["hup_blocked"] == blocked,
                  f"{name}: {record.stem} TERM unblocked, unrelated HUP mask preserved")
        if (work / "samplers").exists():
            for pid in map(int, (work / "samplers").read_text().splitlines()):
                check(pid not in rows, f"{name}: sampler {pid} reaped")
                check(not any(group == pid and "Z" not in state for _, group, state in rows.values()),
                      f"{name}: no live sampler descendants")
        return work
    finally:
        # Emergency cleanup is confined to the private sessions created by this proof. Samplers keep
        # that session even though each has its own group. Never touch the actual VM or another run.
        for pid, (_, _, state) in snapshot().items():
            if "Z" not in state:
                try:
                    if os.getsid(pid) == proc.pid:
                        os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=3)


def cases(root):
    bin_dir = root / "bin"
    bin_dir.mkdir()
    tool = bin_dir / "tool.py"
    tool.write_text('''#!/usr/bin/env python3
from pathlib import Path
import json, os, signal, subprocess, sys, time
name = Path(sys.argv[0]).name
if name == 'ps':
    if os.environ.get('FAIL_PS') == '1': sys.exit(1)
    if os.environ.get('FAIL_PS') == 'hang': time.sleep(60)
    os.execv('/bin/ps', ['ps', *sys.argv[1:]])
if name == 'sysctl':
    print('{ 1.0 2.0 3.0 }' if sys.argv[-1] == 'vm.loadavg' else '1')
    sys.exit(0)
mode = os.environ['PROOF_MODE']
if name == 'descendant' or (name == 'tart' and mode == 'hang'):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])
p = Path(os.environ['PROOF_DIR']) / (name + '.json')
p.with_suffix('.tmp').write_text(json.dumps(dict(pid=os.getpid(), group=os.getpgrp(),
    session=os.getsid(0), term_blocked=signal.SIGTERM in mask, hup_blocked=signal.SIGHUP in mask)))
p.with_suffix('.tmp').replace(p)
assert signal.SIGTERM not in mask
assert (signal.SIGHUP in mask) == (os.environ['PROOF_BLOCKED'] == '1')
if name == 'tart':
    assert sys.argv[1:5] == ['exec', 'vm space', 'bash', '-c'], sys.argv
    if mode == 'hang':
        subprocess.Popen([str(Path(sys.argv[0]).with_name('descendant'))])
    elif mode == 'drop': sys.exit(1)
    else:
        print('1.5\\t20\\t30\\t40\\t5.0\\t600\\t7.0\\t800')
        sys.exit(0)
while True: time.sleep(.05)
''')
    tool.chmod(0o755)
    for name in ("tart", "sleep", "sysctl", "ps", "descendant"):
        (bin_dir / name).symlink_to(tool.name)

    for blocked in (True, False):
        work = run_case(root, f"sleep-{blocked}", '''start
ready sleep
python3 - "$PROOF_DIR" "$TART_SAMPLER_PID" <<'CHECK'
from pathlib import Path
import json, os, sys
p = Path(sys.argv[1])
for name in ('tart', 'sleep'):
    data = json.loads((p / (name + '.json')).read_text())
    assert data['group'] == int(sys.argv[2])
    assert data['session'] == os.getsid(0), 'sampler escaped heavy supervisor session'
CHECK
tart_sampler_stop
[ -z "$TART_SAMPLER_PID" ]
tart_sampler_stop
''', blocked=blocked)
        rows = (work / "sampler.tsv").read_text().splitlines()
        check(len(rows) == 2 and len(rows[0].split("\t")) == len(rows[1].split("\t")) == 11,
              f"sleep-{blocked}: original 11-column TSV sample preserved")
        check(rows[1].split("\t")[1:] == ['1.0', '1', '1.5', '20', '30', '40', '5.0', '600', '7.0', '800'],
              f"sleep-{blocked}: original host/guest values preserved")
    work = run_case(root, "hung-transport", """start
ready descendant
python3 - "$TART_SAMPLER_PID" "$PROOF_DIR" <<'WATCH' &
from pathlib import Path
import json, subprocess, sys, time
pid, directory = sys.argv[1], Path(sys.argv[2])
descendant = json.loads((directory / 'descendant.json').read_text())['pid']
for n in range(300):
    leader = subprocess.run(['/bin/ps', '-p', pid, '-o', 'stat='], capture_output=True, text=True)
    child = subprocess.run(['/bin/ps', '-p', str(descendant), '-o', 'stat='], capture_output=True, text=True)
    if (not leader.stdout.strip() or 'Z' in leader.stdout) and child.stdout.strip() and 'Z' not in child.stdout:
        (directory / 'leader-exited-first').touch()
        break
    time.sleep(.01)
else: raise SystemExit('did not observe leader exit before stubborn descendant')
WATCH
watcher=$!
tart_sampler_stop
wait "$watcher"
""", mode="hang", fallback=True)
    check((work / "leader-exited-first").exists(), "group authority retained after leader exits")
    work = run_case(root, "transport-drop", "start\nready sleep\ntart_sampler_stop\n", mode="drop")
    check(len((work / "sampler.tsv").read_text().splitlines()) == 1, "dropped transport leaves only header")
    run_case(root, "immediate-stop", "for ((n=0; n<12; n++)); do start; tart_sampler_stop; done\n")
    run_case(root, "already-exited", '''python3 "$TART_SAMPLER_HELPER" run true &
TART_SAMPLER_PID=$!
printf '%s\\n' "$TART_SAMPLER_PID" > "$PROOF_DIR/samplers"
wait "$TART_SAMPLER_PID"
tart_sampler_stop
''')
    run_case(root, "no-sampler", "tart_sampler_stop\n")
    run_case(root, "start-twice", "start\nready sleep\nstart\ntart_sampler_stop\n")
    for verdict, status, marker in (("succeeded", 0, "** TEST SUCCEEDED **"),
                                    ("failed", 7, "** TEST FAILED **"), ("unknown", 9, "incomplete")):
        run_case(root, f"verdict-{verdict}", f'''printf '%s\\n' {shlex.quote(marker)} > "$PROOF_DIR/test.log"
finish() {{
  local status=$?
  tart_sampler_stop || exit 1
  [ "$(tart_test_verdict "$PROOF_DIR/test.log")" = {verdict} ] || exit 1
  exit "$status"
}}
trap finish EXIT
start
ready sleep
exit {status}
''', status=status)
    for failure in ("1", "hang"):
        run_case(root, "inspection-" + failure, f'''start
ready sleep
if FAIL_PS={failure} tart_sampler_stop; then exit 9; fi
[ -n "$TART_SAMPLER_PID" ]
kill -0 "$TART_SAMPLER_PID"
tart_sampler_stop
''')
    peer = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        run_case(root, "foreign-pid", f'''TART_SAMPLER_PID={peer.pid}
if tart_sampler_stop; then exit 9; fi
[ "$TART_SAMPLER_PID" = {peer.pid} ]
''')
        check(peer.poll() is None, "foreign PID and caller group never signalled")
    finally:
        peer.kill()
        peer.wait(timeout=3)


if __name__ == "__main__":
    if os.environ.get("CODEX_SANDBOX"):
        print("Process inspection requires running this proof outside the Codex sandbox.", file=sys.stderr)
        sys.exit(3)
    with tempfile.TemporaryDirectory(prefix="VM sampler [scratch] ") as directory:
        cases(Path(directory))
    print(f"{PASS} checks passed")
