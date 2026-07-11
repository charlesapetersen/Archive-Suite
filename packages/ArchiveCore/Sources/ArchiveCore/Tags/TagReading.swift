import Foundation

/// Result of reading a file's Finder tags.
///
/// CRITICAL: this distinguishes a **confirmed** read (even one that legitimately found zero tags)
/// from an **unreadable** file. A read failure must NEVER be silently coerced into "no tags" — that
/// is the trap that would let a later write append `Read` to a file whose real tags couldn't be read,
/// destroying subject/date/priority tags. (Safety Protocol §3.) `CoordinatedTagWriter` will refuse
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

public enum TagReading {
    /// Read tag names + Finder label number from the on-disk resource values (the ground truth).
    ///
    /// Intentionally does NOT request `.documentIdentifierKey` — requesting it can cause the kernel to
    /// assign & persist a document identifier, which would be a mutation of a file we only meant to read.
    public static func read(_ url: URL) -> TagReadResult {
        do {
            let values = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
            // The call succeeded → a nil `tagNames` legitimately means "no tags" (confirmed empty),
            // as distinct from the throwing case below (unreadable).
            return .success(tagNames: values.tagNames ?? [], labelNumber: values.labelNumber)
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
