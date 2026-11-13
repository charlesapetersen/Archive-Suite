import Foundation

/// File-identity and destination helpers for Processor output paths.
///
/// Review flows sometimes map an input directly as its own output (notably pre-OCRed PDFs). Any cleanup
/// routine must therefore prove that an output is a distinct generated file before removing it.
enum OutputFileSafety {
    struct ArtifactMove {
        let source: URL
        let destination: URL
    }

    static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    /// Prove file identity using resolved exact paths or filesystem resource identifiers. Case-folded path
    /// equality alone is not proof on a case-sensitive volume, where `Photo.JPG` and `photo.jpg` may differ.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left.path == right.path { return true }
        guard FileManager.default.fileExists(atPath: left.path),
              FileManager.default.fileExists(atPath: right.path),
              let leftID = try? left.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rightID = try? right.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    /// Relocate a related artifact set without creating a partial, unrecoverable move. Every source is
    /// copied to an operation-owned temporary sibling and byte-verified first, then installed without
    /// replacing existing files. A staging/install failure removes only artifacts owned by this attempt,
    /// leaving every source intact. Sources are removed only after the complete destination set is durable;
    /// a cleanup failure intentionally leaves a duplicate rather than risking loss.
    static func relocateArtifactSet(
        _ artifacts: [ArtifactMove],
        fileManager: FileManager = .default,
        copyItem: ((URL, URL) throws -> Void)? = nil
    ) throws {
        guard !artifacts.isEmpty else { return }
        var destinationKeys = Set<String>()
        for artifact in artifacts {
            guard fileManager.fileExists(atPath: artifact.source.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: artifact.source.path])
            }
            guard destinationKeys.insert(pathKey(artifact.destination)).inserted,
                  !fileManager.fileExists(atPath: artifact.destination.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: artifact.destination.path])
            }
        }

        var staged: [(artifact: ArtifactMove, temporary: URL)] = []
        do {
            for artifact in artifacts {
                try fileManager.createDirectory(
                    at: artifact.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let temporary = artifact.destination.deletingLastPathComponent().appendingPathComponent(
                    ".archiveprocessor-\(UUID().uuidString).staging",
                    isDirectory: false
                )
                // The UUID sibling is owned by this operation. Record it before copying so a partial file
                // left by a failed copy is safe to remove without touching the final destination.
                staged.append((artifact, temporary))
                if let copyItem {
                    try copyItem(artifact.source, temporary)
                } else {
                    try fileManager.copyItem(at: artifact.source, to: temporary)
                }
                guard fileManager.contentsEqual(atPath: artifact.source.path,
                                                andPath: temporary.path) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
                }
            }
        } catch {
            for item in staged.reversed() {
                try? fileManager.removeItem(at: item.temporary)
            }
            throw error
        }

        var installed: [URL] = []
        do {
            for item in staged {
                // `moveItem` does not replace an existing destination. If another actor wins the race after
                // preflight, its file is preserved and only our unique staging files are rolled back.
                try fileManager.moveItem(at: item.temporary, to: item.artifact.destination)
                installed.append(item.artifact.destination)
            }
        } catch {
            for destination in installed.reversed() {
                try? fileManager.removeItem(at: destination)
            }
            for item in staged.reversed() {
                try? fileManager.removeItem(at: item.temporary)
            }
            throw error
        }

        // Establish identity while all sources still exist. Reservation keys intentionally case-fold to
        // avoid output collisions, but source cleanup must distinguish case-only files on case-sensitive
        // volumes.
        var uniqueSources: [URL] = []
        for artifact in artifacts where !uniqueSources.contains(where: { isSameFile($0, artifact.source) }) {
            uniqueSources.append(artifact.source)
        }
        for source in uniqueSources {
            do {
                try fileManager.removeItem(at: source)
            } catch {
                NSLog("OutputFileSafety: destination verified but source cleanup failed at %@: %@",
                      source.path, error.localizedDescription)
            }
        }
    }

    /// Reserve a destination without overwriting an existing file or another output from this run.
    /// `allowedExisting` supports the intentional dual-output case where the pristine source image already
    /// occupies the preferred image path and should be reused rather than copied over itself.
    static func reserveUniqueDestination(
        preferred: URL,
        allowedExisting: URL? = nil,
        reservedPaths: inout Set<String>,
        fileManager: FileManager = .default
    ) -> URL {
        let directory = preferred.deletingLastPathComponent()
        let base = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        var candidate = preferred
        var suffix = 2

        while true {
            let key = pathKey(candidate)
            let allowed = allowedExisting.map { isSameFile(candidate, $0) } ?? false
            if !reservedPaths.contains(key) && (!fileManager.fileExists(atPath: candidate.path) || allowed) {
                reservedPaths.insert(key)
                return candidate
            }
            let name = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }
    }

    enum ReplaceError: Error, Equatable {
        case aliasesSource, missing, notVerified
    }

    /// W46.date-route-header — replace a generated output's bytes in place, never a file that aliases its source. The
    /// new bytes go to a hidden sibling first, are read back byte for byte and flushed to the disk; the output's
    /// extended attributes (its Finder tags) are copied onto it and read back; then one `rename(2)` swaps it in, so the
    /// output is the old file or the new one, never partial. Any failure before the swap removes only the sibling and
    /// leaves the output untouched.
    static func replaceGeneratedOutput(_ outputURL: URL, for sourceURL: URL, with data: Data,
                                       fileManager: FileManager = .default) throws {
        guard !isSameFile(outputURL, sourceURL) else { throw ReplaceError.aliasesSource }
        guard fileManager.fileExists(atPath: outputURL.path) else { throw ReplaceError.missing }
        let temp = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".archiveprocessor-\(UUID().uuidString).tmp")   // short: a long output name still fits
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            guard (try? Data(contentsOf: temp)) == data else { throw ReplaceError.notVerified }
            let handle = try FileHandle(forUpdating: temp)
            let flushed = fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0
            try handle.close()
            guard flushed else { throw ReplaceError.notVerified }
            try copyExtendedAttributes(from: outputURL, to: temp)
            guard rename(temp.path, outputURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    /// Attributes macOS keeps itself (a process may not set them, and a new file gets its own): never copied.
    static let systemAttributes: Set<String> = ["com.apple.provenance", "com.apple.quarantine", "com.apple.macl",
                                                "com.apple.rootless"]

    /// Every extended attribute of `source` (its Finder tags and label among them) put on `destination` by
    /// `copyfile`, as Improve OCR's reviewed publication does (ReOCRFileWriter), then each one but the system's own
    /// read back equal. Not a raw `setxattr` per attribute: the write-surface lint forbids a direct Finder-tag write.
    static func copyExtendedAttributes(from source: URL, to destination: URL) throws {
        func fail() -> Error { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw fail() }
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(source.path, &names, size, XATTR_NOFOLLOW) == size else { throw fail() }
        let list = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var want: [(name: String, value: [UInt8])] = []
        for name in list where !systemAttributes.contains(name) {
            let length = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw fail() }
            var value = [UInt8](repeating: 0, count: length)
            guard getxattr(source.path, name, &value, length, 0, XATTR_NOFOLLOW) == length else { throw fail() }
            want.append((name, value))
        }
        guard copyfile(source.path, destination.path, nil,
                       copyfile_flags_t(COPYFILE_XATTR | COPYFILE_NOFOLLOW)) == 0 else { throw fail() }
        for (name, value) in want {
            var back = [UInt8](repeating: 0, count: value.count)
            guard getxattr(destination.path, name, &back, value.count, 0, XATTR_NOFOLLOW) == value.count, back == value else {
                throw ReplaceError.notVerified
            }
        }
    }

    /// Remove a proven generated output, but never when it aliases the source. Do not infer ownership of a
    /// same-basename JSON: when input and output directories coincide, that sidecar may be user metadata.
    /// Errors propagate so callers retain the output mapping for a later cleanup attempt.
    static func removeGeneratedOutput(_ outputURL: URL, for sourceURL: URL,
                                      fileManager: FileManager = .default) throws {
        guard !isSameFile(outputURL, sourceURL) else { return }
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
    }
}
