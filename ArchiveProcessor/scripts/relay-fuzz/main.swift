// W40.e6 — fuzz and round-trip properties for RelayObjectFormat, compiled standalone against ONE platform's
// copy (Mac, or iOS with -D IOS). Driven by scripts/test-relay-fuzz.sh, which also compares the two
// platforms' canonical bytes for the same seeded maps. A crash or a silent wrong value is a failure; a clean
// nil from parse is a pass.
import Foundation

struct RNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
}

var failures = 0
func fail(_ s: String) { failures += 1; if failures <= 20 { print("  FAIL \(s)") } }

let keys = ["kind", "token", "epoch", "group", "seq", "type", "quality", "year", "month", "replaces", "device",
            "fp", "received", "seqs", "x", "ü", "a\"b", "k\\", "\u{01}"]
let atoms: [String] = ["a", "Z", "0", "7", " ", "\"", "\\", "/", "\n", "\r", "\t", "\u{08}", "\u{0C}", "\u{00}",
                       "\u{01}", "\u{1F}", "\u{7F}", "é", "\u{2019}", "\u{1F600}", "\u{FEFF}", "\u{2028}", "e\u{301}",
                       "{", "}", ":", ",", "[", "]", "null", "true", "1e3", "-0"]
func value(_ r: inout RNG) -> String { (0..<r.int(0...6)).map { _ in r.pick(atoms) }.joined() }

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "props"

if mode == "bytes" {
    // The canonical bytes for 2000 seeded maps, one hex line each — compared across platforms by the script.
    var r = RNG(state: 0xB17E5)
    for _ in 0..<2000 {
        var m: [String: String?] = [:]
        for _ in 0..<r.int(0...6) { m[r.pick(keys)] = r.chance(0.2) ? .some(nil) : value(&r) }
        print(RelayObjectFormat.canonicalJSON(m).map { String(format: "%02x", $0) }.joined())
        let sc = RelayObjectFormat.encodeSidecar(token: value(&r), epoch: value(&r), group: "g\(r.int(0...99))",
            seq: r.int(0...9999), type: r.pick(["document", "box", "folder"]), quality: r.chance(0.5) ? "Q\(r.int(1...3))" : nil,
            year: r.chance(0.5) ? String(r.int(800...2099)) : nil, month: r.chance(0.5) ? String(r.int(1...12)) : nil,
            replaces: r.chance(0.2) ? value(&r) : nil, device: r.chance(0.5) ? value(&r) : nil)
        print(sc.map { String(format: "%02x", $0) }.joined())
    }
    exit(0)
}

// 1. Round trip: parse(canonicalJSON(m)) is m without its nils, for any string map.
var r = RNG(state: 0xE6_4E1A)
for i in 0..<20_000 {
    var m: [String: String?] = [:]
    for _ in 0..<r.int(0...8) { m[r.pick(keys)] = r.chance(0.2) ? .some(nil) : value(&r) }
    let want = m.compactMapValues { $0 }
    let bytes = RelayObjectFormat.canonicalJSON(m)
    guard let got = RelayObjectFormat.parse(bytes) else { fail("round trip \(i): parse refused its own encoding of \(want)"); continue }
    // Includes a leading U+FEFF, which JSONSerialization used to drop (W40.fix-processor-relay-parse-lenient).
    if got != want { fail("round trip \(i): \(want) → \(got)") }
}

