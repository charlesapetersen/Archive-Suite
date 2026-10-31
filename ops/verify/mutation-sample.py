#!/usr/bin/env python3
"""mutation-sample.py — plant mutants in the irreversible paths and see whether the tests notice (W40.e7).

USAGE:  ops/verify/mutation-sample.sh <core|processor|notes|reader> [--check] [--only ID[,ID…]]
        (the .sh wrapper takes the Mac-wide heavy lock; run this file directly only for --check)
ENV:    MUT_OUT (default /tmp/mutation-sample) — per-mutant logs and <area>.tsv land in $MUT_OUT/<area>/
EXIT:   0 = every mutant was killed · 1 = at least one survived · 2 = could not measure (baseline red,
        a mutant did not apply or did not compile, a source file was dirty) — never read as "all killed"

One mutant at a time: replace one exact, unique snippet in one source file, rebuild, run the area's tests,
put the original back (always, in a `finally`; the original bytes are also saved in $MUT_OUT/<area>/.orig/).

"Prove each mutant landed before believing it survived" (the plan's wording). A mutant counts as LANDED only
when the compiled object file for its source differs from the baseline object — so a stale build, a wrong
path or a cached test product cannot pass for a survivor. A mutant that did not change its object file is
reported `not-landed` and makes the run exit 2.

Verdicts:  killed (tests failed) · timeout (tests hung; counted as killed, but listed) · survived (tests
green, object changed) · not-landed · compile-error (the mutant is invalid; fix its text).
"""
import functools, hashlib, os, pathlib, subprocess, sys, time
print = functools.partial(print, flush=True)  # progress lines reach a redirected log as they happen

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT_BASE = pathlib.Path(os.environ.get("MUT_OUT", "/tmp/mutation-sample"))

TAGW = "packages/ArchiveCore/Sources/ArchiveCore/Tags/TagWrite.swift"
CSES = "ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/CaptureSession.swift"
LCP = "ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/LiveCaptureProcessor.swift"
NSTORE = "ArchiveNotes/macOS/Sources/ArchiveNotes/Store/NoteStore.swift"
FMC = "ArchiveNotes/macOS/Sources/ArchiveNotes/Store/FrontMatterCodec.swift"
RTW = "ArchiveReader/macOS/Sources/ArchiveReader/Core/TagWriter.swift"
NAV = "ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift"
LEDGER = "ArchiveReader/macOS/Sources/ArchiveReader/Core/AuditLedger.swift"

