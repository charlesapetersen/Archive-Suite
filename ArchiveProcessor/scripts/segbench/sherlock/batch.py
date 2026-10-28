#!/usr/bin/env python3
"""Submit and collect a batch of ready W46 packs on Sherlock in one owner-started session (W46.sherlock-batch).

Run on a Sherlock login node, through batch.sh (which sources sh.env), only in a session the owner starts:

    bash batch.sh check   BATCH [--dry-run]   check every pack's paths; queue nothing
    bash batch.sh submit  BATCH [--dry-run]   check, then submit the packs that pass, every job held, and one CPU
                                              job that imports each pack's chain and releases or cancels its jobs
    bash batch.sh collect BATCH [--dry-run]   one CPU job that copies each finished pack's job evidence into its
                                              results folder, so batch_mac.py fetch can bring it home

BATCH is the folder batch_mac.py send made: `batch.tsv` (tag, pack, manifest) and `manifests/<TAG>.json`, the pack
manifests from ArchiveProcessor/scripts/segbench/sherlock/packs/ (their fields are in packs/README.md). Each pack is
in `$GROUP_HOME/$USER/archive-suite/<pack>/`, as its hand-over says, and its own submit script runs unchanged:
`bash <pack>/<submit> <pack>`. What it adds is the order: no GPU job of any pack can start before that pack's
inputs were found and its code imported in the real environment, and a pack that fails is left out while the others
go on. The batch writes, in BATCH:

    submitted.tsv   tag, pack, status (submitted | left-out), job ids, reason
    imports.tsv     tag, status (released | cancelled), reason            (by the import job)
    collected.tsv   tag, status (collected | waiting | not-run), states   (by the collect job)

Rules kept from execution-plans/sherlock-access.md: the size-and-necessity review is read before `submit` (the
manifest names it, and `submit` prints each one); stages chain with --dependency inside each pack's own script;
nothing here polls the scheduler: the import and collect jobs each run once, and `collect` reads sacct once. Copies
inside Sherlock run in the collect job, never on the login node. A submission is never retried: a pack whose submit
script fails after some of its jobs were accepted has those held jobs cancelled and is reported, with its own
jobs.tsv reservation left for the owner's session to judge.

Python 3.6 (CentOS 7's python3): no f-string `=`, no walrus, no subprocess capture_output/text.
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM = os.path.join(HERE, "batch-shim")
# The variables a pack's files may use in a path that the check can resolve. Anything else ($ROOT, $SOURCE, a
# script's own locals) is skipped rather than guessed. sh.env exports the cluster ones; HOME and USER are the login's.
PATH_VARS = ("HOME", "USER", "GROUP_HOME", "SCRATCH", "FS_ROOT", "HF_HOME", "SH_IMG", "SH_SHIM", "SH_PPOCR_ENV",
             "SH_ENH_ENV", "SH_ENH_EXTRA")
SCANNED = (".json", ".jsonl", ".tsv", ".sh", ".env")
IGNORED_PREFIXES = ("/dev/", "/proc/", "/tmp/", "/sys/", "/etc/agents")
TERMINAL = ("COMPLETED", "FAILED", "CANCELLED", "TIMEOUT", "OUT_OF_MEMORY", "NODE_FAIL", "PREEMPTED", "BOOT_FAIL",
            "DEADLINE")
VAR = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
# A path-looking token in a shell file: absolute, ~/, or starting with a variable, at the start of a shell word (so
# not `sherlock/bin/py` or the `/v1/models` of a URL). Quotes and the characters that end a shell word stop it.
SH_TOKEN = re.compile(r"""(?<![\w}$/.:~-])(?:~/|/|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)[^\s"'`;|&<>()]*""")
# The overlay venvs sh.env names for every pack but only the PP-OCR and enhancement arms use: a pack that needs one
# lists it in its manifest's `requires`, so its absence leaves out only that pack.
OPTIONAL = ("$SH_PPOCR_ENV", "$SH_ENH_ENV", "$SH_ENH_EXTRA")
# An absolute path is checked when its top folder exists here or is one of these, so a Mac path (/Users/...) or a
# FarmShare home is still caught on Sherlock, while an HTTP route in inline code ('/v1/models') is not a path.
ROOTS = ("Users", "Volumes", "home", "scratch", "oak", "share", "farmshare")


