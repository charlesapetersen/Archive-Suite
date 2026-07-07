#!/bin/bash
# test-drive-live.sh — OWNER-GATED live validation of DriveObjectStore against REAL Google Drive.
#
# Proves the Mac Drive backend (auth-bearer, multipart create, files.list, media get, delete, appProperties,
# and the dedup-reap fix) works against real Drive — the thing the headless mock test can't cover. Compiles
# the REAL RelayObjectFormat + DriveClient + DriveObjectStore standalone (swiftc) against a stub
# RelayObjectStore, runs a create/list/read/overwrite/quarantine/delete round-trip + a coexisting-duplicate
# reap check in a throwaway "LIVETEST" Drive folder, then DELETES everything it created.
#
# Requires a drive.file access token in $DRIVE_ACCESS_TOKEN (get one via the loopback sign-in, e.g.
#   export DRIVE_ACCESS_TOKEN=$(python3 <scratchpad>/drive_token.py)
# or DriveAuth.signIn in-app). Touches only files this run creates; safe to re-run.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; NET="$REPO/ArchiveProcessor/Sources/ArchiveProcessor/Net"
[ -n "${DRIVE_ACCESS_TOKEN:-}" ] || { echo "set DRIVE_ACCESS_TOKEN (a drive.file access token) first"; exit 2; }
W=$(mktemp -d)
cat > "$W/main.swift" <<'SWIFT'
import Foundation
protocol RelayObjectStore: Sendable {
    func ensureSessionFolder() throws
    func publishEpoch(_ data: Data)
    func listNames() -> [String]
    func readData(_ name: String) -> Data?
    func exists(_ name: String) -> Bool
    func modificationDate(_ name: String) -> Date?
    func writeAtomic(_ name: String, _ data: Data)
    func delete(_ name: String)
    func quarantine(_ name: String)
}
let token = ProcessInfo.processInfo.environment["DRIVE_ACCESS_TOKEN"]!
let ns = "LIVETEST"
let client = DriveClient(http: URLSessionHTTP(), token: { token })
let store: RelayObjectStore = DriveObjectStore(client: client, token: ns)
var pass = true
func check(_ l: String, _ c: Bool) { print("  [\(c ? "PASS":"FAIL")] \(l)"); if !c { pass = false } }

func cleanup() {
    if let folders = try? client.listFiles(query: "mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='relayToken' and value='\(ns)' } and trashed = false") {
        for f in folders {
            if let kids = try? client.listFiles(query: "'\(f.id)' in parents and trashed = false") { for k in kids { try? client.delete(fileId: k.id) } }
            try? client.delete(fileId: f.id)
        }
    }
}
cleanup()   // clear any leftovers from a prior aborted run

do {
    try store.ensureSessionFolder()
    store.writeAtomic("g1__7.json", Data("SIDE1".utf8))
    store.writeAtomic("g1__7.jpg", Data("JPEG1".utf8))
    check("live: list has both objects", Set(store.listNames()) == Set(["g1__7.json", "g1__7.jpg"]))
    check("live: read sidecar bytes", store.readData("g1__7.json") == Data("SIDE1".utf8))
    check("live: exists true/false", store.exists("g1__7.json") && !store.exists("nope.json"))
    store.writeAtomic("g1__7.json", Data("SIDE2".utf8))
    check("live: overwrite updates bytes", store.readData("g1__7.json") == Data("SIDE2".utf8))
    check("live: overwrite no duplicate", store.listNames().filter { $0 == "g1__7.json" }.count == 1)
    store.publishEpoch(Data("EPOCHBYTES".utf8))
    check("live: publishEpoch", store.readData("_epoch.json") == Data("EPOCHBYTES".utf8))
    store.quarantine("g1__7.jpg")
    check("live: quarantine hides from list", !store.listNames().contains("g1__7.jpg"))
    store.delete("g1__7.json")
    check("live: delete removes", !store.listNames().contains("g1__7.json"))

    // Coexisting-duplicate reap (D7 HIGH fix) against REAL Drive: raw-create two same-relayName sidecars.
    let folders = try client.listFiles(query: "mimeType = 'application/vnd.google-apps.folder' and appProperties has { key='relayToken' and value='\(ns)' } and trashed = false")
    if let fid = folders.first?.id {
        _ = try client.createFile(name: "dup__1.json", parents: [fid], appProperties: ["relayName": "dup__1.json", "relayToken": ns, "rev": "1"], media: Data("OLD".utf8), mimeType: "application/json")
        _ = try client.createFile(name: "dup__1.json", parents: [fid], appProperties: ["relayName": "dup__1.json", "relayToken": ns, "rev": "2"], media: Data("NEW".utf8), mimeType: "application/json")
        check("live: dup newest-rev survives", store.readData("dup__1.json") == Data("NEW".utf8))
        check("live: dup listed once (older reaped)", store.listNames().filter { $0 == "dup__1.json" }.count == 1)
    } else { check("live: dup setup (folder found)", false) }
} catch { print("  [FAIL] live round-trip threw: \(error)"); pass = false }

cleanup()
print(pass ? "DRIVE LIVE: PASS" : "DRIVE LIVE: FAIL")
exit(pass ? 0 : 1)
SWIFT
if swiftc "$NET/RelayObjectFormat.swift" "$NET/DriveClient.swift" "$NET/DriveObjectStore.swift" "$W/main.swift" -o "$W/live" 2>"$W/err"; then
  "$W/live"
else echo "  [FAIL] swiftc:"; head -25 "$W/err"; exit 1; fi
