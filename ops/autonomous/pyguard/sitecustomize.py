"""Refuse a model or segmenter run outside the heavy lock, in any unattended session, whichever agent runs it.

Why (owner, 2026-11-12): `.claude/hooks/heavy-unlocked.sh` refuses `kraken`, `ketos` and `python -m mlx_vlm`,
`kraken` or `ketos` run outside `ops/autonomous/heavy-run.py`, but a Claude hook never sees a Codex session's
commands, so under Codex the rule was prose only (codex-preamble.txt). The 2026-10-31 panic came from exactly such
runs started beside other heavy work (Agent Manager ISSUES.md). The engine puts this folder on every Archive Suite
session's PYTHONPATH (Agent Manager projects.json "env"), so Python imports this file at start-up, before it runs a
script or resolves a `-m` module.

What it refuses, with exit code 2 and the reason on stderr:
- a console script named kraken or ketos (a venv's bin/kraken is a Python script);
- python -m mlx_vlm..., kraken... or ketos....
It does nothing when ARCHIVE_UNATTENDED is not 1 (interactive sessions), when the heavy lock is held
(MAC_HEAVY_HELD=1 or ARCHIVE_HEAVY_TOKEN, which heavy-run.py sets for everything it runs), or on Python before
3.10, which does not expose the full command at start-up. Not covered: layout-order (a Swift program) and a
script that imports mlx_vlm or kraken itself; the hook and the preamble still cover those for Claude.

Any other sitecustomize on sys.path still runs after this one. Any fault here lets Python start normally.
"""
import os
import sys

HEAVY_SCRIPTS = {"kraken", "ketos"}
HEAVY_MODULES = {"mlx_vlm", "kraken", "ketos"}


def _refusal(argv):
    if os.environ.get("ARCHIVE_UNATTENDED") != "1":
        return None
    if os.environ.get("MAC_HEAVY_HELD") == "1" or os.environ.get("ARCHIVE_HEAVY_TOKEN"):
        return None
    args = list(argv or [])[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-m":
            mod = args[i + 1] if i + 1 < len(args) else ""
            return mod.split(".")[0] if mod.split(".")[0] in HEAVY_MODULES else None
        if a == "-c" or a == "-" or not a.startswith("-"):
            if a.startswith("-"):
                return None
            return os.path.basename(a) if os.path.basename(a) in HEAVY_SCRIPTS else None
        i += 2 if a in ("-W", "-X", "--check-hash-based-pycs") else 1
    return None


def _chain():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in sys.path:
        try:
            if not p or os.path.abspath(p) == here:
                continue
            path = os.path.join(p, "sitecustomize.py")
            if os.path.isfile(path):
                import importlib.util
                spec = importlib.util.spec_from_file_location("_chained_sitecustomize", path)
                spec.loader.exec_module(importlib.util.module_from_spec(spec))
                return
        except Exception:
            return


try:
    _what = _refusal(getattr(sys, "orig_argv", None))
except Exception:
    _what = None
if _what:
    sys.stderr.write(
        "heavy-lock guard: refused '%s' outside the heavy lock in an unattended session. Run it as\n"
        "  python3 ops/autonomous/heavy-run.py run -- <the same command>\n"
        "(background runs included; owner 2026-10-31 and 2026-11-12, ops/autonomous/pyguard/sitecustomize.py).\n"
        % _what)
    sys.stderr.flush()
    os._exit(2)
_chain()
