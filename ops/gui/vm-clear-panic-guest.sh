#!/usr/bin/env bash
# vm-clear-panic-guest.sh OUT_DIR — the GUEST half of tart_clear_panic (ops/gui/tart-lib.sh; read its header for
# why). Runs INSIDE the GUI VM from the repo mount. A file rather than a quoted blob inside `tart exec bash -lc`
# for the reason vm-seed-accessibility-guest.sh gives: the JSON the panic line is read from needs a third level
# of escaping there.
#
# A pending panic is any of: the PanicReporter link Diagnostics Reporter reads at login, the `.contents.panic`
# it points at, or a `panic-full-*.panic` report not yet retired. Each report is copied to OUT_DIR, then all of
# them are moved to DiagnosticReports/Retired/panic-acknowledged-<stamp>/ (where the 2026-11-26 hand fix put
# the earlier two), and the alert is closed. Nothing is deleted.
#
# Prints one `PANIC <file>: <first line of its panicString>` per report, then exactly one last line:
#   NONE            nothing was pending
#   CLEARED <dir>   it was pending; the reports are in <dir> and the link is gone
#   FAILED <why>    it was pending and is not cleared
set -u
out="${1:-}"
link=/private/var/db/PanicReporter/current.panic
dr=/Library/Logs/DiagnosticReports
shopt -s nullglob
files=("$dr"/panic-full-*.panic)
contents="$dr/.contents.panic"

pending() { [ -L "$link" ] || [ -e "$link" ]; }
if ! pending && [ ! -e "$contents" ] && [ "${#files[@]}" -eq 0 ]; then
  echo NONE; exit 0
fi

for f in "${files[@]}"; do
  # Line 1 is a small JSON header; the rest is one JSON object whose panicString starts with the cause.
  why="$(tail -n +2 "$f" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("panicString","").splitlines()[0])' 2>/dev/null)"
  echo "PANIC ${f##*/}: ${why:-(unreadable)}"
  if [ -n "$out" ]; then mkdir -p "$out" && cp "$f" "$out/" 2>/dev/null; fi
done

dest="$dr/Retired/panic-acknowledged-$(date +%Y%m%d-%H%M%S)"
sudo -n mkdir -p "$dest" || { echo "FAILED sudo -n mkdir $dest"; exit 0; }
for f in "${files[@]}" "$contents"; do
  [ -e "$f" ] && sudo -n mv "$f" "$dest/"
done
pending && sudo -n mv "$link" "$dest/"
# The alert is Diagnostics Reporter's window. With the link gone it does not come back at the next boot.
pkill -x 'Diagnostics Reporter' 2>/dev/null
if pending; then echo "FAILED $link is still there"; else echo "CLEARED $dest"; fi