// 2. Encoders: every field reads back, and the receiver recomputes the same fingerprint — a leading U+FEFF too.
func fieldValue(_ r: inout RNG) -> String { r.chance(0.1) ? "\u{FEFF}" + value(&r) : value(&r) }
for i in 0..<5_000 {
    let q: String? = r.chance(0.5) ? "Q\(r.int(1...3))" : nil
    let y: String? = r.chance(0.5) ? String(r.int(800...2099)) : nil
    let mo: String? = r.chance(0.5) ? String(r.int(1...12)) : nil
    let rep: String? = r.chance(0.2) ? fieldValue(&r) : nil
    let type = r.pick(["document", "box", "folder", fieldValue(&r)])
    let group = "g-\(r.int(0...999))_x", seq = r.int(0...99_999), tok = fieldValue(&r), ep = fieldValue(&r), dev = fieldValue(&r)
    let sc = RelayObjectFormat.encodeSidecar(token: tok, epoch: ep, group: group, seq: seq, type: type,
                                             quality: q, year: y, month: mo, replaces: rep, device: dev)
    guard let m = RelayObjectFormat.parse(sc) else { fail("sidecar \(i): unparseable"); continue }
    let want: [String: String?] = ["kind": "photo", "token": tok, "epoch": ep, "group": group, "seq": String(seq),
                                   "type": type, "quality": q, "year": y, "month": mo, "replaces": rep, "device": dev]
    if m.filter({ $0.key != "fp" }) != want.compactMapValues({ $0 }) { fail("sidecar \(i): \(m)") }
    let fp = RelayObjectFormat.fingerprint(type: m["type"]!, quality: m["quality"], year: m["year"], month: m["month"], replaces: m["replaces"])
    if m["fp"] != fp || fp.count != 16 { fail("sidecar \(i): fingerprint \(m["fp"] ?? "nil") vs recomputed \(fp)") }
    let seg = RelayObjectFormat.encodeSegment(token: tok, epoch: ep, group: group, quality: q, year: y, month: mo, seqs: "1,\(seq)")
    if RelayObjectFormat.parse(seg)?["seqs"] != "1,\(seq)" { fail("segment \(i)") }
    if RelayObjectFormat.parse(RelayObjectFormat.encodeSessionComplete(token: tok, epoch: ep)) != ["kind": "session-complete", "token": tok, "epoch": ep] { fail("session \(i)") }
}

// 3. Damaged bodies: truncate, flip, splice, nest. parse returns nil or a map — never crashes — and what
//    it accepts is a fixed point: re-encoded canonically, it reads back the same.
func damage(_ d: Data, _ r: inout RNG) -> Data {
    var b = [UInt8](d)
    for _ in 0..<r.int(1...3) {
        let n = b.count
        guard n > 1 else { break }
        switch r.int(0...5) {
        case 0: b = Array(b.prefix(r.int(0...(n - 1))))
        case 1: b[r.int(0...(n - 1))] ^= UInt8(1 << r.int(0...7))
        case 2: b.insert(r.pick(Array("{}[]\":,\\0e-".utf8)), at: r.int(0...n))
        case 3: let a = r.int(0...(n - 1)); b.insert(contentsOf: b[a..<min(n, a + r.int(1...24))], at: r.int(0...n))
        case 4: b = Array("{\"seq\":".utf8) + b + Array("}".utf8)                       // nest the object in itself
        default: b = Array(repeating: UInt8(ascii: "["), count: r.int(1...3000)) + b     // deep nesting
        }
    }
    return Data(b)
}
var parsedDamaged = 0
for i in 0..<20_000 {
    let base = RelayObjectFormat.encodeSidecar(token: "TK", epoch: "E1", group: "g1", seq: r.int(0...99), type: "document",
                                               quality: "Q2", year: "1958", month: "3", replaces: nil, device: value(&r))
    let d = damage(base, &r)
    guard let m = RelayObjectFormat.parse(d) else { continue }
    parsedDamaged += 1
    if RelayObjectFormat.parse(RelayObjectFormat.canonicalJSON(m)) != m {
        fail("damage \(i): \(m) does not survive a canonical re-encode")
    }
}
// Bare numbers are tolerated on read (A6). A JSON boolean is not a number: it is dropped, never read as "1"
// or "0" (JSONSerialization handed it over as an NSNumber). Null, arrays and objects are dropped too.
for b in ["true", "false", "null", "[1]", "{\"a\":1}"] {
    if let m = RelayObjectFormat.parse(Data("{\"seq\":\(b),\"k\":\"v\"}".utf8)), m != ["k": "v"] { fail("A6: {\"seq\":\(b)} read as \(m)") }
}
for (n, want) in [("7", "7"), ("0", "0"), ("-3", "-3"), ("1e3", "1000"), ("7.5", "7.5")] {
    if RelayObjectFormat.parse(Data("{\"seq\":\(n)}".utf8))?["seq"] != want { fail("A6: a bare number \(n) is not read as \(want)") }
}
if RelayObjectFormat.parse(Data("{\"a\":\"\\ufeffx\"}".utf8))?["a"] != "\u{FEFF}x" { fail("an escaped leading U+FEFF is dropped") }

