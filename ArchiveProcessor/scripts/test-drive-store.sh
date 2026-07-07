#!/bin/bash
# test-drive-store.sh — offline unit test of DriveObjectStore against a MOCK Google Drive (no network,
# no OAuth). Compiles the REAL RelayObjectFormat + DriveClient + DriveObjectStore standalone (swiftc)
# against a stub RelayObjectStore protocol + an in-memory mock HTTPExecuting that simulates a Drive folder,
# and asserts the name→fileId mapping, idempotent overwrite, list-filtering, quarantine, and delete. The
# live Drive integration test is owner-gated (OAuth); this proves the store logic. Key-free, $0.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; W=$(mktemp -d); NET="$REPO/ArchiveProcessor/Sources/ArchiveProcessor/Net"
cat > "$W/main.swift" <<'SWIFT'
import Foundation

// Stub of the real RelayObjectStore (defined in FileRelayReceiver.swift, which can't compile standalone —
// it references CaptureSession). Signatures must match DriveObjectStore's conformance.
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

// In-memory mock of Google Drive covering exactly the DriveClient calls DriveObjectStore makes. Test media
// is text, so multipart parsing can be string-based.
final class MockDrive: HTTPExecuting, @unchecked Sendable {
    struct File { var id: String; var name: String; var appProps: [String: String]; var parents: [String]; var media: Data; var mime: String }
    private var store: [String: File] = [:]
    private var seq = 0
    private let lock = NSLock()
    private func newId() -> String { seq += 1; return "f\(seq)" }
    private func props(_ m: [String: Any]) -> [String: String] {
        guard let d = m["appProperties"] as? [String: Any] else { return [:] }
        var o: [String: String] = [:]; for (k, v) in d { o[k] = "\(v)" }; return o
    }
    private func parentsOf(_ m: [String: Any]) -> [String] { (m["parents"] as? [Any])?.compactMap { $0 as? String } ?? [] }

    func execute(method: String, url: String, headers: [String: String], body: Data?) throws
        -> (status: Int, data: Data, headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        let path = url
        func idFromFilesPath() -> String? {  // .../files/<id>?...
            guard let r = path.range(of: "/files/") else { return nil }
            let rest = path[r.upperBound...]
            return String(rest.prefix { $0 != "?" })
        }
        func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

        if method == "POST", path.contains("/upload/drive/v3/files") {          // createFile (multipart)
            let ct = headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            let boundary = ct.components(separatedBy: "boundary=").last ?? ""
            let s = String(data: body ?? Data(), encoding: .utf8) ?? ""
            let parts = s.components(separatedBy: "--\(boundary)")
            func content(_ p: String) -> String {
                guard let r = p.range(of: "\r\n\r\n") else { return "" }
                var c = String(p[r.upperBound...]); if c.hasSuffix("\r\n") { c = String(c.dropLast(1)) }; return c  // "\r\n" is ONE grapheme
            }
            let meta = (try? JSONSerialization.jsonObject(with: Data(content(parts[1]).utf8)) as? [String: Any]) ?? [:]
            let id = newId()
            store[id] = File(id: id, name: meta["name"] as? String ?? "", appProps: props(meta),
                             parents: parentsOf(meta), media: Data(content(parts[2]).utf8), mime: "")
            return (200, json(["id": id]), [:])
        }
        if method == "POST", path.contains("/drive/v3/files") {                  // createMetadata (folder)
            let meta = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]) ?? [:]
            let id = newId()
            store[id] = File(id: id, name: meta["name"] as? String ?? "", appProps: props(meta),
                             parents: parentsOf(meta), media: Data(), mime: meta["mimeType"] as? String ?? "")
            return (200, json(["id": id]), [:])
        }
        if method == "PATCH", path.contains("/upload/drive/v3/files/"), let id = idFromFilesPath() {  // updateMedia
            store[id]?.media = body ?? Data()
            return (200, json(["id": id]), [:])
        }
        if method == "PATCH", let id = idFromFilesPath() {                       // updateAppProperties
            let meta = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]) ?? [:]
            for (k, v) in props(meta) { store[id]?.appProps[k] = v }
            return (200, json(["id": id]), [:])
        }
        if method == "GET", path.contains("alt=media"), let id = idFromFilesPath() {  // getMedia
            return (200, store[id]?.media ?? Data(), [:])
        }
        if method == "GET", path.contains("/drive/v3/files?q=") {                // listFiles
            let q = (path.components(separatedBy: "?q=").last ?? "").removingPercentEncoding ?? ""
            func between(_ a: String, _ b: String) -> String? {
                guard let r1 = q.range(of: a) else { return nil }
                let rest = q[r1.upperBound...]
                guard let r2 = rest.range(of: b) else { return nil }
                return String(rest[..<r2.lowerBound])
            }
            var matched: [File]
            if q.contains("in parents"), let fid = between("'", "' in parents") {
                matched = store.values.filter { $0.parents.contains(fid) }
            } else if q.contains("relayToken"), let tok = between("value='", "'") {
                matched = store.values.filter { $0.mime == "application/vnd.google-apps.folder" && $0.appProps["relayToken"] == tok }
            } else { matched = [] }
            let files = matched.map { ["id": $0.id, "name": $0.name, "appProperties": $0.appProps] as [String: Any] }
            return (200, json(["files": files]), [:])
        }
        if method == "DELETE", let id = idFromFilesPath() {
            store[id] = nil; return (204, Data(), [:])
        }
        return (404, Data("{}".utf8), [:])
    }
}

var pass = true
func check(_ l: String, _ c: Bool) { print("  [\(c ? "PASS":"FAIL")] \(l)"); if !c { pass = false } }

let mock = MockDrive()
let client = DriveClient(http: mock, token: { "fake-access-token" })
let store: RelayObjectStore = DriveObjectStore(client: client, token: "TESTTK")

try! store.ensureSessionFolder()
store.writeAtomic("g1__7.json", Data("SIDE1".utf8))
store.writeAtomic("g1__7.jpg", Data("JPEG1".utf8))
check("list has both objects", Set(store.listNames()) == Set(["g1__7.json", "g1__7.jpg"]))
check("read sidecar bytes", store.readData("g1__7.json") == Data("SIDE1".utf8))
check("exists true / false", store.exists("g1__7.json") && !store.exists("nope.json"))

store.writeAtomic("g1__7.json", Data("SIDE2".utf8))                       // idempotent overwrite
check("overwrite updates bytes", store.readData("g1__7.json") == Data("SIDE2".utf8))
check("overwrite does NOT duplicate", store.listNames().filter { $0 == "g1__7.json" }.count == 1)

store.publishEpoch(Data("EPOCHBYTES".utf8))
check("publishEpoch writes _epoch.json", store.readData("_epoch.json") == Data("EPOCHBYTES".utf8))

store.quarantine("g1__7.jpg")                                            // flagged out of listing
check("quarantine removes from listing", !store.listNames().contains("g1__7.jpg"))

store.delete("g1__7.json")
check("delete removes object", !store.listNames().contains("g1__7.json") && store.readData("g1__7.json") == nil)

print(pass ? "DRIVE STORE (mock): PASS" : "DRIVE STORE (mock): FAIL")
exit(pass ? 0 : 1)
SWIFT
if swiftc "$NET/RelayObjectFormat.swift" "$NET/DriveClient.swift" "$NET/DriveObjectStore.swift" "$W/main.swift" -o "$W/ds" 2>"$W/err"; then
  "$W/ds"
else echo "  [FAIL] swiftc:"; head -25 "$W/err"; exit 1; fi
