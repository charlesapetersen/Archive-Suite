#!/usr/bin/env bash
# vm-clear-panic-guest.sh OUT_DIR — the GUEST half of tart_clear_panic (ops/gui/tart-lib.sh; read its header for
# why). Runs INSIDE the GUI VM from the repo mount. A file rather than a quoted blob inside `tart exec bash -lc`
# for the reason vm-seed-accessibility-guest.sh gives: the JSON the panic line is read from needs a third level
# of escaping there.
#
# A pending panic is any of: a link in /var/db/PanicReporter (`current.panic`, or `display.panic` while the
# alert is up), the `.contents.panic` it points at, or a `panic-full-*.panic` report not yet retired.
# Diagnostics Reporter is a launchd QueueDirectories job on that folder: launchd starts it whenever the folder
# is not empty, which is why the alert comes back at every boot, and why an empty folder keeps it away. Each report is copied to OUT_DIR, then all of
# them are moved to DiagnosticReports/Retired/panic-acknowledged-<stamp>/ (where the 2026-11-26 hand fix put
# the earlier two), and the alert is closed. Nothing is deleted.
#
# Prints one `PANIC <file>: <first line of its panicString>` per report, then exactly one last line:
#   NONE            nothing was pending
#   CLEARED <dir>   it was pending; the reports are in <dir> and the link is gone
#   FAILED <why>    it was pending and is not cleared
set -u
out="${1:-}"
pr=/private/var/db/PanicReporter
dr=/Library/Logs/DiagnosticReports
shopt -s nullglob
files=("$dr"/panic-full-*.panic)
contents="$dr/.contents.panic"

# Anything in the folder starts the reporter, so every entry counts, not only the two links named above.
pending() { [ -n "$(ls -A "$pr" 2>/dev/null)" ]; }
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
for l in "$pr"/* "$pr"/.[!.]*; do
  [ -L "$l" ] || [ -e "$l" ] && sudo -n mv "$l" "$dest/"
done
# The alert is Diagnostics Reporter's window. With the folder empty launchd does not start it again.
pkill -x 'Diagnostics Reporter' 2>/dev/null
# The guest may next be powered off hard (tart_stop_clean's fallback), which loses unflushed writes.
sync
if pending; then echo "FAILED $pr is not empty: $(ls -A "$pr" | tr '\n' ' ')"; else echo "CLEARED $dest"; fi
