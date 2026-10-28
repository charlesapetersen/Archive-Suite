#!/usr/bin/python3
"""The Mac half of a Sherlock batch (W46.sherlock-batch): pick the ready packs, send them, mark what was submitted,
and bring the results home. Run only in a session the owner starts, after he has opened the shared login
(execution-plans/sherlock-access.md); it refuses under ARCHIVE_UNATTENDED=1, as no-sherlock.sh does.

    batch_mac.py plan [--leave-out TAG]...   make a batch of every ready pack with a manifest; prints the reviews
    batch_mac.py send BATCH                  copy the packs, the batch and this kit to Sherlock; prints the commands
    batch_mac.py mark BATCH                  read submitted.tsv back: mark each pack submitted, release the left-out
    batch_mac.py fetch BATCH                 read collected.tsv back: copy each collected pack's results into its Mac
                                             folder, mark it finished and release it; release import failures

BATCH is the stamp `plan` prints (a folder in $AGENT_STATE/sherlock-batches/). Every command takes --dry-run, which
prints the remote commands and copies instead of running them. In between, on Sherlock, the session runs
`bash <remote batch>/kit/batch.sh submit <remote batch>` and later `… collect …` (batch.py).

A pack is ready when cluster-reach.py says so (held `ready to submit`, empty ledger) and has a manifest in packs/.
Released packs go back to the engine with plan-edit.sh release: a left-out or failed pack with its reason, so the
next session fixes it on the Mac; a collected one with its manifest's `release` note, so the next session scores it.
Results are copied with --ignore-existing: the Mac folder's freeze and inputs are never overwritten, and a returned
file that differs from the Mac copy is listed instead.

Test seam: SHERLOCK_BATCH_LOCAL=DIR makes "Sherlock" the local folder DIR (its GROUP_HOME), with no SSH at all.
"""
import datetime
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("AGENT_REPO") or os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
STATE = os.environ.get("AGENT_STATE") or os.path.expanduser("~/.local/state/archive-autonomous")
PLAN = os.environ.get("AUTONOMOUS_PLAN") or os.path.join(REPO, ".maintenance", "AUTONOMOUS_PLAN.md")
SCRIPTS = os.path.join(REPO, "ops", "autonomous")
BATCHES = os.path.join(STATE, "sherlock-batches")
LOCAL = os.environ.get("SHERLOCK_BATCH_LOCAL")
SSH = os.environ.get("CLUSTER_SSH") or "/usr/bin/ssh"
MAX_SEND_BYTES = 2 * 1024 ** 3          # beyond this a pack goes through the DTN, not the login node


