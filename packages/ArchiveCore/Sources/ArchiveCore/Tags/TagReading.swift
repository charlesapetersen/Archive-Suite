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
    public var isReadable: Bool {
        if case .success = self { return true }
        return false
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
    public static func read(_ url: URL) -> TagReadResult {
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
