#!/bin/bash
# storage-pilot.sh — W49.storage-pilot: the catalogue rollout and its rollback drill, end to end, on scratch roots
# (execution-plans/storage-simplify.md §15, stage 8). $0: no model call, no network beyond 127.0.0.1.
#
#   1. Copies a small sample of the pre-app archive, PDFs and their JPEG originals with Finder tags and colours,
#      into a fresh mktemp folder. The real archive is only READ (ditto); its files' size, mtime and tags are
#      recorded before and compared after. Adds edge cases in scratch: an encrypted PDF, a joined two-page PDF,
#      a duplicate filename in another folder, a PDF with no original and a non-PDF file.
#   2. Adopts the scratch copy with the adoption tool (inventory, decide, convert killed with SIGKILL partway,
#      convert again, verify, labels) and checks the scratch source is byte- and tag-identical afterwards, nothing
#      was filed twice and every unconvertible entry stayed out.
#   3. New output: a real Process Files run (the stand-in gateway) on copies of three originals.
#   4. The rollback drill on both roots (ArchiveCore StoragePilotDrillTests): post-cutover edits, an export of
#      the latest records, a copy of the root at another path, each reopened read-only and compared record by record.
#
#   ops/verify/storage-pilot.sh [KEEP_DIR]   (KEEP_DIR receives the reports; default: the scratch folder)
# Needs the Debug Processor built in this checkout. Prints ALL PASS on success.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CORPUS="$HOME/Desktop/Google Drive"
BIN="$REPO/ArchiveProcessor/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
ADOPT="$REPO/ArchiveProcessor/scripts/adopt-archive.sh"
[ -x "$BIN" ] || { echo "ArchiveProcessor is not built (ArchiveProcessor/macOS/build/DD)" >&2; exit 1; }
W=$(mktemp -d "${TMPDIR:-/tmp}/storage-pilot.XXXXXX")
KEEP="${1:-$W}"
mkdir -p "$KEEP"
echo "scratch: $W"
source "$REPO/ArchiveProcessor/scripts/test-child.sh"
processor_test_init "$W"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

# ── 1. The sample: three folders of the pre-app archive, read only ───────────────────────────────────────────────
SAMPLE=("Hoover Institute/Young Americans for Freedom (note, unprocessed)|28"
        "Hoover Institute/Wilbur at Hoover|12"
        "Harvard University Archives/Greene Papers|12")
SRC="$W/src/Archival Photos"
JPG="$W/src/Archival Photos JPEGS"
real_list="$W/real-files.txt"
: >"$real_list"
for spec in "${SAMPLE[@]}"; do
    rel="${spec%|*}" n="${spec#*|}"
    mkdir -p "$SRC/$rel" "$JPG/$rel"
    while IFS= read -r -d '' pdf; do
        name="$(basename "$pdf")" stem="${name%.pdf}"
        ditto "$pdf" "$SRC/$rel/$name"
        printf '%s\n' "$pdf" >>"$real_list"
        # Its original by name, also where the PDF's name has a no-break space for the JPEG's space.
        plain="$(printf '%s' "$stem" | LC_ALL=C sed $'s/\xc2\xa0/ /g')"
        for orig in "$CORPUS/Archival Photos JPEGS/$rel/$stem".{jpg,JPG,jpeg} "$CORPUS/Archival Photos JPEGS/$rel/$plain".{jpg,JPG,jpeg}; do
            if [ -f "$orig" ]; then ditto "$orig" "$JPG/$rel/$(basename "$orig")"; printf '%s\n' "$orig" >>"$real_list"; break; fi
        done
    done < <(find "$CORPUS/Archival Photos/$rel" -maxdepth 1 -name '*.pdf' -print0 | sort -z \
             | python3 -c 'import sys; n=int(sys.argv[1]); sys.stdout.buffer.write(b"".join(x+b"\0" for x in sys.stdin.buffer.read().split(b"\0")[:-1][:n]))' "$n")
