#!/usr/bin/env bash
# PreToolUse(Bash) hook — a model or segmenter run outside the Mac-wide heavy lock is refused, in unattended runs.
#
# Why (owner, 2026-10-31): at 13:08 that day the Mac panicked with memory and swap exhausted, swap having grown
# into the last of the free disk. An engine session (W46.ocr-ppocrv6-hands) had started Apple Vision's line
# pass (layout-order over xargs) and kraken's blla segmenter straight into the background, beside two other
# sessions; neither took the heavy lock, so nothing serialised them against the other heavy work on the Mac.
# Builds already take the lock through the xcodebuild PATH shim; these tools are called by absolute path
# (a venv's bin/kraken, the cache's layout-order), which a PATH shim never sees, so this hook checks the
# command string instead. Agent Manager ISSUES.md has the incident.
#
# What it matches: a command segment whose program is kraken, ketos or layout-order (directly, or through
# xargs, nohup, time, timeout, env, nice, a loop or if body, or bash -c), or python -m mlx_vlm/kraken. Commands
# are split the way the shell splits them (quotes kept, heredoc bodies skipped), and a segment run by
# ops/autonomous/heavy-run.py or Vision OCR's run-guarded.sh is not looked inside: it holds the lock. Reading
# about these tools (grep, ls, cat, pip show) is untouched, since none of them is the program of its segment.
# A script that runs a heavy tool itself is not seen: the session prompt tells sessions to wrap the script.
#
# Codex sessions do not run Claude hooks: ops/autonomous/pyguard/sitecustomize.py, on every engine session's
# PYTHONPATH (owner, 2026-11-12), refuses the same Python programs for any agent at interpreter start.
# SCOPE: unattended only (ARCHIVE_UNATTENDED=1). CONTRACT: exit 0 allow, exit 2 deny with the reason on stderr.
# Fail-open on any internal error: a broken hook must never wedge a run.
set -uo pipefail

[ "${ARCHIVE_UNATTENDED:-0}" = "1" ] || exit 0

payload="$(cat 2>/dev/null)" || exit 0
[ -n "$payload" ] || exit 0

hit="$(printf '%s' "$payload" | python3 -c '
import json, os, re, shlex, sys
try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(0)
HEAVY = {"kraken", "ketos", "layout-order"}
WRAP = {"nohup", "time", "env", "nice", "caffeinate", "command", "exec", "timeout", "gtimeout", "arch",
        "taskpolicy", "sudo", "do", "then", "else", "if", "while", "until", "!", "{", "}"}
XARGS_ARG = {"-n", "-P", "-I", "-L", "-s", "-d", "-E", "-J", "-R", "-S"}
def no_heredocs(c):   # a heredoc body is data, not commands
    out, lines, i = [], c.split("\n"), 0
    while i < len(lines):
        out.append(lines[i])
        m = re.search(r"<<-?\s*[\x27\x22]?(\w+)[\x27\x22]?", lines[i])
        i += 1
        if m:
            while i < len(lines) and lines[i].strip() != m.group(1):
                i += 1
            i += 1
    return "\n".join(out)
def segments(c):
    lx = shlex.shlex(c, posix=True, punctuation_chars="();<>|&\n")
    lx.whitespace = " \t\r"
    lx.whitespace_split = True
    seg = []
    for t in lx:
        if t and set(t) <= set("();<>|&\n"):
            if seg: yield seg
            seg = []
        else:
            seg.append(t)
    if seg: yield seg
def skip_wrappers(w):
    while w:
        if w[0] in WRAP or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w[0]):
            w = w[1:]
            while w and (w[0].startswith("-") or re.match(r"^[0-9.]+[smhd]?$", w[0])):
                w = w[1:]
        else:
            return w
    return w
def heavy(c, depth=0):
    for w in segments(no_heredocs(c)):
        w = skip_wrappers(w)
        if not w:
            continue
        prog = os.path.basename(w[0])
        if prog.startswith("python") and len(w) > 1 and os.path.basename(w[1]) == "heavy-run.py":
            continue                       # wrapped: the lock holds whatever it runs
        if prog == "run-guarded.sh":
            continue
        if prog == "xargs":
            rest, i = w[1:], 0
            while i < len(rest) and rest[i].startswith("-"):
                i += 2 if rest[i] in XARGS_ARG else 1
            prog = os.path.basename(rest[i]) if i < len(rest) else ""
        if prog in HEAVY:
            return prog
        if prog.startswith("python") and "-m" in w:
            mod = w[w.index("-m") + 1] if w.index("-m") + 1 < len(w) else ""
            if mod.split(".")[0] in ("mlx_vlm", "kraken", "ketos"):
                return mod.split(".")[0]
        if prog in ("bash", "sh", "zsh") and "-c" in w and depth < 3:
            i = w.index("-c") + 1
            if i < len(w):
                inner = heavy(w[i], depth + 1)
                if inner:
                    return inner
    return ""
try:
    print(heavy(cmd))
except Exception:
    pass
' 2>/dev/null)" || exit 0
[ -n "$hit" ] || exit 0

cat >&2 <<EOF
BLOCKED by .claude/hooks/heavy-unlocked.sh — $hit runs outside the Mac-wide heavy lock

A model or segmenter run in an unattended session takes the heavy lock, background runs included, so it is
serialised against builds, VM runs and the other sessions' model runs. On 2026-10-31 two such runs started
in the background beside other work exhausted memory and the Mac panicked.

Do this instead: wrap the same command, unchanged,
  python3 ops/autonomous/heavy-run.py run -- <command>
(or Vision OCR's run-guarded.sh, which also checks free memory first). Put the whole pipeline inside one
call, e.g.  python3 ops/autonomous/heavy-run.py run -- bash -c '<the pipeline>' , and use the Bash tool's
run_in_background for a long run rather than a trailing &. Do not work around this hook.
EOF
exit 2
