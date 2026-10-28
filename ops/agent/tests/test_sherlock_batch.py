#!/usr/bin/python3
"""Tests for the Sherlock batch (W46.sherlock-batch): cluster-reach.py's batch request, and a whole batch round trip
through ArchiveProcessor/scripts/segbench/sherlock/batch_mac.py and batch.py on the Mac.

"Sherlock" here is a scratch folder (batch_mac.py's SHERLOCK_BATCH_LOCAL seam, $GROUP_HOME and $SCRATCH pointing
into it) and sbatch, scontrol, scancel and sacct are fakes that log their arguments. Nothing connects anywhere, and
nothing outside the scratch folder is read or written.

Run: /usr/bin/python3 -m unittest discover -s ops/agent/tests   (from the repo root)
"""
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
AUTONOMOUS = os.path.join(ROOT, "ops", "autonomous")
KIT = os.path.join(ROOT, "ArchiveProcessor", "scripts", "segbench", "sherlock")

PLAN = """# plan

RUN STATUS: IN_PROGRESS — fixture

## WORK QUEUE (priority order — do top to bottom)

- [ ] **W9.good — a pack that passes [S]** (lane: segbench) (uses: light) (cluster: sherlock) (needs: owner) — HELD 2026-10-20: ready to submit: bash good
- [ ] **W9.badpath — a pack naming a missing home path [S]** (lane: segbench) (uses: light) (cluster: sherlock) (needs: owner) — HELD 2026-10-21: ready to submit: bash badpath
- [ ] **W9.badimport — a pack whose chain does not import [S]** (lane: segbench) (uses: light) (cluster: sherlock) (needs: owner) — HELD 2026-10-22: ready to submit: bash badimport
- [ ] **W9.released — held once, then released [S]** (lane: segbench) (uses: light) (cluster: sherlock) — HELD 2026-10-01: ready to submit: x — RELEASED 2026-10-02: done
- [ ] **W9.other — held for something else [S]** (lane: segbench) (uses: light) (cluster: sherlock) (needs: owner) — HELD 2026-10-01: owner sheet
- [ ] **W9.farm — FarmShare [S]** (lane: segbench) (uses: light) (cluster: farmshare) (needs: owner) — HELD 2026-10-01: ready to submit: x

## HOLD QUEUE (owner-gated)

## Daemon Report

## Session Log
"""

SUBMIT = r"""#!/bin/bash
# Like the real hand-overs: a CPU stage, then GPU jobs afterok it, ids recorded in the pack's own jobs.tsv.
set -euo pipefail
SOURCE="$1"; DRY="${2:-}"
ROOT="$FS_ROOT/$(basename "$SOURCE")"
run() { if [ "$DRY" = --dry-run ]; then echo 0; else "$@"; fi; }
mkdir -p "$ROOT/logs"; TSV="$ROOT/jobs.tsv"; [ "$DRY" = --dry-run ] || (set -o noclobber; : > "$TSV")
stage=$(run sbatch --parsable --output="$ROOT/logs/stage-%j.out" "$SOURCE/support/stage.sh")
[[ "$stage" =~ ^[0-9]+$ ]] || exit 3
echo "stage $stage" >> "$TSV"
gpu=$(run sbatch --parsable --partition=gpu -G 1 --dependency="afterok:$stage" "$SOURCE/support/stage.sh")
echo "gpu $gpu" >> "$TSV"
"""

