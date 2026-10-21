#!/usr/bin/env bash
# W40.d5 — runs IN THE GUEST after the live-capture journey (vm-gui-runner.sh, PROCESSOR_JOURNEY=livecapture).
# Prints what the sandboxed UI-test runner cannot see: the filed PDFs' times and Finder tags, the session
# folder, and the Trash entries the run produced, so the evidence can show each original reached the Trash
# only after its output was on disk (a PDF's mtime %m against the trashed original's ctime %c, the moment
# of the move). Read-only.
# Usage: live-capture-journey-record.sh <started-epoch-file> <live-out-dir> <live-backup-dir>
set -u
started="$(cat "$1")"; out="$2"; backup="$3"
echo "== run started: $started ($(date -r "$started"))"
echo "== filed PDFs: mtime birth path"
find "$out" -name '*.pdf' -exec stat -f '%m %B %N' {} \;
echo "== their Finder tags (xattr com.apple.metadata:_kMDItemUserTags)"
find "$out" -name '*.pdf' | while IFS= read -r f; do
  echo "$f"
  python3 -c 'import plistlib, subprocess, sys
r = subprocess.run(["xattr", "-px", "com.apple.metadata:_kMDItemUserTags", sys.argv[1]], capture_output=True, text=True)
tags = plistlib.loads(bytes.fromhex("".join(r.stdout.split()))) if r.returncode == 0 else []
print("    " + (", ".join(repr(t) for t in tags) if tags else "(no tags)"))' "$f"
done
echo "== session folder after finalize"
find "$backup" -print
echo "== Trash entries moved there since the run started: ctime mtime path"
for f in "$HOME/.Trash"/* "$HOME/.Trash"/.[!.]*; do
  [ -e "$f" ] || continue
  c="$(stat -f %c "$f")"
  [ "$c" -ge "$started" ] && stat -f '%c %m %N' "$f"
done
exit 0
