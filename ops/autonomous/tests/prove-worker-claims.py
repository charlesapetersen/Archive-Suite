#!/usr/bin/env python3
"""Exercise real resolver, claims, idle upkeep and plan edits on scratch files."""
import concurrent.futures
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent.parent
PASS = 0


def check(value, label):
    global PASS
    assert value, label
    PASS += 1
    print("PASS " + label, flush=True)


with tempfile.TemporaryDirectory(prefix="worker claims [scratch] ") as scratch:
    root = Path(scratch)
    repo = root / "repo with space"
    state = root / "state with space"
    repo.mkdir()
    (repo / "ops").mkdir()
    (repo / "ops/autonomous").symlink_to(HERE, target_is_directory=True)
    plan = repo / "plan.md"
    todo = repo / "SUITE_TODO.md"
    todo.write_text("")
    env = dict(os.environ, AUTONOMOUS_PLAN=str(plan), AUTONOMOUS_STATE=str(state),
               AUTONOMOUS_SUITE_TODO=str(todo), AUTONOMOUS_SUITE_TODO_DONE=str(repo / "done.md"))
    env.pop("AUTONOMOUS_IGNORE_CLAIMS", None)
    env.pop("AUTONOMOUS_HEAVY_STATE", None)  # heavy-lock records are read from the scratch state/heavy
    env.pop("AUTONOMOUS_CLAIMS_CMD", None)
    children = []

    def run(*args, stale=1500, expected=0):
        p = subprocess.run(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                            "--repo", str(repo), "--plan", str(plan), "--stale", str(stale), *args],
                           env=env, capture_output=True, text=True)
        assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
        return p.stdout.strip()

    def queue(*lines):
        plan.write_text("RUN STATUS: IN_PROGRESS\n## WORK QUEUE\n" + "\n".join(lines)
                        + "\n## HOLD QUEUE\n- [ ] **Owner — hold**\n## Session Log\n## Daemon Report\n"
                        + "### ✅ settled walkthrough\nold question\n")

    def reserve(worker, stale=1500, expected=0, pid=None, special=None):
        args = ["reserve", worker, str(pid or os.getpid())]
        if special:
            args += ["--special", special]
        out = run(*args, stale=stale, expected=expected)
        return out.split("\t", 2) if out else []

    def release(claim):
        run("release", *claim[:2])

    try:
        queue("- [ ] **A — initial advisory query**")
        result = subprocess.run(["bash", str(HERE / "next-queue-item.sh"), str(repo)], env=env,
                                capture_output=True, text=True)
        check(result.returncode == 0 and "ok\tA\t" in result.stdout and not state.exists(),
              "advisory resolver does not initialize a serial daemon's installed state")
        queue("- [ ] **A — reader** (lane: reader)", "- [ ] **B — reader two** (lane: reader)",
              "- [ ] **C — notes** (lane: notes)", "- [ ] **D — blocked** (blocked-on: Missing)")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            # Capture exit codes: eight racing supervisors may win exactly two disjoint lanes.
            def race(i):
                p = subprocess.run(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                                    "--repo", str(repo), "reserve", "worker-" + str(i), str(os.getpid())],
                                   env=env, capture_output=True, text=True)
                return p.returncode, p.stdout.strip().split("\t", 2)
            outcomes = list(pool.map(race, range(1, 9)))
        winners = [c for rc, c in outcomes if rc == 0]
        check({c[0] for c in winners} == {"A", "C"} and len(winners) == 2,
              "racing selection never duplicates a tag or overlaps a lane")
        check(all(rc in (0, 4) for rc, _ in outcomes), "losers defer cleanly")
        resolver = subprocess.run(["bash", str(HERE / "next-queue-item.sh"), str(repo)], env=env,
                                  capture_output=True, text=True)
        check(resolver.returncode == 4 and "\tA\t" not in resolver.stdout and "\tB\t" not in resolver.stdout,
              "resolver hides claimed tags and shared lanes, preserving blocked exit")
        run("idle", "--", "python3", "-c", "raise SystemExit(99)", expected=4)
        check(True, "upkeep refuses while any worker owns a claim")
        run("release", winners[0][0], "wrong-token", expected=4)
        check((state / "claims" / winners[0][0]).exists(), "wrong token cannot release another owner")
        for c in winners:
            release(c)
        # Lane LISTS (efficiency plan round 1): sets conflict on intersection, suite on everything.
        queue("- [ ] **A — notes and reader** (lane: notes, reader)", "- [ ] **B — reader** (lane: reader)",
              "- [ ] **C — processor** (lane: processor)", "- [ ] **E — ops** (lane: ops)")
        c = reserve("worker-1")
        c2 = reserve("worker-2")
        check(c[0] == "A" and c2[0] == "C", "a lane list skips an item sharing one of its lanes")
        check(json.loads((state / "claims/A/owner.json").read_text())["lane"] == "notes,reader",
              "a lane list is recorded as its sorted set")
        resolver = subprocess.run(["bash", str(HERE / "next-queue-item.sh"), str(repo)], env=env,
                                  capture_output=True, text=True)
        check(resolver.returncode == 0 and "\tB\t" not in resolver.stdout and "ok\tE\t" in resolver.stdout,
              "resolver hides the intersecting item and offers the disjoint one")
        release(c); release(c2)
        # Resource tags (W35.uses-tags): parsed beside the lane, returned and recorded; untagged reads as build.
        queue("- [ ] **A — quotes (uses: …) and (uses: build) in prose** (lane: notes) (uses: light, paid)",
              "- [ ] **B — untagged** (lane: reader)", "- [ ] **C — model** (lane: ops) (uses: model:12,vm)")
        c, c2, c3 = reserve("worker-1"), reserve("worker-2"), reserve("worker-3")
        check([x[0] for x in (c, c2, c3)] == ["A", "B", "C"]
              and [x[2].split("\t")[0] for x in (c, c2, c3)] == ["light,paid", "build", "model:12,vm"],
              "a uses tag is returned with the selection; the last tag wins over prose; untagged reads as build")
        check(json.loads((state / "claims/A/owner.json").read_text())["uses"] == "light,paid",
              "the uses value is recorded in the claim")
        release(c); release(c2); release(c3)
        queue("- [ ] **A — typo** (lane: notes) (uses: lite)", "- [ ] **B — zero model** (lane: ops) (uses: model:0)",
              "- [ ] **C — owner word** (lane: reader) (uses: owner)", "- [ ] **E — fine** (lane: processor) (uses: light)")
        p = subprocess.run(["python3", str(HERE / "worker-state.py"), "--state", str(state), "--repo", str(repo),
                            "--plan", str(plan), "reserve", "worker-1", str(os.getpid())],
                           env=env, capture_output=True, text=True)
        c = p.stdout.strip().split("\t", 2)
        check(p.returncode == 0 and c[0] == "E" and all("refused " + t + ": unknown uses value" in p.stderr
                                                        for t in "ABC"),
              "an unknown uses value refuses the item, with a stderr reason, instead of defaulting")
        release(c)
        queue("- [ ] **A — trailing comma** (lane: notes) (uses: light,)", "- [ ] **B — no comma** (lane: ops) (uses: light paid)",
              "- [ ] **C — capital** (lane: reader) (Uses: light)", "- [ ] **D — empty** (lane: gui) (uses:)",
              "- [ ] **E — fine** (lane: processor) (uses: vm)")
        p = subprocess.run(["python3", str(HERE / "worker-state.py"), "--state", str(state), "--repo", str(repo),
                            "--plan", str(plan), "reserve", "worker-1", str(os.getpid())],
                           env=env, capture_output=True, text=True)
        c = p.stdout.strip().split("\t", 2)
        check(p.returncode == 0 and c[0] == "E" and all("refused " + t + ": malformed uses tag" in p.stderr
                                                        for t in "ABCD"),
              "a malformed uses tag is refused, never read as untagged build")
        release(c)
        queue("- [ ] **A — light is no hold** (lane: notes) (uses: light)")
        c = reserve("worker-1")
        check(c[0] == "A", "a uses tag is never read as a `needs: owner` hold")
        release(c)
        queue("- [ ] **A — unlabelled** ", "- [ ] **B — notes and reader** (lane: notes,reader)")
        c = reserve("worker-1")
        reserve("worker-2", expected=4)
        check(c[0] == "A", "an unlabelled suite claim still blocks a lane list")
        release(c)
        queue("- [ ] **B — notes and reader** (lane: notes,reader)", "- [ ] **A — unlabelled**")
        c = reserve("worker-1")
        reserve("worker-2", expected=4)
        check(c[0] == "B", "a lane-list claim still blocks an unlabelled suite item")
        release(c)
        queue("- [ ] **A — unlabelled suite edit**", "- [ ] **C — notes** (lane: notes)")
        c = reserve("worker-1")
        reserve("worker-2", expected=4)
        check(True, "unlabelled items serialize against every lane")
        d = state / "claims/A"
        old = time.time() - 10000
        os.utime(d, (old, old))
        reserve("worker-2", stale=0, expected=4)
        check(d.exists(), "live owner survives age beyond stale threshold")
        record = json.loads((d / "owner.json").read_text())
        record["pid_start"] = "wrong process birth (PID reused)"
        (d / "owner.json").write_text(json.dumps(record))
        c2 = reserve("worker-2", stale=0)
        check(c2[0] == "A" and c2[1] != c[1], "dead/PID-reused owner is reclaimed after expiry")
        run("release", *c[:2], expected=4)
        check(d.exists(), "late old cleanup cannot release replacement claim")
        release(c2)
        queue("- [ ] **A — next**")
        owner = subprocess.Popen(["sleep", "60"])
        child = subprocess.Popen(["sleep", "60"])
        children += [owner, child]
        c = reserve("worker-1", pid=owner.pid)
        run("child", *c[:2], str(child.pid))
        owner.terminate(); owner.wait()
        run("release", *c[:2], expected=4)
        reserve("worker-2", stale=0, expected=4)
        check(True, "surviving CLI stays protected after supervisor exit")
        child.terminate(); child.wait()
        c2 = reserve("worker-2", stale=0)
        release(c2)
        check(True, "claim becomes reclaimable after the last live owner exits")
        # A claim kept after a refused release expires after the preserved bound, not never.
        owner = subprocess.Popen(["sleep", "60"])
        child = subprocess.Popen(["sleep", "60"])
        straggler = subprocess.Popen(["sleep", "60"])
        children += [owner, child, straggler]
        c = reserve("worker-1", pid=owner.pid)
        run("child", *c[:2], str(child.pid))
        run("protect", *c[:2], str(straggler.pid))
        owner.terminate(); owner.wait()
        run("release", *c[:2], expected=4)
        refused = json.loads((d / "owner.json").read_text()).get("release_refused")
        check(isinstance(refused, (int, float)) and refused > 0, "a refused release stamps when it was first refused")
        record = json.loads((d / "owner.json").read_text()); record["release_refused"] = time.time() - 4000
        (d / "owner.json").write_text(json.dumps(record))
        reserve("worker-2", stale=0, expected=4)
        check(d.exists(), "a preserved claim whose CLI still runs never expires, however old the refusal")
        child.terminate(); child.wait()
        record = json.loads((d / "owner.json").read_text()); record["release_refused"] = time.time() - 60
        (d / "owner.json").write_text(json.dumps(record))
        reserve("worker-2", stale=0, expected=4)
        check(d.exists(), "a straggler keeps a recently refused claim inside the bound")
        # A straggler still queued for, or holding, the heavy lock keeps the claim past the bound: the hour is
        # sized to the longest heavy job, and the queue in front of it can be longer than that.
        def ps_start(pid):
            return subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
        heavy = state / "heavy"
        (heavy / "waiters").mkdir(parents=True, exist_ok=True)
        heavy_token = "0123456789abcdef0123456789abcdef"
        waiter = heavy / "waiters" / (heavy_token + ".json")
        waiter.write_text(json.dumps({"pid": straggler.pid, "start": ps_start(straggler.pid),
                                      "heartbeat": time.time(), "mac": True}))
        record["release_refused"] = time.time() - 3601
        (d / "owner.json").write_text(json.dumps(record))
        reserve("worker-2", stale=0, expected=4)
        restamped = json.loads((d / "owner.json").read_text()).get("release_refused", 0)
        check(d.exists() and time.time() - restamped < 60,
              "a straggler queued for the heavy lock keeps its claim past the bound, and the bound restarts")
        waiter.write_text(json.dumps({"pid": straggler.pid, "start": ps_start(straggler.pid),
                                      "heartbeat": time.time() - 30, "mac": True}))
        (heavy / "owner.json").write_text(json.dumps({"token": heavy_token, "owner": straggler.pid,
                                                      "owner_start": ps_start(straggler.pid),
                                                      "child": straggler.pid, "child_start": ps_start(straggler.pid)}))
        record["release_refused"] = time.time() - 3601
        (d / "owner.json").write_text(json.dumps(record))
        reserve("worker-2", stale=0, expected=4)
        check(d.exists(), "a straggler holding the heavy lock keeps its claim past the bound (a stale waiter does not count)")
        gone = subprocess.Popen(["true"]); gone.wait()
        (heavy / "owner.json").write_text(json.dumps({"token": heavy_token, "owner": gone.pid, "owner_start": "gone",
                                                      "child": gone.pid, "child_start": "gone"}))
        record["release_refused"] = time.time() - 3601
        (d / "owner.json").write_text(json.dumps(record))
        c2 = reserve("worker-2", stale=0)
        check(c2[0] == "A" and straggler.poll() is None,
              "past the bound a preserved claim expires though a straggler lives, and nothing is signalled")
        release(c2)
        straggler.terminate(); straggler.wait()
        # Known dead claims are still protected until the engine's timeout.
        c = reserve("worker-1")
        record = json.loads((d / "owner.json").read_text()); record["pid_start"] = "dead"
        (d / "owner.json").write_text(json.dumps(record))
        reserve("worker-2", expected=4)
        check(True, "recent dead owner remains protected for engine stale interval")
        c2 = reserve("worker-2", stale=0); release(c2)
        # Upkeep holds the coordination lock across its command, including the plan lock.
        marker = root / "upkeep-running"
        holder = subprocess.Popen(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                                   "--repo", str(repo), "idle", "--", "python3", "-c",
                                   "from pathlib import Path; import time; Path(" + repr(str(marker))
                                   + ").touch(); time.sleep(1)"], env=env)
        children.append(holder)
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        check(marker.exists(), "idle command starts")
        before = time.monotonic(); c = reserve("worker-1")
        check(time.monotonic() - before > .5, "reservation waits until upkeep finishes")
        holder.wait(); release(c)
        # Trapping/kill does not strand a kernel lock. Kill the coordinator only once its child
        # is running (a fixed 0.1 s sleep raced holder startup, ~0.25 s, so it usually killed the
        # holder before the child existed), then probe the locks directly instead of timing.
        started, finished = root / "orphan-started", root / "orphan-finished"
        holder = subprocess.Popen(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                                   "--repo", str(repo), "idle", "--", "python3", "-c",
                                   "from pathlib import Path; import time; Path(" + repr(str(started))
                                   + ").touch(); time.sleep(1.5); Path(" + repr(str(finished))
                                   + ").touch()"], env=env)
        children.append(holder)
        deadline = time.monotonic() + 10
        while not started.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        check(started.exists(), "orphan upkeep child starts")
        holder.terminate(); holder.wait()

        def held(path):
            with path.open("a+") as f:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return True
                fcntl.flock(f, fcntl.LOCK_UN)
                return False
        check(not finished.exists() and held(state / "coordination.lock")
              and held(plan.resolve().with_name(plan.name + ".lock")),
              "orphan upkeep child keeps both kernel locks after its coordinator dies")
        c = reserve("worker-1"); release(c)
        check(finished.exists(), "orphan upkeep child retains kernel lock until mutation ends")
        c = reserve("worker-1", special="gate-fix")
        check(c[0] == "gate-fix", "special gate/doc sessions are suite-wide claims")
        reserve("worker-2", expected=4); release(c)
        alias = root / "plan alias.md"; alias.symlink_to(plan)
        subprocess.run(["python3", str(HERE / "worker-state.py"), "--state", str(state), "--repo", str(repo),
                        "--plan", str(alias), "idle", "--", "python3", "-c",
                        "import os; assert os.environ['AUTONOMOUS_PLAN'] == " + repr(str(plan.resolve()))],
                       env=env, check=True)
        check(alias.is_symlink(), "upkeep receives the same canonical plan path as its stable lock")
        # Plan writes contend on one stable lock, not the inode being replaced.
        queue("- [ ] **A — complete**", "- [ ] **B — complete**")
        def plan_run(action, *values):
            p = subprocess.run(["bash", str(HERE / "plan-edit.sh"), str(plan), action, *values],
                               env=env, capture_output=True, text=True)
            assert p.returncode == 0, p.stderr
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: plan_run("log", "entry " + str(i)), range(16)))
        text = plan.read_text()
        check(all(text.count("\nentry " + str(i) + "\n") == 1 for i in range(16)),
              "16 simultaneous plan appends conserve every entry")
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda tag: plan_run("complete", tag, "abcdef0", "shipped"), ["A", "B"]))
        text = plan.read_text()
        check(text.count("[x]") == 2 and "- [ ] **Owner" in text, "simultaneous ticks stay inside WORK QUEUE")
        check("RUN STATUS: COMPLETE" in text, "last queue tick sets COMPLETE through the locked helper")
        # `add` files new work into the queue, after a named item's whole span, under the same lock.
        plan_run("add", "C", "A", "**C — filed later** (lane: notes)")
        text = plan.read_text()
        check("RUN STATUS: IN_PROGRESS" in text and text.index("**C — filed later**") > text.index("**A — complete")
              and text.index("**C — filed later**") < text.index("**B — complete"),
              "add files the item after its anchor and reopens a finished queue")
        # Reopening rewrites only the status line: the blank line after it survives (\s* once ate the newline).
        plan.write_text("RUN STATUS: COMPLETE  \n\n## WORK QUEUE\n- [x] **A — done**\n## HOLD QUEUE\n## Session Log\n")
        plan_run("add", "Z", "A", "**Z — reopens**")
        check(plan.read_text().startswith("RUN STATUS: IN_PROGRESS\n\n## WORK QUEUE\n"),
              "add reopens a COMPLETE plan without deleting the blank line after the status line")
        queue("- [x] **A — complete**", "- [ ] **C — filed later** (lane: notes)", "- [x] **B — complete**")
        resolver = subprocess.run(["bash", str(HERE / "next-queue-item.sh"), str(repo)], env=dict(env, AUTONOMOUS_IGNORE_CLAIMS="1"),
                                  capture_output=True, text=True)
        check("ok\tC\t" in resolver.stdout, "an added item is offered by the resolver")
        queue("- [ ] **A — first**", "  continuation of A", "- [ ] **B — second**")
        plan_run("add", "D", "A", "**`D` — after a wrapped item**")
        lines = plan.read_text().splitlines()
        check(lines.index("  continuation of A") + 1 == lines.index("- [ ] **`D` — after a wrapped item**"),
              "add never splits an item from its continuation line")
        def plan_fail(*values):
            return subprocess.run(["bash", str(HERE / "plan-edit.sh"), str(plan), "add", *values],
                                  env=env, capture_output=True).returncode
        before = plan.read_text()
        check(plan_fail("D", "A", "**D — again**") == 2 and plan_fail("Owner", "A", "**Owner — hold**") == 2,
              "add refuses a tag that already has a checkbox line, in the queue or the HOLD QUEUE")
        check(plan_fail("E", "A", "**F — wrong tag**") == 2 and plan_fail("E", "A", "**E — two\nlines**") == 2
              and plan_fail("E", "Missing", "**E — x**") == 2 and plan_fail("E", "Owner", "**E — x**") == 2,
              "add refuses a mismatched tag, a second line, and an anchor outside the WORK QUEUE")
        check(plan.read_text() == before, "a refused add leaves the plan byte-identical")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: plan_run("add", "N" + str(i), "B", "**N%d — racer**" % i), range(12)))
        text = plan.read_text()
        check(all(text.count("**N%d — racer**" % i) == 1 for i in range(12)), "12 simultaneous adds conserve every item")
        queue("- [ ] **A — needs a decision**")
        plan_run("block", "A", "A-owner-ok", "choose X or Y?")
        text = plan.read_text()
        check("(blocked-on: A-owner-ok)" in text and "- [ ] **A-owner-ok — OWNER GATE" in text,
              "owner-pending dependency and HOLD gate are one locked mutation")
        plan_run("report", "### new decision\nquestion")
        check(plan.read_text().index("### new decision") < plan.read_text().index("### ✅ settled"),
              "new report lands before the settled walkthrough anchor")
        p = subprocess.run(["bash", str(HERE / "plan-edit.sh"), str(plan), "complete", "Owner", "abcdef0", "bad"],
                           env=env, capture_output=True)
        check(p.returncode == 2, "a HOLD entry cannot be ticked as queued work")
        queue("- [ ] **A — first**", "  - [ ] **B — indented pending**")
        plan_run("complete", "A", "abcdef0", "done")
        check("RUN STATUS: IN_PROGRESS" in plan.read_text(), "indented pending entry prevents premature COMPLETE")
        plan_run("complete", "B", "abcdef0", "done")
        check("RUN STATUS: COMPLETE" in plan.read_text(), "indented target can be completed")
        queue("- [ ] **A — first**", "```", "## example heading", "- [ ] **example — fictitious**", "```",
              "- [ ] **B — real pending**", "> - [ ] **quoted — fictitious**")
        plan_run("complete", "A", "abcdef0", "done")
        check("RUN STATUS: IN_PROGRESS" in plan.read_text(), "fenced heading cannot hide later pending entries")
        plan_run("complete", "B", "abcdef0", "done")
        check("RUN STATUS: COMPLETE" in plan.read_text() and "- [ ] **example" in plan.read_text(),
              "fenced and blockquoted examples do not keep a finished queue open")
        # Interrupted mkdir/update are bounded and do not strand a live supervisor.
        queue("- [ ] **A — next**")
        d.mkdir()
        reserve("worker-1", expected=4)
        c = reserve("worker-1", stale=0)
        check(c[0] == "A", "expired empty mkdir is recovered without deleting unknown files")
        record = json.loads((d / "owner.json").read_text())
        (d / "owner.json").rename(d / "owner.json.tmp")
        run("heartbeat", *c[:2])
        check((d / "owner.json").exists(), "interrupted initial metadata publication is recovered")
        (d / "owner.json.tmp").write_text("incomplete update")
        release(c)
        check(not d.exists(), "interrupted update cannot strand a live supervisor's reservation")
        # No CLI can run on a revoked token, even if its wrapper starts late.
        c = reserve("worker-1")
        release(c)
        run("session", *c[:2], "--", "python3", "-c", "raise SystemExit(99)", expected=4)
        check(True, "delayed launch with revoked claim cannot exec a CLI")
        c = reserve("worker-1")
        marker = root / "session-registered"
        proc = subprocess.Popen(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                                 "--repo", str(repo), "session", *c[:2], "--", "python3", "-c",
                                 "from pathlib import Path; import time; Path(" + repr(str(marker))
                                 + ").touch(); time.sleep(1)"], env=env)
        children.append(proc)
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        check(marker.exists(), "registered session execs command")
        record = json.loads((d / "owner.json").read_text())
        check(record["child"] == proc.pid and bool(record["child_start"]),
              "session owns claim before CLI exec, with unchanged process identity")
        run("release", *c[:2], expected=4)
        proc.wait(); release(c)
        # A CLI can exit first while its tool stays in a different process group.
        # Controlled gates keep each child alive until the proof releases it.
        for escaped in (False, True):
            queue("- [ ] **A — descendant test**")
            c = reserve("worker-1")
            member_file = root / ("escaped-member" if escaped else "group-member")
            gate = root / ("escaped-gate" if escaped else "group-gate")
            handoff = root / "handoff"; successor = root / "successor"
            code = ("import os,time,signal; from pathlib import Path; pid=os.fork(); "
                    + "marker=Path(" + repr(str(member_file)) + "); gate=Path(" + repr(str(gate)) + ")\n"
                    + "handoff=Path(" + repr(str(handoff)) + "); successor=Path(" + repr(str(successor)) + ")\n"
                    + "if pid == 0:\n " + ("os.setsid()" if escaped else "os.setpgid(0,0)")
                    + "\n signal.signal(signal.SIGTERM,signal.SIG_IGN)\n marker.write_text(str(os.getpid()))\n"
                    + " deadline=time.monotonic()+30\n"
                    + (" while not handoff.exists() and time.monotonic()<deadline: time.sleep(.02)\n if os.fork(): os._exit(0)\n successor.write_text(str(os.getpid()))\n" if escaped else "")
                    + " while not gate.exists() and time.monotonic()<deadline: time.sleep(.02)\n os._exit(0)\n"
                    + "while not marker.exists(): time.sleep(.02)\n"
                    + ("time.sleep(30)\n" if escaped else "os._exit(0)\n"))
            proc = subprocess.Popen(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                                     "--repo", str(repo), "session", *c[:2], "--", "python3", "-c", code], env=env)
            children.append(proc)
            deadline = time.monotonic() + 5
            while not member_file.exists() and time.monotonic() < deadline: time.sleep(.02)
            check(member_file.exists(), "tool child has published its private fixture identity")
            member = int(member_file.read_text())
            try:
                if escaped:
                    run("protect", *c[:2], str(member))
                    proc.terminate()
                proc.wait(timeout=5)
                if escaped:
                    handoff.touch()
                    deadline = time.monotonic() + 5
                    while not successor.exists() and time.monotonic() < deadline: time.sleep(.02)
                    check(successor.exists(), "captured escaped victim hands work to a same-session successor")
                run("release", *c[:2], expected=4)
                reserve("worker-2", stale=0, expected=4)
                run("idle", "--", "python3", "-c", "raise SystemExit(99)", expected=4)
                check(True, "escaped watchdog victim stays protected" if escaped
                      else "same-session tool in another process group stays claimed after CLI exits")
            finally:
                gate.touch()
                if proc.poll() is None: proc.terminate(); proc.wait()
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    p = subprocess.run(["python3", str(HERE / "worker-state.py"), "--state", str(state),
                                        "--repo", str(repo), "release", *c[:2]], env=env, capture_output=True)
                    if p.returncode == 0: break
                    assert p.returncode == 4, p.stderr
                    time.sleep(.02)
                check(p.returncode == 0, "claim releases after the last protected tool ends")
        # Fault injection at the ps/getSID boundary proves fork/exit handoffs
        # retain ownership rather than treating a vanished snapshot PID as empty.
        spec = importlib.util.spec_from_file_location("claims_under_test", HERE / "worker-state.py")
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        class Snapshot:
            pid = 999991; returncode = 0
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def communicate(self): return "999992 999993 S\n", ""
        original_probe, original_sid = module.subprocess.Popen, module.os.getsid
        try:
            module.subprocess.Popen = lambda *args, **kwargs: Snapshot()
            def gone(pid): raise ProcessLookupError()
            module.os.getsid = gone
            check(module.session_live({"sid": 999990}), "fork/exit between ps and session lookup retains claim for a fresh scan")
            # A machine-wide exit is not a session member: the next snapshot decides.
            scans = []
            class Churn(Snapshot):
                def communicate(self):
                    scans.append(1)
                    return ("999992 999993 S\n" if len(scans) == 1 else "999994 999994 S\n"), ""
            module.subprocess.Popen = lambda *args, **kwargs: Churn()
            module.os.getsid = lambda pid: 1 if pid == 999994 else gone(pid)
            check(not module.session_live({"sid": 999990}) and len(scans) == 2,
                  "one vanished unrelated process costs a rescan, not a refused release")
            # A vanished process whose live group leader is in another session is resolved at once.
            scans.clear()
            module.subprocess.Popen = lambda *args, **kwargs: Snapshot()
            module.os.getsid = lambda pid: 1 if pid == 999993 else gone(pid)
            check(not module.session_live({"sid": 999990}) and not scans,
                  "a vanished process is placed by its live group leader")
            module.os.getsid = lambda pid: 999990 if pid == 999993 else gone(pid)
            check(module.session_live({"sid": 999990}),
                  "a vanished process whose group leader is in the session keeps the claim")
            scans.clear()
            class Member(Snapshot):
                def communicate(self):
                    scans.append(1)
                    return "999992 999990 S\n", ""
            module.subprocess.Popen = lambda *args, **kwargs: Member()
            module.os.getsid = gone
            check(module.session_live({"sid": 999990}) and len(scans) == 1,
                  "a vanished process in the session's own group is a member at once, without rescans")
        finally:
            module.subprocess.Popen, module.os.getsid = original_probe, original_sid
        queue("- [ ] **A — uncertain termination**")
        c = reserve("worker-1")
        # A definitively dead fixture PID models a victim that left before its
        # escaped SID could be captured. No signal is sent to any process.
        departed = subprocess.Popen(["true"]); departed.wait()
        run("protect", *c[:2], str(departed.pid), expected=2)
        run("release", *c[:2], expected=2)
        check(json.loads((d / "owner.json").read_text())["uncertain"],
              "ambiguous escaped victim surfaces inspection error and preserves claim")
        (d / "owner.json").unlink(); d.rmdir()  # fixture cleanup after proving preservation
        # Intentional owner-stop cleanup bypasses crash TTL only for confirmed dead.
        queue("- [ ] **A — restart test**")
        owner = subprocess.Popen(["sleep", "60"]); children.append(owner)
        child = subprocess.Popen(["sleep", "60"]); children.append(child)
        c = reserve("worker-1", pid=owner.pid)
        run("child", *c[:2], str(child.pid))
        lock = state / "worker-1/engine.lock"; lock.parent.mkdir(exist_ok=True); lock.touch()
        owner.terminate(); owner.wait()
        run("stopped", expected=4)
        run("restart", expected=4)
        check(lock.exists() and (state / "owner-stopped").exists(), "stop/restart protects surviving CLI and fresh engine lock")
        child.terminate(); child.wait()
        run("restart")
        check(not lock.exists() and not (state / "claims/A").exists() and not (state / "owner-stopped").exists(),
              "intentional restart retires confirmed-dead claim and fresh worker lock immediately")
        c = reserve("worker-1"); release(c)
        # An unidentified owner can never be silently expired as a dead owner.
        d.mkdir(); (d / "owner.json").write_text("{}")
        reserve("worker-1", stale=0, expected=2)
        check((d / "owner.json").read_text() == "{}", "schema-corrupt owner record is preserved, even after expiry")
        (d / "owner.json").unlink(); d.rmdir()
        # Unknown artifacts fail closed and are preserved, never recursively deleted.
        queue("- [ ] **A — next**")
        d.mkdir(); (d / "unknown.txt").write_text("preserve")
        reserve("worker-1", stale=0, expected=2)
        check((d / "unknown.txt").read_text() == "preserve", "malformed claim is preserved and blocks dispatch")
        (d / "unknown.txt").unlink(); d.rmdir()
        # Real tick()/CLI dispatch in a process group owned by this proof. System
        # integrations are stubs with different names; none of the banned host
        # commands, installed daemon, keys, applications or launchd is executed.
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.name", "fixture"], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(repo), "add", "SUITE_TODO.md"], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm", "fixture"], check=True)
        subprocess.run(["git", "-C", str(repo), "update-ref", "refs/remotes/origin/main", "HEAD"], check=True)
        home = root / "home"; (home / "Desktop").mkdir(parents=True)
        bin_dir = root / "bin"; bin_dir.mkdir()
        for name in ("fixture-launchctl", "fixture-osascript", "fixture-curl", "security", "caffeinate"):
            f = bin_dir / name; f.write_text("#!/bin/sh\nexit 0\n"); f.chmod(0o755)
        f = bin_dir / "df"
        f.write_text("#!/bin/sh\necho 'Filesystem 1M-blocks Used Available Capacity Mounted'\necho '/dev/test 1000000 1 999999 1% /'\n")
        f.chmod(0o755)
        daemon = root / "fixture-daemon.sh"
        source = (HERE / "archive-suite-autonomous.sh").read_text()
        for old, new in (("launchctl", "fixture-launchctl"), ("osascript", "fixture-osascript"), ("curl", "fixture-curl")):
            source = source.replace(old, new)
        daemon.write_text(source)
        capture = root / "captured.json"
        cli = root / "cli.py"
        cli.write_text("#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\n"
                       + "Path(" + repr(str(capture)) + ").write_text(json.dumps({'args':sys.argv[1:], 'worker':os.environ.get('AUTONOMOUS_WORKER_STATE'), 'unattended':os.environ.get('ARCHIVE_UNATTENDED')}))\n"
                       + "p=Path(" + repr(str(plan)) + "); t=p.read_text(); p.write_text(t.replace('RUN STATUS: IN_PROGRESS','RUN STATUS: COMPLETE'))\n"
                       + "print('{\"type\":\"turn.completed\"}')\n")
        cli.chmod(0o755)
        queue("- [ ] **A — assigned**")
        state.mkdir(exist_ok=True)
        (state / "resume-prompt.txt").write_text("autonomous maintenance session\nSTEP 2 pick first item\n")
        (state / "codex-preamble.txt").write_text("CODEX PREAMBLE\n")
        denv = dict(env, HOME=str(home), PATH=str(bin_dir) + ":" + os.environ["PATH"],
                    AUTONOMOUS_REPO=str(repo), AUTONOMOUS_AGENT="codex", AUTONOMOUS_CODEX=str(cli),
                    AUTONOMOUS_CODEX_MODEL="fixture", AUTONOMOUS_WORKER_ID="worker-1",
                    AUTONOMOUS_DOC_PREGATE="0", AUTONOMOUS_GATE_EVERY="0", AUTONOMOUS_COMPACTOR=str(root / "none"),
                    AUTONOMOUS_YIELD_CMD=str(root / "none"), AUTONOMOUS_GRANT_CMD=str(root / "none"), AUTONOMOUS_USAGE_CMD=str(root / "none"),
                    AUTONOMOUS_STATUS_CMD="/usr/bin/true", AUTONOMOUS_MAXRUN="10", AUTONOMOUS_HB_POLL="1",
                    AUTONOMOUS_INTERVAL="1", AUTONOMOUS_MAX_NOCOMPLETE="0", AUTONOMOUS_IDLE_STOP="0")
        denv.pop("AUTONOMOUS_WORKER_STATE", None)
        with (root / "daemon-output").open("w") as out:
            full = subprocess.Popen(["bash", str(daemon)], env=denv, stdout=out, stderr=out, start_new_session=True)
            try:
                full.wait(timeout=20)
            finally:
                # Only this proof's private process group; also reaps its watchdogs.
                try:
                    os.killpg(full.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                full.wait()
        check(full.returncode == 0 and capture.exists(), "real daemon dispatch completes with scratch CLI")
        captured = json.loads(capture.read_text())
        prompts = [a for a in captured["args"] if "SUPERVISOR ASSIGNMENT" in a]
        check(len(prompts) == 1 and "Your ONE item is A" in prompts[0] and "OVERRIDES ALL PICK" in prompts[0],
              "supervisor-selected item reaches CLI in one overriding prompt argv")
        check(captured["worker"] == str(state / "worker-1") and captured["unattended"] == "1",
              "worker artifacts are isolated while unattended environment is preserved")
        check((state / "last-session.log").is_symlink() and (state / "worker-1/last-session.log").exists(),
              "legacy status log mirrors worker-1 without mixing session state")
        check(not (state / "claims/A").exists() and not (state / "worker-1/engine.lock").exists(),
              "real dispatch releases claim and engine lock only after session ends")
        queue("- [ ] **A — worktree test**")
        worktree = root / "worker checkout"
        subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", str(worktree), "-b", "fixture-worker"], check=True)
        c = reserve("worker-1")
        run("worktree", *c[:2], str(worktree))
        record = json.loads((state / "claims/A/owner.json").read_text())
        check(record["worktree"] == str(worktree.resolve()), "claim records only an isolated worktree of the same repository")
        run("worktree", *c[:2], str(repo), expected=2)
        check(record["worktree"] == json.loads((state / "claims/A/owner.json").read_text())["worktree"],
              "primary checkout registration refuses and preserves the isolated path")
        run("idle", "--", "python3", "-c", "raise SystemExit(99)", expected=4)
        release(c)
        # Inject a departed victim at the watchdog's real protect boundary.
        # Failed protection must retain uncertainty without disabling TERM/KILL
        # or leaving the supervisor stuck in wait forever.
        fault_helper = root / "departed-victim.py"
        fault_helper.write_text("import os,subprocess,sys\nargs=sys.argv[1:]\n"
                                + "if 'protect' in args:\n departed=subprocess.Popen(['true']); departed.wait()\n"
                                + " args=args[:args.index('protect')+3]+[str(departed.pid)]\n"
                                + "os.execv(sys.executable,[sys.executable," + repr(str(HERE / "worker-state.py")) + "]+args)\n")
        hang = root / "hang.py"
        hang.write_text("#!/usr/bin/env python3\nimport os,time\nfrom pathlib import Path\n"
                        + "Path(" + repr(str(capture)) + ").write_text(str(os.getpid()))\ntime.sleep(60)\n")
        hang.chmod(0o755); capture.unlink()
        henv = dict(denv, AUTONOMOUS_CLAIMS_CMD=str(fault_helper), AUTONOMOUS_CODEX=str(hang), AUTONOMOUS_MAXRUN="1")
        with (root / "watchdog-output").open("w") as out:
            hung = subprocess.Popen(["bash", str(daemon)], env=henv, stdout=out, stderr=out, start_new_session=True)
            try:
                hung.wait(timeout=20)
                check(hung.returncode == 0 and capture.exists()
                      and json.loads((d / "owner.json").read_text())["uncertain"]
                      and "PARKED (worker claim inspection required)" in (state / "daemon.log").read_text(),
                      "failed watchdog protection still terminates hung CLI and parks with claim preserved")
            finally:
                # Exact private session identity; a failed assertion must not leave
                # this intentionally hung CLI outside the supervisor's group.
                if (d / "owner.json").exists():
                    owned = json.loads((d / "owner.json").read_text())
                    pid, birth = owned.get("child"), owned.get("child_start")
                    try:
                        if pid and birth and module.identity(pid) == birth and os.getsid(pid) == owned.get("sid"):
                            os.killpg(owned["sid"], signal.SIGKILL)
                    except ProcessLookupError: pass
                try: os.killpg(hung.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                hung.wait()
        (d / "owner.json").unlink(); d.rmdir()
        # Permanent invalid claim state must park, so launchd KeepAlive cannot
        # repeatedly relaunch into the same inspection error.
        d.mkdir(); (d / "owner.json").write_text("{}")
        job = home / "Library/LaunchAgents/com.archivesuite.autonomous.plist"
        job.parent.mkdir(parents=True); job.write_text("private fixture")
        capture.unlink(missing_ok=True)
        p = subprocess.run(["bash", str(daemon)], env=denv, capture_output=True, text=True, timeout=20)
        check(p.returncode == 0 and not capture.exists() and not job.exists()
              and (d / "owner.json").read_text() == "{}"
              and "worker claim inspection required" in (state / "daemon.log").read_text(),
              "invalid claim parks durably, launches no CLI and preserves ambiguous state")
        (d / "owner.json").unlink(); d.rmdir()
        # Second startup must not move a live legacy serial lock aside.
        (state / "engine.lock").unlink(); (state / "engine.lock").touch()
        p = subprocess.run(["bash", str(daemon)], env=denv, capture_output=True, text=True)
        check(p.returncode == 2 and "serial engine still active" in p.stderr and not (state / "engine.lock").is_symlink(),
              "fresh legacy engine prevents worker-state migration")
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
            child.wait()

print(f"prove-worker-claims: {PASS} passed", flush=True)