# (id, file, original, mutant, what it breaks). `original` must occur exactly once in `file`.
MUTANTS = {
  "core": [
    ("C01", TAGW, "guard current.matches(expectedIdentity) else {",
     "guard current.matches(expectedIdentity) || true else {", "identity re-check skipped: a replaced file is tagged"),
    ("C02", TAGW, "guard let current = FileIdentity.capture(target) else {",
     "guard let current = FileIdentity.capture(target) ?? Optional(expectedIdentity) else {",
     "a target with no identity (moved/deleted) passes the check"),
    ("C03", TAGW, "case let .failure(why):\n                    throw TagWriteError.unreadable(why)",
     "case .failure:\n                    before = []; beforeLabel = nil",
     "an unreadable tag read is treated as no tags (the W26.deny bug)"),
    ("C04", TAGW, "if normalizedLabel(intendedLabel) != normalizedLabel(beforeLabel) {\n                    try (target as NSURL).setResourceValue(intendedLabel ?? 0",
     "if normalizedLabel(intendedLabel) == normalizedLabel(beforeLabel) {\n                    try (target as NSURL).setResourceValue(intendedLabel ?? 0",
     "the colour label is written only when it is unchanged"),
    ("C05", TAGW, "if normalizedLabel(intendedLabel) == normalizedLabel(beforeLabel), normalizedLabel(afterLabel) != normalizedLabel(beforeLabel) {",
     "if false, normalizedLabel(afterLabel) != normalizedLabel(beforeLabel) {", "label-drift restore removed"),
    ("C06", TAGW, "guard multisetEqual(after, intendedTags) else {",
     "guard multisetEqual(after, intendedTags) || true else {", "verify-after-write of the tags skipped"),
    ("C07", TAGW, "guard normalizedLabel(afterLabel) == normalizedLabel(expectedLabel) else {",
     "guard normalizedLabel(afterLabel) == normalizedLabel(expectedLabel) || true else {", "verify-after-write of the label skipped"),
    ("C08", TAGW, "add: Array(beforeSet.subtracting(afterSet)),",
     "add: Array(afterSet.subtracting(beforeSet)),", "set inverse re-adds what was added (undo wrong)"),
    ("C09", TAGW, "add: multisetDifference(before, minus: after),",
     "add: multisetDifference(after, minus: before),", "occurrence inverse re-adds the wrong surplus"),
    ("C10", TAGW, "if let n = remaining[t], n > 0 { remaining[t] = n - 1 }",
     "if let n = remaining[t], n > 1 { remaining[t] = n - 1 }", "multiset difference off by one"),
    ("C11", TAGW, "    token == target || (isReadStateWord(target)",
     "    token.hasPrefix(target) || (isReadStateWord(target)", "removal matches by prefix (removing a subject strips a longer one)"),
    ("C12", TAGW, "public func multisetEqual(_ a: [String], _ b: [String]) -> Bool { a.sorted() == b.sorted() }",
     "public func multisetEqual(_ a: [String], _ b: [String]) -> Bool { Set(a) == Set(b) }", "verify ignores duplicate counts"),
  ],
  "processor": [
    ("P01", CSES, "do { try fm.trashItem(at: url, resultingItemURL: nil); return true }",
     "do { try fm.removeItem(at: url); return true }", "originals hard-deleted instead of moved to the Trash"),
    ("P02", CSES, "catch { try? fm.removeItem(at: url); return false }",
     "catch { return true }", "a failed Trash move is reported as done"),
    ("P03", CSES, "guard recordFiledGroups(idsToRecord) else { return false }",
     "_ = recordFiledGroups(idsToRecord)", "photos trashed although the filed-group ledger did not save"),
    ("P04", CSES, "let removed = photos.filter { filed.contains($0.url) }",
     "let removed = photos.filter { !filed.contains($0.url) }", "the UNFILED photos are trashed"),
    ("P05", CSES, "guard !filedGroupIds.isSubset(of: durableFiledGroupIds) else { return true }",
     "guard filedGroupIds.isSubset(of: durableFiledGroupIds) else { return true }", "the ledger write is skipped when it is needed"),
    ("P06", CSES, "guard clearPhase == \"prepared\", clearToken == token else { return false }",
     "guard clearPhase == \"prepared\" || clearToken == token else { return false }", "a Clear commits without a matching prepare"),
    ("P07", LCP, "if pdfExpected > 0 && pdfLanded == pdfExpected { filedGroupIds.insert(seg.groupId) }",
     "if pdfExpected > 0 || pdfLanded == pdfExpected { filedGroupIds.insert(seg.groupId) }", "a group whose PDF did not land counts as filed"),
    ("P08", LCP, "let allFiled = failedMoves == 0 && filedGroupIds.count == totalSegments",
     "let allFiled = filedGroupIds.count == totalSegments", "a failed move does not stop 'all filed'"),
    ("P09", LCP, "safe.formUnion(sources.filter { !withheld.contains($0) })",
     "safe.formUnion(sources)", "withheld sources are retired with the rest"),
    ("P10", LCP, "allPlannedFiled && segmentsStillStaged == 0",
     "allPlannedFiled || segmentsStillStaged == 0", "staging reclaimed while segments are still in it"),
    ("P11", LCP, "if fm.fileExists(atPath: dest.path) { CaptureSession.trashOrRemove(dest, fm) }",
     "if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }", "an existing destination is hard-deleted, not trashed"),
    ("P12", LCP, "case .failed: failedMoves += 1; return false",
     "case .failed: failedMoves += 1; return true", "a failed move counts as landed"),
    ("P13", LCP, "guard self.session.recordFiledGroups(filedGroups) else {",
     "guard self.session.recordFiledGroups(filedGroups) || true else {", "finalize retires sources although the ledger did not save"),
  ],
  "notes": [
    ("N01", NSTORE, "if body != expectedBody && body != markdown {",
     "if body != expectedBody && body == markdown {", "an outside edit is overwritten instead of kept as a recovered draft"),
    ("N02", NSTORE, "draft.id = UUID()\n", "\n", "the recovered draft reuses the original's id"),
    ("N03", NSTORE, "if body == markdown { return BodySave(current: current, recoveredDraft: nil) }",
     "if body != markdown { return BodySave(current: current, recoveredDraft: nil) }", "a changed body is never saved"),
    ("N04", NSTORE, "try fm.moveItem(at: currentURL, to: targetURL)",
     "_ = currentURL", "a title rename does not move the file (the save lands in a second file)"),
    ("N05", NSTORE, "if fm.fileExists(atPath: targetURL.path) {\n                targetURL = Self.disambiguate(targetURL, in: dir)",
     "if false {\n                targetURL = Self.disambiguate(targetURL, in: dir)", "a rename onto an existing file is not disambiguated"),
    ("N06", NSTORE, "_ = try fm.replaceItemAt(targetURL, withItemAt: replacementURL, backupItemName: nil, options: [])",
     "try Data(text.utf8).write(to: targetURL, options: [.atomic])", "a save replaces the inode and drops the file's Finder tags"),
    ("N07", NSTORE, "guard (revisions[ref.id] ?? 0) == ref.revision else { return false }",
     "guard (revisions[ref.id] ?? 0) == ref.revision || true else { return false }", "a stale revision still writes (lost update)"),
    ("N08", NSTORE, "item.trailingBodyRaw = parsed.leadingText\n                    item.blocks = parsed.blocks",
     "item.blocks = parsed.blocks", "the text before the first block is not saved"),
    ("N09", FMC, "lines.append(\"modified: \\(formatISO(item.modified))\")",
     "lines.append(\"modified: \\(formatISO(item.created))\")", "the modified date is written as the created date"),
    ("N10", FMC, "result += BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)",
     "result += BlockParser.serialize(leadingText: \"\", blocks: item.blocks)", "the leading body text is dropped on save"),
    ("N11", FMC, "if s.hasPrefix(\" \") || s.hasSuffix(\" \") { return true }",
     "if s.hasPrefix(\" \") && s.hasSuffix(\" \") { return true }", "a value with one edge space is written unquoted (space lost)"),
    ("N12", FMC, "lines.append(\"date_uncertain: \\(item.dateUncertain)\")",
     "lines.append(\"date_uncertain: \\(!item.dateUncertain)\")", "date_uncertain is written inverted"),
  ],
  "reader": [
    ("R01", RTW, "&& normalizedLabel(label) != normalizedLabel(change.afterLabel)",
     "&& normalizedLabel(label) == normalizedLabel(change.afterLabel)", "undo overwrites a colour set since the change"),
    ("R02", RTW, "if colourChangedSince { targetLabel = label }",
     "if colourChangedSince { _ = label }", "a newer colour is replaced by the undone one"),
    ("R03", RTW, "removalBudget[t] = min(n, max(0, now[t, default: 0] - was[t, default: 0]))",
     "removalBudget[t] = n", "undo strips a token past its count before the change"),
    ("R04", RTW, "additionBudget[t] = min(n, max(0, was[t, default: 0] - now[t, default: 0]))",
     "additionBudget[t] = n", "undo re-adds a token past its count before the change"),
    ("R05", RTW, "if let n = removalBudget[token], n > 0 { removalBudget[token] = n - 1 }",
     "if let n = removalBudget[token], n > 0 { _ = n }", "undo strips every copy of a removed token"),
    ("R06", RTW, "if let n = additionBudget[token], n > 0 { additionBudget[token] = n - 1; newTags.append(token) }",
     "if let n = additionBudget[token], n > 0 { _ = n; newTags.append(token) }", "undo adds every listed copy, ignoring the budget"),
    ("R07", RTW, "case .restoreLabel(let lbl): targetLabel = lbl",
     "case .restoreLabel(let lbl): _ = lbl", "undo never restores the colour label"),
    ("R08", NAV, "guard let batch = undoGroups.last, let group = batch.first?.group else { return }",
     "guard let batch = undoGroups.first, let group = batch.first?.group else { return }", "Undo reverses the OLDEST change, not the latest"),
    ("R09", NAV, "guard isInsideMainArchive(target.url) else {",
     "guard isInsideMainArchive(target.url) || true else {", "undo writes to a file outside the current archive"),
    ("R10", NAV, "undoing: .init(before: entry.before, afterLabel: entry.afterLabel)))",
     "undoing: .init(before: entry.after, afterLabel: entry.afterLabel)))", "undo budgets against the post-change tags"),
    ("R11", LEDGER, "if let undone = entry.undoes { consumed.insert(undone); continue }",
     "if entry.undoes != nil { continue }", "an already-undone change is offered for undo again"),
    ("R12", LEDGER, "return order.reversed().filter { !consumed.contains($0) }.compactMap { groups[$0] }",
     "return order.filter { !consumed.contains($0) }.compactMap { groups[$0] }", "undo history order reversed"),
    ("R13", LEDGER, "if let atPath, atPath != expected {", "if let atPath, atPath == expected {",
     "undo target identity check inverted"),
  ],
}

