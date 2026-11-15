import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import VisionOCRKit

/// The fixed layout stage (W46.layout-newspapers). The selected reader reads every region, pictures included,
/// in PP's native order. A failed region replaces the assembled reading with a whole-page reading. Never use
/// textual deduplication: repeated headings and repeated words on a newspaper can both be real.
struct NewspaperPageReader: PageReader {
    /// Set by the run's call boundary, inherited by cascade/refusal readers. It outlives a cancelled read.
    @TaskLocal static var spend: NewspaperReadingSpend?
    @TaskLocal static var hasBasePageAllowance = true
    let client: any PageReader<OCRResult>
    var route: String { client.route }

    static let queue = VisionQueue(name: "ArchiveProcessor.NewspaperLayout", width: 1)

    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        try Task.checkCancellation()
        let prepared = try await Self.preparePage(page)
        guard let plan = prepared.plan else {
            if let reason = prepared.fallback { return try await whole(page, reason: reason) }
            return try await client.read(page)
        }
        defer { plan.removeScratch() }
        return try await readRegions(page, plan: plan)
    }

    static func preparePage(_ page: PageReaderInput) async throws -> (plan: NewspaperPagePlan?, fallback: String?) {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            let prepared = try await Preparation.shared.prepare(page, cancelled: cancelled)
            switch prepared {
            case .whole(let reason): return (nil, reason)
            case .regions(let plan): return (plan, nil)
            }
        } onCancel: { cancelled.cancel() }
    }

    func readRegions(_ page: PageReaderInput, plan: NewspaperPagePlan) async throws -> PageReading<OCRResult> {
            let spendID = UUID()
            var readings: [PageReading<OCRResult>] = []
            var attempts = 0
            for image in plan.images {
                try Task.checkCancellation()
                var crop = page
                crop.imageURL = image
                crop.visionLines = [] // page coordinates do not describe a crop
                let read: PageReading<OCRResult>
                attempts += 1
                do {
                    read = try await client.read(crop)
                } catch {
                    try Task.checkCancellation()
                    return try await whole(page, reason: "a region could not be read", previous: readings, attempts: attempts, spendID: spendID)
                }
                readings.append(read)
                Self.spend?.add(read.dollars ?? 0, id: spendID, source: page.imageURL,
                               baseAllowance: Self.hasBasePageAllowance)
                guard read.detail.text != nil, read.detail.errorCode == nil else {
                    try Task.checkCancellation()
                    return try await whole(page, reason: "a region could not be read", previous: readings, attempts: attempts, spendID: spendID)
                }
            }
            var combined = Self.combine(readings, regions: plan.regionCount, coverage: plan.coverage, filled: plan.hasFill)
            combined.detail.newspaperLayout?.spendIDs = [spendID]
            return combined
    }

    private enum Prepared: Sendable { case whole(String?), regions(NewspaperPagePlan) }

    /// Classification itself holds an upright page and its grey copy. Serialize it as well as detection, including
    /// across async Vision calls; an HTTP-worker-sized set of those copies can exhaust a small Mac.
    private actor Preparation {
        static let shared = Preparation()
        private var busy = false
        func prepare(_ page: PageReaderInput, cancelled: CancellationFlag) async throws -> Prepared {
            while busy { try await Task.sleep(for: .milliseconds(50)) }
            try Task.checkCancellation()
            busy = true
            defer { busy = false }
            guard let source = CGImageSourceCreateWithURL(page.imageURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Double,
                  let height = props[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0, width * height <= 80_000_000 else {
                return .whole(nil)
            }
            let kind = await PageKindClassifier.classify(url: page.imageURL)
            try Task.checkCancellation()
            guard NewspaperPagePlan.usesRegions(kind) else { return .whole(nil) }
            guard NewspaperLayout.isInstalled() else {
                return .whole("download the newspaper layout helper in Settings, Columns and reading order")
            }
            do {
                let plan = try await NewspaperPageReader.queue.run {
                    try NewspaperPagePlan.prepare(page.imageURL, photographed: kind?.photographed == true,
                                                  isCancelled: { cancelled.isCancelled })
                }
                if Task.isCancelled { plan.removeScratch(); throw CancellationError() }
                return .regions(plan)
            } catch {
                try Task.checkCancellation()
                return .whole("the layout helper could not prepare the page")
            }
        }
    }

    private func whole(_ page: PageReaderInput, reason: String,
                       previous: [PageReading<OCRResult>] = [], attempts: Int = 0,
                       spendID: UUID = UUID()) async throws -> PageReading<OCRResult> {
        try Task.checkCancellation()
        var read = try await client.read(page)
        Self.spend?.add(read.dollars ?? 0, id: spendID, source: page.imageURL,
                       baseAllowance: Self.hasBasePageAllowance)
        read.seconds += previous.reduce(0) { $0 + $1.seconds }
        if let dollars = read.dollars { read.dollars = dollars + previous.compactMap(\.dollars).reduce(0, +) }
        read.detail.newspaperLayout = NewspaperLayoutRecord(regions: 0, requests: attempts + 1,
                                                          coverage: nil, filled: false, fallback: reason,
                                                          estimatedExtraCost: previous.compactMap(\.dollars).reduce(0, +),
                                                          standardFallbackCost: previous.compactMap(\.dollars).reduce(0, +))
        read.detail.newspaperLayout?.spendIDs = [spendID]
        return read
    }

    static func combine(_ readings: [PageReading<OCRResult>], regions: Int, coverage: Double?, filled: Bool)
        -> PageReading<OCRResult> {
        let first = readings.first?.detail
        let text = readings.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        var result = OCRResult(text: text, classification: first?.classification, rotationDegrees: first?.rotationDegrees ?? 0,
                               errorMessage: nil, errorCode: nil, enclosure: first?.enclosure)
        result.newspaperLayout = NewspaperLayoutRecord(regions: regions, requests: readings.count,
                                                      coverage: coverage, filled: filled, fallback: nil,
                                                      estimatedExtraCost: readings.dropFirst().compactMap(\.dollars).reduce(0, +),
                                                      standardFallbackCost: readings.dropFirst().compactMap(\.dollars).reduce(0, +))
        return PageReading(text: text, seconds: readings.reduce(0) { $0 + $1.seconds },
                           dollars: readings.contains { $0.dollars != nil }
                               ? readings.compactMap(\.dollars).reduce(0, +) : nil, detail: result)
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }
}

struct NewspaperLayoutRecord: Codable, Equatable, Sendable {
    let regions: Int
    let requests: Int
    let coverage: Double?
    let filled: Bool
    let fallback: String?
    var estimatedExtraCost: Double? = nil
    /// Standard-rate requests beyond an original batch reserve: a raw fallback and any later region reads.
    var standardFallbackCost: Double? = nil
    /// Matches this result to the runtime cost accumulator, so successful results are counted only once.
    var spendIDs: [UUID]? = nil

    /// The first route may have bought several successful regions before it failed. A second reader replaces
    /// its text, never its incurred request count or estimate. Its own one-page charge is counted separately.
    static func combining(_ current: Self?, after previous: Self?) -> Self? {
        guard let previous else { return current }
        guard var current else { return previous }
        current.estimatedExtraCost = (current.estimatedExtraCost ?? 0) + (previous.estimatedExtraCost ?? 0)
        current.standardFallbackCost = (current.standardFallbackCost ?? 0) + (previous.standardFallbackCost ?? 0)
        return Self(regions: current.regions, requests: current.requests + previous.requests,
                    coverage: current.coverage, filled: current.filled, fallback: current.fallback,
                    estimatedExtraCost: current.estimatedExtraCost, standardFallbackCost: current.standardFallbackCost,
                    spendIDs: (previous.spendIDs ?? []) + (current.spendIDs ?? []))
    }

    var summary: String {
        if let fallback { return "Whole page: \(fallback)." }
        return "\(regions) newspaper regions in reading order" + (filled ? ", plus text outside them." : ".")
    }
}

/// Completed readings remain billable if Stop or a throwing fallback prevents the page result returning.
/// Only a run owns this accumulator; it never looks at current controller state or another run's ledger ID.
final class NewspaperReadingSpend: @unchecked Sendable {
    /// Legacy runs without a persisted settings ID still need an idempotent identity during Stop's two updates.
    let parentLedgerID = UUID()
    private struct Reading {
        let source: URL
        let first: Double
        let sequence: Int
        var total: Double
    }
    private let lock = NSLock()
    private var readings: [UUID: Reading] = [:]

    func add(_ dollars: Double, id: UUID, source: URL, baseAllowance: Bool = true) {
        guard dollars.isFinite, dollars >= 0 else { return }
        lock.withLock {
            if readings[id] == nil {
                readings[id] = Reading(source: source, first: baseAllowance ? dollars : 0, sequence: readings.count, total: 0)
            }
            readings[id]?.total += dollars
        }
    }

    /// Add only calls missing from the returned page records. A completed record consumes that source's base
    /// page allowance. Otherwise subtract the first call once when the normal estimate already prices it.
    /// nil baseSources means the final estimate prices every original page; a partial run names its read pages.
    func unreported(layouts: [NewspaperLayoutRecord], baseSources: Set<URL>?, allPDFPagesRead: Bool = false) -> Double {
        unreportedCharges(layouts: layouts, baseSources: baseSources, allPDFPagesRead: allPDFPagesRead).values.reduce(0, +)
    }

    func unreportedCharges(layouts: [NewspaperLayoutRecord], baseSources: Set<URL>?,
                           allPDFPagesRead: Bool = false) -> [UUID: Double] {
        let reported = Set(layouts.flatMap { $0.spendIDs ?? [] })
        return lock.withLock {
            var consumed = Set(reported.compactMap { readings[$0]?.source })
            var charges: [UUID: Double] = [:]
            for (id, read) in readings.sorted(by: { $0.value.sequence < $1.value.sequence }) where !reported.contains(id) {
                let hasBase = baseSources == nil || baseSources!.contains(read.source) || allPDFPagesRead
                let subtract = hasBase && consumed.insert(read.source).inserted ? read.first : 0
                charges[id] = max(0, read.total - subtract)
            }
            return charges
        }
    }
}

/// All scratch belongs to this one reading. The source is opened read-only. Preparation is serialized, so a
/// full-size image, Vision and the 794 MB detector never multiply by the run's network-worker count.
struct NewspaperPagePlan: Sendable {
    static let coverageFloor = 0.95
    static let padding = 0.004
    static let maximumRegions = 128
    let directory: URL
    let images: [URL]
    let regionCount: Int
    let coverage: Double?
    let hasFill: Bool

    static func usesRegions(_ kind: PageKind?) -> Bool {
        kind?.kind == .newspapers && (kind?.confidence ?? 0) >= PageKindRouting.minimumConfidence
    }

    func removeScratch() { try? FileManager.default.removeItem(at: directory) }

    enum Failure: Error { case image, geometry, regions, cancelled }

    static func prepare(_ url: URL, photographed: Bool, isCancelled: () -> Bool) throws -> Self {
        guard !isCancelled() else { throw Failure.cancelled }
        guard let upright = PageKindClassifier.loadImage(url) else { throw Failure.image }
        let image: CGImage
        if photographed {
            guard let corrected = quad(upright) else { throw Failure.geometry }
            image = corrected
        } else { image = upright }
        let regions = try NewspaperLayout.detect(image: image, isCancelled: isCancelled)
        guard !regions.isEmpty, regions.count <= maximumRegions else { throw Failure.regions }
        let rawBoxes = regions.compactMap { pixelBox($0.box, width: image.width, height: image.height) }
        guard rawBoxes.count == regions.count else { throw Failure.regions }
        // Retain every class. A box wholly covered by earlier boxes adds no pixels; omit only that redundant
        // read. Partly overlapping boxes are read with the earlier boxes whitened, so pixels have one owner.
        var boxes: [CGRect] = []
        for box in rawBoxes where unionArea(boxes.map { box.intersection($0) }) < box.width * box.height - 0.5 {
            boxes.append(box)
        }
        let vision = TextLayer.visionLines(of: image)?.lines.map(\.box) ?? []
        let normalized = boxes.map { CGRect(x: $0.minX / Double(image.width), y: $0.minY / Double(image.height),
                                            width: $0.width / Double(image.width), height: $0.height / Double(image.height)) }
        let coverage = coverage(lines: vision, crops: normalized)
        let boundaries = boundaryLines(vision, crops: normalized)
        let fill = coverage == nil || coverage! < coverageFloor || !boundaries.isEmpty
        // A line crossing the crop union must reach one reader intact. On fill pages move those complete
        // line rectangles into the fill, whitening them in every region. Include any intersecting Vision line
        // transitively, so restoring one box cannot duplicate characters from another overlapping line.
        let fillLines = boundaries
        let fillPixels = fillLines.map { r in
            CGRect(x: r.minX * Double(image.width), y: r.minY * Double(image.height),
                   width: r.width * Double(image.width), height: r.height * Double(image.height)).integral
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ap-newspaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: dir) } }
        var images: [URL] = []
        for (i, box) in boxes.enumerated() {
            guard !isCancelled() else { throw Failure.cancelled }
            guard let cut = image.cropping(to: box) else { throw Failure.image }
            let erase = (fillPixels + Array(boxes.prefix(i))).compactMap { r -> CGRect? in
                let overlap = r.intersection(box)
                return overlap.isNull ? nil : overlap.offsetBy(dx: -box.minX, dy: -box.minY)
            }
            guard let crop = erase.isEmpty ? cut : masked(cut, boxes: erase) else { throw Failure.image }
            let target = dir.appendingPathComponent("region-\(i).png")
            try write(crop, to: target)
            images.append(target)
        }
        if fill {
            // Whole-page geometry, only unowned pixels: reading the original again and concatenating it would
            // repeat every region. Covered rectangles are whitened, never textually subtracted afterwards.
            guard let masked = masked(image, boxes: boxes, restore: fillPixels) else { throw Failure.image }
            let target = dir.appendingPathComponent("outside-regions.png")
            try write(masked, to: target)
            images.append(target)
        }
        success = true
        return Self(directory: dir, images: images, regionCount: boxes.count, coverage: coverage, hasFill: fill)
    }

    /// Benchmark crop geometry: 0.004 of each page dimension, ties-to-even, clipped, at least 32 px a side.
    static func pixelBox(_ box: CGRect, width: Int, height: Int) -> CGRect? {
        var x0 = max(0, ((box.minX - padding) * Double(width)).rounded(.toNearestOrEven))
        var y0 = max(0, ((box.minY - padding) * Double(height)).rounded(.toNearestOrEven))
        var x1 = min(Double(width), ((box.maxX + padding) * Double(width)).rounded(.toNearestOrEven))
        var y1 = min(Double(height), ((box.maxY + padding) * Double(height)).rounded(.toNearestOrEven))
        if x1 - x0 < 32 {
            x0 = max(0, ((x0 + x1) / 2 - 16).rounded(.toNearestOrEven)); x1 = min(Double(width), x0 + 32)
            x0 = max(0, x1 - 32)
        }
        if y1 - y0 < 32 {
            y0 = max(0, ((y0 + y1) / 2 - 16).rounded(.toNearestOrEven)); y1 = min(Double(height), y0 + 32)
            y0 = max(0, y1 - 32)
        }
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Vision line-box coverage, not dark-pixel ink and not OCR accuracy. Exact rectangle unions avoid counting
    /// overlapping lines twice. The 95% engineering floor fills 7/15 cached L9 pages; sensitivity is recorded in
    /// segbench-results/layout-coverage-fallback.md. No Vision lines means an unconditional fill.
    static func coverage(lines: [CGRect], crops: [CGRect]) -> Double? {
        let total = unionArea(lines)
        guard total > 0 else { return nil }
        return min(1, unionArea(lines.flatMap { line in crops.map { line.intersection($0) } }) / total)
    }

    static func unionArea(_ rectangles: [CGRect]) -> Double {
        let boxes = rectangles.filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
        let xs = Array(Set(boxes.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xs.count > 1 else { return 0 }
        var area = 0.0
        for i in 1..<xs.count {
            let a = xs[i - 1], b = xs[i]
            let ys = boxes.filter { $0.minX < b && $0.maxX > a }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var top = 0.0, bottom = 0.0, span = 0.0
            for (lo, hi) in ys {
                if lo > bottom { span += bottom - top; top = lo; bottom = hi }
                else { bottom = max(bottom, hi) }
            }
            area += (b - a) * (span + bottom - top)
        }
        return area
    }

    static func boundaryLines(_ lines: [CGRect], crops: [CGRect]) -> [CGRect] {
        var selected = Set(lines.indices.filter { i in
            // The first intersecting crop owns the pixels. Union coverage alone misses a line divided
            // between two adjacent or overlapping crops even when their union covers every character.
            guard let first = crops.first(where: {
                let hit = lines[i].intersection($0)
                return !hit.isNull && hit.width * hit.height > 1e-12
            }) else { return false }
            let hit = lines[i].intersection(first)
            return hit.width * hit.height < lines[i].width * lines[i].height - 1e-12
        })
        var previous = -1
        while previous != selected.count {
            previous = selected.count
            for i in lines.indices where !selected.contains(i) {
                if selected.contains(where: { !lines[i].intersection(lines[$0]).isNull
                    && lines[i].intersection(lines[$0]).width * lines[i].intersection(lines[$0]).height > 0 }) {
                    selected.insert(i)
                }
            }
        }
        return selected.sorted().map { lines[$0] }
    }

    static func masked(_ image: CGImage, boxes: [CGRect], restore: [CGRect] = []) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for r in boxes { ctx.fill(CGRect(x: r.minX, y: Double(image.height) - r.maxY, width: r.width, height: r.height)) }
        for r in restore {
            guard let crop = image.cropping(to: r) else { return nil }
            ctx.draw(crop, in: CGRect(x: r.minX, y: Double(image.height) - r.maxY, width: r.width, height: r.height))
        }
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.image
        }
        CGImageDestinationAddImage(dst, image, nil)
        guard CGImageDestinationFinalize(dst) else { throw Failure.image }
    }

    static func quad(_ image: CGImage) -> CGImage? {
        let request = VNDetectDocumentSegmentationRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let r = request.results?.first, r.confidence >= 0.5 else { return nil }
        let w = Double(image.width), h = Double(image.height)
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        let corrected = CIImage(cgImage: image).applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(r.topLeft), "inputTopRight": point(r.topRight),
            "inputBottomLeft": point(r.bottomLeft), "inputBottomRight": point(r.bottomRight)])
        guard corrected.extent.width > 0, corrected.extent.height > 0,
              corrected.extent.width * corrected.extent.height <= w * h * 2 else { return nil }
        return CIContext().createCGImage(corrected, from: corrected.extent)
    }
}
