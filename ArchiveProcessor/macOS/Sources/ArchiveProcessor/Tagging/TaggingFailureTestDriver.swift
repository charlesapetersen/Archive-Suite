#if DEBUG // a test driver, compiled out of Release
import Foundation
import AppKit
import ArchiveCore

/// Headless, key-free ($0) self-test of W49.proc-fix-s042 (suspect S-042), gated by `TAGGING_FAILURE_TEST=1`
/// (`scripts/test-tagging-failure.sh`): a tagging call that fails is reported, not counted as tagged. No real network:
/// every request goes to `NetworkSession.testTransport`, and the driver stops before any call if that seam is not
/// active. No Keychain read, no window, never the corpus: scratch images and PDFs under a temporary folder, removed.
///
/// Five documents through `performTaggingPhase` on a gateway: A answers; B gets a provider 500, C a timeout, D a reply
/// that is not JSON, and E (an input in another folder with B's file name) a 200 whose JSON is an error, not tags.
/// What has to hold:
///   1. B, C, D and E are recorded in `taggingCallFailures` (by their input, with a reason), A is not; B and E are two.
///   2. What is filed: A's output carries its subjects; B-E are still filed, with no subject from the model.
///   3. The existing retry route decides the retries: the 500 and the timeout are asked once each (`NetworkSession`
///      retries neither for a paid, non-idempotent call), not again by the tagging phase.
///   4. The status line counts 1 of 5 tagged and names them; the log section lists all four with reasons.
///   5. A second pass (the final review's Redo) whose calls answer clears the record, and the count is the old one.
@MainActor
enum TaggingFailureTestDriver {
    nonisolated static let envKey = "TAGGING_FAILURE_TEST"
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        lines.append("\(ok ? "PASS" : "FAIL"): \(name)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    /// Called from concurrent requests, so every access holds the lock.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var asked: [String: Int] = [:]
        var failing = true
    }

    nonisolated private static let markers = ["DOCA", "DOCB", "DOCC", "DOCD", "DOCE"]
    nonisolated private static let goodReply =
        #"{"year": "1918", "month": "03 March", "day": "Day 12", "date_uncertain": false, "subject_tags": ["War Department", "Military Intelligence"], "format": "memo"}"#