done
real_state() {   # size, mtime, change time and tags of every real file read; the change time moves on any write
    while IFS= read -r f; do
        printf '%s\t%s\t%s\n' "$f" "$(stat -f '%z %m %c' "$f")" \
            "$(xattr -px com.apple.metadata:_kMDItemUserTags "$f" 2>/dev/null | tr -d ' \n')"
    done <"$real_list"
}
real_state >"$W/real-before.txt"
echo "sample: $(grep -c '\.pdf$' "$real_list") PDFs and $(grep -vc '\.pdf$' "$real_list") originals copied from the pre-app archive"

# Edge cases, all in scratch.
first="$(find "$SRC/Hoover Institute/Wilbur at Hoover" -name '*.pdf' | sort | head -1)"
second="$(find "$SRC/Hoover Institute/Wilbur at Hoover" -name '*.pdf' | sort | sed -n 2p)"
mkdir -p "$SRC/Pilot Edge"
qpdf --encrypt pilot pilot 256 -- "$first" "$SRC/Pilot Edge/encrypted.pdf"
qpdf --empty --pages "$first" "$second" -- "$SRC/Pilot Edge/two pages.pdf"
ditto "$first" "$SRC/Pilot Edge/$(basename "$first")"           # a duplicate filename: its original is ambiguous
ditto "$second" "$SRC/Pilot Edge/no original.pdf"
echo "not a PDF" >"$SRC/Pilot Edge/notes.txt"

tree_state() {   # every file's bytes and tags under a folder
    (cd "$1" && find . -type f -print0 | sort -z | while IFS= read -r -d '' f; do
        printf '%s\t%s\t%s\n' "$f" "$(shasum -a 256 "$f" | cut -c1-64)" \
            "$(xattr -px com.apple.metadata:_kMDItemUserTags "$f" 2>/dev/null | tr -d ' \n')$(xattr -px com.apple.FinderInfo "$f" 2>/dev/null | tr -d ' \n')"
    done)
}
tree_state "$W/src" >"$W/src-before.txt"

# ── 2. Adoption ──────────────────────────────────────────────────────────────────────────────────────────────────
STATE="$W/state" DEST="$W/Adopted Archive"
mkdir -p "$STATE"
adopt() { "$ADOPT" "$@" >>"$W/adopt.log" 2>&1; }
adopt inventory "$STATE" "$SRC" "$JPG" red-box-purple-folder || bad "inventory failed: $(tail -3 "$W/adopt.log")"
reasons="$(python3 - "$STATE/adoption-manifest.json" <<'EOF'
import collections, json, sys
m = json.load(open(sys.argv[1]))
c = collections.Counter(r for e in m['entries'] for r in e.get('review', []))
print(' '.join(f'{k}={v}' for k, v in sorted(c.items())))
EOF
)"
echo "inventory reasons: ${reasons:-none}"
CONVERTIBLE="type-conflict,date-ambiguous,date-incomplete,quality-conflict,original-missing,original-ambiguous,original-unknown,original-shared,original-multipage,original-offline"
adopt decide "$STATE" accept "$CONVERTIBLE" || true
accepted="$(python3 -c 'import json,sys; print(sum(e["decision"]=="accept" for e in json.load(open(sys.argv[1]))["entries"]))' "$STATE/adoption-manifest.json")"
total="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["entries"]))' "$STATE/adoption-manifest.json")"
echo "manifest: $total entries, $accepted accepted"

