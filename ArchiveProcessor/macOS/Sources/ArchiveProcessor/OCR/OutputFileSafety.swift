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
