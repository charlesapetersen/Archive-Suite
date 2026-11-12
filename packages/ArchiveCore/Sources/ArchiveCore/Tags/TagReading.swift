import Foundation

/// Result of reading a file's Finder tags.
///
/// CRITICAL: this distinguishes a **confirmed** read (even one that legitimately found zero tags)
/// from an **unreadable** file. A read failure must NEVER be silently coerced into "no tags" — that
/// is the trap that would let a later write append `Read` to a file whose real tags couldn't be read,
/// destroying subject/date/quality tags. (Safety Protocol §3.) `CoordinatedTagWriter` will refuse
/// to write on `.failure`.
public enum TagReadResult: Sendable, Equatable {
    case success(tagNames: [String], labelNumber: Int?)
    case failure(String)  // human-readable error description

    public var tagNames: [String]? {
        if case let .success(tagNames, _) = self { return tagNames }
        return nil
    }
}

/// The extended attribute macOS keeps Finder tags in.
let finderTagsXattrName = "com.apple.metadata:_kMDItemUserTags"

/// What the on-disk tag attribute says when `URLResourceValues.tagNames` came back `nil`.
///
/// `nil` is ambiguous — it is macOS's answer both for "this file has no tags" and for "I could not
/// read this file's tags" — and resolving that ambiguity the wrong way DESTROYED TAGS (see
/// `TagXattr.inspect`). This enum is the disambiguation, and it is deliberately three-valued:
/// *nothing there* and *could not look* are different answers.
enum TagXattrState: Equatable {
    case absent            // no such attribute (ENOATTR) — an honest "this file has no tags"
    case readableEmpty     // attribute present and readable, but holds no tag names — honest too
    case unreadable(String)  // could not be read, or is not a tag array — we DO NOT know
}

enum TagXattr {

    /// Ask the filesystem directly whether a file's tag attribute is *absent* or merely *unreadable*.
    ///
    /// Why this exists (measured 2026-08-05 on this machine, and independently on 2026-08-04):
    /// `url.resourceValues(forKeys: [.tagNamesKey])` **does not throw** for a file whose extended
    /// attributes cannot be read while its directory is traversable — it returns `tagNames == nil`,
    /// exactly as it does for a genuinely untagged file:
    ///
    /// | file state                              | resourceValues | tagNames | getxattr        |
    /// |-----------------------------------------|----------------|----------|-----------------|
    /// | tagged, 0644                            | ok             | \[…\]    | size 69         |
    /// | untagged                                | ok             | nil      | -1 / ENOATTR    |
    /// | tags removed (empty-array residue)      | ok             | nil      | size 42         |
    /// | tagged, mode 0o200 or 0o000             | ok             | **nil**  | -1 / EACCES     |
    /// | tagged, ACL denies only `readextattr`   | ok             | **nil**  | -1 / EACCES     |
    /// | ACL denies `read,readattr,readextattr`  | throws 257     | —        | -1 / EACCES     |
    /// | parent directory sealed (0o000)         | throws 257     | —        | -1 / EACCES     |
    ///
    /// The three **bold** rows are the leak: coercing them to `[]` reports "confirmed no tags" about a
    /// file carrying real ones, and `CoordinatedTagWriter` then computes a delta against nothing and
    /// writes it — reproduced turning `["Unread","Subj","P9"]` into `["Read"]`.
    ///
    /// Two details are load-bearing, both measured rather than assumed:
    ///
    /// 1. **The probe must be `getxattr`, not `access(R_OK)`.** An ACE denying only `readextattr`
    ///    leaves the file *data* readable, so `access(R_OK)` returns 0 while the tags are unreadable.
    /// 2. **The probe must FOLLOW symlinks** (options `0`, never `XATTR_NOFOLLOW`). `resourceValues`
    ///    reports the *target's* tags through a symlink, so a `XATTR_NOFOLLOW` probe would answer
    ///    about the link — which has no attribute of its own — and return `ENOATTR` for a denied
    ///    target: the very coercion this function exists to prevent, reintroduced one indirection out.
    ///
    /// Only called on the `tagNames == nil` branch, so a tagged file costs nothing extra and an
    /// untagged one costs a single `getxattr` that returns immediately.
    static func inspect(_ url: URL) -> TagXattrState {
        guard url.isFileURL else { return .unreadable("not a file URL: \(url)") }
        return url.withUnsafeFileSystemRepresentation { rawPath -> TagXattrState in
            guard let rawPath else { return .unreadable("path has no filesystem representation") }

            errno = 0
            let size = getxattr(rawPath, finderTagsXattrName, nil, 0, 0, 0)
            if size == -1 {
                let code = errno
                // ENOATTR is the ONLY errno that confirms absence. Everything else — EACCES, EPERM,
                // EIO, ENOTSUP, ENOENT — means we could not look, which is not the same as nothing.
                return code == ENOATTR ? .absent
                                       : .unreadable("tag attribute unreadable: \(describe(code))")
            }
            if size == 0 { return .readableEmpty }

            // The attribute is readable but macOS decoded no names from it. That is normal — a file
            // whose tags were removed keeps a 42-byte empty-array plist (51 such files in the owner's
            // corpus, measured). Confirm it really is a tag array before calling it "no tags", so a
            // corrupt or foreign attribute is reported as unknown instead of being silently overwritten.
            var buffer = [UInt8](repeating: 0, count: size)
            errno = 0
            let read = getxattr(rawPath, finderTagsXattrName, &buffer, size, 0, 0)
            if read == -1 {
                let code = errno
                return code == ENOATTR ? .absent   // removed between sizing and reading
                                       : .unreadable("tag attribute unreadable: \(describe(code))")
            }
            let data = Data(buffer[0..<read])
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let entries = plist as? [Any]
            else {
                return .unreadable("tag attribute present (\(read) bytes) but is not a readable tag array")
            }
            // It must be an EMPTY array. A non-empty one that macOS nonetheless reported as no tags is
            // an attribute we can see but cannot interpret — including the case where the file became
            // readable between the resourceValues call above and this probe. Either way the honest
            // answer is "I don't know", never "there is nothing here".
            guard entries.isEmpty else {
                return .unreadable("tag attribute holds \(entries.count) entr\(entries.count == 1 ? "y" : "ies") that macOS did not report as tags")
            }
            return .readableEmpty
        }
    }