def log(*a):
    print(*a, file=sys.stderr)


def run(cmd, **kw):
    """(returncode, stdout, stderr) without raising; text mode."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, **kw)
        out, err = p.communicate()
        return p.returncode, out, err
    except OSError as e:
        return 127, "", str(e)


# ---- the batch ---------------------------------------------------------------------------------------------

def archive_root():
    return os.path.join(os.environ["GROUP_HOME"], os.environ["USER"], "archive-suite")


def expand(s):
    """s with PATH_VARS and a leading ~/ expanded; None when any other variable is left in it."""
    if s.startswith("~/"):
        s = os.environ.get("HOME", "~") + s[1:]
    missing = []

    def sub(m):
        if m.group(1) in PATH_VARS and os.environ.get(m.group(1)):
            return os.environ[m.group(1)]
        missing.append(m.group(1))
        return m.group(0)
    s = VAR.sub(sub, s)
    return None if missing else s


def load_batch(batch):
    packs = []
    with open(os.path.join(batch, "batch.tsv")) as f:
        for ln in f:
            if not ln.strip() or ln.startswith("#"):
                continue
            tag, pack, manifest = ln.rstrip("\n").split("\t")[:3]
            with open(os.path.join(batch, manifest)) as m:
                man = json.load(m)
            if man.get("tag") != tag or man.get("pack") != pack:
                raise SystemExit("%s: manifest names %s/%s, batch.tsv %s/%s"
                                 % (manifest, man.get("tag"), man.get("pack"), tag, pack))
            man["dir"] = os.path.join(archive_root(), pack)
            packs.append(man)
    return packs


def read_tsv(path):
    try:
        with open(path) as f:
            return [ln.rstrip("\n").split("\t") for ln in f if ln.strip()]
    except OSError:
        return []


def write_tsv(path, rows):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for r in rows:
            f.write("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in r) + "\n")
    os.replace(tmp, path)


# ---- check: every path a pack's files name -----------------------------------------------------------------

def strings_of(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield k
            for s in strings_of(v):
                yield s
    elif isinstance(obj, list):
        for v in obj:
            for s in strings_of(v):
                yield s


def candidates(path):
    """Path-looking strings in one json, jsonl, tsv or shell file."""
    name = os.path.basename(path)
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError:
        return
    if name.endswith(".json"):
        try:
            for s in strings_of(json.loads(text)):
                yield s
        except ValueError:
            yield "!unparsable json"
    elif name.endswith(".jsonl"):
        for i, ln in enumerate(text.splitlines()):
            if ln.strip():
                try:
                    for s in strings_of(json.loads(ln)):
                        yield s
                except ValueError:
                    yield "!unparsable jsonl line %d" % (i + 1)
    elif name.endswith(".tsv"):
        for ln in text.splitlines():
            for cell in ln.split("\t"):
                yield cell.strip()
    else:
        for ln in text.splitlines():
            code = ln.split(" #", 1)[0] if not ln.lstrip().startswith("#") else ""
            for m in SH_TOKEN.finditer(code):
                yield m.group(0)


def check_pack(man):
    """A list of problems with the pack's inputs; empty when every resolvable path it names exists."""
    d = man["dir"]
    if not os.path.isdir(d):
        return ["pack folder %s is missing" % d]
    problems = []
    submit = os.path.join(d, man["submit"])
    if not os.path.isfile(submit):
        problems.append("submit script %s is missing" % submit)
    creates = [c for c in (expand(x) for x in list(man.get("creates", [])) + list(OPTIONAL)) if c]
    provenance = set(man.get("provenance", []))
    for req in man.get("requires", []):
        p = expand(req)
        if p is None or not os.path.exists(p):
            problems.append("required %s is missing" % req)
    top = set(os.listdir(d))
    for root, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x != "__pycache__"]
        for fn in files:
            if not fn.endswith(SCANNED):
                continue
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, d)
            if rel in provenance:
                continue
            for s in candidates(path):
                bad = check_string(s, d, top, creates)
                if bad:
                    problems.append("%s: %s" % (rel, bad))
    # One line per missing path, not one per mention.
    seen, out = set(), []
    for p in problems:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def check_string(s, d, top, creates):
    if s.startswith("!"):
        return s[1:]
    if not s or "\n" in s or len(s) > 4096 or "://" in s:
        return None
    if any(c in s for c in "*?%{<") and "${" not in s:
        return None                      # a glob or a Slurm %j pattern: the folder is made when the job starts
    if s.startswith(("/", "~/", "$")):
        p = expand(s.rstrip(",.:"))
        if p is None or not p.startswith("/") or p.count("/") < 2:
            return None
    else:
        first = s.split("/", 1)[0]
        if "/" not in s or first not in top:
            return None                  # a relative path is checked only when it starts inside the pack
        p = os.path.join(d, s)
    p = os.path.normpath(p)
    head = p.split("/")[1]
    if head not in ROOTS and not os.path.isdir("/" + head):
        return None
    if p.startswith(IGNORED_PREFIXES) or any(p == c or p.startswith(c.rstrip("/") + "/") for c in creates):
        return None
    if "$" in p:
        return None
    return None if os.path.exists(p) else "%s is missing" % p


