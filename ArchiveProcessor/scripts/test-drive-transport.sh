#!/bin/bash
# test-drive-transport.sh — offline verification of the iOS DriveRelayTransport never-lose contract against
# a MOCK Drive (no network/OAuth). Compiles the REAL RelayObjectFormat + DriveClient + DriveRelayTransport
# standalone (swiftc) against a stub SegmentTransport + an in-memory mock Drive, and asserts postPhoto returns
# true ONLY after a matching-(token,epoch,group,seq,fp) receipt appears — never on a write alone, and rejects
# stale-fp (A1) / wrong-epoch (A2) acks. Key-free, $0.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; W=$(mktemp -d); NET="$REPO/ArchiveCaptureiOS/Sources/ArchiveCaptureiOS/Net"
cat > "$W/main.swift" <<'SWIFT'
import Foundation
protocol SegmentTransport {
    func postPhoto(jpeg: Data, group: String, seq: Int, type: String, quality: String?, year: Int?, month: Int?, device: String, replaces: String?) async -> Bool
    func segmentComplete(group: String, quality: String?, year: Int?, month: Int?, seqs: String?) async -> Bool
    func sessionComplete() async -> Bool
    func sessionDisconnect() async -> Bool
}
// In-memory mock Drive (same shape as test-drive-store.sh) + inject helpers to seed the Mac-created folder,
// the epoch marker, and receipts.
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
    // test seams:
    func injectFolder(relayToken: String) { lock.lock(); defer { lock.unlock() }
        let id = newId(); store[id] = File(id: id, name: "folder", appProps: ["relayToken": relayToken, "relayFolder": "1"], parents: [], media: Data(), mime: "application/vnd.google-apps.folder") }
    func injectFile(_ name: String, token: String, media: Data) { lock.lock(); defer { lock.unlock() }
        let folder = store.values.first { $0.mime == "application/vnd.google-apps.folder" && $0.appProps["relayToken"] == token }
        let id = newId(); store[id] = File(id: id, name: name, appProps: ["relayName": name, "relayToken": token], parents: folder.map { [$0.id] } ?? [], media: media, mime: "") }
    func hasName(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }
        return store.values.contains { $0.appProps["relayName"] == name && $0.appProps["relayRejected"] != "1" } }

    func execute(method: String, url: String, headers: [String: String], body: Data?) throws -> (status: Int, data: Data, headers: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        let path = url
        func idFromFilesPath() -> String? { guard let r = path.range(of: "/files/") else { return nil }; return String(path[r.upperBound...].prefix { $0 != "?" }) }
        func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
        if method == "POST", path.contains("/upload/drive/v3/files") {
            let ct = headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            let boundary = ct.components(separatedBy: "boundary=").last ?? ""
            let s = String(data: body ?? Data(), encoding: .utf8) ?? ""
            let parts = s.components(separatedBy: "--\(boundary)")
            func content(_ p: String) -> String { guard let r = p.range(of: "\r\n\r\n") else { return "" }; var c = String(p[r.upperBound...]); if c.hasSuffix("\r\n") { c = String(c.dropLast(1)) }; return c }
            let meta = (try? JSONSerialization.jsonObject(with: Data(content(parts[1]).utf8)) as? [String: Any]) ?? [:]
            let id = newId(); store[id] = File(id: id, name: meta["name"] as? String ?? "", appProps: props(meta), parents: parentsOf(meta), media: Data(content(parts[2]).utf8), mime: "")
            return (200, json(["id": id]), [:])
        }
        if method == "POST", path.contains("/drive/v3/files") {
            let meta = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]) ?? [:]
            let id = newId(); store[id] = File(id: id, name: meta["name"] as? String ?? "", appProps: props(meta), parents: parentsOf(meta), media: Data(), mime: meta["mimeType"] as? String ?? "")
            return (200, json(["id": id]), [:])
        }
        if method == "PATCH", path.contains("/upload/drive/v3/files/"), let id = idFromFilesPath() { store[id]?.media = body ?? Data(); return (200, json(["id": id]), [:]) }
        if method == "PATCH", let id = idFromFilesPath() {
            let meta = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]) ?? [:]
            for (k, v) in props(meta) { store[id]?.appProps[k] = v }; return (200, json(["id": id]), [:]) }
        if method == "GET", path.contains("alt=media"), let id = idFromFilesPath() { return (200, store[id]?.media ?? Data(), [:]) }
        if method == "GET", path.contains("/drive/v3/files?q=") {
            let q = (path.components(separatedBy: "?q=").last ?? "").removingPercentEncoding ?? ""
            func between(_ a: String, _ b: String) -> String? { guard let r1 = q.range(of: a) else { return nil }; let rest = q[r1.upperBound...]; guard let r2 = rest.range(of: b) else { return nil }; return String(rest[..<r2.lowerBound]) }
            var matched: [File]
            if q.contains("in parents") {
                let fid = between("'", "' in parents") ?? ""
                matched = store.values.filter { $0.parents.contains(fid) }
                if q.contains("relayName"), let n = between("key='relayName' and value='", "'") { matched = matched.filter { $0.appProps["relayName"] == n } }
            } else if q.contains("relayToken"), let tok = between("value='", "'") {
                matched = store.values.filter { $0.mime == "application/vnd.google-apps.folder" && $0.appProps["relayToken"] == tok }
            } else { matched = [] }
            let files = matched.map { ["id": $0.id, "name": $0.name, "appProperties": $0.appProps] as [String: Any] }
            return (200, json(["files": files]), [:])
        }
        if method == "DELETE", let id = idFromFilesPath() { store[id] = nil; return (204, Data(), [:]) }
        return (404, Data("{}".utf8), [:])
    }
}

