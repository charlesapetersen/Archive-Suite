#!/bin/bash
# test-relay-transport.sh — verifies the phone-side never-lose contract of FileRelayTransport (iOS).
#
# Compiles the REAL iOS RelayObjectFormat + FileRelayTransport standalone (swiftc) against a stub
# SegmentTransport protocol (the real one can't compile standalone — its file also carries the MacClient
# conformance), and drives postPhoto against simulated Mac receipts. Asserts postPhoto returns true ONLY
# after a matching-(token,epoch,group,seq,fp) receipt appears — never on a stale/wrong-fp/wrong-epoch ack.
# Android's transport is the symmetric blocking mirror (org.json parse), covered by the format golden +
# the Mac receiver invariants. Key-free, $0.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; W=$(mktemp -d)
cat > "$W/main.swift" <<'SWIFT'
import Foundation
// Stub of the real SegmentTransport (its file also declares `extension MacClient: SegmentTransport`,
// so it can't be compiled standalone). Signatures must match FileRelayTransport's conformance.
protocol SegmentTransport {
    func postPhoto(jpeg: Data, group: String, seq: Int, type: String, priority: String?, year: Int?, month: Int?, device: String, replaces: String?) async -> Bool
    func segmentComplete(group: String, priority: String?, year: Int?, month: Int?) async -> Bool
    func sessionComplete() async -> Bool
    func sessionDisconnect() async -> Bool
}
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rtt-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let token = "TESTTK", epoch = "EP1"
func writeObj(_ n: String, _ d: Data) { try! d.write(to: dir.appendingPathComponent(n)) }
func exists(_ n: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(n).path) }
func receipt(_ g: String, _ s: Int, _ ep: String, _ fp: String) -> Data {
    RelayObjectFormat.canonicalJSON(["kind":"receipt","token":token,"epoch":ep,"group":g,"seq":String(s),"received":"true","fp":fp]) }
writeObj(RelayObjectFormat.epochMarkerName, RelayObjectFormat.canonicalJSON(["kind":"epoch","token":token,"epoch":epoch]))
var pass = true
func check(_ l: String, _ c: Bool) { print("  [\(c ? "PASS":"FAIL")] \(l)"); if !c { pass = false } }
var t = FileRelayTransport(sessionDir: dir, token: token); t.receiptWaitTimeout = 1.5; t.receiptPollInterval = 0.2
let r1 = await t.postPhoto(jpeg: Data("b1".utf8), group:"g", seq:1, type:"document", priority:"P8", year:1968, month:3, device:"X", replaces:nil)
check("no-receipt -> false (timeout, never-lose)", r1 == false)
check("no-receipt -> sidecar+jpeg written", exists(RelayObjectFormat.sidecarName(group:"g",seq:1)) && exists(RelayObjectFormat.jpegName(group:"g",seq:1)))
let fp2 = RelayObjectFormat.fingerprint(type:"document", priority:"P8", year:"1968", month:"3", replaces:nil)
writeObj(RelayObjectFormat.receiptName(group:"g",seq:2), receipt("g",2,epoch,fp2))
let r2 = await t.postPhoto(jpeg: Data("b2".utf8), group:"g", seq:2, type:"document", priority:"P8", year:1968, month:3, device:"X", replaces:nil)
check("matching receipt -> true", r2 == true)
writeObj(RelayObjectFormat.receiptName(group:"g",seq:3), receipt("g",3,epoch,"deadbeefdeadbeef"))
let r3 = await t.postPhoto(jpeg: Data("b3".utf8), group:"g", seq:3, type:"document", priority:"P8", year:1968, month:3, device:"X", replaces:nil)
check("wrong-fp receipt -> false (stale-ack rejected, A1/H3)", r3 == false)
let fp4 = RelayObjectFormat.fingerprint(type:"document", priority:nil, year:nil, month:nil, replaces:nil)
writeObj(RelayObjectFormat.receiptName(group:"g",seq:4), receipt("g",4,"OLD-EPOCH",fp4))
let r4 = await t.postPhoto(jpeg: Data("b4".utf8), group:"g", seq:4, type:"document", priority:nil, year:nil, month:nil, device:"X", replaces:nil)
check("wrong-epoch receipt -> false (A2)", r4 == false)
let sc = await t.segmentComplete(group:"g", priority:"P8", year:1968, month:3)
check("segmentComplete -> true + object", sc && exists(RelayObjectFormat.segmentName(group:"g")))
print(pass ? "TRANSPORT ROUND-TRIP: PASS" : "TRANSPORT ROUND-TRIP: FAIL")
exit(pass ? 0 : 1)
SWIFT
IOS="$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net"
if swiftc "$IOS/RelayObjectFormat.swift" "$IOS/FileRelayTransport.swift" "$W/main.swift" -o "$W/rtt" 2>"$W/err"; then
  "$W/rtt"
else echo "  [FAIL] swiftc:"; head -20 "$W/err"; exit 1; fi
