#!/usr/bin/python3
"""Whether a cluster item can be offered now (W46.engine-cluster).

    cluster-reach.py check NAME          exit 0 if NAME's login answers, else 1; prints why
    cluster-reach.py mark TAG STATE      record where TAG's cluster jobs are: submitted|finished|in-box|clear
    cluster-reach.py ask                 the upkeep hook's once-a-day login request in the Daemon Report

An item names its cluster with a `(cluster: farmshare)` or `(cluster: sherlock)` marker. It is not a uses value,
because worker-state.py and the Agent Manager refuse unknown ones. The queue hook (ops/agent/hooks.py) offers such
an item only when `offer()` says so:

  * the cluster's login answers the bounded read-only preflight of execution-plans/farmshare-access.md, through
    the owner's existing SSH master (never a fresh login, never a password or Duo prompt); or
  * W46.box-collect is done, the item's ledger says `in-box`, and so only collection is left and Box has the files.

Otherwise the item is `blocked` with a reason starting `cluster NAME not reachable`, which the engine skips without
an alert. The upkeep hook then runs `ask`, which writes at most one Daemon Report line a day, without the words
that mark a mention, so the owner is emailed: which clusters to log in to, with the items ready to submit and the
items submitted or finished to collect. An item still waiting on a prerequisite is not counted: there is nothing to submit yet.

The ledger is one file per item, `$AGENT_STATE/cluster-jobs/<TAG>`, holding one word. A session that submits an
item's jobs writes `submitted`; one that sees them finish writes `finished`; the Box pickup (W46.box-collect)
writes `in-box`; the item's last session writes `clear` (deletes the file). No file means nothing submitted yet.

The preflight result is cached for CACHE_SECONDS in `$AGENT_STATE/cluster-reach/<NAME>.json`, so the queue hook,
which the engine runs often, costs at most one SSH round trip per cluster per five minutes. Stdlib only.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.environ.get("AGENT_STATE") or os.path.expanduser("~/.local/state/archive-autonomous")
REPO = os.environ.get("AGENT_REPO") or os.path.normpath(os.path.join(HERE, "..", ".."))
PLAN = os.environ.get("AUTONOMOUS_PLAN") or os.path.join(REPO, ".maintenance", "AUTONOMOUS_PLAN.md")
SSH = os.environ.get("CLUSTER_SSH") or "/usr/bin/ssh"          # the tests point this at a stub
GTIMEOUT = "/opt/homebrew/bin/gtimeout"
CACHE_SECONDS = 300
BOX_ITEM = "W46.box-collect"

# name -> (display name, control socket, login). Sherlock's entry names it for messages only: it is PREP_ONLY.
CLUSTERS = {
    "farmshare": ("FarmShare", "~/.ssh/cm-farmshare", "cp1@login.farmshare.stanford.edu"),
    "sherlock": ("Sherlock", "~/.ssh/cm-sherlock", "cp1@login.sherlock.stanford.edu"),
}
# Clusters no engine session may contact at all (owner, 2026-10-22; execution-plans/sherlock-access.md): Sherlock's
# /etc/agents rules forbid agent sessions a supervisor starts or feeds while nobody is there, even over SSH. Their
# items are offered for the Mac-side preparation only, with no preflight; the session stops at a ready-to-submit
# hold (plan-edit.sh hold) and an owner-started session submits. preflight() refuses them, so nothing here can SSH.
PREP_ONLY = {"sherlock"}
MARKER = re.compile(r"\(cluster:\s*([A-Za-z]+)\s*\)")
LEDGER_STATES = ("submitted", "finished", "in-box")
UNREACHABLE = re.compile(r"^cluster ([a-z]+) not reachable")


def cluster_of(text):
    """The item's cluster name, or None. An unknown name is returned as is, and is never reachable."""
    m = MARKER.search(text or "")
    return m.group(1).lower() if m else None


def preflight(name):
    """(ok, why): one bounded remote `hostname; id -un; pwd` through the existing master."""
    if name not in CLUSTERS:
        return False, "unknown cluster %r" % name
    if name in PREP_ONLY:
        return False, "%s is never contacted by the engine; an owner-started session submits" % CLUSTERS[name][0]
    _, socket, host = CLUSTERS[name]
    socket = os.path.expanduser(socket)
    if not os.path.exists(socket):
        return False, "no SSH master at %s; the owner logs in to open it" % socket
    cmd = [SSH, "-S", socket, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "ProxyCommand=false", host, "hostname; id -un; pwd"]
    if os.access(GTIMEOUT, os.X_OK):
        cmd = [GTIMEOUT, "--foreground", "-k", "3", "15"] + cmd   # ConnectTimeout alone did not bound a stall
    try:
        p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace",
                           timeout=25)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, "preflight failed: %s" % type(e).__name__
    if p.returncode != 0:
        tail = " ".join((p.stderr or p.stdout).split())[-160:]
        return False, "preflight exited %d%s" % (p.returncode, ": " + tail if tail else "")
    return True, "preflight answered: " + " ".join(p.stdout.split())[:120]


_seen = {}


def reachable(name, now=None):
    """(ok, why), from this run's memo, else the cache when it is fresh, else one preflight. The memo matters when
    the cache cannot be written: without it a stalled login would cost up to 25 s for EVERY marked item, and thirty
    of them would run the queue hook past its 300 s limit, which offers no work at all."""
    if name not in _seen:
        _seen[name] = _reachable(name, time.time() if now is None else now)
    return _seen[name]