# The drivers that cover finalize/Trash. MUT_DRIVERS=all widens it to every driver that spends no money (the
# sanitizer runner's list), to confirm a survivor is not killed somewhere else in the gate.
PROC_DRIVERS = ["test-recovery.sh", "test-manifest-persistence.sh", "test-merge-safety.sh"]
ALL_DRIVERS = """test-batch-resume.sh test-collection-organize.sh test-dual-date.sh test-institutional-compute-import.sh
test-filerelay.sh test-incremental-skip.sh test-local-models.sh test-localagent.sh test-manifest-persistence.sh
test-merge-safety.sh test-multipage-reocr.sh test-network-session.sh test-ocr-cascade.sh test-ocr-page-guidance.sh
test-ocr-page-kind.sh test-ocr-refusal.sh test-processfiles-tagwarn.sh test-processing-history.sh test-recovery.sh
test-retry-backend.sh test-segment-json.sh test-segmentation-chatgpt.sh test-segmentation-chooser.sh
test-segmentation-engine.sh test-segmentation-plan.sh test-segmentation-review.sh test-vision-hybrid.sh
test-usbmux-bridge.sh""".split()
if os.environ.get("MUT_DRIVERS") == "all":
    PROC_DRIVERS = ALL_DRIVERS


def run(cmd, cwd, log, timeout, env=None):
    """Run cmd, append its output to log, return (rc, timed_out)."""
    e = dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ.get("PATH", ""))
    if env:
        e.update(env)
    with open(log, "a") as fh:
        fh.write(f"\n$ (cd {cwd} && {' '.join(cmd)})\n"); fh.flush()
        try:
            p = subprocess.run(cmd, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT, env=e, timeout=timeout)
            return p.returncode, False
        except subprocess.TimeoutExpired:
            fh.write(f"\n[mut] TIMEOUT after {timeout}s\n")
            return 124, True


