import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import VisionOCRKit

/// Which detector finds a newspaper page's regions (W47.wh-yolo-scans). PP-DocLayoutV3 is the default and the only
/// one measured after the quad on photographs; DocLayout-YOLO through newspaper-ocr's route is the user's choice for
/// scanned newspapers (owner, 2026-11-19, call 15), measured 4.6 points above it on 15 L9 scans.
enum NewspaperDetector: String, Sendable, Equatable {
    case ppDocLayoutV3, docLayoutYOLO

    /// A frozen settings snapshot's choice for scanned newspapers; the built-in default without one.
    static func scans(_ values: [String: ResolvedSetting]?) -> Self {
        values?[SettingsKey.scanNewspapersDocLayoutYOLO.rawValue]?.value.bool == true ? .docLayoutYOLO : .ppDocLayoutV3
    }

    /// The detector a page gets: a photograph always PP-DocLayoutV3; a scan the run's choice, or PP-DocLayoutV3 while
    /// the chosen detector is not downloaded (what the switch's note says).
    static func forPage(photographed: Bool, scans: Self,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        guard !photographed, scans == .docLayoutYOLO, ScanNewspaperLayout.isInstalled(environment) else { return .ppDocLayoutV3 }
        return .docLayoutYOLO
    }

    func isInstalled() -> Bool {
        switch self {
        case .ppDocLayoutV3: return NewspaperLayout.isInstalled()
        case .docLayoutYOLO: return ScanNewspaperLayout.isInstalled()
        }
    }

    func detect(_ image: CGImage, isCancelled: () -> Bool) throws -> [NewspaperLayout.Region] {
        switch self {
        case .ppDocLayoutV3: return try NewspaperLayout.detect(image: image, isCancelled: isCancelled)
        case .docLayoutYOLO: return try ScanNewspaperLayout.detect(image: image, isCancelled: isCancelled)
        }
    }
}

/// The fixed layout stage (W46.layout-newspapers). The selected reader reads every region, pictures included,
/// in PP's native order. A failed region replaces the assembled reading with a whole-page reading. Never use
/// textual deduplication: repeated headings and repeated words on a newspaper can both be real.
struct NewspaperPageReader: PageReader {
    /// Set by the run's call boundary, inherited by cascade/refusal readers. It outlives a cancelled read.
    @TaskLocal static var spend: NewspaperReadingSpend?
    @TaskLocal static var hasBasePageAllowance = true
    /// The run's detector for scanned newspapers (W47.wh-yolo-scans), set at the same call boundary from its frozen
    /// settings (`NewspaperDetector.scans(_:)`). Photographed newspapers always use PP-DocLayoutV3.
    @TaskLocal static var scanDetector: NewspaperDetector = .ppDocLayoutV3
    let client: any PageReader<OCRResult>
    var estimatedPrice: (@Sendable (PageReaderInput) -> Double)? = nil
    var route: String { client.route }

    static let queue = VisionQueue(name: "ArchiveProcessor.NewspaperLayout", width: 1)

    /// Readers that read a newspaper page whole, with no detector (W47.wh-whole-page-large; owner, 2026-11-19, call
    /// 15). Qwen3.6 27B scored 0.967 whole against 0.965 on DocLayout-YOLO's raw regions on the 15 L9 scans
    /// (NewsBench overall, E-layout.md claim 34): a tie, and one whole-page request is faster and cheaper than one per
    /// region, so the tie goes to the whole page. Measured on raw regions, not the app's partition. No other reader has
    /// that tie measured, so every other one keeps the detector (call 5).
    static let wholePageReaderIDs: Set<String> = ["qwen/qwen3.6-27b"]

    static func readsWhole(modelID: String) -> Bool { wholePageReaderIDs.contains(modelID) }

    func read(_ page: PageReaderInput) async throws -> PageReading<OCRResult> {
        try Task.checkCancellation()
        let prepared = try await Self.preparePage(page)
        guard let plan = prepared.plan else {
            if let reason = prepared.fallback { return try await whole(page, reason: reason) }
            return try await client.read(page)
        }
        defer { plan.removeScratch() }
        // Use the original whole-page allowance if the complete region plan cannot fit.
        if let price = estimatedPrice, plan.images.count > 1,
           await Self.spend?.allowsExtra(Double(plan.images.count - 1) * price(page)) == false {
            return try await whole(page, reason: "the monthly spending limit did not allow the region reads")
        }
        return try await readRegions(page, plan: plan)
    }

