import Foundation

/// A JPEG candidate found during a fingerprint-only walk of the partner subtree.
///
/// `collectionContext` is the candidate's relative parent path. It is retained alongside the leaf stem so
/// callers can disambiguate repeated names without discarding the information needed to explain a refusal.
public struct JPEGPartnerCandidate: Sendable, Equatable {
    public let stem: String
    public let path: String
    public let collectionContext: String
    public let fingerprint: CorpusFileFingerprint

    public init(stem: String, path: String, collectionContext: String,
                fingerprint: CorpusFileFingerprint) {
        self.stem = stem
        self.path = path
        self.collectionContext = collectionContext
        self.fingerprint = fingerprint
    }
}

/// The result of resolving a PDF's optional JPEG partner.
public enum JPEGPartnerResolution: Sendable, Equatable {
    case match(URL)
    case none
    case unknown
    case ambiguous([URL])
}

/// A clean-pass-gated index over the JPEGS subtree.
///
/// The index only reads names and syscall fingerprints. It never opens image bytes, reads tags, or guesses
/// between duplicate stems. An incomplete walk remains `unknown`; its partial rows cannot establish that a
/// partner is absent.
public struct JPEGPartnerIndex: Sendable, Equatable {
    private struct FileSystemKey: Hashable, Sendable {
        let bytes: [UInt8]
        init(_ value: String) { bytes = Array(value.utf8) }
    }

    public let jpegRootPath: String
    public let isClean: Bool
    public let filesSeen: Int
    public let candidates: [JPEGPartnerCandidate]

    public init(jpegRoot: URL, scan: CorpusFingerprintScanResult) {
        // Keep the caller's spelling for storage/security-scope identity. The discovered prefix is only
        // used for byte-exact comparison because CorpusWalker resolves aliased ancestors such as /var.
        jpegRootPath = Self.filesystemPath(jpegRoot)
        let comparisonRoot = Self.comparisonRootPath(jpegRoot)
        let rootMatches = scan.rootPath.map {
            FileSystemKey($0) == FileSystemKey(comparisonRoot)
        } ?? false
        let entriesStayUnderRoot = scan.entries.allSatisfy {
            Self.relativePath(Self.filesystemPath($0.url), under: comparisonRoot) != nil
        }
        isClean = scan.isClean && rootMatches && entriesStayUnderRoot
        filesSeen = scan.filesSeen
        candidates = scan.entries.compactMap { entry in
            let path = Self.filesystemPath(entry.url)
            guard let relative = Self.relativePath(path, under: comparisonRoot),
                  Self.isSupportedImageExtension((path as NSString).pathExtension) else { return nil }
            let filename = (path as NSString).lastPathComponent
            let stem = (filename as NSString).deletingPathExtension
            let parent = (relative as NSString).deletingLastPathComponent
            return JPEGPartnerCandidate(stem: stem, path: path,
                                        collectionContext: parent == "." ? "" : parent,
                                        fingerprint: entry.fingerprint)
        }.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }

    /// Reconstruct a persisted table. Only `LibraryIndex` should call this after reading its clean marker.
    public init(jpegRootPath: String, candidates: [JPEGPartnerCandidate], isClean: Bool,
                filesSeen: Int) {
        self.jpegRootPath = jpegRootPath
        self.candidates = candidates
        self.isClean = isClean
        self.filesSeen = filesSeen
    }

    /// Resolve a PDF by an exact mirrored relative path first, then by a unique stem. A supplied context
    /// narrows duplicate stems only when it identifies exactly one candidate; otherwise ambiguity is
    /// surfaced. A unique stem remains safe even when its collection was relocated and renamed.
    public func resolve(pdfURL: URL, mainRoot: URL,
                        collectionContext: String? = nil) -> JPEGPartnerResolution {
        guard isClean else { return .unknown }
        let pdfPath = Self.comparisonFilePath(pdfURL)
        guard let relative = Self.relativePath(pdfPath, under: Self.comparisonRootPath(mainRoot)) else {
            return .unknown
        }
        let pdfStem = (relative as NSString).deletingPathExtension
        let exactMatches = candidates.filter {
            let candidateRelative = Self.relativePath($0.path, under: Self.comparisonRootPath(
                URL(fileURLWithPath: jpegRootPath, isDirectory: true)))
            return candidateRelative.map {
                FileSystemKey(($0 as NSString).deletingPathExtension) == FileSystemKey(pdfStem)
            } ?? false
        }
        if exactMatches.count == 1, let exact = exactMatches.first {
            return .match(Self.exactFileURL(exact.path))
        }
        if exactMatches.count > 1 {
            return .ambiguous(exactMatches.map { Self.exactFileURL($0.path) })
        }

        let stem = (pdfStem as NSString).lastPathComponent
        let matches = candidates.filter { FileSystemKey($0.stem) == FileSystemKey(stem) }
        guard !matches.isEmpty else { return .none }

        if let collectionContext {
            let scoped = matches.filter {
                FileSystemKey($0.collectionContext) == FileSystemKey(collectionContext)
            }
            if scoped.count == 1, let candidate = scoped.first {
                return .match(Self.exactFileURL(candidate.path))
            }
            if scoped.count > 1 {
                return .ambiguous(scoped.map { Self.exactFileURL($0.path) })
            }
        }

        if matches.count == 1, let candidate = matches.first {
            return .match(Self.exactFileURL(candidate.path))
        }
        return .ambiguous(matches.map { Self.exactFileURL($0.path) })
    }

    public static func isSupportedImageExtension(_ pathExtension: String) -> Bool {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg", "heic": true
        default: false
        }
    }

    private static func filesystemPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { raw in raw.map(String.init(cString:)) ?? url.path }
    }

    private static func exactFileURL(_ path: String) -> URL {
        path.withCString {
            URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
        }
    }

    private static func comparisonRootPath(_ url: URL) -> String {
        CorpusWalker.discoveredPathPrefix(for: url) ?? filesystemPath(url)
    }

    /// Canonicalize the existing file's parent the same way a discovered path is spelled, without
    /// resolving or persisting a new security-scoped URL for that file.
    private static func comparisonFilePath(_ url: URL) -> String {
        let spelled = filesystemPath(url)
        let parent = url.deletingLastPathComponent()
        guard let canonicalParent = CorpusWalker.discoveredPathPrefix(for: parent) else { return spelled }
        let leaf = (spelled as NSString).lastPathComponent
        return canonicalParent + (canonicalParent == "/" ? "" : "/") + leaf
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        let pathBytes = Array(path.utf8)
        var rootBytes = Array(root.utf8)
        while rootBytes.count > 1, rootBytes.last == UInt8(ascii: "/") { rootBytes.removeLast() }
        guard pathBytes.starts(with: rootBytes), pathBytes.count > rootBytes.count,
              pathBytes[rootBytes.count] == UInt8(ascii: "/") else { return nil }
        return String(decoding: pathBytes.dropFirst(rootBytes.count + 1), as: UTF8.self)
    }
}