    /// The attribute's raw entries, each a tag name optionally followed by `\n` and the tag's own colour
    /// ("Purple\n3"). `[]` when the attribute is absent; nil when it cannot be read or is not an array of
    /// strings — a caller then has no colours to keep, which is never a reason to write.
    static func rawEntries(_ url: URL) -> [String]? {
        guard url.isFileURL else { return nil }
        return url.withUnsafeFileSystemRepresentation { rawPath -> [String]? in
            guard let rawPath else { return nil }
            let size = getxattr(rawPath, finderTagsXattrName, nil, 0, 0, 0)
            if size == -1 { return errno == ENOATTR ? [] : nil }
            if size == 0 { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(rawPath, finderTagsXattrName, &buffer, size, 0, 0)
            guard read >= 0 else { return nil }
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(buffer[0..<read]),
                                                                          options: [], format: nil)
            else { return nil }
            return plist as? [String]
        }
    }

    /// Replace the attribute with `entries`, as the binary plist Finder writes. Throws on any failure.
    static func writeRawEntries(_ entries: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        let status = url.withUnsafeFileSystemRepresentation { rawPath -> Int32 in
            guard let rawPath else { errno = EINVAL; return -1 }
            return data.withUnsafeBytes { setxattr(rawPath, finderTagsXattrName, $0.baseAddress, data.count, 0, 0) }
        }
        if status != 0 {
            throw TagWriteError.verificationFailed("the tags were written, but their colours could not be kept: \(describe(errno))")
        }
    }

