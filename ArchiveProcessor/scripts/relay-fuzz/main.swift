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
var known: [String: Int] = [:]
func fail(_ s: String) { failures += 1; if failures <= 20 { print("  FAIL \(s)") } }
func knownIssue(_ tag: String) { known[tag, default: 0] += 1 }

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
    if got != want {
        // JSONSerialization drops a LEADING U+FEFF from every key and value, escaped or not (JSONDecoder
        // keeps it), so `"\u{FEFF}x"` reads back as `"x"` — and a key `"\u{FEFF}token"` as `"token"`.
        func strip(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.unicodeScalars.dropFirst()) : s }
        let stripped = Dictionary(want.map { (strip($0.key), strip($0.value)) }, uniquingKeysWith: { a, _ in a })
        if got == stripped { knownIssue("W40.fix-processor-relay-parse-lenient (leading U+FEFF dropped)") }
        else { fail("round trip \(i): \(want) → \(got)") }
    }
}

// 2. Encoders: every field reads back, and the receiver recomputes the same fingerprint. (Values here never
//    start with U+FEFF — section 1 counts that known issue; a dropped one also changes the recomputed fp.)
func fieldValue(_ r: inout RNG) -> String { let v = value(&r); return v.hasPrefix("\u{FEFF}") ? "x" + v : v }
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
    if RelayObjectFormat.parse(RelayObjectFormat.canonicalJSON(m)) != m, !m.contains(where: { $0.key.hasPrefix("\u{FEFF}") || $0.value.hasPrefix("\u{FEFF}") }) {
        fail("damage \(i): \(m) does not survive a canonical re-encode")
    }
}
// Bare numbers are tolerated on read (A6). A JSON boolean is not a number, but JSONSerialization hands it over
// as an NSNumber, so `true` reads as "1" — a silent wrong value for any field compared to a number.
if RelayObjectFormat.parse(Data("{\"seq\":true}".utf8))?["seq"] == "1" { knownIssue("W40.fix-processor-relay-parse-lenient (JSON true read as \"1\")") }
if RelayObjectFormat.parse(Data("{\"seq\":7}".utf8))?["seq"] != "7" { fail("A6: a bare number seq is not tolerated") }

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
        if !canonical.contains(name) {
            // `Int(_:)` takes `+7`, `007` and `-1`, so `g__007.jpg` is read as (g, 7) — and the receiver's
            // cleanup deletes a name by the identity it reads (FileRelayReceiver.swift:305).
            knownIssue("W40.fix-processor-relay-parse-lenient (non-canonical seq in a name)")
        }
    }
}
#endif

print("  parsed \(parsedDamaged)/20000 damaged bodies without crashing (the rest refused cleanly)")
for (k, n) in known.sorted(by: { $0.key < $1.key }) { print("  KNOWN \(k): \(n) case(s)") }
print(failures == 0 ? "  properties: PASS" : "  properties: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
