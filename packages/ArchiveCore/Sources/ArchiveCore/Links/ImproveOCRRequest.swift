// ImproveOCRRequest.swift — the Reader → Processor "Improve OCR" hand-off values (ArchiveCore)
// Design: execution-plans/reocr/00-plan.md §3. Values and validation only: the request store (its private
// directory, file ownership, symlink refusal, replay record) belongs to each app's audited adapter.
// An incoming request only opens the review dialog; it never authorizes OCR spending, a flag change
// or a replacement.

import Foundation

/// A hand-off asking Archive Processor to open its Improve OCR dialog on some files.
///
/// - `inline`: up to `maxInlineFiles` files, carried in the URL.
///   URL: `archiveprocessor://improve-ocr?request=<UUID>&root=<root UUID>&rel=<path>&rel=<path>…`
/// - `manifest`: a larger selection, staged as `<shared support>/Requests/<UUID>.json`.
///   URL: `archiveprocessor://improve-ocr?request=<UUID>`
///   The URL names only the UUID; the store resolves it under its own directory, never a URL-supplied path.
public enum ImproveOCRRequest: Equatable, Sendable {
    case inline(requestID: UUID, rootGUID: UUID, relativePaths: [String])
    case manifest(requestID: UUID)

    public static let scheme = "archiveprocessor"
    public static let host = "improve-ocr"
    /// Our protocol bounds for the inline form, not a claimed OS limit. Larger selections use a manifest.
    public static let maxInlineFiles = 8
    public static let maxInlineURLBytes = 8 * 1024

    public enum ParseError: Error, Equatable, Sendable {
        case notImproveOCR
        case unexpectedURLPart(String)
        case unknownParameter(String)
        case repeatedParameter(String)
        case missingRequestID
        case invalidUUID(String)
        case rootWithoutFiles
        case filesWithoutRoot
        case tooManyFiles(Int)
        case tooLong(Int)
        case invalidPath(String, ImproveOCRPathError)
        case duplicateTarget(String)
    }

    public var requestID: UUID {
        switch self {
        case .inline(let id, _, _), .manifest(let id): return id
        }
    }

    // MARK: - Format to URL

    /// Builds the URL, or throws when the values would not parse back (a bad path, too many files, too long):
    /// the sender then stages a manifest instead.
    public func url() throws -> URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items = [URLQueryItem(name: "request", value: requestID.uuidString.lowercased())]
        if case .inline(_, let rootGUID, let paths) = self {
            try Self.validateInline(paths)
            items.append(URLQueryItem(name: "root", value: rootGUID.uuidString.lowercased()))
            items += paths.map { URLQueryItem(name: "rel", value: $0) }
        }
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value.map(Self.encodeQueryValue))
        }
        guard let url = components.url else { throw ParseError.notImproveOCR }
        let length = url.absoluteString.utf8.count
        guard length <= Self.maxInlineURLBytes else { throw ParseError.tooLong(length) }
        return url
    }

    // MARK: - Parse from URL

    public init(url: URL) throws {
        let length = url.absoluteString.utf8.count
        guard length <= Self.maxInlineURLBytes else { throw ParseError.tooLong(length) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.host?.lowercased() == Self.host
        else { throw ParseError.notImproveOCR }
        if components.user != nil || components.password != nil { throw ParseError.unexpectedURLPart("user") }
        if components.port != nil { throw ParseError.unexpectedURLPart("port") }
        if !components.path.isEmpty && components.path != "/" { throw ParseError.unexpectedURLPart("path") }
        if components.fragment != nil { throw ParseError.unexpectedURLPart("fragment") }

        var requestValue: String?
        var rootValue: String?
        var paths: [String] = []
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name {
            case "request":
                guard requestValue == nil else { throw ParseError.repeatedParameter("request") }
                requestValue = value
            case "root":
                guard rootValue == nil else { throw ParseError.repeatedParameter("root") }
                rootValue = value
            case "rel":
                paths.append(value)
            default:
                throw ParseError.unknownParameter(item.name)
            }
        }
        guard let requestValue else { throw ParseError.missingRequestID }
        guard let requestID = UUID(uuidString: requestValue) else { throw ParseError.invalidUUID(requestValue) }

        switch (rootValue, paths.isEmpty) {
        case (nil, true):
            self = .manifest(requestID: requestID)
        case (nil, false):
            throw ParseError.filesWithoutRoot
        case (.some, true):
            throw ParseError.rootWithoutFiles
        case (.some(let rootValue), false):
            guard let rootGUID = UUID(uuidString: rootValue) else { throw ParseError.invalidUUID(rootValue) }
            try Self.validateInline(paths)
            self = .inline(requestID: requestID, rootGUID: rootGUID, relativePaths: paths)
        }
    }

    // MARK: - Helpers

    private static func validateInline(_ paths: [String]) throws {
        guard !paths.isEmpty else { throw ParseError.rootWithoutFiles }
        guard paths.count <= maxInlineFiles else { throw ParseError.tooManyFiles(paths.count) }
        var seen = Set<String>()
        for path in paths {
            if let problem = ImproveOCRPath.problem(path) { throw ParseError.invalidPath(path, problem) }
            guard seen.insert(ImproveOCRPath.targetKey(path)).inserted else { throw ParseError.duplicateTarget(path) }
        }
    }

    /// Percent-encodes everything outside the unreserved set, so `&`, `=`, `+`, `#` and `%` in a filename
    /// survive the round trip (URLComponents' own query encoding leaves `&` and `+` alone).
    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Why a hand-off path is refused.
public enum ImproveOCRPathError: Error, Equatable, Sendable {
    case empty
    case absolute
    case emptyComponent
    case dotComponent
    case controlCharacter
    case notPDF
}

/// Lexical rules for a hand-off's relative path. Containment, symlinks, the root marker and the file's
/// identity are checked again by the receiving app against its own grant, at open and at commit.
public enum ImproveOCRPath {
    public static func problem(_ path: String) -> ImproveOCRPathError? {
        if path.isEmpty { return .empty }
        if path.hasPrefix("/") { return .absolute }
        // Controls, and invisible format and separator characters (bidi overrides, U+2028/2029) that would let a
        // name read as another in the dialog.
        if path.unicodeScalars.contains(where: {
            [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }) {
            return .controlCharacter
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty { return .emptyComponent }
            if component == "." || component == ".." { return .dotComponent }
        }
        guard let last = components.last, last.lowercased().hasSuffix(".pdf"), last.count > 4 else { return .notPDF }
        return nil
    }

    /// Two spellings of one file on a case-insensitive, normalization-insensitive volume (APFS default)
    /// share this key, so a request cannot name the same file twice. Full case folding (ς and σ, ß and ss),
    /// not `lowercased()`. On a case-sensitive volume this refuses two names that are two files; the person
    /// then sends them in two requests.
    public static func targetKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}

/// The staged form of a large hand-off: `<shared support>/Requests/<request UUID>.json`.
/// It carries no keys and no OCR text.
public struct ImproveOCRManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to the root, under the rules of `ImproveOCRPath`.
        public var relativePath: String
        /// The image/text pairs to re-read, 0-based; nil means every pair.
        public var pairIndices: [Int]?
        /// The file the sender saw: its file number (inode) and size, and the SHA-256 of its bytes as
        /// 64 lowercase hex digits. The receiver refuses a file that no longer matches.
        public var fileNumber: UInt64
        public var byteCount: Int64
        public var sha256: String

        public init(relativePath: String, pairIndices: [Int]? = nil, fileNumber: UInt64, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath
            self.pairIndices = pairIndices
            self.fileNumber = fileNumber
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public var requestID: UUID
    public var createdAt: Date
    public var rootGUID: UUID
    /// Only a way to locate the folder; never an access grant and never trusted over the root marker.
    public var rootPathHint: String?
    public var entries: [Entry]

    public static let maxBytes = 1024 * 1024
    public static let maxEntries = 1000
    /// An unconsumed request older than this asks the person to select the files again.
    public static let lifetime: TimeInterval = 24 * 60 * 60
    /// Clock skew tolerated for a creation time in the future.
    public static let futureSkew: TimeInterval = 5 * 60

    public enum ValidationError: Error, Equatable, Sendable {
        case tooLarge(Int)
        case malformed
        case requestIDMismatch
        case noEntries
        case tooManyEntries(Int)
        case invalidPath(String, ImproveOCRPathError)
        case duplicateTarget(String)
        case invalidPairs(String)
        case invalidDigest(String)
        case invalidSize(String)
        case expired
        case fromTheFuture
    }

    /// `createdAt` is kept to the whole second, as the ISO 8601 form stores it, so a manifest equals itself
    /// after a round trip.
    public init(requestID: UUID, createdAt: Date, rootGUID: UUID, rootPathHint: String?, entries: [Entry]) {
        self.requestID = requestID
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.rootGUID = rootGUID
        self.rootPathHint = rootPathHint
        self.entries = entries
    }

    /// Decodes and validates a staged manifest for the request the URL named. `now` is the receiver's clock.
    public static func decode(_ data: Data, expecting requestID: UUID, now: Date) throws -> ImproveOCRManifest {
        guard data.count <= maxBytes else { throw ValidationError.tooLarge(data.count) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ImproveOCRManifest.self, from: data) else {
            throw ValidationError.malformed
        }
        guard manifest.requestID == requestID else { throw ValidationError.requestIDMismatch }
        try manifest.validate(now: now)
        return manifest
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func validate(now: Date) throws {
        guard !entries.isEmpty else { throw ValidationError.noEntries }
        guard entries.count <= Self.maxEntries else { throw ValidationError.tooManyEntries(entries.count) }
        if now.timeIntervalSince(createdAt) > Self.lifetime { throw ValidationError.expired }
        if createdAt.timeIntervalSince(now) > Self.futureSkew { throw ValidationError.fromTheFuture }
        var seen = Set<String>()
        for entry in entries {
            let path = entry.relativePath
            if let problem = ImproveOCRPath.problem(path) { throw ValidationError.invalidPath(path, problem) }
            guard seen.insert(ImproveOCRPath.targetKey(path)).inserted else { throw ValidationError.duplicateTarget(path) }
            if let pairs = entry.pairIndices {
                guard !pairs.isEmpty, pairs.allSatisfy({ $0 >= 0 }), Set(pairs).count == pairs.count else {
                    throw ValidationError.invalidPairs(path)
                }
            }
            guard entry.byteCount > 0 else { throw ValidationError.invalidSize(path) }
            guard entry.sha256.count == 64,
                  entry.sha256.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
            else { throw ValidationError.invalidDigest(path) }
        }
    }
}
