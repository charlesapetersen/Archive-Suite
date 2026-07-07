import Foundation
import CryptoKit

/// iOS mirror of the Mac's `RelayObjectFormat` — MUST produce byte-identical output (canonical JSON, escape
/// table, fingerprint) so the Mac receiver reads what this writes. Guarded by the golden byte-check against
/// `SPEC/relay-golden/`. Keep in lockstep with `ArchiveProcessor/.../Net/RelayObjectFormat.swift` and the
/// Android `net/RelayObjectFormat.kt`. Governing spec: `LIVE_CAPTURE_FILERELAY_SPEC.md` (v2 amendments bind).
enum RelayObjectFormat {

    // MARK: - Object names
    static func jpegName(group: String, seq: Int) -> String { "\(group)__\(seq).jpg" }
    static func sidecarName(group: String, seq: Int) -> String { "\(group)__\(seq).json" }
    static func receiptName(group: String, seq: Int) -> String { "\(group)__\(seq).receipt.json" }
    static func segmentName(group: String) -> String { "\(group).segment.json" }
    static let sessionCompleteName = "_session.complete.json"
    static let epochMarkerName = "_epoch.json"

    // MARK: - Canonical JSON (all-string values, sorted keys, nil-omitted, fixed escaping)
    static func canonicalJSON(_ map: [String: String?]) -> Data {
        let pairs = map.compactMap { (k, v) -> (String, String)? in v.map { (k, $0) } }
                       .sorted { $0.0 < $1.0 }
        var s = "{"
        for (i, pair) in pairs.enumerated() {
            if i > 0 { s += "," }
            s += "\"" + escape(pair.0) + "\":\"" + escape(pair.1) + "\""
        }
        s += "}"
        return Data(s.utf8)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    // MARK: - Metadata fingerprint (A1) — identical function+inputs on Mac & phone → same fp
    static func fingerprint(type: String, priority: String?, year: String?, month: String?, replaces: String?) -> String {
        let m: [String: String?] = ["type": type, "priority": priority, "year": year, "month": month, "replaces": replaces]
        let digest = SHA256.hash(data: canonicalJSON(m))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encode (what the phone writes)
    static func encodeSidecar(token: String, epoch: String, group: String, seq: Int, type: String,
                              priority: String?, year: String?, month: String?, replaces: String?,
                              device: String? = nil) -> Data {
        let fp = fingerprint(type: type, priority: priority, year: year, month: month, replaces: replaces)
        return canonicalJSON(["kind": "photo", "token": token, "epoch": epoch, "group": group,
                              "seq": String(seq), "type": type, "priority": priority, "year": year,
                              "month": month, "replaces": replaces, "device": device, "fp": fp])
    }

    static func encodeSegment(token: String, epoch: String, group: String,
                              priority: String?, year: String?, month: String?, seqs: String?) -> Data {
        canonicalJSON(["kind": "segment-complete", "token": token, "epoch": epoch, "group": group,
                       "priority": priority, "year": year, "month": month, "seqs": seqs])
    }

    static func encodeSessionComplete(token: String, epoch: String) -> Data {
        canonicalJSON(["kind": "session-complete", "token": token, "epoch": epoch])
    }

    // MARK: - Parse (lenient — number-or-string tolerated). The phone reads the receipt + the epoch marker.
    static func parse(_ data: Data) -> [String: String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }
}
