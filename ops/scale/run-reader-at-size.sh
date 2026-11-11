#!/bin/bash
# run-reader-at-size.sh — W40.d7: the Reader at corpus size.
#
# Runs `ArchiveReaderTests/ReaderAtSizeTests` (app-hosted, screen-free) against two trees and prints its
# `D7 ` lines:
#   * the W40.c2 rehearsal sample of the real corpus (APFS clones under ArchiveSuiteRehearsal/) — FTS index
#     build, search latency, the health popover and memory, on real OCR text;
#   * the 150k synthetic scale corpus — sort, filter, the model's per-publish cost, the table's per-change
#     and per-row cell cost, at list length;
#   * the chain (W40.reader-scale-measure, `ReaderChainAtSizeTests`, `CH ` lines) — an APFS clone of the
#     150k tree, live under the real FSEvents watcher with 10 smart folders: main-thread time end to end and
#     per stage for a foreign tag change, Reader writes, selection changes and document-window file
#     switches, then 200 tag edits and 200 file switches with `footprint`, `heap` and `leaks` run on the test
#     host from here, on its request. The clone is made before the run and deleted after it.
#
# The sample is listed (size, mtime, ctime, inode, every xattr) before and after by THIS script, not by the
# process under test, and any difference fails the run: the subject cannot vouch for itself.
#
#   ./ops/scale/run-reader-at-size.sh
#   ./ops/scale/run-reader-at-size.sh --only sample      # or: --only synthetic, --only chain
#   ./ops/scale/run-reader-at-size.sh --optimized        # build with -O, as Release ships
#
# Without --optimized the numbers are a Debug (-Onone) build's, which is what the unit bundle normally
# is. Swift-side work (sorting, filtering, the model) runs several times slower unoptimized; SQLite,
# PDFKit and AppKit are system code and are optimized either way. Quote -O numbers as the shipped cost.
#
# The synthetic tree must exist: build it with `./ops/scale/run-scale-verify.sh --keep` (which also
# re-measures discovery at 150k, the numbers this lane is compared with). Exit 0 = both cases ran and
# passed, nothing skipped, the sample unchanged.

set -uo pipefail
. "$(dirname "$0")/../autonomous/heavy-enter.sh"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAMPLE="${ARCHIVE_D7_SAMPLE:-$HOME/Library/Caches/ArchiveSuiteRehearsal/reader-sample}"
SYNTHETIC="${ARCHIVE_D7_SYNTHETIC:-$HOME/Library/Caches/ArchiveSuiteScale/scale-corpus-150000}"
HANDSHAKE="$HOME/Library/Caches/ArchiveSuiteScale/reader-at-size.txt"
OUT="$HOME/Library/Caches/ArchiveSuiteScale/reader-at-size"
CHAIN="$SYNTHETIC-chain"
ONLY=""
OPTIMIZED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --only)    ONLY="$2"; shift 2 ;;
    --optimized) OPTIMIZED=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)         echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$SAMPLE$SYNTHETIC" in
  *"Google Drive"*) echo "refusing: a root names the real corpus" >&2; exit 2 ;;
esac
[ "$ONLY" = chain ] && OUT="$HOME/Library/Caches/ArchiveSuiteScale/reader-chain"
[ "$OPTIMIZED" = 1 ] && OUT="$OUT-O"
mkdir -p "$OUT"
FAILED=0
fail() { printf '❌ %s\n' "$*"; FAILED=1; }
REQ="$OUT/requests"
SERVER=""
cleanup() {
  rm -f "$HANDSHAKE"
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null
  case "$CHAIN" in */ArchiveSuiteScale/scale-corpus*-chain) [ -d "$CHAIN" ] && rm -rf "$CHAIN" ;; esac
}

only_filter=""
: > "$HANDSHAKE.tmp"
if [ "$ONLY" = chain ]; then
  [ -d "$SYNTHETIC" ] || { echo "no synthetic tree at $SYNTHETIC — run ops/scale/run-scale-verify.sh --keep" >&2; exit 2; }
  # A clone, because the chain writes tags (another process's xattr writes and the Reader's own), and the
  # 150k tree's manifest is what run-scale-verify.sh compares against. APFS clones share blocks.
  case "$CHAIN" in */ArchiveSuiteScale/scale-corpus*-chain) ;; *) echo "refusing clone path $CHAIN" >&2; exit 2 ;; esac
  [ -d "$CHAIN" ] && rm -rf "$CHAIN"
  t0=$(date +%s); cp -c -R "$SYNTHETIC" "$CHAIN" || { echo "could not clone $SYNTHETIC" >&2; exit 2; }
  echo "chain clone: $CHAIN in $(( $(date +%s) - t0 )) s"
  rm -rf "$REQ"; mkdir -p "$REQ"
  printf 'chain=%s\nrequests=%s\n' "$CHAIN" "$REQ" >> "$HANDSHAKE.tmp"
  # Five real PDFs for the document window, when the W40.c2 sample is there (read only).
  if [ -d "$SAMPLE" ]; then
    viewer=$(find "$SAMPLE" -name '*.pdf' -size +20k 2>/dev/null | sort | head -5 | paste -sd '|' -)
    [ -n "$viewer" ] && printf 'viewer-files=%s\n' "$viewer" >> "$HANDSHAKE.tmp"
  fi
  only_filter="-only-testing:ArchiveReaderTests/ReaderChainAtSizeTests"
  # footprint / heap / leaks on the test host, asked for by `<label>-<kind>.req` files; `.done` answers.
  serve() {
    while :; do
      for req in "$REQ"/*.req; do
        [ -e "$req" ] || continue
        read -r kind label pid < "$req"
        base="${req%.req}"
        case "$kind" in
          footprint) footprint -p "$pid" > "$base.txt" 2>&1 ;;
          heap)
            heap -s -H "$pid" > "$base.txt" 2>&1
            if [ "$label" = start ]; then leaks --outputGraph="$OUT/start.memgraph" "$pid" > "$base-graph.txt" 2>&1
            elif [ -e "$OUT/start.memgraph" ]; then heap -s -H --diffFrom="$OUT/start.memgraph" "$pid" > "$base-diff.txt" 2>&1; fi ;;
          leaks) leaks -q "$pid" > "$base.txt" 2>&1 ;;
        esac
        mv "$req" "$base.served"; touch "$base.done"
      done
      sleep 1
    done
  }
  serve & SERVER=$!
fi
if [ "$ONLY" != synthetic ] && [ "$ONLY" != chain ]; then
  [ -d "$SAMPLE" ] || { echo "no sample at $SAMPLE — run ArchiveReader/scripts/rehearsal-sample.py make" >&2; exit 2; }
  printf 'sample=%s\n' "$SAMPLE" >> "$HANDSHAKE.tmp"
  only_filter="-only-testing:ArchiveReaderTests/ReaderAtSizeTests/testIndexSearchAndHealthOnTheRealSample"
fi
if [ "$ONLY" != sample ] && [ "$ONLY" != chain ]; then
  [ -d "$SYNTHETIC" ] || { echo "no synthetic tree at $SYNTHETIC — run ops/scale/run-scale-verify.sh --keep" >&2; exit 2; }
  printf 'synthetic=%s\n' "$SYNTHETIC" >> "$HANDSHAKE.tmp"
  only_filter="$only_filter -only-testing:ArchiveReaderTests/ReaderAtSizeTests/testListAtOneHundredFiftyThousandFiles"
fi
[ -z "$ONLY" ] && only_filter="-only-testing:ArchiveReaderTests/ReaderAtSizeTests"
# Which build the time budgets in ReaderAtSizeTests apply to (W40.fix-reader-list-recompute-at-size).
printf 'optimized=%s\n' "$OPTIMIZED" >> "$HANDSHAKE.tmp"
mv "$HANDSHAKE.tmp" "$HANDSHAKE"
trap cleanup EXIT

# Size, mtime, ctime, inode and a digest of every xattr, per path. ctime moves on any metadata write.
listing() {
  /usr/bin/python3 - "$1" <<'PY'
import ctypes, hashlib, os, sys
# macOS Python has no os.listxattr/getxattr; call libc directly. XATTR_NOFOLLOW = 1.
libc = ctypes.CDLL(None, use_errno=True)
libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
libc.listxattr.restype = ctypes.c_ssize_t
libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
libc.getxattr.restype = ctypes.c_ssize_t
def xattrs(path):
    p = path.encode()
    n = libc.listxattr(p, None, 0, 1)
    if n < 0: raise OSError(ctypes.get_errno(), "listxattr", path)
    buf = ctypes.create_string_buffer(n)
    n = libc.listxattr(p, buf, n, 1)
    if n < 0: raise OSError(ctypes.get_errno(), "listxattr", path)
    for name in sorted(x for x in buf.raw[:n].split(b"\0") if x):
        size = libc.getxattr(p, name, None, 0, 0, 1)
        if size < 0: raise OSError(ctypes.get_errno(), "getxattr", path)
        value = ctypes.create_string_buffer(max(size, 1))
        size = libc.getxattr(p, name, value, size, 0, 1)
        if size < 0: raise OSError(ctypes.get_errno(), "getxattr", path)
        yield name, value.raw[:size]
root = sys.argv[1]
count = 0
for dirpath, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files) + [""]:
        path = os.path.join(dirpath, name) if name else dirpath
        st = os.lstat(path)
        h = hashlib.sha256()
        for attr, value in xattrs(path):
            h.update(attr + b"\0" + value + b"\0")
        print(f"{path}\t{st.st_size}\t{st.st_mtime_ns}\t{st.st_ctime_ns}\t{st.st_ino}\t{h.hexdigest()}")
        count += 1
if count == 0: sys.exit("listing: no paths under " + root)
PY
}

if [ "$ONLY" != synthetic ] && [ -d "$SAMPLE" ]; then
  listing "$SAMPLE" > "$OUT/sample-before.tsv" || { echo "could not list the sample" >&2; exit 2; }
  echo "sample listed: $(wc -l < "$OUT/sample-before.tsv" | tr -d ' ') paths"
fi

LOG="$OUT/test.log"
(
  cd "$REPO/ArchiveReader/macOS" || exit 1
  export PATH=/opt/homebrew/bin:$PATH
  xcodegen generate >/dev/null 2>&1
  # Its own DerivedData for -O, so switching flavours does not rebuild the other one from scratch.
  if [ "$OPTIMIZED" = 1 ]; then flavour=(SWIFT_OPTIMIZATION_LEVEL=-O -derivedDataPath ./build/DD-O)
  else flavour=(-derivedDataPath ./build/DD); fi
  # shellcheck disable=SC2086
  xcodebuild test -scheme ArchiveReader -destination "platform=macOS" $only_filter "${flavour[@]}" 2>&1
) > "$LOG"
{ [ "$OPTIMIZED" = 1 ] && echo "D7 build=-O" || echo "D7 build=Debug(-Onone)"; grep -E '^(D7|CH) ' "$LOG"; } | tee "$OUT/report.txt"
grep -q 'TEST SUCCEEDED' "$LOG" || fail "ReaderAtSizeTests did not pass (see $LOG)"
# A skipped case measured nothing; it must not read as a pass.
grep -qE "Test Case.*' skipped" "$LOG" && fail "a case SKIPPED — the handshake did not reach it ($HANDSHAKE)"
# Compiler diagnostics only (a path:line: prefix); the test host's own os_log noise is not a warning.
grep -E '^/.*:[0-9]+:[0-9]+: (error|warning): ' "$LOG" | sort -u | head -20

if [ "$ONLY" != synthetic ] && [ -d "$SAMPLE" ]; then
  if ! listing "$SAMPLE" > "$OUT/sample-after.tsv"; then
    fail "could not list the sample after the run"
  elif cmp -s "$OUT/sample-before.tsv" "$OUT/sample-after.tsv"; then
    echo "✓ sample unchanged: $(wc -l < "$OUT/sample-after.tsv" | tr -d ' ') paths, listing SHA-256 $(shasum -a 256 < "$OUT/sample-after.tsv" | cut -c1-16)"
  else
    fail "the sample CHANGED during the run:"
    diff "$OUT/sample-before.tsv" "$OUT/sample-after.tsv" | head -10
  fi
fi

[ "$FAILED" = 0 ] && echo "✓ W40.d7 lane passed — $OUT/report.txt" || echo "❌ W40.d7 lane failed"
exit "$FAILED"
