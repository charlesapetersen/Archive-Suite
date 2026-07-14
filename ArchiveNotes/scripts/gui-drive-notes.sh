#!/usr/bin/env bash
# ArchiveNotes/scripts/gui-drive-notes.sh
# =============================================================================
# Archive Notes — reliable GUI-drive helpers (source me; do not execute).
#
#   source "$(dirname "$0")/gui-drive-notes.sh"     # from another script
#   source ArchiveNotes/scripts/gui-drive-notes.sh  # from an interactive shell
#
# Ported byte-for-byte from `scripts/gui-drive.sh` (the shipped Reader helper),
# adapting only the app name, the safety banner, and the table geometry — every
# cliclick / osascript / capture / tag-read primitive is identical (W8-S7 §3.6).
#
# WHY THIS EXISTS
#   AppleScript System Events `click at {x,y}` does NOT reliably select
#   NSTableView rows or focus in-content text fields in Notes' 3-pane window.
#   Real CGEvent mouse posting (cliclick) does. So:
#     - POINTER input (click / double-click / right-click / drag) -> cliclick
#     - KEYSTROKES + MENU-ITEM invocation                        -> osascript
#       (System Events keystroke + `click menu item` DO work reliably)
#     - CAPTURE -> screencapture -x (full) / -l <windowid> (window-scoped)
#
# PERMISSIONS
#   cliclick posts real CGEvents, so the CONTROLLING PROCESS (Terminal / the
#   autonomous daemon / whatever is running this script) MUST hold macOS
#   Accessibility permission (System Settings > Privacy & Security >
#   Accessibility). Without it clicks silently no-op. Screen Recording
#   permission is required for window-scoped `screencapture -l`.
#
# SAFETY (CORE DIRECTIVE — Notes-specific)
#   ALL GUI checks run against a SCRATCH fixture store ONLY — never the real
#   Notes store, never the real corpus. The harness points the app at the
#   fixture via the volatile `-ANUITestStorePath` launch argument (never a
#   persisted bookmark). NEVER drive "Choose Store Folder…" — that would
#   overwrite the user's real root bookmark (RootFolderStore key
#   `notesStoreRootBookmark` in UserDefaults). All tag WRITES must go through
#   the app's single NotesTagProjector; this helper only READS tags (via
#   `tag -l`) to assert on write results.
# =============================================================================

set -uo pipefail

# --- Tool paths (Homebrew on Apple Silicon) ---------------------------------
CLICLICK="${CLICLICK:-/opt/homebrew/bin/cliclick}"
TAG="${TAG:-/opt/homebrew/bin/tag}"
NOTES_APP_NAME="${NOTES_APP_NAME:-Archive Notes}"

# Table geometry — Notes' item list is the MIDDLE pane of a 3-pane window
# (folder tree | item list | detail editor), so the list origin sits further
# right than Reader's, and a filter bar + segmented kind control + column
# header push the first row down. These are ESTIMATES: calibrate them against a
# `gui_capture_window` shot during the GUI-on run (W8-S8) before trusting
# row-index clicks — an untuned origin silently clicks the wrong row.
# GUI_ROW_HEIGHT   : pixel height of one NSTableView row.
# GUI_TABLE_ORIGIN_X / _Y : offset of the FIRST row's clickable center, measured
#                           from the Notes window's top-left corner.
GUI_ROW_HEIGHT="${GUI_ROW_HEIGHT:-24}"
GUI_TABLE_ORIGIN_X="${GUI_TABLE_ORIGIN_X:-360}"
GUI_TABLE_ORIGIN_Y="${GUI_TABLE_ORIGIN_Y:-160}"

_gui_die() { echo "gui-drive-notes: $*" >&2; return 1; }

gui_check_env() {
  [ -x "$CLICLICK" ] || { _gui_die "cliclick not found at $CLICLICK"; return 1; }
  [ -x "$TAG" ]      || { _gui_die "tag not found at $TAG"; return 1; }
  command -v osascript    >/dev/null || { _gui_die "osascript missing";    return 1; }
  command -v screencapture >/dev/null || { _gui_die "screencapture missing"; return 1; }
  return 0
}

# --- Focus -------------------------------------------------------------------
gui_activate() {
  osascript -e "tell application \"$NOTES_APP_NAME\" to activate" >/dev/null 2>&1
  # let the window come forward before we post events at it
  osascript -e 'delay 0.4' >/dev/null 2>&1
}

# --- Window bounds / id ------------------------------------------------------
# gui_window_bounds -> "x y w h"  (front window of Notes, screen coords)
gui_window_bounds() {
  osascript <<OSA
tell application "System Events"
  tell process "$NOTES_APP_NAME"
    set p to position of front window
    set s to size of front window
    return (item 1 of p as text) & " " & (item 2 of p as text) & " " & (item 1 of s as text) & " " & (item 2 of s as text)
  end tell
end tell
OSA
}

# gui_window_id -> CoreGraphics window id of Notes' front window,
# suitable for `screencapture -l <id>`.
gui_window_id() {
  osascript <<OSA 2>/dev/null
use framework "Foundation"
use framework "CoreGraphics"
use scripting additions
set info to (current application's CGWindowListCopyWindowInfo(current application's kCGWindowListOptionOnScreenOnly, 0)) as list
repeat with w in info
  set d to w as record
  try
    if (|kCGWindowOwnerName| of d) as text is "$NOTES_APP_NAME" then
      return (|kCGWindowNumber| of d) as text
    end if
  end try
