#!/usr/bin/env bash
# capture-window.sh — grab the actual on-screen pixels of an app window to a PNG a session can Read.
#
# XCUITest sees the *accessibility tree* (an element exists / is hittable). This sees what is
# actually *drawn* — the truth XCUITest is blind to (PDF panes, thumbnails, custom-drawn views,
# layout, colour, dark mode). Pair it with `cliclick` (drive by coordinate) and re-capture to run
# the "sighted loop": launch in a known state → capture → Read the shot → decide next click → repeat.
#
# Requires the GUI-on grants (Accessibility + Screen Recording), seeded on this machine
# (see AGENTS.md → "GUI verification"). This is the live-session / Morning-Review path — the
# headless, permission-free counterpart is the RenderProbe pixel guards in the unit test bundle.
#
# SAFETY: point the app at a SCRATCH copy, never the real corpus (choosing a folder clobbers the
# Reader's root bookmark — see the Reader Core Directive). Quit the app when done.
#
# Usage:
#   ops/gui/capture-window.sh <AppProcessName> [outfile.png] [windowIndex]
# Examples:
#   ops/gui/capture-window.sh ArchiveReader                 # → $TMPDIR/ArchiveReader-<ts>.png
#   ops/gui/capture-window.sh ArchiveNotes /tmp/notes.png
#   ops/gui/capture-window.sh ArchiveReader /tmp/r.png 2    # window 2 (if multiple are open)

set -euo pipefail

APP="${1:-}"
OUT="${2:-}"
WIN="${3:-1}"

if [[ -z "$APP" ]]; then
  echo "usage: $0 <AppProcessName> [outfile.png] [windowIndex]" >&2
  exit 2
fi

if ! [[ "$WIN" =~ ^[0-9]+$ ]] || [[ "$WIN" -lt 1 ]]; then
  echo "error: window index must be a positive integer (got '$WIN')" >&2
  exit 2
fi

if [[ -z "$OUT" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  OUT="${TMPDIR:-/tmp}/${APP}-${ts}.png"
fi

# Ask System Events (Accessibility) for the window's on-screen rectangle, in points.
# APP/WIN are passed as argv into a QUOTED heredoc (no shell interpolation into the AppleScript
# source) so an app name with quotes/specials can't break the script or inject AppleScript.
bounds="$(osascript - "$APP" "$WIN" <<'EOF' 2>/dev/null || true
on run argv
  set appName to item 1 of argv
  set winIndex to (item 2 of argv) as integer
  tell application "System Events"
    if not (exists process appName) then return "NOPROC"
    tell process appName
      set frontmost to true
      if (count of windows) < winIndex then return "NOWIN"
      set p to position of window winIndex
      set s to size of window winIndex
      return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of s) as text) & " " & ((item 2 of s) as text)
    end tell
  end tell
end run
EOF
)"

case "$bounds" in
  NOPROC|"") echo "error: process '$APP' is not running (launch it first: ./launch.sh reader|processor|notes)" >&2; exit 1 ;;
  NOWIN)     echo "error: '$APP' has no window index $WIN" >&2; exit 1 ;;
esac

read -r x y w h <<<"$bounds"
if [[ -z "${h:-}" || "$w" -le 0 || "$h" -le 0 ]]; then
  echo "error: could not read a valid window rect for '$APP' (got: '$bounds')" >&2
  exit 1
fi

# -x: silent, -o: omit the window shadow, -R: capture the region (points; output is Retina-scaled px).
screencapture -x -o -R"${x},${y},${w},${h}" "$OUT"

if [[ ! -s "$OUT" ]]; then
  echo "error: screencapture wrote no data — is Screen Recording permission granted?" >&2
  exit 1
fi

echo "$OUT"   # print the path so a session can Read the pixels