    private static func install(_ wire: Wire) {
        NetworkSession.testTransport = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let prompt = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
            let ok = { (content: String) throws -> (Data, URLResponse) in
                (try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            guard prompt.contains("You are a metadata tagging assistant") else { return try ok("no") }   // dating
            let marker = markers.compactMap { m in prompt.range(of: m).map { (m, $0.lowerBound) } }
                .min { $0.1 < $1.1 }?.0 ?? ""
            let failing: Bool = wire.lock.withLock {
                wire.asked[marker, default: 0] += 1
                return wire.failing
            }
            guard failing else { return try ok(goodReply) }
            switch marker {
            case "DOCB":
                return (Data(#"{"error": {"message": "upstream overloaded"}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            case "DOCC": throw URLError(.timedOut)
            case "DOCD": return try ok("I am sorry, I cannot tag this document.")
            case "DOCE": return try ok(#"{"error": {"message": "quota exceeded"}}"#)
            default: return try ok(goodReply)
            }
        }
    }

    static func run() async {
        await endToEnd()
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["TAGGING_FAILURE_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        exit(failures == 0 ? 0 : 1)
    }

    private static func endToEnd() async {
        let fm = FileManager.default
        check("seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("the injected transport is active", false, "stopping before any request")
            return
        }
        guard let route = OpenRouterRoute.catalog.first else { check("an OpenRouter route", false); return }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APTagFail-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let p = OCRProcessor()
        p.taggingMode = .automatic
        p.currentGateway = GatewayConfig(baseURL: "https://gateway.test/v1", modelID: "some-tagging-model",
                                         displayName: "Gateway")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        // E's input is in another folder under B's file name: two failures, not one.
        let sub = tmp.appendingPathComponent("sub", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let files = markers.map { $0 == "DOCE" ? sub.appendingPathComponent("DOCB.jpg") : tmp.appendingPathComponent("\($0).jpg") }
        for f in files { if let d = bitmap?.representation(using: .jpeg, properties: [:]) { try? d.write(to: f) } }
        p.jobs = markers.enumerated().map { i, m in
            var job = OCRJob(sourceURL: files[i])
            job.result = OCRResult(text: "\(m) MEMORANDUM\nTo: Files\nMarch 12, 1918", classification: .documentStart,
                                   errorMessage: nil, errorCode: nil)
            job.classification = .documentStart
            job.status = .succeeded
            return job
        }
        var outputs: [String: URL] = [:]
        var map: [URL: URL] = [:]
        for (i, m) in markers.enumerated() {
            let pdf = outDir.appendingPathComponent("\(m).pdf")
            if let result = p.jobs[i].result {
                _ = try? PDFGenerator().generate(imageURL: files[i], result: result, model: route.model, outputURL: pdf,
                                                 originalFileName: files[i].lastPathComponent)
            }
            outputs[m] = pdf
            map[files[i]] = pdf
        }
        p.outputURLMap = map
        p.rebuildSegments(files: files)
        check("five segments", p.segments.count == 5, "\(p.segments.count)")
        func tagsOf(_ m: String) -> [String] {
            guard let u = outputs[m], case .success(let names, _) = TagReading.read(u) else { return [] }
            return names
        }

        await p.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: outDir,
                                    enableSegmentJSON: false)
        let named = p.taggingFailureNames.map(\.name)
        check("1 B, C, D and E are recorded as failed calls, A is not; B and E (one name, two folders) are two",
              named.sorted() == ["DOCB.jpg", "DOCB.jpg", "DOCC.jpg", "DOCD.jpg"], "\(p.taggingFailureNames)")
        check("1 each failure has a reason", p.taggingCallFailures.allSatisfy { !$0.reason.isEmpty })
        check("1 D's reason says the reply was not the tag JSON",
              p.taggingFailureNames.first { $0.name == "DOCD.jpg" }?.reason == "the reply was not the tag JSON",
              "\(p.taggingFailureNames)")
        check("1 E's error JSON with a 200 is a failed call too",
              p.taggingCallFailures.first { $0.source == files[4] }?.reason == "the reply was not the tag JSON",
              "\(p.taggingFailureNames)")
        check("1 C's timeout says so",
              p.taggingCallFailures.first { $0.source == files[2] }?.reason == "the request timed out",
              "\(p.taggingFailureNames)")
        check("2 A is filed with its subjects", tagsOf("DOCA").contains("War Department"), "\(tagsOf("DOCA"))")
        for m in ["DOCB", "DOCC", "DOCD", "DOCE"] {
            check("2 \(m) is still filed (its output is there) with no subject from the model",
                  fm.fileExists(atPath: outputs[m]!.path) && !tagsOf(m).contains("War Department"), "\(tagsOf(m))")
        }
        let asked = wire.lock.withLock { wire.asked }
        check("3 the 500 and the timeout are each asked once (the network route retries neither for a paid call)",
              markers.allSatisfy { asked[$0] == 1 }, "\(asked)")

        let suffix = OCRProcessor.taggedSegmentsSuffix(segments: p.segments.count, failures: p.taggingFailureNames)
        check("4 the status line counts 1 of 5 tagged", suffix.hasPrefix(" 1 of 5 segments tagged."), suffix)
        check("4 ...and names the documents, in the plural",
              ["DOCB.jpg", "DOCC.jpg"].allSatisfy(suffix.contains) && suffix.contains("+1 more")
              && suffix.contains("4 documents' tagging calls failed") && !suffix.contains("DOCA"), suffix)
        let log = OCRProcessor.taggingFailureLogLines(p.taggingFailureNames)
        check("4 the log section lists all four with their reasons",
              log.count == 6 && log.contains("  \u{2022} DOCD.jpg: the reply was not the tag JSON"), "\(log)")
        check("4 one failure reads in the singular",
              OCRProcessor.taggedSegmentsSuffix(segments: 2, failures: [("X.jpg", "the request timed out")])
              .contains("1 document's tagging call failed (X.jpg): the request timed out — it was filed"))
        check("4 a clean pass says only the count",
              OCRProcessor.taggedSegmentsSuffix(segments: 4, failures: []) == " 4 segments tagged."
              && OCRProcessor.taggingFailureLogLines([]).isEmpty)
        let many = (1...5).map { (name: "P\($0).jpg", reason: "bad response") }
        let manySuffix = OCRProcessor.taggedSegmentsSuffix(segments: 9, failures: many)
        check("4 five failures: four of nine tagged, three named and the rest counted, the reason said once",
              manySuffix.hasPrefix(" 4 of 9 segments tagged.") && manySuffix.contains("+2 more")
              && manySuffix.components(separatedBy: "bad response").count == 2, manySuffix)

        p.forgetOutputWarnings(forSources: [files[1]])
        check("4 an output removed in review takes its record with it",
              Set(p.taggingCallFailures.map(\.source)) == Set([files[2], files[3], files[4]]), "\(p.taggingFailureNames)")

        // 5. Redo: the calls answer now, so the record clears and every document gets its subjects.
        wire.lock.withLock { wire.failing = false }
        await p.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: outDir,
                                    enableSegmentJSON: false)
        check("5 a Redo whose calls answer clears the record", p.taggingCallFailures.isEmpty, "\(p.taggingFailureNames)")
        check("5 ...and files every document with its subjects",
              markers.allSatisfy { tagsOf($0).contains("War Department") }, "\(markers.map(tagsOf))")
        check("5 ...and the status line is the plain count",
              OCRProcessor.taggedSegmentsSuffix(segments: p.segments.count, failures: p.taggingFailureNames)
              == " 5 segments tagged.")
    }
}
#endif
