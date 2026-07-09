import Foundation
import CryptoKit

/// On-disk format for the local-directory capture relay — the offline stand-in for the Google Drive
/// backend that proves the cloud-transport contract without OAuth/network. SINGLE SOURCE OF TRUTH for
/// object names, canonical JSON, the metadata fingerprint (A1), and parse/encode. The iOS + Android
/// writers mirror this byte-for-byte (guarded by the golden cross-check). Governing spec:
/// `SPEC/relay-object-format.md` (its v2 amendments bind over the v1 body).
///
/// All object metadata is a **string→string** map (so it maps 1:1 onto Drive `appProperties` later),
/// serialized with `canonicalJSON` (sorted keys, nil-omitted, fixed escaping, UTF-8) so three platforms
/// agree on the bytes. Reading is lenient (number-or-string tolerated, A6).
enum RelayObjectFormat {

    // MARK: - Object names
    // '.' never appears in a safe group id (CaptureValidation.isSafeGroupId) → suffix classification is
    // unambiguous. Identity (group,seq) is still read from the sidecar BODY, never parsed from the name.
    static func jpegName(group: String, seq: Int) -> String { "\(group)__\(seq).jpg" }
    static func sidecarName(group: String, seq: Int) -> String { "\(group)__\(seq).json" }
    static func receiptName(group: String, seq: Int) -> String { "\(group)__\(seq).receipt.json" }
    static func segmentName(group: String) -> String { "\(group).segment.json" }
    static let sessionCompleteName = "_session.complete.json"
    static let epochMarkerName = "_epoch.json"

    enum Kind { case media, photo, segmentComplete, sessionComplete, receipt, epoch, ignored }

    static func classify(_ name: String) -> Kind {
        if name.hasPrefix(".") || name.hasSuffix(".part") { return .ignored }
        if name == epochMarkerName { return .epoch }
        if name == sessionCompleteName { return .sessionComplete }
        if name.hasSuffix(".receipt.json") { return .receipt }
        if name.hasSuffix(".segment.json") { return .segmentComplete }
        if name.hasSuffix(".jpg") { return .media }
        if name.hasSuffix(".json") { return .photo }
        return .ignored
    }

    /// Parse the leading `<group>__<seq>` from a media/sidecar/receipt filename, for the A10 filename↔body
    /// identity cross-check. `nil` if the name doesn't fit the pattern. Group ids may contain `_`, so split
    /// on the LAST `__` before the extension.
    static func identityFromName(_ name: String) -> (group: String, seq: Int)? {
        var base = name
        for suffix in [".receipt.json", ".jpg", ".json"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count)); break
        }
        guard let r = base.range(of: "__", options: .backwards) else { return nil }
        let group = String(base[..<r.lowerBound])
        guard let seq = Int(base[r.upperBound...]) else { return nil }
        return (group, seq)
    }

    // MARK: - Canonical JSON (all-string values, sorted keys, nil-omitted, fixed escaping)

    /// Deterministic JSON both Swift and Kotlin can reproduce byte-for-byte. Do NOT substitute a built-in
    /// encoder (Swift escapes `/`→`\/` unless disabled; org.json escapes differently). Emits `{"k":"v",…}`,
    /// no spaces, UTF-8, keys ascending (fixed lowercase ASCII keys → Swift/Kotlin byte-sort agree).
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

    /// String-replacement escape (build the String, encode to UTF-8 once at the end so astral scalars stay
    /// identical UTF-8 sequences on both platforms): only `"` `\` and C0 controls are escaped; `/` and all
    /// non-ASCII are emitted verbatim. C0 hex is lowercase.
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

    // MARK: - Metadata fingerprint (A1)
    // fp = SHA-256(canonicalJSON of the INGEST-RELEVANT metadata) → first 16 hex. Identical inputs on the
    // phone and Mac (same function, same fields) yield the same fp, so: the receipt echoes it and the phone
    // trusts a receipt only when its fp matches the current metadata (defeats the stale-ack bug, H3); the
    // Mac re-ingests iff fp changed (identical re-send skipped, real P10/tag change re-applied).
    static func fingerprint(type: String, priority: String?, year: String?, month: String?, replaces: String?) -> String {
        let m: [String: String?] = ["type": type, "priority": priority, "year": year, "month": month, "replaces": replaces]
        let digest = SHA256.hash(data: canonicalJSON(m))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encode

    static func encodeSidecar(token: String, epoch: String, group: String, seq: Int, type: String,
                              priority: String?, year: String?, month: String?, replaces: String?,
                              device: String? = nil) -> Data {
        // fp deliberately excludes `device` (it doesn't change OCR/tags), so a device-name change never
        // forces a re-ingest — matches the A1 fingerprint contract.
        let fp = fingerprint(type: type, priority: priority, year: year, month: month, replaces: replaces)
        return canonicalJSON(["kind": "photo", "token": token, "epoch": epoch, "group": group,
                              "seq": String(seq), "type": type, "priority": priority, "year": year,
                              "month": month, "replaces": replaces, "device": device, "fp": fp])
    }

    static func encodeReceipt(token: String, epoch: String, group: String, seq: Int, fp: String) -> Data {
        canonicalJSON(["kind": "receipt", "token": token, "epoch": epoch, "group": group,
                       "seq": String(seq), "received": "true", "fp": fp])
    }

    static func encodeSegment(token: String, epoch: String, group: String,
                              priority: String?, year: String?, month: String?, seqs: String?) -> Data {
        canonicalJSON(["kind": "segment-complete", "token": token, "epoch": epoch, "group": group,
                       "priority": priority, "year": year, "month": month, "seqs": seqs])
    }

    static func encodeSessionComplete(token: String, epoch: String) -> Data {
        canonicalJSON(["kind": "session-complete", "token": token, "epoch": epoch])
    }

    static func encodeEpochMarker(token: String, epoch: String) -> Data {
        canonicalJSON(["kind": "epoch", "token": token, "epoch": epoch])
    }

    // MARK: - Parse (lenient — number-or-string tolerated, A6)

    /// Parse an object body to `[String:String]`, stringifying numeric values so a bare `"seq":7` from a
    /// non-canonical writer is tolerated (not a fatal skip that would silently stall one platform, H7).
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
