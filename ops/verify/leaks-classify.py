#!/usr/bin/env python3
"""leaks-classify.py — split a `leaks` report into OUR leaks and framework noise (W40.e2).

USAGE: leaks-classify.py REPORT [--ours REGEX]          exit 0 = none of ours · 1 = ours found · 2 = no report
       --ours matches stack-frame IMAGE names. Default ^(Archive|com\.archive): the apps' executables and
       .debug.dylib (ArchiveCore links statically into them), ArchiveCoreTests, and the hosted test bundles,
       which `leaks` names by bundle id (com.archivenotes.tests). Tree text is matched for Module.Type names
       only, so a leaked string that merely contains a path such as ArchiveNotes.app does not count.

Why a classifier at all: a clean run of the Notes unit suite reports hundreds of leaked nodes inside three
AppIntents root cycles around the `com.apple.linkd.autoShortcut` XPC lookup that the sandboxed test host
cannot make; ArchiveCore's report has one 48-byte leak inside XCTest's own Swift Testing shim. Failing on
the raw count would fail every run for Apple's code. A root leak or root cycle is OURS when its allocation
stack (MallocStackLogging, which leaks-harvest.sh turns on) has a frame in one of our images, or its leak
tree names one of our types — a framework cycle that is holding one of our objects is still our problem.
Entry-point frames do not count: every main-thread stack in an app-hosted run starts in
`ArchiveNotesApp.$main()`, which would make every AppKit allocation look like ours.

It cannot tell a product leak from a test that leaked: in a unit run nearly everything is allocated under
a test. So each of ours is labelled with the test it came through, and a person triages it (phase rule 5).
The first run's findings were all test hygiene (W40.e2 evidence file).

`leaks` output, after the "leaks Report Version" line, is a run of groups:
    STACK OF 3 INSTANCES OF 'ROOT CYCLE: <NSXPCConnection>':
    5   libdispatch.dylib   0x18ac62120 _dispatch_worker_thread2 + 184      <- frames, image in column 2
    ====
        96 (6.12K) ROOT CYCLE: <NSXPCConnection 0xb708e4840> [192] …        <- one tree per instance;
           6 (800 bytes) _connection --> ROOT CYCLE: <xpc_connection_t …>      deeper indent = its children
Without MallocStackLogging there are no STACK/==== lines, only the trees.
"""
import re
import sys

FRAME = re.compile(r"^\s*\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.*)$")
ENTRY = re.compile(r"__debug_main_executable_dylib_entry_point|\$main\(\)|^main \+|^start \+")
TEST_IMAGE = re.compile(r"\.tests$|Tests$")
ROOT = re.compile(r"^( *)(\d+) \(([^)]*)\) ROOT (LEAK|CYCLE): (.*)$")
OUR_TYPE = re.compile(r"\bArchive\w*\.[A-Z_]|\$s\d+Archive")   # ArchiveNotes.NoteStore, or mangled


def parse(text):
    """Return a list of roots: {kind, nodes, size, line, tree: [lines], stack: [(image, symbol)]}."""
    marker = text.find("leaks Report Version")
    if marker < 0:
        return None
    lines = text[marker:].splitlines()
    roots, stack, in_stack, current, root_indent, left = [], [], False, None, None, 0
    for line in lines:
        if line.startswith("Binary Images:"):
            break
        if line.startswith("STACK OF "):
            m = re.match(r"STACK OF (\d+) INSTANCE", line)
            stack, in_stack, current, left = [], True, None, int(m.group(1)) if m else 1
            continue
        if in_stack:
            if line.startswith("===="):
                in_stack = False
            else:
                m = FRAME.match(line)
                if m and not ENTRY.search(m.group(2)):
                    stack.append((m.group(1), m.group(2).strip()))
            continue
        m = ROOT.match(line)
        if m and (current is None or len(m.group(1)) <= root_indent):
            root_indent = len(m.group(1))
            # A group's stack belongs to its N instances only; a tree printed after them without a STACK
            # header of its own (no MallocStackLogging record) must not inherit it.
            if left <= 0:
                stack = []
            left -= 1
            current = {"kind": m.group(4), "nodes": int(m.group(2)), "size": m.group(3),
                       "line": m.group(5).strip(), "tree": [line], "stack": list(stack)}
            roots.append(current)
        elif current is not None and line.strip():
            current["tree"].append(line)
    return roots


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    ours_pattern = r"^(Archive|com\.archive)"
    if "--ours" in argv:
        ours_pattern = argv[argv.index("--ours") + 1]
    ours = re.compile(ours_pattern)
    with open(argv[1], encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    roots = parse(text)
    if roots is None:
        print("leaks-classify: no 'leaks Report' in the file — leaks did not run or did not finish")
        return 2
    total = re.search(r"Process \d+: (\d+) leaks? for (\d+) total leaked bytes", text)
    mine = [r for r in roots
            if any(ours.search(img) for img, _ in r["stack"]) or any(OUR_TYPE.search(t) for t in r["tree"])]
    noise = [r for r in roots if r not in mine]
    print(f"leaks-classify: {total.group(1) if total else '?'} leaked node(s), "
          f"{total.group(2) if total else '?'} bytes, in {len(roots)} root(s): "
          f"{len(mine)} ours, {len(noise)} framework")
    groups = {}
    for r in mine:
        frames = [(img, sym) for img, sym in r["stack"] if ours.search(img)]
        # The stack lists outermost first, so the LAST of our frames is the one nearest the allocation.
        nearest = re.sub(r" \+ \d+", "", frames[-1][1]) if frames else "(no stack — named in the tree)"
        tests = [sym for img, sym in frames if TEST_IMAGE.search(img)]
        # Prefer a frame in a test TYPE: the compiler emits thunks such as
        # `@nonobjc NSPasteboard.__allocating_init(name:)` into the test bundle too.
        tests = [sym for sym in tests if re.search(r"Tests?\b", sym)] or tests
        via = re.sub(r" \+ \d+.*", "", tests[-1]) if tests else "no test frame"
        typ = re.sub(r" 0x[0-9a-fA-F]+.*", ">", r["line"])
        key = (r["kind"], typ, nearest, via)
        n, c = groups.get(key, (0, 0))
        groups[key] = (n + r["nodes"], c + 1)
    for (kind, typ, nearest, via), (n, c) in sorted(groups.items(), key=lambda kv: -kv[1][0]):
        print(f"  OURS  {c} root(s), {n} node(s): ROOT {kind} {typ}")
        print(f"        allocated at: {nearest[:150]}")
        print(f"        via test:     {via[:150]}")
    by_type = {}
    for r in noise:
        key = re.sub(r" 0x[0-9a-fA-F]+", "", r["line"])[:140]
        n, c = by_type.get(key, (0, 0))
        by_type[key] = (n + r["nodes"], c + 1)
    for key, (n, c) in sorted(by_type.items(), key=lambda kv: -kv[1][0]):
        print(f"  framework  {c} root(s), {n} node(s): ROOT {key}")
    return 1 if mine else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