# ---- submit ------------------------------------------------------------------------------------------------

def cmd_check(batch, dry):
    bad = 0
    for man in load_batch(batch):
        problems = check_pack(man)
        print("%s\t%s\t%s" % (man["tag"], "ok" if not problems else "fails", "; ".join(problems[:5])))
        bad += bool(problems)
    return 1 if bad else 0


def cmd_submit(batch, dry):
    out = os.path.join(batch, "submitted.tsv")
    if not dry:
        try:   # reserved before any sbatch, as the packs' own scripts do: a second run cannot submit twice
            os.close(os.open(out, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644))
        except FileExistsError:
            log("%s exists: this batch was submitted already; inspect it and squeue" % out)
            return 2
    packs = load_batch(batch)
    rows, ids_all = [], []
    for man in packs:
        review = man.get("review")
        print("== %s (%s): %s jobs, at most %s GPU-hours; review %s"
              % (man["tag"], man["pack"], man.get("jobs", "?"), man.get("gpu_hours", "?"), review or "(none)"))
        problems = check_pack(man)
        if problems:
            rows.append([man["tag"], man["pack"], "left-out", "-", "inputs: " + "; ".join(problems[:5])])
            print("   left out: %s" % "; ".join(problems[:5]))
            continue
        rc, ids, own, err = submit_pack(man, batch, dry)
        if rc != 0:
            cancel(ids + own, dry)
            rows.append([man["tag"], man["pack"], "left-out", ",".join(ids + own) or "-",
                         "submit script exited %d: %s" % (rc, " ".join(err.split())[-200:])])
            print("   left out: its submit script exited %d (held jobs cancelled: %s)" % (rc, ids + own or "none"))
            continue
        rows.append([man["tag"], man["pack"], "submitted", ",".join(ids) + ("|" + ",".join(own) if own else ""), ""])
        ids_all += ids + own
        print("   submitted, held: %s%s" % (" ".join(ids), " (its own holds: %s)" % " ".join(own) if own else ""))
    if not dry:
        write_tsv(out, rows)
    if not ids_all and not dry:
        print("nothing submitted")
        return 1 if any(r[2] == "left-out" for r in rows) else 0
    job = [os.path.join(HERE, "batch-job.sh"), HERE, "imports", batch]
    cmd = ["sbatch", "--parsable", "--partition=normal", "--cpus-per-task=2", "--mem=8G", "--time=00:30:00",
           "--job-name=w46-batch-imports", "--output=%s" % os.path.join(batch, "imports-%j.out")] + job
    if dry:
        log(" ".join(shlex.quote(c) for c in cmd))
        jid = "0"
    else:
        rc, so, se = run(cmd)
        jid = so.strip().split(";")[0]
        if rc != 0 or not jid.isdigit():
            print("the import job was not accepted (%d: %s); every pack's jobs stay held: release them with "
                  "scontrol release once their imports are checked by hand, or scancel them" % (rc, se.strip()))
            return 2
        with open(os.path.join(batch, "imports-job"), "w") as f:
            f.write(jid + "\n")
    print("import job %s: it releases each pack whose chain imports and cancels the rest (imports.tsv)" % jid)
    return 0