class Area:
    """How one area builds, tests, and where the object file of a source lands."""
    def __init__(self, name):
        self.name = name

    def test(self, log):  # → "pass" | "fail" | "timeout" | "build-fail"
        n = self.name
        if n == "core":
            rc, to = run(["swift", "test", "--scratch-path", ".build/mut"], ROOT / "packages/ArchiveCore", log, 1200)
            t = pathlib.Path(log).read_text(errors="replace")
            if to: return "timeout"
            if ": error:" in t and "Executed" not in t and "Test run with" not in t: return "build-fail"
            return "pass" if rc == 0 else "fail"
        if n in ("reader", "notes"):
            d = ROOT / ("ArchiveReader/macOS" if n == "reader" else "ArchiveNotes/macOS")
            scheme, target = ("ArchiveReader", "ArchiveReaderTests") if n == "reader" else ("ArchiveNotesUnit", "ArchiveNotesTests")
            cmd = ["xcodebuild", "test", "-scheme", scheme, "-destination", "platform=macOS",
                   f"-only-testing:{target}", "-derivedDataPath", "./build/mut-DD"]
            if n == "reader":
                cmd.append("-skip-testing:ArchiveReaderTests/DeepLinkTests")
            rc, to = run(cmd, d, log, 1500)
            t = pathlib.Path(log).read_text(errors="replace")
            if to: return "timeout"
            if "Testing cancelled because the build failed" in t or "** BUILD FAILED **" in t: return "build-fail"
            if rc == 0 and "** TEST SUCCEEDED **" in t: return "pass"
            return "fail" if "** TEST FAILED **" in t else "build-fail"
        # processor: one build, then the drivers that cover finalize/Trash
        d = ROOT / "ArchiveProcessor/macOS"
        rc, to = run(["xcodebuild", "build", "-scheme", "ArchiveProcessor", "-configuration", "Debug",
                      "-destination", "platform=macOS", "-derivedDataPath", "./build/DD"], d, log, 1500)
        if to or rc != 0: return "build-fail"
        for drv in PROC_DRIVERS:
            rc, to = run(["bash", f"scripts/{drv}"], ROOT / "ArchiveProcessor", log, 900)
            if to: return "timeout"
            if rc != 0:
                with open(log, "a") as fh: fh.write(f"\n[mut] {drv} FAILED rc={rc}\n")
                return "fail"
        return "pass"

    def object_hash(self, src):
        stem = pathlib.Path(src).name
        n = self.name
        if n == "core":
            # Either SwiftPM layout: `…/ArchiveCore.build/TagWrite.swift.o` or the swift-build one,
            # `…/ArchiveCore.build/Debug/ArchiveCore-t.build/Objects-normal/arm64/TagWrite.o`.
            base = ROOT / "packages/ArchiveCore/.build/mut"
            cands = [p for name in (stem + ".o", pathlib.Path(stem).stem + ".o") for p in base.rglob(name)
                     if "ArchiveCore" in str(p) and "Tests" not in str(p)]
        else:
            app = {"reader": "ArchiveReader", "notes": "ArchiveNotes", "processor": "ArchiveProcessor"}[n]
            base = ROOT / f"{app}/macOS/build/{'DD' if n == 'processor' else 'mut-DD'}/Build/Intermediates.noindex"
            obj = pathlib.Path(stem).stem + ".o"
            cands = [p for p in base.rglob(obj) if f"/{app}.build/" in str(p) and "Objects-normal" in str(p)]
        if not cands:
            return None
        h = hashlib.sha256()
        for p in sorted(cands):
            h.update(p.read_bytes())
        return h.hexdigest()[:16]


