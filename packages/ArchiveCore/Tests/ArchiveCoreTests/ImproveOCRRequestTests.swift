// ImproveOCRRequestTests.swift — the Improve OCR hand-off URL and manifest (W44.reocr-processor)
import Testing
import Foundation
@testable import ArchiveCore

@Suite("ImproveOCRRequest")
struct ImproveOCRRequestTests {
    let request = UUID(uuidString: "0b7f3a9c-4b5e-4a8c-9d3f-1e2a6b7c8d9e")!
    let root = UUID(uuidString: "7f3a9c21-4b5e-4a8c-9d3f-1e2a6b7c8d9e")!

    private func parse(_ string: String) throws -> ImproveOCRRequest {
        try ImproveOCRRequest(url: URL(string: string)!)
    }

    private func parseError(_ string: String) -> ImproveOCRRequest.ParseError? {
        do { _ = try parse(string); return nil } catch let error as ImproveOCRRequest.ParseError { return error } catch { return nil }
    }

    // MARK: - Round trips

    @Test func inlineRoundTripKeepsAwkwardFilenames() throws {
        let paths = ["Box 3/Folder 2/letter & reply = 1+1 #2 100%.pdf", "Ünïcødé/ça.PDF", "a/b.pdf"]
        let link = ImproveOCRRequest.inline(requestID: request, rootGUID: root, relativePaths: paths)
        let url = try link.url()
        #expect(url.scheme == "archiveprocessor")
        #expect(url.host == "improve-ocr")
        #expect(try ImproveOCRRequest(url: url) == link)
    }

    @Test func manifestRoundTrip() throws {
        let link = ImproveOCRRequest.manifest(requestID: request)
        let url = try link.url()
        #expect(url.absoluteString == "archiveprocessor://improve-ocr?request=0b7f3a9c-4b5e-4a8c-9d3f-1e2a6b7c8d9e")
        #expect(try ImproveOCRRequest(url: url) == link)
    }

    @Test func schemeAndHostAreCaseInsensitive() throws {
        let parsed = try parse("ArchiveProcessor://Improve-OCR?request=\(request.uuidString)")
        #expect(parsed == .manifest(requestID: request))
    }

    // MARK: - Bounds

    @Test func inlineRefusesMoreThanEightFiles() {
        let paths = (1...9).map { "f\($0).pdf" }
        #expect(throws: ImproveOCRRequest.ParseError.tooManyFiles(9)) {
            try ImproveOCRRequest.inline(requestID: request, rootGUID: root, relativePaths: paths).url()
        }
        let query = paths.map { "rel=\($0)" }.joined(separator: "&")
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&root=\(root)&\(query)") == .tooManyFiles(9))
    }

    @Test func inlineRefusesAURLOverEightKiB() {
        let long = String(repeating: "a", count: 2100) + ".pdf"
        let paths = (1...4).map { "\($0)/\(long)" }
        #expect(throws: (any Error).self) {
            try ImproveOCRRequest.inline(requestID: request, rootGUID: root, relativePaths: paths).url()
        }
        let query = paths.map { "rel=\($0)" }.joined(separator: "&")
        if case .tooLong = parseError("archiveprocessor://improve-ocr?request=\(request)&root=\(root)&\(query)") {} else {
            Issue.record("an over-long URL must be refused as too long")
        }
    }

    // MARK: - Malformed requests

    @Test func refusesOtherSchemesHostsAndURLParts() {
        #expect(parseError("archivereader://improve-ocr?request=\(request)") == .notImproveOCR)
        #expect(parseError("archiveprocessor://improve?request=\(request)") == .notImproveOCR)
        #expect(parseError("archiveprocessor://improve-ocr/x?request=\(request)") == .unexpectedURLPart("path"))
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)#frag") == .unexpectedURLPart("fragment"))
        #expect(parseError("archiveprocessor://u@improve-ocr?request=\(request)") == .unexpectedURLPart("user"))
        #expect(parseError("archiveprocessor://improve-ocr:80?request=\(request)") == .unexpectedURLPart("port"))
    }

    @Test func refusesUnknownRepeatedAndMissingParameters() {
        #expect(parseError("archiveprocessor://improve-ocr") == .missingRequestID)
        #expect(parseError("archiveprocessor://improve-ocr?request=nope") == .invalidUUID("nope"))
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&manifest=/tmp/x.json")
                == .unknownParameter("manifest"))
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&request=\(request)")
                == .repeatedParameter("request"))
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&root=\(root)&root=\(root)&rel=a.pdf")
                == .repeatedParameter("root"))
    }

    @Test func refusesHalfAnInlineForm() {
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&rel=a.pdf") == .filesWithoutRoot)
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&root=\(root)") == .rootWithoutFiles)
        #expect(parseError("archiveprocessor://improve-ocr?request=\(request)&root=bad&rel=a.pdf") == .invalidUUID("bad"))
    }

    @Test func refusesDuplicateTargetsIncludingCaseAndNormalizationVariants() {
        let base = "archiveprocessor://improve-ocr?request=\(request)&root=\(root)"
        #expect(parseError("\(base)&rel=a/b.pdf&rel=a/b.pdf") == .duplicateTarget("a/b.pdf"))
        #expect(parseError("\(base)&rel=a/b.pdf&rel=A/B.PDF") == .duplicateTarget("A/B.PDF"))
        // "é" precomposed and decomposed name one file on APFS.
        let decomposed = "e\u{301}.pdf".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(parseError("\(base)&rel=%C3%A9.pdf&rel=\(decomposed)") == .duplicateTarget("e\u{301}.pdf"))
    }

    // MARK: - Paths

    @Test func pathRules() {
        #expect(ImproveOCRPath.problem("Box 1/letter.pdf") == nil)
        #expect(ImproveOCRPath.problem("") == .empty)
        #expect(ImproveOCRPath.problem("/Users/x/a.pdf") == .absolute)
        #expect(ImproveOCRPath.problem("~/a.pdf") == .absolute)
        #expect(ImproveOCRPath.problem("../a.pdf") == .dotComponent)
        #expect(ImproveOCRPath.problem("a/../../b.pdf") == .dotComponent)
        #expect(ImproveOCRPath.problem("./a.pdf") == .dotComponent)
        #expect(ImproveOCRPath.problem("a//b.pdf") == .emptyComponent)
        #expect(ImproveOCRPath.problem("a/") == .emptyComponent)
        #expect(ImproveOCRPath.problem("a\u{0}.pdf") == .controlCharacter)
        #expect(ImproveOCRPath.problem("a\nb.pdf") == .controlCharacter)
        #expect(ImproveOCRPath.problem("a.jpg") == .notPDF)
        #expect(ImproveOCRPath.problem("dir/.pdf") == .notPDF)
    }

    @Test func parentTraversalInTheURLIsRefused() {
        let base = "archiveprocessor://improve-ocr?request=\(request)&root=\(root)"
        #expect(parseError("\(base)&rel=..%2Fsecret.pdf") == .invalidPath("../secret.pdf", .dotComponent))
        #expect(parseError("\(base)&rel=%2Fetc%2Fa.pdf") == .invalidPath("/etc/a.pdf", .absolute))
    }

    // MARK: - Manifest

    private func entry(_ path: String, pairs: [Int]? = nil) -> ImproveOCRManifest.Entry {
        .init(relativePath: path, pairIndices: pairs, fileNumber: 42, byteCount: 1000,
              sha256: String(repeating: "ab", count: 32))
    }

    private func manifest(_ entries: [ImproveOCRManifest.Entry], created: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ImproveOCRManifest {
        ImproveOCRManifest(requestID: request, createdAt: created, rootGUID: root, rootPathHint: "/Volumes/Archive", entries: entries)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000 + 60)

    @Test func manifestRoundTripsThroughJSON() throws {
        let original = manifest([entry("a.pdf"), entry("b/c.pdf", pairs: [0, 2])])
        let decoded = try ImproveOCRManifest.decode(original.encoded(), expecting: request, now: now)
        #expect(decoded == original)
    }

    @Test func manifestRefusals() throws {
        func error(_ m: ImproveOCRManifest, expecting id: UUID? = nil, at time: Date? = nil) -> ImproveOCRManifest.ValidationError? {
            do { _ = try ImproveOCRManifest.decode(m.encoded(), expecting: id ?? request, now: time ?? now); return nil }
            catch let e as ImproveOCRManifest.ValidationError { return e } catch { return nil }
        }
        #expect(error(manifest([entry("a.pdf")]), expecting: root) == .requestIDMismatch)
        #expect(error(manifest([])) == .noEntries)
        #expect(error(manifest((0...1000).map { entry("f\($0).pdf") })) == .tooManyEntries(1001))
        #expect(error(manifest([entry("a.pdf"), entry("A.pdf")])) == .duplicateTarget("A.pdf"))
        #expect(error(manifest([entry("../a.pdf")])) == .invalidPath("../a.pdf", .dotComponent))
        #expect(error(manifest([entry("a.pdf", pairs: [])])) == .invalidPairs("a.pdf"))
        #expect(error(manifest([entry("a.pdf", pairs: [1, 1])])) == .invalidPairs("a.pdf"))
        #expect(error(manifest([entry("a.pdf", pairs: [-1])])) == .invalidPairs("a.pdf"))
        var badDigest = entry("a.pdf"); badDigest.sha256 = String(repeating: "AB", count: 32)
        #expect(error(manifest([badDigest])) == .invalidDigest("a.pdf"))
        var badSize = entry("a.pdf"); badSize.byteCount = 0
        #expect(error(manifest([badSize])) == .invalidSize("a.pdf"))
        #expect(error(manifest([entry("a.pdf")]), at: now.addingTimeInterval(24 * 3600)) == .expired)
        #expect(error(manifest([entry("a.pdf")]), at: now.addingTimeInterval(-3600)) == .fromTheFuture)
    }

    @Test func manifestRefusesMalformedAndOversizeData() {
        #expect(throws: ImproveOCRManifest.ValidationError.malformed) {
            try ImproveOCRManifest.decode(Data("{\"requestID\":1}".utf8), expecting: request, now: now)
        }
        #expect(throws: ImproveOCRManifest.ValidationError.tooLarge(ImproveOCRManifest.maxBytes + 1)) {
            try ImproveOCRManifest.decode(Data(count: ImproveOCRManifest.maxBytes + 1), expecting: request, now: now)
        }
    }
}
