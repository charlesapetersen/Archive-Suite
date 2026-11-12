#!/usr/bin/env bash
# prove-pyguard.sh — ops/autonomous/pyguard/sitecustomize.py refuses unlocked model/segmenter runs in unattended
# sessions (any agent), lets everything else start, and still runs another sitecustomize on the path.
# Needs a Python 3.10+ as python3 (orig_argv). Uses fake kraken/ketos scripts; no model is installed or run.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$here/pyguard"
py="${PYGUARD_PYTHON:-python3}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
printf '#!/usr/bin/env %s\nprint("ran")\n' "$py" > "$tmp/kraken"; chmod +x "$tmp/kraken"
cp "$tmp/kraken" "$tmp/ketos"
mkdir "$tmp/other"; printf 'import sys\nsys.stderr.write("chained\\n")\n' > "$tmp/other/sitecustomize.py"

check() {   # check NAME WANT_RC CMD...   (WANT_RC: 2 = refused, ok = anything but 2)
  local name="$1" want="$2"; shift 2
  out="$("$@" 2>&1)"; rc=$?
  if { [ "$want" = 2 ] && [ "$rc" = 2 ] && grep -q 'heavy-lock guard' <<<"$out"; } ||
     { [ "$want" = ok ] && ! grep -q 'heavy-lock guard' <<<"$out"; }; then
    echo "  ✓ $name"
  else
    echo "  ✗ $name (rc=$rc): $out"; fail=1
  fi
}
U=(env -u MAC_HEAVY_HELD -u ARCHIVE_HEAVY_TOKEN PYTHONPATH="$guard" ARCHIVE_UNATTENDED=1)
check "python -m mlx_vlm refused"          2  "${U[@]}" "$py" -m mlx_vlm.generate --help
check "python -m kraken.ketos refused"     2  "${U[@]}" "$py" -m kraken.ketos
check "python -X opt -m ketos refused"     2  "${U[@]}" "$py" -X utf8 -m ketos
check "kraken console script refused"      2  "${U[@]}" "$py" "$tmp/kraken" segment
check "ketos via shebang refused"          2  "${U[@]}" "$tmp/ketos"
check "ordinary -m allowed"                ok "${U[@]}" "$py" -m json.tool --help
check "ordinary script allowed"            ok "${U[@]}" "$py" -c 'print(1)'
check "a script named kraken.py allowed"   ok "${U[@]}" "$py" -c 'import sys' kraken
check "held lock (MAC_HEAVY_HELD) allowed" ok env PYTHONPATH="$guard" ARCHIVE_UNATTENDED=1 MAC_HEAVY_HELD=1 "$py" "$tmp/kraken"
check "held lock (token) allowed"          ok env PYTHONPATH="$guard" ARCHIVE_UNATTENDED=1 ARCHIVE_HEAVY_TOKEN=x "$py" "$tmp/kraken"
check "interactive allowed"                ok env -u ARCHIVE_UNATTENDED PYTHONPATH="$guard" "$py" "$tmp/kraken"
out="$(env PYTHONPATH="$guard:$tmp/other" ARCHIVE_UNATTENDED=1 "$py" -c 'print(1)' 2>&1)"
if grep -q chained <<<"$out"; then echo "  ✓ another sitecustomize still runs"; else echo "  ✗ chain: $out"; fail=1; fi
[ "$fail" = 0 ] && echo "prove-pyguard: ALL PASS" || { echo "prove-pyguard: FAIL"; exit 1; }
