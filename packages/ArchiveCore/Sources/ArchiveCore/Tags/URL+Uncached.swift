import Foundation

extension URL {
    /// The same file as a NEW `URL`, with no resource-value cache behind it.
    ///
    /// `URL.resourceValues(forKeys:)` answers from a cache on the backing `NSURL`, and every copy of a
    /// Swift `URL` value shares that one object. Measured on this machine (W40.fix-identity-url-cache,
    /// 2026-10-17): after a file is deleted and a different file written at its path, a reused `URL`
    /// still reports the OLD file's `fileResourceIdentifier` and the OLD file's `tagNames`, while a fresh
    /// `URL` for the same path reports the new ones. `NSFileCoordinator` hands its accessor block the
    /// very same `NSURL` object it was given (`===`), so a "fresh read inside coordination" through
    /// that URL is served from the caller's cache too. The cache is flushed on the main thread by a
    /// run-loop turn, and never on a background thread, which is why the defect showed in an undo made
    /// in the same turn as the edit and would show in any writer off the main thread.
    ///
    /// Writes are affected as well: `setResourceValue` on an `NSURL` that holds cached Finder info
    /// rebuilds the 32-byte Finder-info block from the CACHE, so a tag or label write through a reused
    /// `URL` silently reverts a hidden flag (measured), a hide-extension bit or a custom icon set by
    /// someone else since the cache was filled. A write through a fresh `URL` leaves them alone.
    ///
    /// Every read that must see the disk as it is NOW (`FileIdentity.capture`, `TagReading.read`) and
    /// every write in `CoordinatedTagWriter.write` goes through this. Built from the file-system
    /// representation, as `CorpusWalker.inspect` does, never from `path`: `URL(fileURLWithPath:)` would
    /// normalise composed Unicode and so could name a different entry on a byte-exact volume, and an
    /// empty `path` (an undecodable escape) would silently become the working directory. A URL with no
    /// representation, an empty path, or a non-file scheme is returned as it is. Building the URL costs
    /// about 1.5 µs; the read behind it is then a real attribute fetch rather than a cache hit.
    var uncached: URL {
        guard isFileURL, !path.isEmpty else { return self }
        return withUnsafeFileSystemRepresentation { raw in
            guard let raw else { return self }
            return URL(fileURLWithFileSystemRepresentation: raw, isDirectory: hasDirectoryPath, relativeTo: nil)
        }
    }
}