def _reachable(name, now):
    path = os.path.join(STATE, "cluster-reach", name + ".json")
    try:
        with open(path) as f:
            c = json.load(f)
        if 0 <= now - float(c["at"]) < CACHE_SECONDS:
            return bool(c["ok"]), str(c["why"])
    except (OSError, ValueError, KeyError, TypeError):
        pass
    ok, why = preflight(name)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=name + ".")
        with os.fdopen(fd, "w") as f:
            json.dump({"ok": ok, "why": why, "at": now}, f)
        os.replace(tmp, path)
    except OSError:
        pass                                   # an unwritable cache costs a round trip, not a wrong answer
    return ok, why


def ledger(tag):
    try:
        with open(os.path.join(STATE, "cluster-jobs", tag), errors="replace") as f:
            word = f.read().strip()
    except OSError:
        return None
    return word if word in LEDGER_STATES else None


def offer(tag, text, box_collect_done, check=reachable):
    """(True, None) to offer the item; (False, reason) to skip it. Items without a marker are always offered."""
    name = cluster_of(text)
    if name is None:
        return True, None
    if box_collect_done and ledger(tag) == "in-box":
        return True, None
    if name in PREP_ONLY:
        # Mac-side work only; no SSH (PREP_ONLY above). Jobs already submitted there are the owner's to collect: a
        # session offered the item now would find nothing to score, so it waits for `mark TAG finished`.
        if ledger(tag) == "submitted":
            return False, "%s jobs submitted; an owner-started session collects them" % CLUSTERS[name][0]
        return True, None
    ok, why = check(name)
    if ok:
        return True, None
    return False, "cluster %s not reachable (%s)" % (name, why)


# ---- ask ----------------------------------------------------------------------------------------------------

def ask_text(rows, today):
    """The report line, or None when no cluster is holding back an otherwise-runnable item. A `submitted` item counts
    as one to collect: only a session that can reach the cluster can see its jobs end and mark it `finished`, so
    leaving it out would go quiet exactly when results are waiting behind an expired login."""
    counts = {}
    for d in rows:
        m = UNREACHABLE.match(d.get("reason") or "")
        if d.get("status") != "blocked" or not m or d.get("blocked_on"):
            continue
        state = ledger(d["tag"])
        if m.group(1) not in CLUSTERS:
            continue                           # a misspelt marker: nobody to ask to log in
        c = counts.setdefault(m.group(1), [0, 0])
        c[0 if state is None else 1] += 1
    parts = []
    for name, (submit, collect) in sorted(counts.items()):
        if submit or collect:
            label = CLUSTERS[name][0]
            parts.append("%s: %d item%s ready to submit, %d submitted or finished to collect"
                         % (label, submit, "" if submit == 1 else "s", collect))
    if not parts:
        return None
    # `- **[…]**` opens an entry under both of hooks.py report_entries() rules, so the ask is always its own entry.
    return ("- **[Cluster login]** (%s) — please log in so cluster work can go on (open the SSH master with Duo, "
            "execution-plans/farmshare-access.md). %s. Cluster items are skipped until the login answers; "
            "this asks at most once a day." % (today, "; ".join(parts)))


def ask(rows, today=None):
    """Write ask_text(rows) to the Daemon Report, at most once a day. The upkeep hook calls it (`ask` below) with
    the queue hook's rows, because only upkeep and gate may write the repo (Agent Manager CONTRACT.md). The day's
    stamp is created with O_EXCL, so two runs at once cannot both ask; a failed write removes it so a later run
    tries again."""
    today = today or datetime.date.today().isoformat()
    text = ask_text(rows, today)
    if text is None:
        return None
    stamp = os.path.join(STATE, "cluster-ask-" + today)
    try:
        os.close(os.open(stamp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
    except FileExistsError:
        return None
    try:
        p = subprocess.run(["/bin/bash", os.path.join(HERE, "plan-edit.sh"), PLAN, "report", text],
                           capture_output=True, text=True, errors="replace", timeout=120)
        if p.returncode != 0:
            raise RuntimeError("report failed (%d): %s" % (p.returncode, p.stderr.strip()[:200]))
    except BaseException:
        os.remove(stamp)
        raise
    for f in os.listdir(STATE):
        if f.startswith("cluster-ask-") and f != os.path.basename(stamp):
            try:
                os.remove(os.path.join(STATE, f))
            except OSError:
                pass
    return text


def queue_rows():
    p = subprocess.run(["/usr/bin/python3", os.path.join(HERE, "..", "agent", "hooks.py"), "queue"],
                       capture_output=True, text=True, errors="replace", timeout=240)
    if p.returncode not in (0, 2, 3):
        raise RuntimeError("queue hook exited %d: %s" % (p.returncode, p.stderr.strip()[:200]))
    return [json.loads(ln) for ln in p.stdout.splitlines() if ln.strip()]


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        ok, why = reachable(argv[2])
        print(why)
        return 0 if ok else 1
    if len(argv) == 4 and argv[1] == "mark" and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", argv[2]):
        path = os.path.join(STATE, "cluster-jobs", argv[2])
        if argv[3] == "clear":
            try:
                os.remove(path)
            except FileNotFoundError:
                pass
            return 0
        if argv[3] in LEDGER_STATES:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(argv[3] + "\n")
            return 0
    if len(argv) == 2 and argv[1] == "ask":
        text = ask(queue_rows())
        print("cluster-reach: asked the owner to log in" if text else "cluster-reach: nothing to ask")
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
