import Foundation
import ArchiveCore

/// Headless, key-free ($0) byte-identity regression for `SegmentJSONBuilder`, gated by
/// `SEGMENT_JSON_TEST=1`. Proves the shared builder reproduces — byte-for-byte — the two ORIGINAL
/// inline implementations it replaced: `OCRProcessor.writeSegmentJSON` (Process Files) and
/// `LiveCaptureProcessor.writeSegmentJSON` (Live Capture). It touches no files, no network, and no
/// archive corpus: it only compares serialized JSON `Data` in memory.
///
/// Method: two `ref*` functions below are verbatim copies of each original's dict-building logic
/// (disk write stripped, returning `Data`). For an input matrix we assert
///   builder(formatOverride: labelFormatOverride(isBox,isFolder)) == refOCRProcessor(isBox,isFolder)
///   builder(formatOverride: nil)                                 == refLive        (document rows)
/// plus a sanity check that the two originals agreed for documents (the premise of the de-dup).
@MainActor
enum SegmentJSONBuilderTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["SEGMENT_JSON_TEST"] == "1" else { return }
        didRun = true
        Task { run() }
    }

    // ── Verbatim reference: the ORIGINAL OCRProcessor.writeSegmentJSON dict-building (OCRProcessor+
    //    Tagging.swift), with the sidecar-URL computation and `try? data.write(...)` removed. ────────
    private static func refOCRProcessor(fileURLs: [URL], texts: [String],
                                        tags: GeneratedTags, isBox: Bool, isFolder: Bool) -> Data? {
        var bodyParts: [String] = []
        for (i, url) in fileURLs.enumerated() {
            let text = i < texts.count ? texts[i] : ""
            bodyParts.append("[Image: \(url.lastPathComponent)]")
            if !text.isEmpty {
                bodyParts.append(text)
            }
        }
        let bodyText = bodyParts.joined(separator: "\n\n")

        var dict: [String: Any] = [:]
        if let date = tags.machineDate {
            dict["date"] = date
        }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }

        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }

        if isBox { dict["format"] = "box_label" }
        if isFolder { dict["format"] = "folder_label" }

        dict["files"] = fileURLs.map { $0.lastPathComponent }
        dict["body"] = bodyText

        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    // ── Verbatim reference: the ORIGINAL LiveCaptureProcessor.writeSegmentJSON dict-building
    //    (LiveCaptureProcessor.swift), disk write removed. ────────────────────────────────────────
    private static func refLive(pageURLs: [URL], texts: [String], tags: GeneratedTags) -> Data? {
        var bodyParts: [String] = []
        for (i, u) in pageURLs.enumerated() {
            let t = i < texts.count ? texts[i] : ""
            bodyParts.append("[Image: \(u.lastPathComponent)]")
            if !t.isEmpty { bodyParts.append(t) }
        }
        var dict: [String: Any] = [:]
        if let d = tags.machineDate { dict["date"] = d }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }
        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }
        dict["files"] = pageURLs.map { $0.lastPathComponent }
        dict["body"] = bodyParts.joined(separator: "\n\n")
        return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }

    struct Case {
        let name: String
        let files: [String]
        let texts: [String]
        let tags: GeneratedTags
        let isBox: Bool
        let isFolder: Bool
    }

    static func run() {
        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        func urls(_ names: [String]) -> [URL] {
            names.map { URL(fileURLWithPath: "/scratch/\($0)") }
        }

        let cases: [Case] = [
            Case(name: "document · all fields · multi-page",
                 files: ["a.pdf", "b.pdf"], texts: ["Hello world", "Second page"],
                 tags: GeneratedTags(year: "1968", month: "03 March", day: "Day 15",
                                     dateUncertain: false, subjectTags: ["democratic party", "elections"],
                                     format: "letter", authorName: "Jane Doe", recipientName: "John Roe",
                                     authorLocation: "Washington", recipientLocation: "New York",
                                     publicationName: "The Times"),
                 isBox: false, isFolder: false),
            Case(name: "document · minimal (subjects only) · single page",
                 files: ["only.pdf"], texts: ["body"],
                 tags: GeneratedTags(subjectTags: ["taxes"]),
                 isBox: false, isFolder: false),
            Case(name: "document · date uncertain · no year (nil machineDate)",
                 files: ["u.pdf"], texts: ["text"],
                 tags: GeneratedTags(dateUncertain: true, subjectTags: ["education"]),
                 isBox: false, isFolder: false),
            Case(name: "document · year only",
                 files: ["y.pdf"], texts: [""],
                 tags: GeneratedTags(year: "1974", subjectTags: []),
                 isBox: false, isFolder: false),
            Case(name: "document · empty texts (markers only)",
                 files: ["p1.pdf", "p2.pdf"], texts: [],
                 tags: GeneratedTags(year: "1959", subjectTags: ["economics"]),
                 isBox: false, isFolder: false),
            Case(name: "document · fewer texts than files",
                 files: ["p1.pdf", "p2.pdf", "p3.pdf"], texts: ["only first"],
                 tags: GeneratedTags(year: "1960", month: "12 December", subjectTags: ["business"]),
                 isBox: false, isFolder: false),
            Case(name: "document · format present · no override",
                 files: ["f.pdf"], texts: ["t"],
                 tags: GeneratedTags(subjectTags: ["literature"], format: "memo"),
                 isBox: false, isFolder: false),
            Case(name: "document · subjects need capitalization",
                 files: ["c.pdf"], texts: ["t"],
                 tags: GeneratedTags(subjectTags: ["foreign policy", "cold war"]),
                 isBox: false, isFolder: false),
            Case(name: "document · empty fileURLs (degenerate)",
                 files: [], texts: [],
                 tags: GeneratedTags(subjectTags: ["misc"]),
                 isBox: false, isFolder: false),
            Case(name: "box label · format override wins over tags.format",
                 files: ["box.pdf"], texts: ["BOX 12 · RG 200"],
                 tags: GeneratedTags(year: "1965", subjectTags: ["records"], format: "letter"),
                 isBox: true, isFolder: false),
            Case(name: "folder label · format override wins",
                 files: ["folder.pdf"], texts: ["Correspondence 1965"],
                 tags: GeneratedTags(subjectTags: ["correspondence"], format: "report"),
                 isBox: false, isFolder: true),
            Case(name: "both box+folder · folder wins (precedence edge)",
                 files: ["both.pdf"], texts: ["ambiguous"],
                 tags: GeneratedTags(subjectTags: ["edge"], format: "draft"),
                 isBox: true, isFolder: true),
        ]

        for c in cases {
            let files = urls(c.files)
            let override = SegmentJSONBuilder.labelFormatOverride(isBox: c.isBox, isFolder: c.isFolder)
            let built = SegmentJSONBuilder.buildData(fileURLs: files, texts: c.texts,
                                                     tags: c.tags, formatOverride: override)
            let refOCR = refOCRProcessor(fileURLs: files, texts: c.texts,
                                         tags: c.tags, isBox: c.isBox, isFolder: c.isFolder)
            check("builder == original OCRProcessor sidecar — \(c.name)",
                  built != nil && built == refOCR)

            // For documents the Live path also produced JSON; assert the builder matches it too and
            // that the two originals agreed (the premise that let them be consolidated).
            if !c.isBox && !c.isFolder {
                let builtNil = SegmentJSONBuilder.buildData(fileURLs: files, texts: c.texts,
                                                            tags: c.tags, formatOverride: nil)
                let refL = refLive(pageURLs: files, texts: c.texts, tags: c.tags)
                check("builder(nil) == original Live sidecar — \(c.name)",
                      builtNil != nil && builtNil == refL)
                check("the two originals agreed for this document — \(c.name)",
                      refOCR != nil && refOCR == refL)
            }
        }

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["SEGMENT_JSON_TEST_OUT"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-segment-json-result.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
