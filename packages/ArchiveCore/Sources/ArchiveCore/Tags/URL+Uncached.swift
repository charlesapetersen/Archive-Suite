import Foundation

extension URL {
    /// The same file path as a NEW `URL`, with no resource-value cache behind it.
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
    /// Every read that must see the disk as it is NOW (`FileIdentity.capture`, `TagReading.read`, and
    /// through it the writer's §2 pre-read and §8 re-read) goes through this. It costs about 1.5 µs
    /// (no `stat`: the directory flag is carried over rather than probed). Non-file URLs are returned
    /// as they are.
    var uncached: URL {
        guard isFileURL else { return self }
        return URL(fileURLWithPath: path, isDirectory: hasDirectoryPath)
    }
}