def submit_pack(man, batch, dry):
    """Run the pack's own submit script with sbatch shimmed to add --hold. (rc, held ids, ids the pack held itself,
    stderr)."""
    rec = os.path.join(batch, "ids-%s.tsv" % man["tag"])
    env = dict(os.environ)
    env["BATCH_IDS"] = rec
    if dry:
        env["BATCH_DRY"] = "1"
        cmd = ["bash", os.path.join(man["dir"], man["submit"]), man["dir"], "--dry-run"]
    else:
        cmd = ["bash", os.path.join(man["dir"], man["submit"]), man["dir"]]
    real = run(["bash", "-c", "command -v sbatch"])[1].strip()
    env["BATCH_REAL_SBATCH"] = real
    env["PATH"] = SHIM + os.pathsep + env.get("PATH", "")
    rc, so, se = run(cmd, env=env, cwd=man["dir"])
    sys.stdout.write("".join("   | %s\n" % ln for ln in so.splitlines()[-20:]))
    ids, own = [], []
    for r in read_tsv(rec):
        (own if len(r) > 1 and r[1] == "own-hold" else ids).append(r[0])
    return rc, ids, own, se


def cancel(ids, dry):
    if ids and not dry:
        run(["scancel"] + ids)


# ---- the import job ----------------------------------------------------------------------------------------

def import_check(man):
    """(ok, why): each import group's modules in the real environment ($FS_PY, the vLLM image)."""
    py = os.environ.get("FS_PY") or "python3"
    for grp in man.get("imports", []):
        mods = grp.get("modules") or []
        if not mods:
            continue
        path = os.path.join(man["dir"], grp["dir"]) if grp.get("dir") else ""
        code = ("import importlib, sys\n"
                "sys.path[:0] = [p for p in sys.argv[1:2] if p]\n"
                "for m in sys.argv[2:]:\n"
                "    importlib.import_module(m)\n")
        rc, so, se = run([py, "-c", code, path] + mods, cwd=man["dir"])
        if rc != 0:
            tail = " ".join((se or so).split())[-300:]
            return False, "import %s failed (%d): %s" % (",".join(mods), rc, tail)
    return True, ""


def cmd_imports(batch, dry):
    packs = {m["tag"]: m for m in load_batch(batch)}
    rows = []
    for r in read_tsv(os.path.join(batch, "submitted.tsv")):
        tag, status, ids = r[0], r[2], r[3]
        if status != "submitted" or tag not in packs:
            continue
        held = ids.split("|")[0].split(",") if ids not in ("", "-") else []
        ok, why = import_check(packs[tag])
        if ok:
            rc, so, se = (0, "", "") if dry else run(["scontrol", "release", ",".join(held)])
            if rc != 0:
                rows.append([tag, "held", "imports ok, but scontrol release failed: %s; release by hand"
                             % " ".join(se.split())[-200:]])
            else:
                rows.append([tag, "released", ""])
        else:
            if not dry:
                run(["scancel"] + held + (ids.split("|")[1].split(",") if "|" in ids else []))
            rows.append([tag, "cancelled", why])
        print("\t".join(rows[-1]))
    if not dry:
        write_tsv(os.path.join(batch, "imports.tsv"), rows)
    return 0


# ---- collect -----------------------------------------------------------------------------------------------

