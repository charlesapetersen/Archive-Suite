#if DEBUG
import AppKit
import CoreGraphics
import CoreText
import Foundation
import SwiftUI
import VisionOCRKit

/// Scratch-only, no-wire functional checks, including the actual PP detector when the script supplies its checked
/// model home. Fake readers exercise assembly, failure and cancellation without buying a reading.
@MainActor
enum NewspaperLayoutTestDriver {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["NEWSPAPER_TEST"] == "1" else { return }
        Task { await run() }
    }

    private actor Fake: PageReader {
        nonisolated let route = "fake"
        var calls: [PageReaderInput] = []
        let failAt: Int?
        let delay: Bool
        let throwAt: Int?
        let delayAt: Int?
        init(failAt: Int? = nil, delay: Bool = false, throwAt: Int? = nil, delayAt: Int? = nil) {
            self.failAt = failAt; self.delay = delay; self.throwAt = throwAt; self.delayAt = delayAt
        }
        func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
            calls.append(page)
            let n = calls.count
            if delay || n == delayAt { try await Task.sleep(for: .seconds(20)) }
            if n == throwAt { throw URLError(.cannotConnectToHost) }
            let result = OCRResult(text: n == failAt ? nil : page.imageURL.lastPathComponent,
                                   classification: .documentStart, errorMessage: nil,
                                   errorCode: n == failAt ? "503" : nil)
            return PageReading(text: result.text, seconds: 1, dollars: 0.01, detail: result)
        }
        func count() -> Int { calls.count }
        func contextIs(_ url: URL) -> Bool { calls.allSatisfy { $0.previousImageURL == url && $0.previousText == "previous page" } }
    }

    private static func run() async {
        var log: [String] = [], failures = 0
        func check(_ name: String, _ ok: Bool) {
            log.append("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("newspaper-proof-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for kind in PageKindName.allCases {
                check("kind gate \(kind.rawValue)", NewspaperPagePlan.usesRegions(PageKind(kind: kind, confidence: 1)) == (kind == .newspapers))
            }
            check("unknown and uncertain are whole", !NewspaperPagePlan.usesRegions(nil)
                  && !NewspaperPagePlan.usesRegions(PageKind(kind: .newspapers, confidence: 0.7)))
            let line = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.1)
            let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
            check("union coverage counts overlapping lines only once", abs((NewspaperPagePlan.coverage(lines: [line, line], crops: [crop]) ?? 0) - 0.5) < 1e-9)
            check("no Vision geometry requests fill", NewspaperPagePlan.coverage(lines: [], crops: [crop]) == nil)
            check("boundary line moves intact to fill", NewspaperPagePlan.boundaryLines([line], crops: [crop]) == [line])
            check("a line divided across two otherwise complete regions reaches fill intact",
                  NewspaperPagePlan.boundaryLines([line], crops: [crop, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]) == [line])
            let overlap = CGRect(x: 0.75, y: 0.3, width: 0.1, height: 0.1)
            check("overlapping line follows the moved line", NewspaperPagePlan.boundaryLines([line, overlap], crops: [crop]).count == 2)
            let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 20, y: 60, width: 60, height: 10))
            let original = context.makeImage()!
            let regionBox = CGRect(x: 0, y: 0, width: 50, height: 100)
            let moved = CGRect(x: 20, y: 30, width: 60, height: 10)
            let regionImage = NewspaperPagePlan.masked(original, boxes: [moved])!
            let fillImage = NewspaperPagePlan.masked(original, boxes: [regionBox], restore: [moved])!
            func ink(_ image: CGImage) -> Int {
                let rep = NSBitmapImageRep(cgImage: image)
                return (0..<100).reduce(0) { sum, y in sum + (0..<100).filter { x in
                    (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
                }.count }
            }
            check("region omits moved line; fill has all its pixels", ink(regionImage) == 0 && ink(fillImage) == ink(original) && ink(fillImage) == 600)
            let source = dir.appendingPathComponent("whole.png")
            try NewspaperPagePlan.write(original, to: source)
            let bytes = try Data(contentsOf: source)
            let previous = dir.appendingPathComponent("previous.png")
            let input = PageReaderInput(imageURL: source, previousText: "previous page", previousImageURL: previous)
            let plan = NewspaperPagePlan(directory: dir, images: [dir.appendingPathComponent("right-first.png"), dir.appendingPathComponent("left-second.png"), dir.appendingPathComponent("outside.png")], regionCount: 2, coverage: 0.7, hasFill: true)
            let fake = Fake()
            let completeSpend = NewspaperReadingSpend()
            let read = try await NewspaperPageReader.$spend.withValue(completeSpend) {
                try await NewspaperPageReader(client: fake).readRegions(input, plan: plan)
            }
            check("native order with fill last, no text deduplication", read.text == "right-first.png\n\nleft-second.png\n\noutside.png")
            let contextOK = await fake.contextIs(previous)
            check("every region keeps preceding original page as context", contextOK)
            check("requests and extra costs count region reads", read.detail.newspaperLayout?.requests == 3 && abs((read.detail.newspaperLayout?.estimatedExtraCost ?? 0) - 0.02) < 1e-9)
            check("returned layout consumes its accumulated costs once",
                  completeSpend.unreported(layouts: [read.detail.newspaperLayout!], baseSources: nil) == 0)
            check("rotation copy preserves layout provenance", read.detail.with(classification: read.detail.classification, rotationDegrees: 90).newspaperLayout == read.detail.newspaperLayout)
            let failing = Fake(failAt: 2)
            let fallback = try await NewspaperPageReader(client: failing).readRegions(input, plan: plan)
            let failCount = await failing.count()
            check("failed region replaces partial text with one whole-page read", fallback.text == "whole.png" && failCount == 3 && fallback.detail.newspaperLayout?.fallback != nil)
            let throwing = Fake(throwAt: 2)
            let thrownFallback = try await NewspaperPageReader(client: throwing).readRegions(input, plan: plan)
            check("a thrown request is still counted before the one fallback", thrownFallback.detail.newspaperLayout?.requests == 3)
            let model = LLMModel.geminiModels[0]
            let priced = PageReaders.Measured(Fake(), dollars: PageReaders.pagePrice(model), pricedModel: model)
            var scaled = input
            scaled.imageScale = 0.5; scaled.costScale = 0.25; scaled.previousText = nil
            let measured = try await priced.read(scaled)
            let expected = CostEstimator.estimate(fileCount: 1, model: model, enableTagging: false,
                sendPreviousImage: true, contextCharCount: 0, imageScale: 0.25).ocrCost
            check("prices use area fraction and repeated previous image", measured.dollars == expected)
            let slow = Fake(delay: true)
            let task = Task { try await NewspaperPageReader(client: slow).readRegions(input, plan: plan) }
            while await slow.count() == 0 { try await Task.sleep(for: .milliseconds(10)) }
            task.cancel()
            var cancelled = false
            do { _ = try await task.value } catch is CancellationError { cancelled = true }
            let cancelledCalls = await slow.count()
            check("Stop never buys a fallback reading", cancelled && cancelledCalls == 1)
            let partialSpend = NewspaperReadingSpend()
            let partial = Fake(delayAt: 3)
            let partialTask = Task {
                try await NewspaperPageReader.$spend.withValue(partialSpend) {
                    try await NewspaperPageReader(client: partial).readRegions(input, plan: plan)
                }
            }
            while await partial.count() < 3 { try await Task.sleep(for: .milliseconds(10)) }
            partialTask.cancel()
            do { _ = try await partialTask.value } catch is CancellationError { }
            check("Stop retains two completed region charges even without a page result",
                  abs(partialSpend.unreported(layouts: [], baseSources: []) - 0.02) < 1e-9)
            check("an already-priced base page is subtracted only once",
                  abs(partialSpend.unreported(layouts: [], baseSources: [source]) - 0.01) < 1e-9)
            let throwSpend = NewspaperReadingSpend()
            do {
                _ = try await NewspaperPageReader.$spend.withValue(throwSpend) {
                    try await NewspaperPageReader(client: Fake(failAt: 2, throwAt: 3)).readRegions(input, plan: plan)
                }
                check("whole fallback throws in the charged-partial fixture", false)
            } catch { }
            check("a throwing whole fallback retains its earlier region costs",
                  abs(throwSpend.unreported(layouts: [], baseSources: []) - 0.02) < 1e-9)
            check("source bytes remain unchanged", (try Data(contentsOf: source)) == bytes)

            let ids = (0..<3).map { NewspaperBatch.regionID(fileIndex: 0, regionIndex: $0, total: 3) }
            let manifest = NewspaperBatch.Manifest(pages: [NewspaperBatch.Page(fileIndex: 0, requestIDs: ids,
                regions: 2, coverage: 0.7, filled: true, fallback: nil)])
            var parts = [ids[0]: OCRResult(text: "repeat", classification: .documentStart, errorMessage: nil, errorCode: nil)]
            check("incomplete cross-chunk page is never output", NewspaperBatch.aggregate(manifest: manifest, parts: parts).isEmpty)
            parts[ids[2]] = OCRResult(text: "outside", classification: nil, errorMessage: nil, errorCode: nil)
            parts[ids[1]] = OCRResult(text: "repeat", classification: nil, errorMessage: nil, errorCode: nil)
            let batchText = NewspaperBatch.aggregate(manifest: manifest, parts: parts)["file-0"]?.text
            check("out-of-order batch replies assemble in native order with real repeated text", batchText == "repeat\n\nrepeat\n\noutside")
            check("manifest rejects unknown ids and wrong file associations", NewspaperBatch.valid(manifest, parts: parts, files: 1)
                  && !NewspaperBatch.valid(manifest, parts: ["file-1-region-0-of-3": parts[ids[0]]!], files: 1))
            check("ids are strictly anchored", NewspaperBatch.originalIndex(ids[0]) == nil
                  && NewspaperBatch.originalIndex("file-00") == nil && NewspaperBatch.parseRegionID("file-0-region-3-of-3") == nil)
            parts[ids[1]] = .cutOff
            check("a failed region invalidates the batch page", NewspaperBatch.aggregate(manifest: manifest, parts: parts)["file-0"]?.errorCode == NewspaperBatch.failedRegionCode)
            parts["file-0"] = OCRResult(text: "whole fallback", classification: .documentStart, errorMessage: nil, errorCode: nil)
            check("replayed parts reuse a journaled whole fallback", NewspaperBatch.aggregate(manifest: manifest, parts: parts)["file-0"]?.text == "whole fallback")
            var pending = OCRProcessor.PendingBatch(batchId: "test-job", provider: .gemini, model: LLMModel.geminiModels[0],
                thinkingLevel: nil, fileURLs: [source], outputDirectory: dir, enableTagging: false,
                sendPreviousImage: false, submittedAt: Date(), taggingMode: .none,
                lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion, submittedChunkIds: ["test-job"],
                submissionComplete: true)
            pending.newspaperManifest = manifest
            pending.newspaperParts = parts
            let journal = dir.appendingPathComponent("pending.json")
            let saved = OCRProcessor._testWritePendingBatch(pending, to: journal)
            let restored = OCRProcessor._testReadPendingBatch(from: journal)
            check("region identities and partial results survive atomic journal roundtrip", saved != nil
                  && restored?.newspaperManifest == manifest && restored?.newspaperParts?[ids[0]]?.text == "repeat")
            if var changed = restored {
                let before = OCRProcessor.pendingBatchLifecycleFingerprint(changed)
                changed.newspaperParts?[ids[0]] = .cutOff
                check("journal fingerprint covers partial region replies", before != OCRProcessor.pendingBatchLifecycleFingerprint(changed))
            }
            let syncHistory = RunHistorySnapshot(startedAt: Date(), provider: .gemini, gatewayConfig: nil,
                localAgent: nil, imageTokenProvider: nil, model: model, visionTextProvider: nil, visionTextModel: nil,
                batchMode: false, enableTagging: false, enableCollectionSegmentation: false, preOCRedInput: false,
                reOCRMultiPagePDF: false, mixedReOCR: false, sendPreviousImage: false, contextCharCount: 0,
                imageScale: 1, rotationMode: .off, fileCount: 1)
            var snapshot = syncHistory
            snapshot.newspaperSpend = partialSpend
            check("the unfinished-run ledger prices completed regions without a completed file",
                  abs(snapshot.spentSoFar(readSources: []) - 0.02) < 1e-9)
            snapshot.newspaperSpend = completeSpend
            check("completed page history does not add its runtime costs again",
                  abs(snapshot.makeRun(succeeded: 1, layouts: [read.detail.newspaperLayout!]).cost
                      - snapshot.estimatedCost - 0.02) < 1e-9)
            snapshot.newspaperSpend = NewspaperReadingSpend()
            let ledger = SettingsLayerStore(directory: dir.appendingPathComponent("ledger"))
            snapshot.ledgerRunID = UUID()
            snapshot.newspaperSpend = partialSpend
            let stoppedCost = snapshot.spentSoFar(readSources: [])
            OCRProcessor.recordNewspaperAdjustedSpend(snapshot, jobs: [], usd: stoppedCost, files: 0,
                                                       baseSources: [], store: ledger)
            let reloadedLedger = SettingsLayerStore(directory: ledger.directory)
            check("abandoned region charges survive reopening the scratch ledger",
                  abs(reloadedLedger.monthSpend().usd - stoppedCost) < 1e-9)
            // A fresh resumed snapshot has no runtime accumulator and the same persisted run identity.
            var resumed = syncHistory
            resumed.ledgerRunID = snapshot.ledgerRunID
            let resumedCost = resumed.makeRun(succeeded: 1).cost
            OCRProcessor.recordNewspaperAdjustedSpend(resumed, jobs: [], usd: resumedCost, files: 1,
                                                       baseSources: nil, store: reloadedLedger)
            check("Stop then Resume adds abandoned regions to the resumed run instead of absorbing them",
                  abs(reloadedLedger.monthSpend().usd - stoppedCost - resumedCost) < 1e-9)
            // A late result with the same attempt ID can arrive from a kept batch journal after Stop.
            let lateIDs = Array(partialSpend.unreportedCharges(layouts: [], baseSources: []).keys)
            let lateNote = NewspaperLayoutRecord(regions: 2, requests: 2, coverage: 1, filled: false,
                                                 fallback: nil, estimatedExtraCost: 0.01, spendIDs: lateIDs)
            var lateJob = OCRJob(sourceURL: source)
            lateJob.result = OCRResult(text: "late result", classification: nil, errorMessage: nil,
                                       errorCode: nil, newspaperLayout: lateNote)
            let lateLedger = SettingsLayerStore(directory: dir.appendingPathComponent("late-ledger"))
            OCRProcessor.recordNewspaperAdjustedSpend(snapshot, jobs: [], usd: stoppedCost, files: 0,
                                                       baseSources: [], store: lateLedger)
            OCRProcessor.recordNewspaperAdjustedSpend(resumed, jobs: [lateJob], usd: 0.03, files: 1,
                                                       baseSources: nil, store: lateLedger)
            check("a late collected result never charges its already-ledgered attempt twice",
                  abs(lateLedger.monthSpend().usd - 0.03) < 1e-9)
            let standardSpend = NewspaperReadingSpend()
            snapshot = RunHistorySnapshot(resuming: pending, rotationMode: .off, imageScale: 1)
            let standardID = UUID()
            standardSpend.add(0.01, id: standardID, source: source, baseAllowance: false)
            standardSpend.add(0.01, id: standardID, source: source, baseAllowance: false)
            snapshot.newspaperSpend = standardSpend
            check("a batch reserve never pays the first call of a later standard-rate reader",
                  abs(snapshot.makeRun(succeeded: 0).cost - snapshot.estimatedCost - 0.02) < 1e-9)
            snapshot.newspaperSpend = NewspaperReadingSpend()
            snapshot.reserveNewspaperBatch(manifest)
            let reserve = snapshot.newspaperBatchExtraCost
            check("unaggregated paid regions reserve money", reserve > 0)
            let note = NewspaperLayoutRecord(regions: 2, requests: 3, coverage: 0.7, filled: true,
                                            fallback: nil, estimatedExtraCost: reserve)
            check("final history does not double-count paid reserve", abs(snapshot.makeRun(succeeded: 1, layouts: [note]).cost - snapshot.estimatedCost) < 1e-9)
            let extra = NewspaperLayoutRecord(regions: 2, requests: 4, coverage: 0.7, filled: true,
                                             fallback: "failed region", estimatedExtraCost: reserve + 0.2, standardFallbackCost: 0.2)
            check("history adds standard-rate fallback beyond batch reserve", abs(snapshot.makeRun(succeeded: 1, layouts: [extra]).cost - snapshot.estimatedCost - 0.2) < 1e-9)
            let second = NewspaperLayoutRecord(regions: 2, requests: 2, coverage: 1, filled: false,
                fallback: nil, estimatedExtraCost: 0.3, standardFallbackCost: 0.3)
            let combined = NewspaperLayoutRecord.combining(second, after: extra)!
            check("batch reserve never swallows later standard region costs", combined.requests == 6
                  && abs(snapshot.makeRun(succeeded: 1, layouts: [combined]).cost - snapshot.estimatedCost - 0.5) < 1e-9)

            if ProcessInfo.processInfo.environment["NEWSPAPER_REAL_DETECTOR"] == "1" {
                // Authored fixture, not a corpus page. It exercises the downloaded, offline detector and its
                // real guarded subprocess; no OCR reader, key or upload is involved.
                let w = 1600, h = 2200
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                func draw(_ text: String, x: Int, y: Int, size: CGFloat) {
                    let font = CTFontCreateWithName("Times-Roman" as CFString, size, nil)
                    let string = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
                    ctx.textPosition = CGPoint(x: x, y: y)
                    CTLineDraw(CTLineCreateWithAttributedString(string), ctx)
                }
                draw("THE DAILY ARCHIVE", x: 140, y: 2040, size: 100)
                for column in 0..<3 {
                    draw("Budget Office Report", x: 70 + column * 500, y: 1900, size: 38)
                    for row in 0..<43 {
                        draw("The public records are available today.", x: 70 + column * 500, y: 1840 - row * 39, size: 27)
                    }
                }
                let authored = dir.appendingPathComponent("authored-newspaper.png")
                try NewspaperPagePlan.write(ctx.makeImage()!, to: authored)
                let realPlan = try await NewspaperPageReader.queue.run {
                    try NewspaperPagePlan.prepare(authored, photographed: false, isCancelled: { false })
                }
                defer { realPlan.removeScratch() }
                check("real PP prepares regions from the authored newspaper", realPlan.regionCount > 0 && realPlan.images.count >= realPlan.regionCount)
                check("real prepared crops exist", realPlan.images.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            }
            let renderer = ImageRenderer(content: NewspaperLayoutDownloadRow().padding().frame(width: 600).background(.white))
            if let shot = renderer.cgImage, let out = ProcessInfo.processInfo.environment["NEWSPAPER_RENDER"] {
                try NewspaperPagePlan.write(shot, to: URL(fileURLWithPath: out))
                check("download row renders to pixels", shot.width > 100 && shot.height > 10)
            } else { check("download row renders to pixels", false) }
        } catch { check("functional run: \(error)", false) }
        log.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        if let out = ProcessInfo.processInfo.environment["NEWSPAPER_TEST_OUT"] {
            try? (log.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
#endif