def cluster_reach():
    spec = importlib.util.spec_from_file_location("cluster_reach", os.path.join(SCRIPTS, "cluster-reach.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def login():
    cr = cluster_reach()
    _, socket, host = cr.CLUSTERS["sherlock"]
    return os.path.expanduser(socket), host


def ssh_base():
    socket, host = login()
    return [SSH, "-S", socket, "-o", "ControlMaster=no", "-o", "BatchMode=yes", host]


def show(cmd):
    print("  $ " + " ".join(shlex.quote(c) for c in cmd))


def remote(script, dry):
    """Run a shell snippet on the login node (or locally under SHERLOCK_BATCH_LOCAL); its stdout."""
    if LOCAL:
        cmd = ["/bin/bash", "-c", script]
    else:
        cmd = ssh_base() + [script]
    if dry and not LOCAL:
        show(cmd)
        return ""
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=120,
                       env=dict(os.environ, GROUP_HOME=LOCAL) if LOCAL else None)
    if p.returncode != 0:
        raise SystemExit("remote command failed (%d): %s" % (p.returncode, p.stderr.strip()[-300:]))
    return p.stdout


def rsync(src, dst, dry, to_remote, extra=()):
    """rsync -a between the Mac and the login node; dst/src on the remote side is an absolute path."""
    if LOCAL:
        cmd = ["rsync", "-a"] + list(extra) + [src, dst]
    else:
        socket, host = login()
        rsh = "%s -S %s -o ControlMaster=no -o BatchMode=yes" % (SSH, shlex.quote(socket))
        if to_remote:
            cmd = ["rsync", "-a", "-e", rsh] + list(extra) + [src, "%s:%s" % (host, dst)]
        else:
            cmd = ["rsync", "-a", "-e", rsh] + list(extra) + ["%s:%s" % (host, src), dst]
    if dry:
        show(cmd)
        return ""
    if LOCAL and to_remote:
        os.makedirs(os.path.dirname(dst.rstrip("/")), exist_ok=True)
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        raise SystemExit("rsync failed (%d): %s" % (p.returncode, p.stderr.strip()[-300:]))
    return p.stdout


def archive_root(dry):
    """$GROUP_HOME/$USER/archive-suite on Sherlock, resolved by the login's own shell."""
    if LOCAL:
        return os.path.join(LOCAL, os.environ.get("USER", "cp1"), "archive-suite")
    out = remote('printf "%s/%s/archive-suite\\n" "$GROUP_HOME" "$USER"', dry).strip()
    if dry:
        return "$GROUP_HOME/$USER/archive-suite"
    if not out.startswith("/") or "//" in out:
        raise SystemExit("could not resolve $GROUP_HOME on Sherlock: %r" % out)
    return out


def batch_dir(stamp):
    d = os.path.join(BATCHES, stamp)
    if not os.path.isfile(os.path.join(d, "batch.tsv")):
        raise SystemExit("no batch %s (looked in %s)" % (stamp, d))
    return d


def packs_of(d):
    out = []
    with open(os.path.join(d, "batch.tsv")) as f:
        for ln in f:
            if ln.strip() and not ln.startswith("#"):
                tag, pack, man = ln.rstrip("\n").split("\t")[:3]
                with open(os.path.join(d, man)) as m:
                    out.append(json.load(m))
    return out


def tsv(path):
    try:
        with open(path) as f:
            return [ln.rstrip("\n").split("\t") for ln in f if ln.strip()]
    except OSError:
        return []


def mark(tag, state, dry):
    cmd = ["/usr/bin/python3", os.path.join(SCRIPTS, "cluster-reach.py"), "mark", tag, state]
    if dry:
        show(cmd)
        return
    subprocess.run(cmd, check=True)


def release(tag, note, dry):
    cmd = ["/bin/bash", os.path.join(SCRIPTS, "plan-edit.sh"), PLAN, "release", tag, note]
    if dry:
        show(cmd)
        return
    p = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if p.returncode != 0:
        print("  release %s failed (%d): %s; release it by hand" % (tag, p.returncode, p.stderr.strip()[-200:]))


# ---- commands ----------------------------------------------------------------------------------------------

def cmd_plan(args, dry):
    leave = {a for a in args if not a.startswith("--")}
    ready, collect = cluster_reach().sherlock_state(open(PLAN, errors="replace").read())
    pending = {}                       # packs in a batch that was made but not yet marked
    for b in sorted(os.listdir(BATCHES)) if os.path.isdir(BATCHES) else []:
        if not os.path.exists(os.path.join(BATCHES, b, "submitted.tsv")):
            for r in tsv(os.path.join(BATCHES, b, "batch.tsv")):
                pending[r[0]] = b
    rows, notes = [], []
    for tag, since, man in ready:
        if tag in pending:
            notes.append("%s: already in batch %s, not yet marked; mark it (or delete that batch folder if it was "
                         "never sent)" % (tag, pending[tag]))
        elif tag in leave:
            notes.append("%s: left out (--leave-out)" % tag)
        elif man is None:
            notes.append("%s: no manifest packs/%s.json; left out (the preparing session writes one)" % (tag, tag))
        elif not os.path.isdir(os.path.join(STATE, man["mac"])):
            notes.append("%s: its Mac folder %s is missing; left out" % (tag, man["mac"]))
        else:
            rows.append((tag, since, man))
    for n in notes:
        print(n)
    if collect:
        print("to collect (bash batch.sh collect on an earlier batch, then fetch): "
              + ", ".join("%s since %s" % c for c in collect))
    if not rows:
        print("no pack to send")
        return 1
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    d = os.path.join(BATCHES, stamp)
    if dry:
        print("would make batch %s:" % stamp)
    else:
        os.makedirs(os.path.join(d, "manifests"))
        with open(os.path.join(d, "batch.tsv"), "w") as f:
            for tag, _, man in rows:
                with open(os.path.join(d, "manifests", tag + ".json"), "w") as m:
                    json.dump(man, m, indent=2)
                f.write("%s\t%s\tmanifests/%s.json\n" % (tag, man["pack"], tag))
        print("batch %s:" % stamp)
    total = 0.0
    for tag, since, man in rows:
        total += float(man.get("gpu_hours") or 0)
        print("  %s  %s  %s jobs, at most %s GPU-hours; read its review first: %s"
              % (tag, man["pack"], man.get("jobs", "?"), man.get("gpu_hours", "?"), man.get("review", "(none)")))
    print("at most %g GPU-hours in all. Next: batch_mac.py send %s" % (total, stamp))
    return 0


def cmd_send(args, dry):
    stamp = args[0]
    d = batch_dir(stamp)
    packs = packs_of(d)
    size = 0
    for man in packs:
        for root, _, files in os.walk(os.path.join(STATE, man["mac"])):
            size += sum(os.path.getsize(os.path.join(root, f)) for f in files)
    if size > MAX_SEND_BYTES:
        raise SystemExit("%.1f GB is too much for the login node; send the packs through the DTN" % (size / 1024 ** 3))
    root = archive_root(dry)
    rb = "%s/batches/%s" % (root, stamp)
    for man in packs:
        rsync(os.path.join(STATE, man["mac"]) + "/", "%s/%s/" % (root, man["pack"]), dry, True)
    rsync(d + "/", rb + "/", dry, True, ["--exclude=*.tsv.remote"])
    rsync(HERE + "/", rb + "/kit/", dry, True, ["--exclude=__pycache__", "--exclude=*.pyc"])
    print("sent %d pack%s (%.0f MB). On Sherlock, in this session:" % (len(packs), "" if len(packs) == 1 else "s",
                                                                       size / 1024 ** 2))
    print("  bash %s/kit/batch.sh check %s" % (rb, rb))
    print("  bash %s/kit/batch.sh submit %s" % (rb, rb))
    print("then: batch_mac.py mark %s" % stamp)
    return 0


def pull(stamp, name, dry):
    """Copy a result table from the remote batch folder into the local one; its rows."""
    d = batch_dir(stamp)
    rb = "%s/batches/%s" % (archive_root(dry), stamp)
    local = os.path.join(d, name)
    rsync("%s/%s" % (rb, name), local, dry, False)
    return d, rb, tsv(local)


def cmd_mark(args, dry):
    stamp = args[0]
    d, _, rows = pull(stamp, "submitted.tsv", dry)
    if not rows and not dry:
        raise SystemExit("submitted.tsv is empty: was batch.sh submit run?")
    for r in rows:
        tag, pack, status = r[0], r[1], r[2]
        reason = r[4] if len(r) > 4 else ""
        if status == "submitted":
            mark(tag, "submitted", dry)
            print("%s: submitted (%s)" % (tag, r[3]))
        else:
            release(tag, "left out of Sherlock batch %s: %s; fix on the Mac and hold it again" % (stamp, reason), dry)
            print("%s: left out, handed back to the engine: %s" % (tag, reason))
    return 0


def cmd_fetch(args, dry):
    stamp = args[0]
    d, rb, rows = pull(stamp, "collected.tsv", dry)
    mans = {m["tag"]: m for m in packs_of(d)}
    if not rows and not dry:
        raise SystemExit("collected.tsv is empty: run batch.sh collect and let its job end first")
    for r in rows:
        tag, status, detail = r[0], r[1], (r[2] if len(r) > 2 else "")
        man = mans.get(tag)
        if man is None:
            continue
        if status == "waiting":
            print("%s: still running (%s); fetch again after the next collect" % (tag, detail))
            continue
        if status == "not-run":
            mark(tag, "clear", dry)
            release(tag, "Sherlock batch %s did not run it: %s; fix on the Mac and hold it again" % (stamp, detail), dry)
            print("%s: not run, handed back to the engine: %s" % (tag, detail))
            continue
        results = man["results"].replace("$GROUP_HOME/$USER/archive-suite", archive_root(dry))
        if "$" in results:
            print("%s: its manifest's results folder %s is not under $GROUP_HOME/$USER/archive-suite; fetch it by hand"
                  % (tag, man["results"]))
            continue
        mac = os.path.join(STATE, man["mac"])
        rsync(results.rstrip("/") + "/", mac + "/", dry, False, ["--ignore-existing"])
        differ = []
        if not dry:
            out = rsync(results.rstrip("/") + "/", mac + "/", False, False,
                        ["--dry-run", "--checksum", "--itemize-changes"])
            differ = [ln.split(" ", 1)[1] for ln in out.splitlines() if ln.startswith(">f") and "+++++++" not in ln]
        if differ:
            # A returned file with the name of one already here was not copied; scoring the old one would be wrong,
            # so the item is not released until the session has looked (the Mac copy is kept as it was).
            print("%s: copied into %s, but %d returned file%s differ from the Mac copy and were not copied: %s. Not "
                  "marked finished: compare them, then mark and release by hand." % (tag, mac, len(differ),
                  "" if len(differ) == 1 else "s", ", ".join(differ[:10])))
            continue
        note = man.get("release", "results collected")
        if status != "collected":
            note += "; some jobs did not complete (%s): inspect the failures before scoring" % detail
        mark(tag, "finished", dry)
        release(tag, "%s (Sherlock batch %s; results in %s)" % (note, stamp, mac), dry)
        print("%s: collected into %s%s" % (tag, mac, "" if status == "collected" else " (%s)" % detail))
    return 0


def main(argv):
    cmds = {"plan": (cmd_plan, 0), "send": (cmd_send, 1), "mark": (cmd_mark, 1), "fetch": (cmd_fetch, 1)}
    if len(argv) < 2 or argv[1] not in cmds:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 64
    fn, nargs = cmds[argv[1]]
    rest = [a for a in argv[2:] if a != "--dry-run"]
    dry = "--dry-run" in argv[2:]
    if os.environ.get("ARCHIVE_UNATTENDED") == "1" and not dry and not LOCAL:
        print("a Sherlock batch runs only in a session the owner starts; engine sessions may only dry-run",
              file=sys.stderr)
        return 2
    leave = []
    if argv[1] == "plan":
        it = iter(argv[2:])
        for a in it:
            if a == "--leave-out":
                leave.append(next(it, ""))
        rest = leave
    if len(rest) < nargs:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 64
    return fn(rest, dry)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