    static func preparePage(_ page: PageReaderInput) async throws -> (plan: NewspaperPagePlan?, fallback: String?) {
        let cancelled = CancellationFlag()
        let scans = scanDetector
        return try await withTaskCancellationHandler {
            let prepared = try await Preparation.shared.prepare(page, scans: scans, cancelled: cancelled)
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
            var combined = Self.combine(readings, regions: plan.regionImages, coverage: plan.coverage, filled: plan.hasFill)
            combined.detail.newspaperLayout?.spendIDs = [spendID]
            return combined
    }

    private enum Prepared: Sendable { case whole(String?), regions(NewspaperPagePlan) }

    /// Classification itself holds an upright page and its grey copy. Serialize it as well as detection, including
    /// across async Vision calls; an HTTP-worker-sized set of those copies can exhaust a small Mac.
    private actor Preparation {
        static let shared = Preparation()
        private var busy = false
        func prepare(_ page: PageReaderInput, scans: NewspaperDetector, cancelled: CancellationFlag) async throws -> Prepared {
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
            let detector = NewspaperDetector.forPage(photographed: kind?.photographed == true, scans: scans)
            guard detector.isInstalled() else {
                return .whole("download the newspaper layout helper in Settings, Columns and reading order")
            }
            do {
                let plan = try await NewspaperPageReader.queue.run {
                    try NewspaperPagePlan.prepare(page.imageURL, photographed: kind?.photographed == true,
                                                  detector: detector, isCancelled: { cancelled.isCancelled })
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
        if attempts > 0, let price = estimatedPrice, await Self.spend?.allowsExtra(price(page)) == false {
            throw ProcessFilesMonthlySpend.ReadingDeclined()
        }
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
    @MainActor var monthlyAdmission: (@MainActor (Double?) -> Bool)?
    @MainActor var hasMonthlyLimit: Bool { monthlyAdmission != nil }

    @MainActor func allowsExtra(_ price: Double?) -> Bool {
        price == 0 || (monthlyAdmission?(price) ?? true)
    }

    private struct Reading {
        let source: URL
        let first: Double?
        let sequence: Int
        var total: Double
    }
    private let lock = NSLock()
    private var readings: [UUID: Reading] = [:]

    func add(_ dollars: Double, id: UUID, source: URL, baseAllowance: Bool = true) {
        guard dollars.isFinite, dollars >= 0 else { return }
        lock.withLock {
            if readings[id] == nil {
                readings[id] = Reading(source: source, first: baseAllowance ? dollars : nil, sequence: readings.count, total: 0)
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
                let subtract: Double
                if let first = read.first, hasBase, consumed.insert(read.source).inserted {
                    subtract = first
                } else {
                    subtract = 0
                }
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
    /// The region crops read, in native order, then `fillCount` crops of text outside every region.
    let images: [URL]
    /// Regions detected and kept; a region whose crop masking left blank is among them but not read.
    let regionCount: Int
    let coverage: Double?
    let fillCount: Int

    var hasFill: Bool { fillCount > 0 }
    var regionImages: Int { images.count - fillCount }

    static func usesRegions(_ kind: PageKind?) -> Bool {
        kind?.kind == .newspapers && (kind?.confidence ?? 0) >= PageKindRouting.minimumConfidence
    }

    func removeScratch() { try? FileManager.default.removeItem(at: directory) }

    enum Failure: Error { case image, geometry, regions, cancelled }

    static func prepare(_ url: URL, photographed: Bool, detector: NewspaperDetector = .ppDocLayoutV3,
                        isCancelled: () -> Bool) throws -> Self {
        guard !isCancelled() else { throw Failure.cancelled }
        guard let upright = PageKindClassifier.loadImage(url) else { throw Failure.image }
        let image: CGImage
        if photographed {
            guard let corrected = quad(upright) else { throw Failure.geometry }
            image = corrected
        } else { image = upright }
        let regions = try detector.detect(image, isCancelled: isCancelled)
        guard !regions.isEmpty, regions.count <= maximumRegions else { throw Failure.regions }
        let rawBoxes = regions.compactMap { pixelBox($0.box, width: image.width, height: image.height) }
        guard rawBoxes.count == regions.count else { throw Failure.regions }
        // Retain every class. A box wholly covered by earlier boxes adds no pixels; omit only that redundant
        // read. Partly overlapping boxes are read with the earlier boxes whitened, so pixels have one owner.
        var boxes: [CGRect] = []
        for box in rawBoxes where unionArea(boxes.map { box.intersection($0) }) < box.width * box.height - 0.5 {
            boxes.append(box)
        }
        let page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let vision = TextLayer.visionLines(of: image)?.lines ?? []
        let normalized = boxes.map { CGRect(x: $0.minX / Double(image.width), y: $0.minY / Double(image.height),
                                            width: $0.width / Double(image.width), height: $0.height / Double(image.height)) }
        let coverage = coverage(lines: vision.map(\.box), crops: normalized)
        let lines = vision.map { l in
            CGRect(x: l.box.minX * Double(image.width), y: l.box.minY * Double(image.height),
                   width: l.box.width * Double(image.width), height: l.box.height * Double(image.height))
                .integral.intersection(page)
        }
        // W46.layout-partition-fix: every Vision line is read once, whole, by the region holding most of it.
        // A line is never moved out of its region, and owning one never pulls in its neighbours.
        let owners = owners(of: lines, boxes: boxes)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ap-newspaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: dir) } }
        var images: [URL] = []
        for (i, box) in boxes.enumerated() {
            guard !isCancelled() else { throw Failure.cancelled }
            let owned = lines.indices.filter { owners[$0] == i }.map { lines[$0] }
            let others = lines.indices.filter { owners[$0] != i }.map { lines[$0] }
            // Earlier regions own their overlap pixels; the region's own lines are restored over them whole,
            // and lines another reader owns are whitened. A crop widens only to hold its own lines.
            let frame = owned.reduce(box) { $0.union($1) }.intersection(page)
            // Where two lines' rectangles overlap across owners, the earlier region keeps the shared pixels.
            let earlier = lines.indices.filter { owners[$0].map { $0 < i } ?? false }.map { lines[$0] }
            guard let crop = compose(image, frame: frame, keep: [box], erase: Array(boxes.prefix(i)) + others,
                                     restore: owned, trim: overlaps(owned, earlier)) else { throw Failure.image }
            // Masking can leave a crop with nothing on it, and a reader invents text on a blank image.
            if owned.isEmpty && !hasInk(crop) { continue }
            let target = dir.appendingPathComponent("region-\(i).png")
            try write(crop, to: target)
            images.append(target)
        }
        var fill = 0
        if vision.isEmpty {
            // No Vision geometry to place: whole-page geometry, only the pixels no region owns. Covered rectangles
            // are whitened, never textually subtracted afterwards.
            // Not ink-checked: a few lines of text are a tiny share of a whole page.
            guard let masked = masked(image, boxes: boxes) else { throw Failure.image }
            let target = dir.appendingPathComponent("outside-regions.png")
            try write(masked, to: target)
            images.append(target)
            fill = 1
        } else {
            // Lines no region touches, read as small crops of their own lines on white, never a whole-page image.
            let leftover = lines.indices.filter { owners[$0] == nil && !lines[$0].isNull && lines[$0].width * lines[$0].height > 0 }
            let margin = padding * Double(max(image.width, image.height))
            for (n, group) in groups(leftover.map { lines[$0] }).enumerated() {
                guard !isCancelled() else { throw Failure.cancelled }
                let members = group.map { leftover[$0] }
                guard members.reduce(0, { $0 + vision[$1].text.filter { $0.isLetter || $0.isNumber }.count }) >= 3 else { continue }
                let held = members.map { lines[$0] }
                let frame = held.dropFirst().reduce(held[0]) { $0.union($1) }.insetBy(dx: -margin, dy: -margin)
                    .integral.intersection(page)
                let read = lines.indices.filter { owners[$0] != nil }.map { lines[$0] }
                guard let crop = compose(image, frame: frame, keep: [], erase: [], restore: held,
                                         trim: overlaps(held, read)) else { throw Failure.image }
                let target = dir.appendingPathComponent("outside-\(n).png")
                try write(crop, to: target)
                images.append(target)
                fill += 1
            }
        }
        guard !images.isEmpty else { throw Failure.regions }
        success = true
        return Self(directory: dir, images: images, regionCount: boxes.count, coverage: coverage, fillCount: fill)
    }

    /// The region that reads each line: the one with most of the line's pixels it owns (earlier regions own an
    /// overlap), the earlier on a tie; nil for a line no region touches. Pixel rectangles, page coordinates.
    static func owners(of lines: [CGRect], boxes: [CGRect]) -> [Int?] {
        lines.map { line in
            var best: (index: Int, area: Double)?
            for (k, box) in boxes.enumerated() {
                let hit = line.intersection(box)
                guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }
                let owned = hit.width * hit.height - unionArea(boxes.prefix(k).map { hit.intersection($0) })
                if owned > 1e-9, owned > (best?.area ?? 0) { best = (k, owned) }
            }
            return best?.index
        }
    }

    static let maximumOutsideCrops = 32

    /// Leftover lines grouped into column-like runs: lines that overlap across and sit within a line height of
    /// each other, transitively, in reading order (top first, then left). Past `maximumOutsideCrops` groups the
    /// lines are read together as one group, still cut to their own extent.
    static func groups(_ lines: [CGRect]) -> [[Int]] {
        var parent = Array(lines.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { i = parent[i] }; return i }
        for i in lines.indices {
            for j in lines.indices where j > i {
                let a = lines[i], b = lines[j]
                let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                if min(a.maxX, b.maxX) > max(a.minX, b.minX), gap <= max(a.height, b.height) {
                    let (ri, rj) = (root(i), root(j))
                    if ri != rj { parent[rj] = ri }
                }
            }
        }
        let grouped = Dictionary(grouping: lines.indices, by: root).values.map { $0.sorted() }
        guard grouped.count <= maximumOutsideCrops else { return lines.isEmpty ? [] : [Array(lines.indices)] }
        func top(_ g: [Int]) -> (Double, Double) { (g.map { lines[$0].minY }.min()!, g.map { lines[$0].minX }.min()!) }
        return grouped.sorted { top($0) < top($1) }
    }

    /// Every non-empty intersection of a rectangle in `a` with one in `b`.
    static func overlaps(_ a: [CGRect], _ b: [CGRect]) -> [CGRect] {
        a.flatMap { r in b.map { r.intersection($0) } }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    /// A crop of `frame` on white: `keep` rectangles copied from the page, then `erase` whitened, then `restore`
    /// copied again, then `trim` whitened. Integral page-pixel rectangles; what lies outside `frame` is ignored.
    static func compose(_ image: CGImage, frame: CGRect, keep: [CGRect], erase: [CGRect], restore: [CGRect],
                        trim: [CGRect] = []) -> CGImage? {
        let f = frame.integral
        guard f.width >= 1, f.height >= 1,
              let ctx = CGContext(data: nil, width: Int(f.width), height: Int(f.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: f.width, height: f.height))
        func local(_ r: CGRect) -> CGRect? {
            let clip = r.intersection(f)
            guard !clip.isNull, clip.width > 0, clip.height > 0 else { return nil }
            return clip
        }
        func place(_ r: CGRect) -> CGRect { CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height) }
        func copy(_ rects: [CGRect]) -> Bool {
            for r in rects.compactMap(local) {
                guard let piece = image.cropping(to: r) else { return false }
                ctx.draw(piece, in: place(r))
            }
            return true
        }
        guard copy(keep) else { return nil }
        for r in erase.compactMap(local) { ctx.fill(place(r)) }
        guard copy(restore) else { return nil }
        for r in trim.compactMap(local) { ctx.fill(place(r)) }
        return ctx.makeImage()
    }

    /// Whether a crop carries any mark: at least 0.3% of its pixels darker than 160/255, sampled (nearest
    /// neighbour, never averaged, so thin strokes keep their darkness) at 512 px at most. A picture or a column of
    /// text passes easily; a crop masked down to slivers does not.
    static func hasInk(_ image: CGImage) -> Bool {
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return true }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return true }
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        let dark = (0..<(w * h)).reduce(0) { $0 + (pixels[$1] < 160 ? 1 : 0) }
        return Double(dark) >= 0.003 * Double(w * h)
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