# Convert, killed with SIGKILL once a few entries have landed, then run again.
completed() { python3 -c 'import json,sys
try: print(sum(i["completed"] for i in json.load(open(sys.argv[1]))["items"].values()))
except Exception: print(0)' "$STATE/adoption-ledger.json"; }
export ARCHIVEPROC_HEADLESS=1 ARCHIVE_ADOPT=convert ARCHIVE_ADOPT_STATE="$STATE" ARCHIVE_ADOPT_DEST="$DEST"
processor_test_start cpid "$BIN" >>"$W/adopt.log" 2>&1
unset ARCHIVEPROC_HEADLESS ARCHIVE_ADOPT ARCHIVE_ADOPT_STATE ARCHIVE_ADOPT_DEST
for _ in $(seq 1 600); do
    [ "$(completed)" -ge 3 ] && break
    kill -0 "$cpid" 2>/dev/null || break
    sleep 0.2
done
at_kill="$(completed)"
if kill -KILL "$cpid" 2>/dev/null; then
    wait "$cpid" 2>/dev/null
    if [ "$at_kill" -lt "$accepted" ]; then pass "convert killed with SIGKILL after $at_kill of $accepted entries"
    else bad "convert finished before the kill ($at_kill of $accepted); the interruption was not exercised"; fi
else
    bad "convert exited before the kill ($at_kill of $accepted)"
fi
adopt convert "$STATE" "$DEST" && pass "convert resumed and verified" || bad "the resumed convert failed: $(tail -5 "$W/adopt.log")"
adopt convert "$STATE" "$DEST" && pass "a third convert over the finished manifest succeeds" || bad "a repeat convert failed"
adopt verify "$STATE" && grep -q '^VERIFIED' "$STATE/verification-report.md" && pass "verify: VERIFIED" \
    || bad "verify did not pass: $(tail -5 "$STATE/verification-report.md" 2>/dev/null)"
python3 - "$STATE/adoption-manifest.json" "$DEST" "$STATE/adoption-ledger.json" <<'EOF' || fail=1
import json, os, sys
m, dest, ledger = json.load(open(sys.argv[1])), sys.argv[2], json.load(open(sys.argv[3]))
acc = {e['path'] for e in m['entries'] if e['decision'] == 'accept'}
held = {e['path']: e.get('review', []) for e in m['entries'] if e['decision'] != 'accept'}
pdfs, comps = set(), set()
for d, dirs, fs in os.walk(dest):
    dirs[:] = [x for x in dirs if x not in ('.archivesuite', 'Preservation')]
    for f in fs:
        rel = os.path.relpath(os.path.join(d, f), dest)
        if f.endswith('.pdf'): pdfs.add(rel)
        if f.endswith('.pdf.archivesuite.json'): comps.add(rel[:-len('.archivesuite.json')])
ok = True
def check(cond, msg):
    global ok
    print(('PASS ' if cond else 'FAIL ') + msg); ok &= cond
check(pdfs == acc, f'the derived archive holds exactly the {len(acc)} accepted PDFs, none twice ({len(pdfs)} filed)')
check(comps == acc, f'each has its catalogue companion ({len(comps)})')
check(all(i['completed'] for i in ledger['items'].values()) and set(ledger['items']) == acc, 'every ledger entry completed, one per accepted PDF')
check(not (pdfs & set(held)), f'no held entry was filed ({len(held)} held: ' + ', '.join(sorted({r for v in held.values() for r in v})) + ')')
enc = [p for p in held if p.endswith('encrypted.pdf')]
check(bool(enc) and 'pdf-unreadable' in held[enc[0]], 'the encrypted PDF waits as pdf-unreadable')
check(not any(p.endswith('notes.txt') for p in [e['path'] for e in m['entries']]), 'a non-PDF file is not inventoried')
pres = sum(len(fs) for d, _, fs in os.walk(dest) if '/Preservation/' in d + '/')
print(f'      preserved originals in the derived archive: {pres}')
sys.exit(0 if ok else 1)
EOF
adopt labels "$STATE" apply && pass "labels applied in the derived archive ($(grep -c . "$STATE/labels-report.md") report lines)" \
    || echo "NOTE labels did not apply: $(tail -3 "$STATE/labels-report.md" 2>/dev/null)"
tree_state "$W/src" >"$W/src-after.txt"
cmp -s "$W/src-before.txt" "$W/src-after.txt" && pass "the scratch source is byte- and tag-identical after every step" \
    || { bad "the scratch source changed"; diff "$W/src-before.txt" "$W/src-after.txt" | head; }
for f in "$DEST"/*/*/*.pdf; do
    [ -n "$(xattr -p com.apple.metadata:_kMDItemUserTags "$f" 2>/dev/null)" ] && { bad "a derived PDF carries Finder tags: $f"; break; }
done

# ── 3. New output: one Process Files run on copies of three originals ────────────────────────────────────────────
NEWIN="$W/new-in" NEWOUT="$W/new-out"
mkdir -p "$NEWIN" "$NEWOUT"
find "$JPG/Hoover Institute/Young Americans for Freedom (note, unprocessed)" -type f | sort | head -n 3 \
    | while IFS= read -r f; do ditto "$f" "$NEWIN/$(basename "$f")"; done
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$REPO/ArchiveProcessor/scripts/fake_gateway.py" "$PORT" "$NEWOUT/gateway.log" 500 stand-in-key &
gw=$!
sleep 1
vars=(ARCHIVEPROC_HEADLESS=1 "ARCHIVEPROC_TEST_BACKUP_ROOT=$W/backup"
      PROCESSFILES_TESTMODE=1 PROCESSFILES_TESTKEY=stand-in-key
      "PROCESSFILES_GATEWAY_URL=http://127.0.0.1:$PORT/v1" PROCESSFILES_GATEWAY_MODEL=stand-in
      PROCESSFILES_METER=1 PROCESSFILES_CAP_USD=100 PROCESSFILES_TAGGING=automatic
      "PROCESSFILES_TESTIN=$NEWIN" "PROCESSFILES_TESTOUT=$NEWOUT" "PROCESSFILES_TESTDONE=$NEWOUT/DONE.txt"
      PROCESSFILES_MAXIMAGES=3 PROCESSFILES_EXPORTORIGINALS=1)
for kv in "${vars[@]}"; do export "$kv"; done
processor_test_start ppid "$BIN" >"$NEWOUT/app.log" 2>&1
for kv in "${vars[@]}"; do unset "${kv%%=*}"; done
for _ in $(seq 1 300); do [ -f "$NEWOUT/DONE.txt" ] && break; sleep 1; done
processor_test_stop "$ppid"
kill "$gw" 2>/dev/null; wait "$gw" 2>/dev/null
rm -f "$HOME/Library/Application Support/ArchiveProcessor/pending_run.json"
NEWROOT="$(find "$NEWOUT" -maxdepth 1 -type d -name 'run-*' | head -1)"
newpairs="$(find "${NEWROOT:-/nonexistent}" -name '*.pdf.archivesuite.json' 2>/dev/null | wc -l | tr -d ' ')"
[ -n "$NEWROOT" ] && [ "$newpairs" -ge 1 ] && pass "Process Files filed $newpairs new catalogue pairs (driver: $(head -1 "$NEWOUT/DONE.txt" 2>/dev/null))" \
    || bad "Process Files filed no catalogue pairs (driver: $(cat "$NEWOUT/DONE.txt" 2>/dev/null || echo 'timed out'))"

# ── 4. The rollback drill on both roots ──────────────────────────────────────────────────────────────────────────
drill() {   # name root
    local out="$W/drill-$1"
    mkdir -p "$out"
    (cd "$REPO/packages/ArchiveCore" && ARCHIVE_PILOT_ROOT="$2" ARCHIVE_PILOT_OUT="$out" ARCHIVE_PILOT_EDIT=1 \
        python3 "$REPO/ops/autonomous/heavy-run.py" run -- swift test --filter StoragePilotDrillTests) >"$out/test.log" 2>&1
    local rc=$?
    if [ $rc -eq 0 ] && [ -f "$out/drill.json" ]; then
        pass "rollback drill ($1): $(python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
print("%d records, %d edited after cutover; the export (%d files, %d preserved originals) and a copy at another "
      "path match record by record" % (d["files"], len(d["edited"]), d["exportFiles"], d["preserved"]))' "$out/drill.json")"
    else
        bad "rollback drill ($1) failed: $(grep -E 'Expectation failed|error' "$out/test.log" | head -5)"
    fi
}
drill adopted "$DEST"
[ -n "$NEWROOT" ] && drill new "$NEWROOT"

# ── The real archive was only read ───────────────────────────────────────────────────────────────────────────────
real_state >"$W/real-after.txt"
cmp -s "$W/real-before.txt" "$W/real-after.txt" && pass "the $(wc -l <"$real_list" | tr -d ' ') real files read are unchanged (size, mtime, change time, tags)" \
    || { bad "a real file's state changed"; diff "$W/real-before.txt" "$W/real-after.txt" | head; }

if [ "$KEEP" != "$W" ]; then
    cp "$STATE"/*.md "$STATE/adoption-manifest.json" "$KEEP/" 2>/dev/null
    for d in "$W"/drill-*; do [ -f "$d/drill.json" ] && cp "$d/drill.json" "$KEEP/$(basename "$d").json"; done
fi
[ $fail -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail
