import ArchiveCore
import CoreGraphics
import Foundation

/// Step 1 of adoption: a read-only walk of a source tree that proposes every fact with its rule and evidence and
/// routes anything uncertain to review (W49.corpus-adoption-tool). It opens files only for reading, never asks a
/// cloud provider to download one, and writes nothing in the source.
enum AdoptionInventory {
    /// The pre-app archive's own folder names. Adoption is where these names mean anything now; the apps' general
    /// paths take an original's location from an explicit association instead.
    static let legacyMainName = "Archival Photos"
    static let legacyOriginalsName = "Archival Photos JPEGS"

    /// The real corpus. Adoption runs on a scratch copy until the owner approves a real run (a separate item).
    static var protectedRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let drive = home.appendingPathComponent("Desktop/Google Drive", isDirectory: true)
        return [drive.appendingPathComponent(legacyMainName, isDirectory: true),
                drive.appendingPathComponent(legacyOriginalsName, isDirectory: true)]
    }

    /// Refuses `url` inside, at or above a protected root. Paths are compared without case, and the folders that
    /// exist are compared by device and inode too, so another spelling (a firmlink, a symlink, other case) of the
    /// same folder is caught.
    static func refuseProtected(_ url: URL, protected: [URL] = protectedRoots) throws {
        let target = canonicalPath(url)
        let path = target.pathComponents.map { $0.lowercased() }
        for root in protected {
            let resolved = canonicalPath(root)
            let base = resolved.pathComponents.map { $0.lowercased() }
            let inside = identity(of: resolved).map { ancestry(of: target).contains($0) } ?? false
            let above = identity(of: target).map { ancestry(of: resolved).contains($0) } ?? false
            if path.starts(with: base) || base.starts(with: path) || inside || above {
                throw AdoptionError.protectedCorpus(root.path)
            }
        }
    }

    private static func identity(of url: URL) -> [UInt64]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    /// The identities of `url` and every ancestor that exists.
    private static func ancestry(of url: URL) -> [[UInt64]] {
        var result: [[UInt64]] = []
        var current = url.standardizedFileURL
        while true {
            if let id = identity(of: current) { result.append(id) }
            guard current.pathComponents.count > 1 else { return result }
            current = current.deletingLastPathComponent()
        }
    }

    /// The originals tree beside a source named like the pre-app archive, when it exists.
    static func legacyOriginals(beside source: URL) -> URL? {
        guard source.standardizedFileURL.lastPathComponent == legacyMainName else { return nil }
        let candidate = source.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(legacyOriginalsName, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? candidate : nil
    }

    static func run(source: URL, originals: URL?, colours: AdoptionManifest.ColourPreset,
                    protected: [URL] = protectedRoots, now: Date = Date()) throws -> AdoptionManifest {
        guard let root = canonicalDirectory(source) else { throw AdoptionError.sourceMissing(source.path) }
        try refuseProtected(root, protected: protected)
        let originals = try originals.map { tree in
            guard let url = canonicalDirectory(tree) else { throw AdoptionError.sourceMissing(tree.path) }
            try refuseProtected(url, protected: protected)
            return url
        }

        let walk = CorpusWalker.scan(root: root, predicate: { _ in true })
        let unreadable = walk.directoryErrors.map { relative($0.url, in: root) ?? $0.url.path }
        let pdfs = walk.entries.filter { isPDF($0.url) && !PreservationCopy.isPayloadPath(relative($0.url, in: root) ?? "") }

        // An originals walk that was not clean resolves every PDF to `unknown`, never to a guess.
        let index = originals.map { JPEGPartnerIndex(jpegRoot: $0, scan: CorpusWalker.scanFingerprints(root: $0)) }

        var entries: [AdoptionManifest.Entry] = []
        for file in pdfs {
            guard let path = relative(file.url, in: root) else { continue }
            entries.append(entry(for: file, path: path, root: root, originals: originals, index: index, colours: colours))
        }
        for failure in walk.unreadable where isPDF(failure.url) {
            guard let path = relative(failure.url, in: root) else { continue }
            entries.append(.init(path: path, byteCount: size(of: failure.url), pageCount: nil, tags: [], labelNumber: nil,
                                 proposal: .init(), original: .init(state: originals == nil ? .notConfigured : .unknown),
                                 review: [.tagsUnreadable], decision: .review, keepOriginal: false))
        }
        markSharedOriginals(&entries)
        entries.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        let complete = walk.directoryErrors.isEmpty && walk.unreadable.isEmpty && unreadable.isEmpty
        return AdoptionManifest(createdAt: now, sourceRoot: root.path, originalsRoot: originals?.path,
                                colours: colours, complete: complete, unreadable: unreadable.sorted(), entries: entries)
    }

    private static func entry(for file: CorpusEntry, path: String, root: URL, originals: URL?, index: JPEGPartnerIndex?,
                              colours: AdoptionManifest.ColourPreset) -> AdoptionManifest.Entry {
        var review: [AdoptionManifest.Reason] = []
        var pageCount: Int?
        if file.isDataless {
            review.append(.pdfOffline)
        } else {
            switch inspect(file.url) {
            case .pages(let count): pageCount = count
            case .catalogued(let count): pageCount = count; review.append(.alreadyCatalogued)
            case .ineligible(let count): pageCount = count; review.append(.pdfIneligible)
            case .unreadable: review.append(.pdfUnreadable)
            }
        }

        let tags = DocumentTags.parse(raw: file.tagNames, labelNumber: file.labelNumber, colours: colours.colours)
        let proposal = proposal(from: tags, colours: colours, review: &review)

        var original = AdoptionManifest.Original(state: .notConfigured)
        if let index, let originals {
            original = match(file.url, path: path, root: root, originals: originals, index: index)
            switch original.state {
            case .missing: review.append(.originalMissing)
            case .ambiguous: review.append(.originalAmbiguous)
            case .unknown: review.append(.originalUnknown)
            case .matched where pageCount.map({ $0 != 1 }) ?? false: review.append(.originalMultipage)
            default: break
            }
            if let path = original.path,
               index.candidate(atPath: originals.appendingPathComponent(path).path)?.fingerprint.isDataless == true {
                review.append(.originalOffline)
            }
        }
        return .init(path: path, byteCount: file.fingerprint?.size ?? size(of: file.url), pageCount: pageCount,
                     tags: file.tagNames, labelNumber: file.labelNumber, proposal: proposal, original: original,
                     review: review, decision: review.isEmpty ? .accept : .review,
                     keepOriginal: original.state == .matched && !review.contains(.originalOffline)
                        && !review.contains(.originalMultipage))
    }

    /// The facets the old archive carried, read by the suite's own tag grammar. Raw tokens stay in the entry.
    static func proposal(from tags: DocumentTags, colours: AdoptionManifest.ColourPreset,
                         review: inout [AdoptionManifest.Reason]) -> AdoptionManifest.Proposal {
        var proposal = AdoptionManifest.Proposal()
        let label = tags.finderLabel
        let fromColour = colours.colours.type(forLabel: tags.labelNumber)
        if let token = tags.itemTypeToken, let type = ItemType(token: token) {
            proposal.itemType = .init(value: type.rawValue.lowercased(), rule: "tag", evidence: token)
            // Another type tag the parser set aside (`Box` beside `Folder`) disagrees just as a colour can.
            let demoted = tags.subjects.contains { ItemType(token: $0) != nil }
            if demoted || (fromColour.map { $0 != type } ?? false) { review.append(.typeConflict) }
        } else if let fromColour, let label {
            proposal.itemType = .init(value: fromColour.rawValue.lowercased(), rule: "colour:" + colours.rawValue,
                                      evidence: "Finder colour \(label.tokenName)")
        }
        if let label {
            proposal.colour = .init(value: label.tokenName.lowercased(), rule: "finder-label",
                                    evidence: "label \(label.rawValue)")
        }

        // A Year supersedes a Decade (SPEC/tag-format.md); a Month needs its Year and a Day its Month.
        let full = tags.year.flatMap { ArchiveDate(year: $0, month: tags.month?.number, day: tags.day) }
        let date = full ?? (tags.year == nil ? tags.decade.flatMap(ArchiveDate.init(decade:)) : nil)
        if let date {
            var tokens = [tags.yearToken, tags.monthToken, tags.dayToken].compactMap { $0 }
            if tags.year == nil, let decade = tags.decadeToken { tokens.append(decade) }
            if tags.year != nil, let decade = tags.decadeToken { tokens.append("\(decade) superseded") }
            proposal.documentDate = .init(value: date.wireValue, uncertain: tags.dateUncertain,
                                          checked: tags.checkedFields.contains(.date), rule: "date-tags",
                                          evidence: tokens.joined(separator: ", "))
        }
        let partial = (tags.monthToken != nil && tags.year == nil)
            || (tags.dayToken != nil && (tags.month == nil || tags.year == nil))
            || (tags.year != nil && full == nil)
            || (tags.dateUncertain && date == nil)
        if partial { review.append(.dateIncomplete) }
        if let sent = tags.sentWith {
            proposal.sentWith = .init(value: sent.wireValue, uncertain: tags.sentWithUncertain,
                                      checked: tags.checkedFields.contains(.sentWith), rule: "sent-with-tag",
                                      evidence: tags.sentWithToken ?? "")
        }
        if tags.dateIsAmbiguous { review.append(.dateAmbiguous) }
        if tags.subjects.contains(where: { DocumentTags.parseQuality($0) != nil }) { review.append(.qualityConflict) }
        proposal.subjects = tags.subjects
        if let state = tags.readState {
            proposal.readState = .init(value: state.rawValue.lowercased(), rule: "tag", evidence: state.rawValue)
        }
        if let quality = tags.quality {
            proposal.quality = .init(value: quality, rule: "tag", evidence: tags.qualityToken ?? "Q\(quality)")
        }
        proposal.ocrPoor = tags.hasPoorOCR
        return proposal
    }

    private static func match(_ pdf: URL, path: String, root: URL, originals: URL,
                              index: JPEGPartnerIndex) -> AdoptionManifest.Original {
        switch index.resolve(pdfURL: pdf, mainRoot: root) {
        case .match(let url):
            let found = relative(url, in: originals) ?? url.path
            let mirrored = (path as NSString).deletingPathExtension
            let rule = JPEGPartnerIndex.pairingKey((found as NSString).deletingPathExtension)
                == JPEGPartnerIndex.pairingKey(mirrored) ? "mirrored" : "stem"
            return .init(state: .matched, path: found, rule: rule)
        case .ambiguous(let urls):
            return .init(state: .ambiguous, candidates: urls.map { relative($0, in: originals) ?? $0.path }.sorted())
        case .none: return .init(state: .missing)
        case .unknown: return .init(state: .unknown)
        }
    }

    /// One original claimed by several PDFs is a duplicate to review: preserving it twice would hide which is right.
    private static func markSharedOriginals(_ entries: inout [AdoptionManifest.Entry]) {
        var claims: [String: Int] = [:]
        for entry in entries { if let path = entry.original.path { claims[path, default: 0] += 1 } }
        for index in entries.indices {
            guard let path = entries[index].original.path, claims[path, default: 0] > 1 else { continue }
            entries[index].review.append(.originalShared)
            entries[index].decision = .review
            // Preserving one image under two files would hide which is right; the reviewer keeps it where it belongs.
            entries[index].keepOriginal = false
        }
    }

    private enum Inspection { case pages(Int), catalogued(Int), ineligible(Int), unreadable }

    private static func inspect(_ url: URL) -> Inspection {
        CorpusWalker.withDatalessMaterializationDisabled {
            // An encrypted PDF cannot take a catalogue identity without changing its protection, so it waits too.
            guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted,
                  document.numberOfPages > 0 else { return .unreadable }
            if CataloguePDFIdentity.identity(in: document) != nil { return .catalogued(document.numberOfPages) }
            // The same check the identity copy makes, so a PDF it would refuse waits for review instead of failing.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  case .success = ReOCRIncrementalWriter.eligibility(of: data) else { return .ineligible(document.numberOfPages) }
            return .pages(document.numberOfPages)
        }
    }

    /// The directory's real path (`/private/var/…`, not `/var/…`), the spelling the walker reports its files in.
    static func canonicalDirectory(_ url: URL) -> URL? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        var isDirectory: ObjCBool = false
        let path = String(cString: resolved)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `canonicalDirectory` for a folder that may not exist yet: its nearest existing ancestor, resolved, plus the rest.
    static func canonicalPath(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while canonicalDirectory(existing) == nil, existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = canonicalDirectory(existing) ?? existing
        for name in rest { result.appendPathComponent(name, isDirectory: true) }
        return result
    }

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    static func relative(_ url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard path.count > base.count, path.starts(with: base) else { return nil }
        return path.dropFirst(base.count).joined(separator: "/")
    }

    private static func size(of url: URL) -> Int64 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int64(info.st_size) : 0
    }
}