def cmd_collect(batch, dry):
    """Login node: submit the one CPU job that does the copies (Sherlock keeps copies off its login nodes)."""
    if not read_tsv(os.path.join(batch, "submitted.tsv")):
        print("no submitted.tsv in %s: nothing was submitted from this batch" % batch)
        return 1
    job = [os.path.join(HERE, "batch-job.sh"), HERE, "copy", batch]
    cmd = ["sbatch", "--parsable", "--partition=normal", "--cpus-per-task=2", "--mem=4G", "--time=01:00:00",
           "--job-name=w46-batch-collect", "--output=%s" % os.path.join(batch, "collect-%j.out")] + job
    if dry:
        log(" ".join(shlex.quote(c) for c in cmd))
        return cmd_copy(batch, True)
    rc, so, se = run(cmd)
    if rc != 0:
        print("the collect job was not accepted (%d): %s" % (rc, se.strip()))
        return 2
    print("collect job %s: when it ends, collected.tsv says what is ready; then batch_mac.py fetch on the Mac"
          % so.strip())
    return 0


def sacct_states(ids):
    """{job id: (state, elapsed, alloc tres)}, from one sacct call (array and step rows folded into their job)."""
    if not ids:
        return {}
    rc, so, se = run(["sacct", "-X", "-n", "-P", "-j", ",".join(ids), "-o", "JobID,State,Elapsed,AllocTRES"])
    out = {}
    for ln in so.splitlines():
        f = ln.split("|")
        if len(f) >= 4:
            out[f[0].split("_")[0].split(".")[0]] = (f[1].split()[0] if f[1] else "", f[2], f[3])
    return out


def cmd_copy(batch, dry):
    """The collect job: for each released pack whose jobs have all ended, copy its job evidence (the manifest's
    `collect` paths) into its results folder with an sacct record. The GPU jobs copy their own outputs there."""
    packs = {m["tag"]: m for m in load_batch(batch)}
    imports = {r[0]: r for r in read_tsv(os.path.join(batch, "imports.tsv"))}
    rows = []
    for r in read_tsv(os.path.join(batch, "submitted.tsv")):
        tag, status, ids = r[0], r[2], r[3]
        if status != "submitted" or tag not in packs:
            continue
        man = packs[tag]
        imp = imports.get(tag)
        if not imp:
            rows.append([tag, "not-run", "the import job has not recorded this pack (imports.tsv)"])
            continue
        if imp[1] == "cancelled":
            rows.append([tag, "not-run", "import check failed: " + (imp[2] if len(imp) > 2 else "")])
            continue
        jobs = [j for j in ids.replace("|", ",").split(",") if j.isdigit()]
        st = sacct_states(jobs) if not dry else {j: ("COMPLETED", "0", "") for j in jobs}
        open_ = [j for j in jobs if (st.get(j) or ("PENDING",))[0] not in TERMINAL]
        summary = ",".join("%s:%s" % (j, (st.get(j) or ("?",))[0]) for j in jobs)
        if open_:
            rows.append([tag, "waiting", summary])
            continue
        dest = expand(man.get("results", ""))
        if not dest:
            rows.append([tag, "not-run", "manifest has no resolvable results folder"])
            continue
        if not dry:
            os.makedirs(os.path.join(dest, "scratch"), exist_ok=True)
            for src in man.get("collect", []):
                s = expand(src)
                if s and os.path.exists(s):
                    run(["rsync", "-a", s.rstrip("/") + ("/" if os.path.isdir(s) else ""),
                         os.path.join(dest, "scratch", os.path.basename(s.rstrip("/"))) + ("/" if os.path.isdir(s) else "")])
            write_tsv(os.path.join(dest, "sacct.tsv"),
                      [["job", "state", "elapsed", "alloc_tres"]] + [[j] + list(st.get(j, ("?", "", ""))) for j in jobs])
        rows.append([tag, "collected", summary])
    for r in rows:
        print("\t".join(r))
    if not dry:
        write_tsv(os.path.join(batch, "collected.tsv"), rows)
    return 0


def main(argv):
    if len(argv) < 3 or argv[1] not in ("check", "submit", "imports", "collect", "copy"):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 64
    batch = os.path.abspath(argv[2])
    dry = "--dry-run" in argv[3:]
    if os.environ.get("ARCHIVE_UNATTENDED") == "1" and not dry:
        log("Sherlock needs an owner-attended session; engine sessions may only dry-run")
        return 2
    return {"check": cmd_check, "submit": cmd_submit, "imports": cmd_imports, "collect": cmd_collect,
            "copy": cmd_copy}[argv[1]](batch, dry)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
