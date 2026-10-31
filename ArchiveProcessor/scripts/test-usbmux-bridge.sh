#!/bin/bash
# The iPhone cable route's Mac end (W40.i-usb-mac) against a fake usbmuxd: codec, pool, handshake, splice,
# expiry, refused Connect, detach, and the separate failed-auth throttle key. $0, no phone, loopback only.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"   # no app launch inside the Codex sandbox (2026-10-05)
set -euo pipefail
cd "$(dirname "$0")/.."

bin="${ARCHIVEPROC_TEST_BINARY:-$PWD/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor}"
[ -x "$bin" ] || { echo "ArchiveProcessor is not built" >&2; exit 1; }

# A Unix socket path must stay under 104 bytes, so not $TMPDIR.
work=$(mktemp -d /tmp/usbmux-test.XXXXXX)
sock="$work/usbmuxd"
report="$work/result.txt"
log="$work/app.log"
/usr/bin/python3 scripts/fake-usbmuxd.py "$sock" >"$work/fake.log" 2>&1 &
fake=$!
pid=
trap 'kill $pid $fake 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 1 50); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { cat "$work/fake.log" >&2; exit 1; }

ARCHIVEPROC_HEADLESS=1 ARCHIVEPROC_TEST_BACKUP_ROOT="$work/backup" \
    USBMUX_TEST=1 USBMUX_TEST_OUT="$report" ARCHIVE_USBMUX_SOCKET="$sock" \
    "$bin" >"$log" 2>&1 &
pid=$!

for _ in $(seq 1 120); do [ -f "$report" ] && break; sleep 1; done
if [ ! -f "$report" ]; then tail -80 "$log" >&2; exit 1; fi
cat "$report"
grep -q '^ALL PASS$' "$report"