#if !IOS
// 4. Names (Mac only — the iOS copy has no classify/identityFromName). The name built for (group, seq) reads
//    back as that identity; a name that reads as an identity is the canonical name for it.
for i in 0..<20_000 {
    let group = (0..<r.int(1...12)).map { _ in r.pick(Array("abcXYZ019-_é")) }.map(String.init).joined()
    let seq = r.int(0...1_000_000)
    for (name, kind) in [(RelayObjectFormat.jpegName(group: group, seq: seq), RelayObjectFormat.Kind.media),
                         (RelayObjectFormat.sidecarName(group: group, seq: seq), .photo),
                         (RelayObjectFormat.receiptName(group: group, seq: seq), .receipt)] {
        guard let id = RelayObjectFormat.identityFromName(name), id.group == group, id.seq == seq else {
            fail("name \(i): \(name) does not read back as (\(group), \(seq))"); continue
        }
        if RelayObjectFormat.classify(name) != kind { fail("name \(i): \(name) classified as \(RelayObjectFormat.classify(name))") }
    }
    if RelayObjectFormat.classify(RelayObjectFormat.segmentName(group: group)) != .segmentComplete { fail("segment name \(i)") }
    // Damaged names.
    var c = Array(RelayObjectFormat.sidecarName(group: group, seq: seq))
    for _ in 0..<r.int(1...3) {
        switch r.int(0...3) {
        case 0: c.insert(r.pick(Array("+-0_. ")), at: r.int(0...c.count))
        case 1: if !c.isEmpty { c.remove(at: r.int(0...(c.count - 1))) }
        case 2: c = Array(c.prefix(r.int(0...c.count)))
        default: c.insert(contentsOf: c, at: r.int(0...c.count))
        }
    }
    let name = String(c)
    _ = RelayObjectFormat.classify(name)
    if let id = RelayObjectFormat.identityFromName(name) {
        let canonical = [RelayObjectFormat.jpegName(group: id.group, seq: id.seq),
                         RelayObjectFormat.sidecarName(group: id.group, seq: id.seq),
                         RelayObjectFormat.receiptName(group: id.group, seq: id.seq)]
        // The receiver's cleanup deletes a name by the identity it reads (FileRelayReceiver), so a name like
        // `g__007.jpg` must not read as (g, 7).
        if !canonical.contains(name) { fail("name \(i): non-canonical \(name) read as (\(id.group), \(id.seq))") }
    }
}
for name in ["g__007.jpg", "g__+7.jpg", "g__-1.jpg", "g__-0.json", "g__ 7.json", "g__.jpg", "g__7a.receipt.json"] {
    if let id = RelayObjectFormat.identityFromName(name) { fail("\(name) read as (\(id.group), \(id.seq))") }
}
if RelayObjectFormat.identityFromName("g__0.jpg")?.seq != 0 { fail("g__0.jpg not read as seq 0") }
#endif

print("  parsed \(parsedDamaged)/20000 damaged bodies without crashing (the rest refused cleanly)")
print(failures == 0 ? "  properties: PASS" : "  properties: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