FAKES = {
    "sbatch": r"""#!/bin/bash
n=$(cat "$FAKE_LOG.n" 2>/dev/null || echo 100); n=$((n + 1)); echo $n > "$FAKE_LOG.n"
echo "sbatch $*" >> "$FAKE_LOG"; echo $n
""",
    "scontrol": '#!/bin/bash\necho "scontrol $*" >> "$FAKE_LOG"\n',
    "scancel": '#!/bin/bash\necho "scancel $*" >> "$FAKE_LOG"\n',
    "sacct": r"""#!/bin/bash
echo "sacct $*" >> "$FAKE_LOG"
while [ $# -gt 0 ]; do [ "$1" = -j ] && ids="$2"; shift; done
for j in ${ids//,/ }; do echo "$j|${FAKE_STATE:-COMPLETED}|00:12:00|cpu=8,gres/gpu=1"; done
""",
}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class BatchFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sherlock-batch-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        t = self.tmp
        self.repo, self.state = os.path.join(t, "repo"), os.path.join(t, "state")
        self.gh, self.scratch = os.path.join(t, "sherlock-group"), os.path.join(t, "sherlock-scratch")
        auto = os.path.join(self.repo, "ops", "autonomous")
        os.makedirs(auto)
        for f in ("cluster-reach.py", "plan-edit.sh", "plan-edit.py"):
            shutil.copy2(os.path.join(AUTONOMOUS, f), auto)
        self.kit = os.path.join(self.repo, "ArchiveProcessor", "scripts", "segbench", "sherlock")
        shutil.copytree(KIT, self.kit, ignore=shutil.ignore_patterns("__pycache__", "packs"))
        os.makedirs(os.path.join(self.kit, "packs"))
        os.makedirs(os.path.join(self.repo, ".maintenance"))
        self.plan = os.path.join(self.repo, ".maintenance", "AUTONOMOUS_PLAN.md")
        with open(self.plan, "w") as f:
            f.write(PLAN)
        for d in (self.state, self.gh, self.scratch, os.path.join(t, "home")):
            os.makedirs(d, exist_ok=True)
        bin_ = os.path.join(t, "bin")
        os.makedirs(bin_)
        for name, body in FAKES.items():
            self.write(os.path.join(bin_, name), body, 0o755)
        self.log = os.path.join(t, "fake.log")
        self.env = dict(os.environ, AGENT_REPO=self.repo, AGENT_STATE=self.state, AUTONOMOUS_PLAN=self.plan,
                        HOME=os.path.join(t, "home"), USER="cp1", GROUP_HOME=self.gh, SCRATCH=self.scratch,
                        FS_ROOT=os.path.join(self.scratch, "fs-ocr"), FS_PY="/usr/bin/python3",
                        SHERLOCK_BATCH_LOCAL=self.gh, FAKE_LOG=self.log,
                        PATH=bin_ + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"))
        self.env.pop("ARCHIVE_UNATTENDED", None)
        for p in ("SH_IMG", "SH_SHIM", "HF_HOME", "SH_PPOCR_ENV", "SH_ENH_ENV", "SH_ENH_EXTRA"):
            self.env.pop(p, None)
        self.make_pack("W9.good", "good-1", "import json\n")
        self.make_pack("W9.badpath", "badpath-1", "", extra='{"image": "$HOME/fs-truthpack/images/p001.jpg"}\n'
                       '{"image": "/Users/cp1/not-here-w46-batch.jpg"}\n')
        self.make_pack("W9.badimport", "badimport-1", "raise ImportError('no scipy in the image')\n")

    def write(self, path, text, mode=None):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)
        if mode:
            os.chmod(path, mode)

    def make_pack(self, tag, pack, module, extra=""):
        mac = os.path.join(self.state, "artifacts", pack)
        self.write(os.path.join(mac, "support", "submit.sh"), SUBMIT, 0o755)
        self.write(os.path.join(mac, "support", "stage.sh"), "#!/bin/bash\n", 0o755)
        self.write(os.path.join(mac, "support", "chain.py"), module)
        self.write(os.path.join(mac, "freeze.json"), json.dumps({"truth": "truth.json", "src": "/Users/cp1/x.jpg"}))
        self.write(os.path.join(mac, "truth.json"), "{}")
        self.write(os.path.join(mac, "requests.jsonl"),
                   json.dumps({"image": "$GROUP_HOME/$USER/archive-suite/%s/truth.json" % pack,
                               "out": "$FS_ROOT/%s/out/x.json" % pack}) + "\n" + extra)
        man = {"tag": tag, "pack": pack, "mac": "artifacts/" + pack, "submit": "support/submit.sh", "jobs": 2,
               "gpu_hours": 1.5, "review": "execution-plans/items/%s.md" % tag,
               "imports": [{"dir": "support", "modules": ["chain"]}],
               "creates": ["$FS_ROOT/" + pack, "$GROUP_HOME/$USER/archive-suite/sherlock-results/" + pack],
               "provenance": ["freeze.json"],
               "results": "$GROUP_HOME/$USER/archive-suite/sherlock-results/" + pack,
               "collect": ["$FS_ROOT/%s/jobs.tsv" % pack, "$FS_ROOT/%s/logs" % pack],
               "release": "results collected"}
        self.write(os.path.join(self.kit, "packs", tag + ".json"), json.dumps(man))

    def mac(self, *args, ok=True):
        p = subprocess.run(["/usr/bin/python3", os.path.join(self.kit, "batch_mac.py")] + list(args),
                           env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p

    def sherlock(self, *args):
        """batch.py as batch.sh and batch-job.sh run it, without sh.env (the fixture's env stands in for it)."""
        p = subprocess.run(["/usr/bin/python3", os.path.join(self.remote_kit, "batch.py")] + list(args),
                           env=self.env, capture_output=True, text=True)
        return p

    def fake_log(self):
        try:
            with open(self.log) as f:
                return f.read().splitlines()
        except OSError:
            return []

    def plan_line(self, tag):
        with open(self.plan) as f:
            return next(ln for ln in f if ("**%s " % tag) in ln)

    def ledger(self, tag):
        try:
            with open(os.path.join(self.state, "cluster-jobs", tag)) as f:
                return f.read().strip()
        except OSError:
            return None


class TestBatchRoundTrip(BatchFixture):
    def test_round_trip(self):
        out = self.mac("plan").stdout
        stamp = out.split("batch ", 1)[1].split(":", 1)[0]
        self.assertIn("W9.good", out)
        self.assertNotIn("W9.released", out)
        self.assertNotIn("W9.other", out)
        self.assertNotIn("W9.farm", out)
        self.mac("send", stamp)
        rb = os.path.join(self.gh, "cp1", "archive-suite", "batches", stamp)
        self.remote_kit = os.path.join(rb, "kit")
        self.assertTrue(os.path.isfile(os.path.join(self.gh, "cp1", "archive-suite", "good-1", "support", "submit.sh")))

        chk = self.sherlock("check", rb)
        self.assertEqual(chk.returncode, 1, chk.stdout + chk.stderr)
        self.assertIn("W9.good\tok", chk.stdout)
        self.assertRegex(chk.stdout, r"W9.badpath\tfails\trequests.jsonl: .*/home/fs-truthpack/images/p001.jpg is missing")
        self.assertIn("/Users/cp1/not-here-w46-batch.jpg is missing", chk.stdout + chk.stderr)
        self.assertEqual(self.fake_log(), [], "check queues nothing")

        sub = self.sherlock("submit", rb)
        self.assertEqual(sub.returncode, 0, sub.stdout + sub.stderr)
        log = self.fake_log()
        packs = [ln for ln in log if ln.startswith("sbatch --hold")]
        self.assertEqual(len(packs), 4, log)            # two packs passed the path check, two jobs each, all held
        self.assertTrue(any("--dependency=afterok:101" in ln for ln in packs))
        self.assertTrue(any("w46-batch-imports" in ln and "--hold" not in ln for ln in log))
        again = self.sherlock("submit", rb)
        self.assertEqual(again.returncode, 2, "a batch is never submitted twice")

        self.mac("mark", stamp)
        self.assertEqual(self.ledger("W9.good"), "submitted")
        self.assertEqual(self.ledger("W9.badimport"), "submitted")
        self.assertIsNone(self.ledger("W9.badpath"))
        line = self.plan_line("W9.badpath")
        self.assertNotIn("(needs: owner)", line)
        self.assertIn("left out of Sherlock batch", line)

        imp = self.sherlock("imports", rb)                # the CPU import job
        self.assertEqual(imp.returncode, 0, imp.stdout + imp.stderr)
        log = self.fake_log()
        self.assertIn("scontrol release 101,102", log)
        self.assertIn("scancel 103 104", log)
        self.assertIn("no scipy", imp.stdout)

        col = self.sherlock("collect", rb)
        self.assertEqual(col.returncode, 0, col.stdout + col.stderr)
        self.assertTrue(any("w46-batch-collect" in ln for ln in self.fake_log()))
        # the results the GPU jobs would have copied home, and one returned file that differs from the Mac copy
        res = os.path.join(self.gh, "cp1", "archive-suite", "sherlock-results", "good-1")
        self.write(os.path.join(res, "out", "r1.json"), "{}")
        self.write(os.path.join(res, "truth.json"), '{"changed": 1}')
        cp = self.sherlock("copy", rb)                    # the collect job
        self.assertEqual(cp.returncode, 0, cp.stdout + cp.stderr)
        self.assertIn("W9.good\tcollected", cp.stdout)
        self.assertIn("W9.badimport\tnot-run", cp.stdout)
        self.assertTrue(os.path.isfile(os.path.join(res, "scratch", "jobs.tsv")))
        self.assertTrue(os.path.isfile(os.path.join(res, "sacct.tsv")))

        fe = self.mac("fetch", stamp)
        mac = os.path.join(self.state, "artifacts", "good-1")
        self.assertTrue(os.path.isfile(os.path.join(mac, "out", "r1.json")))
        with open(os.path.join(mac, "truth.json")) as f:
            self.assertEqual(f.read(), "{}", "a Mac file is never overwritten by a returned one")
        self.assertIn("truth.json", fe.stdout)
        self.assertEqual(self.ledger("W9.good"), "finished")
        self.assertNotIn("(needs: owner)", self.plan_line("W9.good"))
        self.assertIsNone(self.ledger("W9.badimport"))
        self.assertIn("did not run it", self.plan_line("W9.badimport"))

    def test_collect_waits_for_running_jobs(self):
        stamp = self.mac("plan", "--leave-out", "W9.badpath", "--leave-out", "W9.badimport").stdout
        stamp = stamp.split("batch ", 1)[1].split(":", 1)[0]
        self.mac("send", stamp)
        rb = os.path.join(self.gh, "cp1", "archive-suite", "batches", stamp)
        self.remote_kit = os.path.join(rb, "kit")
        self.assertEqual(self.sherlock("submit", rb).returncode, 0)
        self.sherlock("imports", rb)
        self.env["FAKE_STATE"] = "RUNNING"
        cp = self.sherlock("copy", rb)
        self.assertIn("W9.good\twaiting", cp.stdout)
        fe = self.mac("fetch", stamp)
        self.assertIn("still running", fe.stdout)
        self.assertIsNone(self.ledger("W9.good"))         # never marked: nothing was collected

    def test_submit_failure_cancels_what_was_accepted(self):
        mac = os.path.join(self.state, "artifacts", "good-1", "support", "submit.sh")
        with open(mac, "a") as f:
            f.write("exit 7\n")
        stamp = self.mac("plan", "--leave-out", "W9.badpath", "--leave-out", "W9.badimport").stdout
        stamp = stamp.split("batch ", 1)[1].split(":", 1)[0]
        self.mac("send", stamp)
        rb = os.path.join(self.gh, "cp1", "archive-suite", "batches", stamp)
        self.remote_kit = os.path.join(rb, "kit")
        sub = self.sherlock("submit", rb)
        self.assertIn("left out", sub.stdout)
        log = self.fake_log()
        self.assertIn("scancel 101 102", log)
        self.assertFalse(any("w46-batch-imports" in ln for ln in log), "no import job for an empty batch")

    def test_unattended_refuses(self):
        env = dict(self.env, ARCHIVE_UNATTENDED="1")
        env.pop("SHERLOCK_BATCH_LOCAL")
        p = subprocess.run(["/usr/bin/python3", os.path.join(self.kit, "batch_mac.py"), "send", "x"], env=env,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        p = subprocess.run(["/usr/bin/python3", os.path.join(self.kit, "batch.py"), "submit", self.tmp], env=env,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)

    def test_batch_py_is_python36_syntax(self):
        import ast
        for f in ("batch.py",):
            with open(os.path.join(KIT, f)) as fh:
                ast.parse(fh.read(), feature_version=(3, 6))


class TestBatchAsk(BatchFixture):
    def cr(self):
        """cluster-reach.py loaded against the fixture: it reads its paths from the environment at import."""
        keys = ("AGENT_REPO", "AGENT_STATE", "AUTONOMOUS_PLAN")
        saved = {k: os.environ.get(k) for k in keys}
        os.environ.update({k: self.env[k] for k in keys})
        try:
            return load(os.path.join(self.repo, "ops", "autonomous", "cluster-reach.py"), "cluster_reach_t")
        finally:
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_ready_packs_and_threshold(self):
        cr = self.cr()
        with open(self.plan) as f:
            text = f.read()
        ready, collect = cr.sherlock_state(text)
        self.assertEqual([r[0] for r in ready], ["W9.good", "W9.badpath", "W9.badimport"])
        self.assertEqual(collect, [])
        msg = cr.batch_ask_text(ready, collect, "2026-10-23")
        self.assertIn("3 packs are ready", msg)
        self.assertIn("at most 4.5 GPU-hours in all", msg)
        self.assertNotIn("no decision", msg.lower())
        self.assertIsNone(cr.batch_ask_text(ready[:2], [], "2026-10-24"))           # 2 ready, oldest 4 days
        self.assertIn("waited 5 days", cr.batch_ask_text(ready[:2], [], "2026-10-25"))
        self.assertIn("to be collected", cr.batch_ask_text([], [("W9.x", "2026-10-01")], "2026-10-06"))

    def test_asks_once_per_batch(self):
        cr = self.cr()
        with open(self.plan) as f:
            text = f.read()
        self.assertIsNotNone(cr.batch_ask(text, "2026-10-23"))
        self.assertIsNone(cr.batch_ask(text, "2026-10-24"), "the same packs are not asked about again")
        with open(self.plan) as f:
            self.assertEqual(f.read().count("[Sherlock batch]"), 1)
        self.assertIsNotNone(cr.batch_ask(text, "2026-10-28"), "but they are after five more days")

    def test_submitted_pack_is_collection_not_ready(self):
        cr = self.cr()
        os.makedirs(os.path.join(self.state, "cluster-jobs"))
        with open(os.path.join(self.state, "cluster-jobs", "W9.good"), "w") as f:
            f.write("submitted\n")
        with open(self.plan) as f:
            ready, collect = cr.sherlock_state(f.read())
        self.assertNotIn("W9.good", [r[0] for r in ready])
        self.assertEqual([c[0] for c in collect], ["W9.good"])

    def test_daily_ask_skips_sherlock(self):
        cr = self.cr()
        rows = [{"tag": "W9.good", "status": "blocked", "reason": "cluster sherlock not reachable (x)"}]
        self.assertIsNone(cr.ask_text(rows, "2026-10-23"))


if __name__ == "__main__":
    unittest.main()