    /// The colour-preserving half of a tag write (W40.vm-macos27-reader). `before` and `after` are the raw
    /// entries around a `.tagNamesKey` write; returns the corrected entries, or nil when nothing needs it.
    /// - One of Finder's seven colour-named tags ("Purple") gets its own colour ("Purple\n3"), whether the
    ///   write kept it or added it: that is the colour Finder gives it, and what a write before macOS 27
    ///   left it with. It follows the name, never the label, so it cannot fight an intended label change.
    /// - Any other tag that was there before and is still there keeps the entry it had, occurrence by
    ///   occurrence, matched on the name's exact bytes ("Café" composed and decomposed are two names).
    /// - Any other tag the write added keeps what macOS gave it.
    /// Only colours change: every corrected entry has the same name as the entry it replaces.
    ///
    /// Why: writing names only lets macOS choose each tag's colour, and on macOS 27 a SANDBOXED app (all
    /// three of ours) gets none, so every write turned "Purple\n3" into "Purple\n0" (measured 2026-11-12 on
    /// the host and in the VM guest; unsandboxed, Finder's colour-named tags kept their colour and any
    /// other tag took the one in the local Finder tag list, often none).
    static func keepingColours(before: [String], after: [String]) -> [String]? {
        func split(_ entry: String) -> (name: String, colour: Int) {
            guard let cut = entry.lastIndex(of: "\n"), let colour = Int(entry[entry.index(after: cut)...])
            else { return (entry, 0) }
            return (String(entry[..<cut]), colour)
        }
        var kept: [[UInt8]: [String]] = [:]   // a name's bytes → its earlier entries, in order
        for entry in before { kept[Array(split(entry).name.utf8), default: []].append(entry) }
        var changed = false
        let corrected = after.map { entry -> String in
            let (name, colour) = split(entry)
            let bytes = Array(name.utf8)
            let earlier = kept[bytes]?.first
            if earlier != nil { kept[bytes]?.removeFirst() }
            let replacement: String
            if let label = FinderLabel.allCases.first(where: { Array($0.tokenName.utf8) == bytes }) {
                guard colour != label.rawValue else { return entry }
                replacement = "\(name)\n\(label.rawValue)"
            } else {
                guard let earlier, split(earlier).colour != colour else { return entry }
                replacement = earlier
            }
            changed = true
            return replacement
        }
        return changed ? corrected : nil
    }

    /// errno → a message a human can act on. Deliberately not `strerror`: the C-string initializers
    /// are deprecation churn, and these are the only codes this probe can produce.
    private static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES:  return "permission denied (EACCES)"
        case EPERM:   return "operation not permitted (EPERM)"
        case ENOENT:  return "no such file (ENOENT)"
        case EIO:     return "I/O error (EIO)"
        case ENOTSUP: return "extended attributes unsupported on this volume (ENOTSUP)"
        case ERANGE:  return "attribute changed size while being read (ERANGE)"
        default:      return "errno \(code)"
        }
    }
}

public enum TagReading {
    /// Read tag names + Finder label number from the on-disk resource values (the ground truth).
    ///
    /// Intentionally does NOT request `.documentIdentifierKey` — requesting it can cause the kernel to
    /// assign & persist a document identifier, which would be a mutation of a file we only meant to read.
    ///
    /// Reads the disk, not the `URL`'s resource-value cache (`URL.uncached`): a reused `URL` instance
    /// would otherwise hand back the tags it read last time, which for the writer's §2 pre-read means a
    /// transform computed from stale tags and a write that clobbers whatever changed them (measured,
    /// W40.fix-identity-url-cache).
    public static func read(_ url: URL) -> TagReadResult {
        readTrustingURL(url.uncached)
    }

    /// `read`, through the URL exactly as handed in. ONLY for a caller that built the `URL` itself in the
    /// same breath (the corpus walker, whose enumerator vends a new URL per file and which already
    /// rebuilds one byte-exactly in `inspect`): there the rebuild buys nothing and costs a second
    /// attribute fetch per file, about 7 µs, or 0.7 s over a 102k-file scan. Anything that holds a `URL`
    /// across time — a row, a stored reference, an undo entry — calls `read`.
    static func readTrustingURL(_ url: URL) -> TagReadResult {
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
            if let names = values.tagNames {
                return .success(tagNames: names, labelNumber: values.labelNumber)
            }
            // A nil `tagNames` does NOT mean "no tags" — this call succeeds, and returns nil, for a
            // file whose tag attribute cannot be read at all (W26.deny). Ask the filesystem which of
            // the two it is; only absence or a readable-but-empty attribute is a confirmed "no tags".
            switch TagXattr.inspect(url) {
            case .absent, .readableEmpty:
                return .success(tagNames: [], labelNumber: values.labelNumber)
            case let .unreadable(why):
                return .failure(why)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Convenience: read and classify into facets. Returns nil when the file is unreadable
    /// (callers must treat nil as "unknown", never as "untagged").
    public static func readTags(_ url: URL) -> DocumentTags? {
        guard case let .success(tagNames, labelNumber) = read(url) else { return nil }
        return DocumentTags.parse(raw: tagNames, labelNumber: labelNumber)
    }
}
