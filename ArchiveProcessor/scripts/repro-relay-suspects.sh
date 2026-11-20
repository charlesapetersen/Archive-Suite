#!/bin/bash
# repro-relay-suspects.sh — W49.relay-suspects, S-038 under phase rule 5a: does Finish over the relay wait for a page
# that is still on the phone?
#
# The built Mac app runs headless on the file relay (LIVECAPTURE_TRANSPORT=fileRelay, the same FileRelayReceiver
# scan the Drive relay runs over DriveObjectStore). This script plays the phone, writing relay objects byte-for-byte
# as ArchiveCapture's RelayObjectFormat does: page 1 of document `g1` is sent and receipted, page 2 is still "on the
# phone" (not written). Then the session-complete marker stands in for the operator's Finish: under
# LIVECAPTURE_AUTOFINALIZE it runs the same `requestFinish` the Finish button calls, with its drain gate. Over LAN a
# phone heartbeat (`POST /phone/status`, pending 1) would hold that gate; the relay has no status object. Finally
# page 2 arrives late. OCR is Apple Vision, tagging off: $0, nothing leaves the Mac. Scratch only (mktemp); the
# settings are launch arguments, which UserDefaults does not persist. S-021 (Android) is the JVM test
# ArchiveCapture/app/src/test/.../capture/DriveRelaySegmentSignalSuspectTest.kt.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/require-unsandboxed.sh"
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
BIN="$REPO/macOS/build/DD/Build/Products/Debug/ArchiveProcessor.app/Contents/MacOS/ArchiveProcessor"
[ -x "$BIN" ] || { echo "no built app at $BIN"; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/relay-suspects.XXXXXX")"
OUT="$WORK/out"; RELAY="$WORK/relay"; READY="$WORK/ready.txt"; LOG="$WORK/mac.log"
mkdir -p "$OUT" "$RELAY"
echo "=== S-038 · Finish over the relay with a page still on the phone · $(date '+%F %T') ==="
echo "scratch: $WORK"

source "$REPO/scripts/test-child.sh"
processor_test_init
ARCHIVEPROC_HEADLESS=1 \
ARCHIVEPROC_TEST_BACKUP_ROOT="$WORK/backup" \
LIVECAPTURE_AUTOSTART=1 \
LIVECAPTURE_TRANSPORT=fileRelay \
LIVECAPTURE_RELAYDIR="$RELAY" \
LIVECAPTURE_READYFILE="$READY" \
LIVECAPTURE_AUTOFINALIZE=1 \
LIVECAPTURE_TESTOUT="$OUT" \
  processor_test_start pid "$BIN" -liveProcessingMode live \
  -useAppleVision YES -visionUseLLMJudgment NO -useGateway NO -useLocalAgent NO \
  -taggingModeRaw none -rotationModeRaw off -reviewRotation NO -mergeDocuments NO \
  -customOCRPrompt '' -tagVocabulary '' -outputDirectory "$OUT" >"$LOG" 2>&1

for _ in $(seq 1 180); do grep -q '^LIVECAPTURE_READY transport=fileRelay' "$READY" 2>/dev/null && break; sleep 1; done
line="$(grep '^LIVECAPTURE_READY transport=fileRelay' "$READY" 2>/dev/null | head -1)"
[ -n "$line" ] || { echo "no READY line (see $LOG)"; processor_test_stop "$pid"; exit 1; }
TOKEN="$(sed -n 's/.* token=\([^ ]*\).*/\1/p' <<<"$line")"
DIR="$RELAY/$TOKEN"
for _ in $(seq 1 30); do [ -f "$DIR/_epoch.json" ] && break; sleep 1; done
[ -f "$DIR/_epoch.json" ] || { echo "no epoch marker in $DIR"; processor_test_stop "$pid"; exit 1; }

# The phone: RelayObjectFormat's names, canonical JSON (sorted keys, nulls dropped) and fingerprint, then write-temp-rename.
phone() {
    python3 - "$DIR" "$TOKEN" "$@" <<'PY'
import hashlib, json, os, shutil, sys, uuid
d, token, what = sys.argv[1], sys.argv[2], sys.argv[3]
epoch = json.load(open(os.path.join(d, "_epoch.json")))["epoch"]
canon = lambda m: json.dumps({k: v for k, v in sorted(m.items()) if v is not None}, separators=(",", ":"), ensure_ascii=False).encode()
def put(name, data):
    tmp = os.path.join(d, "." + name + "." + uuid.uuid4().hex + ".part")
    open(tmp, "wb").write(data); os.replace(tmp, os.path.join(d, name))
if what == "photo":
    group, seq, jpeg = sys.argv[4], sys.argv[5], sys.argv[6]
    fp = hashlib.sha256(canon({"type": "document", "quality": None, "year": None, "month": None, "replaces": None})).digest()[:8].hex()
    put(f"{group}__{seq}.jpg", open(jpeg, "rb").read())
    put(f"{group}__{seq}.json", canon({"kind": "photo", "token": token, "epoch": epoch, "group": group, "seq": seq,
        "type": "document", "device": "repro-phone", "fp": fp}))
elif what == "session-complete":
    put("_session.complete.json", canon({"kind": "session-complete", "token": token, "epoch": epoch}))
PY
}
FIX="$REPO/scripts/e2e-fixtures"

phone photo g1 1 "$FIX/doc1_memo.jpg"
for _ in $(seq 1 60); do [ -f "$DIR/g1__1.receipt.json" ] && break; sleep 1; done
echo "page 1 of g1: $([ -f "$DIR/g1__1.receipt.json" ] && echo receipted || echo 'NO receipt')"
echo "page 2 of g1: still on the phone (not written)"

phone session-complete
echo "Finish (session-complete marker) at $(date '+%T')"
for _ in $(seq 1 300); do [ -f "$OUT/DONE.txt" ] && break; sleep 1; done
echo "finalize: $(cat "$OUT/DONE.txt" 2>/dev/null || echo 'none within 300 s — Finish held')"
pages() { find "$OUT" -name '*.pdf' -not -path '*/.archivesuite/*' -print0 | xargs -0 -n1 python3 -c '
import re, sys; d = open(sys.argv[1], "rb").read(); print(sys.argv[1].split("/out/")[-1], len(re.findall(rb"/Type\s*/Page[^s]", d)))' 2>/dev/null; }
echo "PDFs filed and their pages:"; pages | sed 's/^/  /'

phone photo g1 2 "$FIX/doc2_letter.jpg"
echo "page 2 of g1 arrives late at $(date '+%T')"
for _ in $(seq 1 60); do [ -f "$DIR/g1__2.receipt.json" ] && break; sleep 1; done
sleep 5
echo "page 2: $([ -f "$DIR/g1__2.receipt.json" ] && echo receipted || echo 'NO receipt')"
echo "PDFs after the late page:"; pages | sed 's/^/  /'
echo "where page 2's photo is:"; find "$WORK/backup" "$OUT" -name '*g1*2*' -o -name '*__2*' 2>/dev/null | sed "s|$WORK/|  |"
echo "Mac log, relay and finish lines:"
grep -iE 'late page|already-finished|phone still has|LIVECAPTURE_PHONE_PENDING|LIVECAPTURE_DONE|finaliz' "$LOG" | cut -c1-200 | sed 's/^/  /'
processor_test_stop "$pid"
echo "scratch kept for reading: $WORK"