def main():
    args = sys.argv[1:]
    if not args or args[0] not in MUTANTS:
        print(__doc__); return 2
    name, check = args[0], "--check" in args
    only = None
    if "--only" in args:
        only = set(args[args.index("--only") + 1].split(","))
    muts = [m for m in MUTANTS[name] if only is None or m[0] in only]
    bad = 0
    for mid, f, orig, new, _ in muts:
        n = (ROOT / f).read_text().count(orig)
        if n != 1:
            print(f"[mut] {mid}: original occurs {n}× in {f}"); bad += 1
    if bad or check:
        print(f"[mut] {name}: {len(muts)} mutant(s), {bad} not unique/missing"); return 2 if bad else 0
    files = sorted({m[1] for m in muts})
    dirty = subprocess.run(["git", "status", "--porcelain", "--"] + files, cwd=ROOT, capture_output=True, text=True).stdout
    if dirty.strip():
        print(f"[mut] refusing: mutated sources are dirty:\n{dirty}"); return 2
    out = OUT_BASE / name
    (out / ".orig").mkdir(parents=True, exist_ok=True)
    area = Area(name)
    if name in ("reader", "notes"):
        subprocess.run(["xcodegen", "generate"], cwd=ROOT / ("ArchiveReader/macOS" if name == "reader" else "ArchiveNotes/macOS"),
                       capture_output=True, env=dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ["PATH"]))
    if name == "processor":
        subprocess.run(["xcodegen", "generate"], cwd=ROOT / "ArchiveProcessor/macOS", capture_output=True,
                       env=dict(os.environ, PATH="/opt/homebrew/bin:" + os.environ["PATH"]))
    log = out / "baseline.log"; log.write_text("")
    t0 = time.time(); res = area.test(log)
    print(f"[mut] {name} baseline: {res} ({time.time()-t0:.0f}s) — {log}")
    if res != "pass":
        return 2
    base_hash = {f: area.object_hash(f) for f in files}
    for f, h in base_hash.items():
        if h is None:
            print(f"[mut] no object file found for {f} — cannot prove landing"); return 2
    rows, worst = [], 0
    for mid, f, orig, new, why in muts:
        path = ROOT / f
        original = path.read_bytes()
        (out / ".orig" / f"{mid}-{path.name}").write_bytes(original)
        log = out / f"{mid}.log"; log.write_text(f"[mut] {mid} {f}\n- {orig}\n+ {new}\n")
        try:
            path.write_text(original.decode().replace(orig, new, 1))
            t0 = time.time(); res = area.test(log); secs = time.time() - t0
            h = area.object_hash(f)
        finally:
            path.write_bytes(original)
        landed = h is not None and h != base_hash[f]
        verdict = {"fail": "killed", "timeout": "timeout", "build-fail": "compile-error"}.get(res, "survived")
        if verdict == "survived" and not landed:
            verdict = "not-landed"
        if verdict in ("killed", "timeout") and not landed:
            verdict += " (object unchanged?)"
        if verdict == "survived": worst = max(worst, 1)
        if verdict in ("not-landed", "compile-error"): worst = 2
        rows.append((mid, verdict, f"{secs:.0f}", h or "-", f, why))
        print(f"[mut] {mid}: {verdict}  obj {base_hash[f]}→{h}  {secs:.0f}s  — {why}")
    # Leave the build matching the source again, so the next run's baseline is a true baseline.
    area.test(out / "restore.log")
    with open(out / f"{name}.tsv", "w") as fh:
        fh.write("id\tverdict\tseconds\tobject\tfile\tbreaks\n")
        for r in rows: fh.write("\t".join(r) + "\n")
    k = sum(r[1].startswith(("killed", "timeout")) for r in rows)
    print(f"[mut] {name}: {k}/{len(rows)} killed — {out / (name + '.tsv')}")
    return worst


if __name__ == "__main__":
    sys.exit(main())