end repeat
return ""
OSA
}

# --- Pointer input (cliclick / real CGEvents) --------------------------------
# All coordinates are ABSOLUTE SCREEN coordinates unless noted.
gui_click()        { "$CLICLICK" "c:${1},${2}"; }        # gui_click X Y
gui_double_click() { "$CLICLICK" "dc:${1},${2}"; }       # gui_double_click X Y
gui_right_click()  { "$CLICLICK" "rc:${1},${2}"; }       # gui_right_click X Y
gui_move()         { "$CLICLICK" "m:${1},${2}"; }        # gui_move X Y

# gui_drag X1 Y1 X2 Y2  — press at 1, release at 2 (panel drag / row drag).
gui_drag() {
  "$CLICLICK" "m:${1},${2}" "dd:${1},${2}" "m:${3},${4}" "du:${3},${4}"
}

# --- Window-relative click ---------------------------------------------------
# gui_click_in_window RELX RELY  — click at an offset from window top-left.
gui_click_in_window() {
  set -- $(gui_window_bounds); local wx=$1 wy=$2
  gui_click $(( wx + ${3:-0} )) $(( wy + ${4:-0} ))
}

# --- Click a table row by index (0-based) ------------------------------------
# gui_click_row N              — single-click row N (selects it)
# gui_double_click_row N       — double-click row N (opens / inline edit)
# gui_right_click_row N        — right-click row N (context menu / sort)
# Row center Y = window.y + TABLE_ORIGIN_Y + N*ROW_HEIGHT ; X = window.x + TABLE_ORIGIN_X
_gui_row_xy() {
  local n=$1 b wx wy
  b="$(gui_window_bounds)" || return 1
  set -- $b; wx=$1; wy=$2
  echo "$(( wx + GUI_TABLE_ORIGIN_X ))" "$(( wy + GUI_TABLE_ORIGIN_Y + n * GUI_ROW_HEIGHT ))"
}
gui_click_row()        { local xy; xy="$(_gui_row_xy "$1")" || return 1; gui_click        $xy; }
gui_double_click_row() { local xy; xy="$(_gui_row_xy "$1")" || return 1; gui_double_click $xy; }
gui_right_click_row()  { local xy; xy="$(_gui_row_xy "$1")" || return 1; gui_right_click  $xy; }

# --- Keystrokes (System Events — these DO work) ------------------------------
# gui_type "text"
gui_type() {
  osascript <<OSA
tell application "System Events" to tell process "$NOTES_APP_NAME"
  keystroke "$1"
end tell
OSA
}
# gui_key <keycode> [modifiers...]  e.g. gui_key 36  (return) ; gui_key 48 (tab)
# gui_key 51  -> delete ;  modifiers: "command down","shift down","option down"
gui_key() {
  local code=$1; shift
  local mods=""
  if [ "$#" -gt 0 ]; then
    local IFS=,; mods=" using {$*}"
  fi
  osascript <<OSA
tell application "System Events" to tell process "$NOTES_APP_NAME"
  key code $code$mods
end tell
OSA
}

# --- Menu-item invocation (System Events — reliable) -------------------------
# gui_menu "Menu>Item"            e.g. gui_menu "File>New Note"
# gui_menu "Menu>Sub>Item"        (one level of submenu supported)
gui_menu() {
  local spec="$1"; local IFS='>'; read -r m1 m2 m3 <<<"$spec"
  if [ -n "${m3:-}" ]; then
    osascript <<OSA
tell application "System Events" to tell process "$NOTES_APP_NAME"
  click menu item "$m3" of menu "$m2" of menu item "$m2" of menu "$m1" of menu bar 1
end tell
OSA
  else
    osascript <<OSA
tell application "System Events" to tell process "$NOTES_APP_NAME"
  click menu item "$m2" of menu "$m1" of menu bar item "$m1" of menu bar 1
end tell
OSA
  fi
}

# --- Capture -----------------------------------------------------------------
# gui_capture_full  OUT.png         — whole screen(s), no shadow, no cursor
gui_capture_full() { screencapture -x "$1"; }
# gui_capture_window OUT.png        — just Notes' front window
gui_capture_window() {
  local id; id="$(gui_window_id)"
  [ -n "$id" ] || { _gui_die "could not resolve Notes window id"; return 1; }
  screencapture -x -l "$id" "$1"
}

# --- Tag read (write-assertions) ---------------------------------------------
# gui_tags PATH  -> space/newline list of Finder tags on PATH (read-only!)
gui_tags() { "$TAG" -l "$1"; }
# gui_assert_tag PATH TAGNAME  -> 0 if present, 1 otherwise
gui_assert_tag() {
  "$TAG" -l "$1" | tr ',' '\n' | grep -qx "$2" \
    && { echo "OK: '$2' present on $1"; return 0; } \
    || { echo "MISSING: '$2' not on $1 (have: $("$TAG" -l "$1"))"; return 1; }
}

# Sourced-marker so callers can verify the include succeeded.
GUI_DRIVE_NOTES_SOURCED=1