let ns = "TESTTK", ep = "EP1"
let mock = MockDrive()
mock.injectFolder(relayToken: ns)
mock.injectFile("_epoch.json", token: ns, media: RelayObjectFormat.canonicalJSON(["kind": "epoch", "token": ns, "epoch": ep]))
func receipt(_ g: String, _ s: Int, _ e: String, _ fp: String) -> Data {
    RelayObjectFormat.canonicalJSON(["kind": "receipt", "token": ns, "epoch": e, "group": g, "seq": String(s), "received": "true", "fp": fp]) }
let client = DriveClient(http: mock, token: { "fake" })
var t = DriveRelayTransport(client: client, token: ns); t.receiptWaitTimeout = 1.5; t.receiptPollInterval = 0.2
var pass = true
func check(_ l: String, _ c: Bool) { print("  [\(c ? "PASS":"FAIL")] \(l)"); if !c { pass = false } }

let r1 = await t.postPhoto(jpeg: Data("b1".utf8), group: "g", seq: 1, type: "document", quality: "Q1", year: 1968, month: 3, device: "X", replaces: nil)
check("no-receipt -> false (timeout, never-lose)", r1 == false)
check("no-receipt -> sidecar+jpeg upserted to Drive", mock.hasName("g__1.json") && mock.hasName("g__1.jpg"))
let fp2 = RelayObjectFormat.fingerprint(type: "document", quality: "Q1", year: "1968", month: "3", replaces: nil)
mock.injectFile("g__2.receipt.json", token: ns, media: receipt("g", 2, ep, fp2))
let r2 = await t.postPhoto(jpeg: Data("b2".utf8), group: "g", seq: 2, type: "document", quality: "Q1", year: 1968, month: 3, device: "X", replaces: nil)
check("matching receipt -> true", r2 == true)
mock.injectFile("g__3.receipt.json", token: ns, media: receipt("g", 3, ep, "deadbeefdeadbeef"))
let r3 = await t.postPhoto(jpeg: Data("b3".utf8), group: "g", seq: 3, type: "document", quality: "Q1", year: 1968, month: 3, device: "X", replaces: nil)
check("wrong-fp receipt -> false (A1/H3)", r3 == false)
let fp4 = RelayObjectFormat.fingerprint(type: "document", quality: nil, year: nil, month: nil, replaces: nil)
mock.injectFile("g__4.receipt.json", token: ns, media: receipt("g", 4, "OLD", fp4))
let r4 = await t.postPhoto(jpeg: Data("b4".utf8), group: "g", seq: 4, type: "document", quality: nil, year: nil, month: nil, device: "X", replaces: nil)
check("wrong-epoch receipt -> false (A2)", r4 == false)
let sc = await t.segmentComplete(group: "g", quality: "Q1", year: 1968, month: 3, seqs: nil)
check("segmentComplete -> true + object", sc && mock.hasName("g.segment.json"))
print(pass ? "DRIVE TRANSPORT (mock): PASS" : "DRIVE TRANSPORT (mock): FAIL")
exit(pass ? 0 : 1)
SWIFT
if swiftc "$NET/RelayObjectFormat.swift" "$NET/DriveClient.swift" "$NET/DriveRelayTransport.swift" "$W/main.swift" -o "$W/dt" 2>"$W/err"; then
  "$W/dt"
else echo "  [FAIL] swiftc:"; head -25 "$W/err"; exit 1; fi
