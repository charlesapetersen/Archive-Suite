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
        let env = ProcessInfo.processInfo.environment
        if let list = env["NEWSPAPER_PLAN_DUMP"], let out = env["NEWSPAPER_PLAN_OUT"] {
            Task { await dumpPlans(list: URL(fileURLWithPath: list), out: URL(fileURLWithPath: out)) }
            return
        }
        if let list = env["SCAN_LAYOUT_DUMP"], let out = env["SCAN_LAYOUT_OUT"] {
            Task { await dumpScanLayout(list: URL(fileURLWithPath: list), out: URL(fileURLWithPath: out)) }
            return
        }
        guard env["NEWSPAPER_TEST"] == "1" else { return }
        Task { await run() }
    }

    /// W46.layout-partition-score: the exact images `NewspaperPagePlan.prepare` gives the reader, copied out for a
    /// bench reader, with the kind gate, the raw detector regions (for the raw-region control) and the partition's
    /// counts. Input pages are only read; everything is written under `out`, which the script makes in scratch.
    private static func dumpPlans(list: URL, out: URL) async {
        var log: [String] = [], failures = 0
        let pages = ((try? String(contentsOf: list, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        for line in pages where !line.isEmpty {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2 else { log.append("FAIL bad line \(line)"); failures += 1; continue }
            let (id, url) = (parts[0], URL(fileURLWithPath: parts[1]))
            let dest = out.appendingPathComponent(id)
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                let kind = await PageKindClassifier.classify(url: url)
                let started = Date()
                let plan = try await NewspaperPageReader.queue.run {
                    try NewspaperPagePlan.prepare(url, photographed: false, isCancelled: { false })
                }
                let prepareSeconds = Date().timeIntervalSince(started)
                defer { plan.removeScratch() }
                var names: [String] = []
                for image in plan.images {
                    try FileManager.default.copyItem(at: image, to: dest.appendingPathComponent(image.lastPathComponent))
                    names.append(image.lastPathComponent)
                }
                // Diagnostics only, recomputed with the plan's own static functions on a second detection.
                let geometry = try await NewspaperPageReader.queue.run { () throws -> Data in
                    guard let image = PageKindClassifier.loadImage(url) else { throw NewspaperPagePlan.Failure.image }
                    let regions = try NewspaperLayout.detect(image: image)
                    let raw = regions.compactMap { NewspaperPagePlan.pixelBox($0.box, width: image.width, height: image.height) }
                    var kept: [CGRect] = []
                    for box in raw where NewspaperPagePlan.unionArea(kept.map { box.intersection($0) }) < box.width * box.height - 0.5 {
                        kept.append(box)
                    }
                    let crops = kept.map { CGRect(x: $0.minX / Double(image.width), y: $0.minY / Double(image.height),
                                                  width: $0.width / Double(image.width), height: $0.height / Double(image.height)) }
                    let vision = TextLayer.visionLines(of: image)?.lines.map(\.box) ?? []
                    let page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    let pixels = vision.map { CGRect(x: $0.minX * Double(image.width), y: $0.minY * Double(image.height),
                        width: $0.width * Double(image.width), height: $0.height * Double(image.height)).integral.intersection(page) }
                    let owners = NewspaperPagePlan.owners(of: pixels, boxes: kept)
                    // fill_lines: lines no region touches; split_lines: lines a region reads whole across its edge.
                    let split = pixels.indices.filter { i in owners[i].map { !kept[$0].contains(pixels[i]) } ?? false }
                    let record: [String: Any] = [
                        "width": image.width, "height": image.height, "vision_lines": vision.count,
                        "fill_lines": owners.filter { $0 == nil }.count, "split_lines": split.count, "kept": kept.count,
                        "coverage_crops": crops.count,
                        "regions": regions.map { ["box": [$0.box.minX, $0.box.minY, $0.box.maxX, $0.box.maxY],
                                                  "order": $0.order, "label": $0.label, "score": $0.score] as [String: Any] }]
                    return try JSONSerialization.data(withJSONObject: record)
                }
                guard var record = try JSONSerialization.jsonObject(with: geometry) as? [String: Any] else {
                    throw NewspaperPagePlan.Failure.geometry
                }
                record["id"] = id
                record["kind"] = kind?.kind.rawValue ?? NSNull()
                record["kind_confidence"] = kind?.confidence ?? NSNull()
                record["uses_regions"] = NewspaperPagePlan.usesRegions(kind)
                record["plan_regions"] = plan.regionCount
                record["coverage"] = plan.coverage ?? NSNull()
                record["has_fill"] = plan.hasFill
                record["region_images"] = plan.regionImages
                record["fill_crops"] = plan.fillCount
                record["images"] = names
                record["prepare_seconds"] = prepareSeconds
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                try data.write(to: dest.appendingPathComponent("plan.json"))
                let same = (record["kept"] as? Int) == plan.regionCount
                log.append("\(same ? "PASS" : "FAIL") \(id) regions \(plan.regionCount) fill \(plan.hasFill)")
                if !same { failures += 1 }
            } catch {
                log.append("FAIL \(id): \(error)"); failures += 1
            }
        }
        log.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        try? (log.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("report.txt"),
                                                         atomically: true, encoding: .utf8)
    }

    /// The app's peak physical footprint so far (the kernel's ledger), for the dump's memory figure.
    nonisolated private static func peakFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }

    /// W47.wh-yolo-scans: the scanned-newspaper detector's two steps on each page, the Core ML detections and the
    /// ordered regions, written as `<out>/<id>.json` for `scan_layout_parity.py compare`. Pages are only read.
    private static func dumpScanLayout(list: URL, out: URL) async {
        var log: [String] = [], failures = 0
        let pages = ((try? String(contentsOf: list, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        for line in pages where !line.isEmpty {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2 else { log.append("FAIL bad line \(line)"); failures += 1; continue }
            let (id, url) = (parts[0], URL(fileURLWithPath: parts[1]))
            do {
                let data = try await NewspaperPageReader.queue.run { () throws -> Data in
                    guard let image = PageKindClassifier.loadImage(url) else { throw NewspaperPagePlan.Failure.image }
                    let started = Date()
                    let raw = try ScanNewspaperLayout.detections(image: image)
                    let detected = Date()
                    let regions = try ScanNewspaperLayout.ordered(raw, width: image.width, height: image.height)
                    let record: [String: Any] = [
                        "width": image.width, "height": image.height,
                        "detect_seconds": detected.timeIntervalSince(started),
                        "order_seconds": Date().timeIntervalSince(detected),
                        "peak_footprint_mb": Self.peakFootprintMB(),
                        "raw": raw.map { ["label": $0.label, "score": Double($0.confidence), "box": $0.box] as [String: Any] },
                        "regions": regions.map { ["label": $0.label, "score": $0.score,
                                                  "box": [$0.box.minX, $0.box.minY, $0.box.maxX, $0.box.maxY]] as [String: Any] }]
                    return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                }
                try data.write(to: out.appendingPathComponent("\(id).json"))
                log.append("PASS \(id)")
            } catch {
                log.append("FAIL \(id): \(error)"); failures += 1
            }
        }
        log.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        try? (log.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("report.txt"),
                                                         atomically: true, encoding: .utf8)
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
            // W47.wh-whole-page-large: Qwen3.6 27B reads newspapers whole; every other reader keeps the detector.
            func wrapped(_ id: String) -> Bool? {
                guard let model = OpenRouterRoute.catalog.first(where: { $0.model.id == id })?.model,
                      let reader = try? PageReaders.reader(provider: .openrouter, model: model, apiKey: "test",
                                                           thinkingLevel: nil) else { return nil }
                return reader is NewspaperPageReader
            }
            check("large reader: Qwen3.6 27B reads newspapers whole, Qwen3-VL 235B and Apple Vision keep the detector",
                  wrapped("qwen/qwen3.6-27b") == false && wrapped("qwen/qwen3-vl-235b-a22b-instruct") == true
                      && (try? PageReaders.reader(provider: .appleVision, model: LLMModel.appleVisionModels[0], apiKey: "",
                                                  thinkingLevel: nil)) is NewspaperPageReader
                      && NewspaperPageReader.wholePageReaderIDs == ["qwen/qwen3.6-27b"])
            // W47.wh-yolo-scans: the scanned-newspaper detector is the run's choice, off by default, scans only.
            let yes = [SettingsKey.scanNewspapersDocLayoutYOLO.rawValue: ResolvedSetting(value: .bool(true))]
            let no = [SettingsKey.scanNewspapersDocLayoutYOLO.rawValue: ResolvedSetting(value: .bool(false))]
            check("scan detector: PP-DocLayoutV3 without a snapshot or switched off, DocLayout-YOLO switched on",
                  NewspaperDetector.scans(nil) == .ppDocLayoutV3 && NewspaperDetector.scans(no) == .ppDocLayoutV3
                      && NewspaperDetector.scans(yes) == .docLayoutYOLO
                      && SettingsKey.scanNewspapersDocLayoutYOLO.defaultValue == .bool(false))
            let bareHome = ["VISIONOCR_MODEL_HOME": dir.appendingPathComponent("no-models").path]
            check("scan detector: a scan keeps PP-DocLayoutV3 while DocLayout-YOLO is not downloaded",
                  !ScanNewspaperLayout.isInstalled(bareHome)
                      && NewspaperDetector.forPage(photographed: false, scans: .docLayoutYOLO, environment: bareHome) == .ppDocLayoutV3)
            let runtime = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Vision OCR/Runtime")
            if FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/python3").path) {
                let home = dir.appendingPathComponent("scan-home")
                try FileManager.default.createDirectory(at: home.appendingPathComponent("Models/doclayout-yolo-1280.mlmodelc"),
                                                        withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Runtime"), withDestinationURL: runtime)
                let env = ["VISIONOCR_MODEL_HOME": home.path]
                check("scan detector: an installed DocLayout-YOLO reads scans only; a photograph keeps PP-DocLayoutV3",
                      ScanNewspaperLayout.isInstalled(env)
                          && NewspaperDetector.forPage(photographed: false, scans: .docLayoutYOLO, environment: env) == .docLayoutYOLO
                          && NewspaperDetector.forPage(photographed: true, scans: .docLayoutYOLO, environment: env) == .ppDocLayoutV3
                          && NewspaperDetector.forPage(photographed: false, scans: .ppDocLayoutV3, environment: env) == .ppDocLayoutV3)
            } else {
                log.append("SKIP scan detector installed case: no shared runtime on this Mac")
            }
            let inherited = await NewspaperPageReader.$scanDetector.withValue(.docLayoutYOLO) {
                await Task { NewspaperPageReader.scanDetector }.value
            }
            check("scan detector: the run's choice reaches the page reader's tasks, and is PP-DocLayoutV3 outside a run",
                  inherited == .docLayoutYOLO && NewspaperPageReader.scanDetector == .ppDocLayoutV3)
            // The layout processing's reply: regions in its order, a degenerate or malformed row dropped, bad JSON a failure.
            let reply = #"[{"label":"title","score":0.9,"box":[0.1,0.1,0.5,0.2]},{"label":"plain_text","score":0.8,"box":[0.6,0.1,0.5,0.9]},"# +
                #"{"label":"plain_text","score":0.7,"box":[0.1,0.3,0.5,1.2]}]"#
            let decoded = try ScanNewspaperLayout.decode(Data(reply.utf8))
            check("scan detector: its regions keep the processing's order and drop a degenerate box",
                  decoded.map(\.label) == ["title", "plain_text"] && decoded.map(\.order) == [1, 2]
                      && abs(decoded[1].box.maxY - 1) < 1e-9)
            check("scan detector: an unreadable reply is a failed page",
                  (try? ScanNewspaperLayout.decode(Data("{}".utf8))) == nil)
            let line = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.1)
            let crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
            check("union coverage counts overlapping lines only once", abs((NewspaperPagePlan.coverage(lines: [line, line], crops: [crop]) ?? 0) - 0.5) < 1e-9)
            check("no Vision geometry requests fill", NewspaperPagePlan.coverage(lines: [], crops: [crop]) == nil)
            // W46.layout-partition-fix, pixel rectangles: a line is read once, whole, by the region holding most.
            let left = CGRect(x: 0, y: 0, width: 50, height: 100), right = CGRect(x: 50, y: 0, width: 50, height: 100)
            let split = CGRect(x: 20, y: 30, width: 60, height: 10), inside = CGRect(x: 60, y: 38, width: 30, height: 10)
            check("a split line goes whole to the region holding most of it",
                  NewspaperPagePlan.owners(of: [split], boxes: [CGRect(x: 0, y: 0, width: 40, height: 100), CGRect(x: 40, y: 0, width: 60, height: 100)]) == [1])
            check("an even split goes to the earlier region", NewspaperPagePlan.owners(of: [split], boxes: [left, right]) == [0])
            check("no transitive closure: an overlapping line stays with its own region",
                  NewspaperPagePlan.owners(of: [split, inside], boxes: [left, right]) == [0, 1])
            check("a line in an overlap belongs to the earlier region, which owns those pixels",
                  NewspaperPagePlan.owners(of: [CGRect(x: 45, y: 0, width: 10, height: 10)], boxes: [CGRect(x: 0, y: 0, width: 60, height: 100), CGRect(x: 40, y: 0, width: 60, height: 100)]) == [0])
            check("a line no region touches is left over", NewspaperPagePlan.owners(of: [split], boxes: [CGRect(x: 0, y: 60, width: 100, height: 40)]) == [nil])
            let column = (0..<4).map { CGRect(x: 10, y: 10 + $0 * 15, width: 30, height: 10) }
            let other = CGRect(x: 60, y: 10, width: 30, height: 10), far = CGRect(x: 10, y: 400, width: 30, height: 10)
            check("leftover lines group by column, top first, never across a gap",
                  NewspaperPagePlan.groups(column + [other, far]) == [[0, 1, 2, 3], [4], [5]])
            check("too many leftover groups read as one",
                  NewspaperPagePlan.groups((0..<40).map { CGRect(x: $0 * 20, y: 0, width: 10, height: 10) }).count == 1)
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
            // The owner's crop widens to hold the whole split line; the other region keeps none of it.
            let owner = NewspaperPagePlan.compose(original, frame: left.union(split), keep: [left], erase: [], restore: [split])!
            let loser = NewspaperPagePlan.compose(original, frame: right, keep: [right], erase: [left, split], restore: [])!
            func inkCount(_ image: CGImage) -> Int {
                let rep = NSBitmapImageRep(cgImage: image)
                return (0..<image.height).reduce(0) { sum, y in sum + (0..<image.width).filter { x in
                    (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
                }.count }
            }
            check("the owning region reads the whole split line and the other none of it",
                  owner.width == 80 && inkCount(owner) == 600 && inkCount(loser) == 0)
            let firstLine = CGRect(x: 20, y: 30, width: 40, height: 10), secondLine = CGRect(x: 50, y: 30, width: 30, height: 10)
            let early = NewspaperPagePlan.compose(original, frame: left.union(firstLine), keep: [], erase: [], restore: [firstLine])!
            let late = NewspaperPagePlan.compose(original, frame: right, keep: [], erase: [], restore: [secondLine],
                                                 trim: NewspaperPagePlan.overlaps([secondLine], [firstLine]))!
            let band = NewspaperPagePlan.compose(original, frame: CGRect(x: 0, y: 25, width: 100, height: 20),
                                                 keep: [CGRect(x: 0, y: 25, width: 100, height: 20)], erase: [], restore: [])!
            let bandRep = NSBitmapImageRep(cgImage: band)
            check("a frame below the top keeps its rows in place",
                  inkCount(band) == 600 && (bandRep.colorAt(x: 25, y: 7)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.5
                      && (bandRep.colorAt(x: 25, y: 2)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0) > 0.5)
            check("overlapping line rectangles across owners: the earlier region keeps the shared pixels",
                  inkCount(early) == 400 && inkCount(late) == 200)
            check("a crop masked blank is skipped, a line of text is not",
                  !NewspaperPagePlan.hasInk(loser) && NewspaperPagePlan.hasInk(owner))
            let source = dir.appendingPathComponent("whole.png")
            try NewspaperPagePlan.write(original, to: source)
            let bytes = try Data(contentsOf: source)
            let previous = dir.appendingPathComponent("previous.png")
            let input = PageReaderInput(imageURL: source, previousText: "previous page", previousImageURL: previous)
            let plan = NewspaperPagePlan(directory: dir, images: [dir.appendingPathComponent("right-first.png"), dir.appendingPathComponent("left-second.png"), dir.appendingPathComponent("outside.png")], regionCount: 2, coverage: 0.7, fillCount: 1)
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
                regions: 2, fills: 1, coverage: 0.7, fallback: nil)])
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
            // W46.layout-partition-fix shapes: skipped regions and several outside crops, or outside crops alone.
            let shapes = [(1, 2), (0, 2), (2, 0)].map { regions, fills in
                NewspaperBatch.Page(fileIndex: 0, requestIDs: (0..<(regions + fills)).map {
                    NewspaperBatch.regionID(fileIndex: 0, regionIndex: $0, total: regions + fills) },
                    regions: regions, fills: fills, coverage: 0.9, fallback: nil) }
            check("pages with skipped regions or several outside crops assemble in order", shapes.allSatisfy { page in
                let replies = Dictionary(uniqueKeysWithValues: page.requestIDs.enumerated().map {
                    ($1, OCRResult(text: "t\($0)", classification: nil, errorMessage: nil, errorCode: nil)) })
                return page.isExpanded && NewspaperBatch.valid(NewspaperBatch.Manifest(pages: [page]), parts: replies, files: 1)
                    && NewspaperBatch.aggregate(manifest: NewspaperBatch.Manifest(pages: [page]), parts: replies)["file-0"]?.text
                        == page.requestIDs.indices.map { "t\($0)" }.joined(separator: "\n\n")
            })
            parts[ids[1]] = .cutOff
            check("a failed region invalidates the batch page", NewspaperBatch.aggregate(manifest: manifest, parts: parts)["file-0"]?.errorCode == NewspaperBatch.failedRegionCode)
            parts["file-0"] = OCRResult(text: "whole fallback", classification: .documentStart, errorMessage: nil, errorCode: nil)
            check("replayed parts reuse a journaled whole fallback", NewspaperBatch.aggregate(manifest: manifest, parts: parts)["file-0"]?.text == "whole fallback")
            var pending = OCRProcessor.PendingBatch(batchId: "test-job", provider: .gemini, model: LLMModel.geminiModels[0],
                thinkingLevel: nil, fileURLs: [source], outputDirectory: dir, enableTagging: false,
                sendPreviousImage: false, submittedAt: Date(), enableSegmentJSON: true, taggingMode: .none,
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
            check("the unfinished run estimate prices completed regions without a completed file",
                  abs(snapshot.spentSoFar(readSources: []) - 0.02) < 1e-9)
            snapshot.newspaperSpend = completeSpend
            check("completed page history does not add its runtime costs again",
                  abs(snapshot.makeRun(succeeded: 1, layouts: [read.detail.newspaperLayout!]).cost
                      - snapshot.estimatedCost - 0.02) < 1e-9)
            let ledger = SettingsLayerStore(directory: dir.appendingPathComponent("ledger"))
            let runID = UUID()
            let scope = PaidRequests(runID: runID, outputDirectory: dir, store: ledger)
            let region = try scope.admit(provider: .gemini, estimate: 0.02)
            let reopened = SettingsLayerStore(directory: ledger.directory)
            check("an abandoned region remains charged on reopening the scratch ledger",
                  abs(reopened.monthSpend().usd - 0.02) < 1e-9)
            let resumed = PaidRequests(runID: runID, outputDirectory: dir, store: reopened)
            let resumedRegion = try resumed.admit(provider: .gemini, estimate: 0.03)
            resumedRegion.settle(.estimate, amount: 0.03)
            check("Stop then Resume adds the resumed request to the abandoned one",
                  abs(reopened.monthSpend().usd - 0.05) < 1e-9)
            region.settle(.estimate, amount: 0.01)
            region.settle(.estimate, amount: 0.01)
            check("a late region response updates its attempt even after Resume",
                  abs(reopened.monthSpend().usd - 0.04) < 1e-9 && reopened.paidRequestsThisMonth().count == 2)
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
                check("real PP prepares regions from the authored newspaper", realPlan.regionCount > 0 && realPlan.regionImages > 0
                      && realPlan.regionImages <= realPlan.regionCount)
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
