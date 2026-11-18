import Foundation
import VisionOCRKit

/// Batch requests use the same newspaper preparation as synchronous readers. The manifest belongs in the
/// durable PendingBatch before submission: a provider may split one page's regions between several jobs, so a
/// region result is never a completed file by itself. The caller journals every part before consuming a job.
enum NewspaperBatch {
    static let failedRegionCode = "newspaper_region_failed"

    struct Page: Codable, Equatable, Sendable {
        let fileIndex: Int
        /// The exact keys expected: the region crops in native order, then the crops of text outside them.
        let requestIDs: [String]
        /// Region crops read (a region masking left blank is not read), then `fills` outside crops.
        let regions: Int
        let fills: Int
        let coverage: Double?
        let fallback: String?

        var filled: Bool { fills > 0 }
        var isExpanded: Bool { regions + fills > 0 }
    }

    struct Manifest: Codable, Equatable, Sendable {
        var pages: [Page] = []
        var hasExpandedPages: Bool { pages.contains(where: \.isExpanded) }
    }

    struct Prepared: Sendable {
        let requests: [BatchOCRRequest]
        let manifest: Manifest
        /// Only this submission's scratch. Keep it until the clients have finished encoding every request.
        let plans: [NewspaperPagePlan]

        func removeScratch() { plans.forEach { $0.removeScratch() } }
    }

    /// Serial preparation uses the same memory gate as synchronous page reading. Context stays the preceding
    /// original page, including for every crop and the fill; a region is never the next region's previous page.
    static func prepare(fileURLs: [URL], sendPreviousImage: Bool) async throws -> Prepared {
        var requests: [BatchOCRRequest] = []
        var pages: [Page] = []
        var plans: [NewspaperPagePlan] = []
        var success = false
        defer { if !success { plans.forEach { $0.removeScratch() } } }
        for (index, url) in fileURLs.enumerated() {
            try Task.checkCancellation()
            let previous = sendPreviousImage && index > 0 ? fileURLs[index - 1] : nil
            let prepared = try await NewspaperPageReader.preparePage(PageReaderInput(imageURL: url))
            if let plan = prepared.plan {
                plans.append(plan)
                let ids = plan.images.indices.map { regionID(fileIndex: index, regionIndex: $0, total: plan.images.count) }
                requests += zip(plan.images, ids).map {
                    BatchOCRRequest(imageURL: $0.0, customID: $0.1, previousImageURL: previous)
                }
                pages.append(Page(fileIndex: index, requestIDs: ids, regions: plan.regionImages,
                                  fills: plan.fillCount, coverage: plan.coverage, fallback: nil))
            } else {
                let id = "file-\(index)"
                requests.append(BatchOCRRequest(imageURL: url, customID: id, previousImageURL: previous))
                pages.append(Page(fileIndex: index, requestIDs: [id], regions: 0, fills: 0, coverage: nil,
                                  fallback: prepared.fallback))
            }
        }
        try Task.checkCancellation()
        success = true
        return Prepared(requests: requests, manifest: Manifest(pages: pages), plans: plans)
    }

    static func regionID(fileIndex: Int, regionIndex: Int, total: Int) -> String {
        "file-\(fileIndex)-region-\(regionIndex)-of-\(total)"
    }

    /// Strict, anchored ids: no replacing a prefix or parsing `file-1-region-0-of-3` as original file 103.
    static func originalIndex(_ id: String) -> Int? {
        let pieces = id.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0] == "file", let index = nonnegative(pieces[1]) else { return nil }
        return index
    }

    static func parseRegionID(_ id: String) -> (fileIndex: Int, regionIndex: Int, total: Int)? {
        let pieces = id.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 6, pieces[0] == "file", pieces[2] == "region", pieces[4] == "of",
              let file = nonnegative(pieces[1]), let region = nonnegative(pieces[3]),
              let total = nonnegative(pieces[5]), total > 0, region < total else { return nil }
        return (file, region, total)
    }

    private static func nonnegative(_ piece: Substring) -> Int? {
        guard !piece.isEmpty, piece.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let number = Int(piece), number >= 0, String(number) == piece else { return nil }
        return number
    }

    /// The manifest and every partial reply are covered by the batch journal fingerprint and checked before
    /// Resume. Unexpected ids can never become a different file's output.
    static func valid(_ manifest: Manifest?, parts: [String: OCRResult]?, files: Int) -> Bool {
        guard let manifest else { return parts == nil }
        guard manifest.pages.map(\.fileIndex) == Array(0..<files) else { return false }
        var allowed = Set<String>()
        for page in manifest.pages {
            guard page.regions >= 0, page.regions <= NewspaperPagePlan.maximumRegions,
                  page.fills >= 0, page.fills <= NewspaperPagePlan.maximumOutsideCrops,
                  page.coverage.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true else { return false }
            let whole = "file-\(page.fileIndex)"
            if page.isExpanded {
                guard page.requestIDs.count == page.regions + page.fills,
                      page.requestIDs.enumerated().allSatisfy({ i, key in
                          key == regionID(fileIndex: page.fileIndex, regionIndex: i, total: page.requestIDs.count)
                      }) else { return false }
            } else {
                guard page.requestIDs == [whole], !page.filled else { return false }
            }
            allowed.formUnion(page.requestIDs)
            allowed.insert(whole) // a raw fallback retained before PDF materialisation
        }
        return Set((parts ?? [:]).keys).isSubset(of: allowed)
    }

    /// Complete original-file results only. Incomplete pages remain absent until their other job's parts arrive.
    /// A missing text or any failed region fails the whole page: the caller then buys one raw whole-page fallback
    /// at the standard rate, records it separately, and never saves a partial newspaper as successful OCR.
    static func aggregate(manifest: Manifest?, parts: [String: OCRResult]) -> [String: OCRResult] {
        var results = parts.filter { originalIndex($0.key) != nil }
        guard let manifest else { return results }
        for page in manifest.pages {
            let key = "file-\(page.fileIndex)"
            if !page.isExpanded {
                if let reason = page.fallback, var whole = results[key] {
                    whole.newspaperLayout = NewspaperLayoutRecord(regions: 0, requests: 1, coverage: nil,
                                                                 filled: false, fallback: reason)
                    results[key] = whole
                }
                continue
            }
            // A raw fallback the caller already journaled wins over the regions that caused it.
            if results[key] != nil { continue }
            guard page.fileIndex >= 0, page.regions >= 0, page.regions <= NewspaperPagePlan.maximumRegions,
                  page.fills >= 0, page.fills <= NewspaperPagePlan.maximumOutsideCrops,
                  page.requestIDs.count == page.regions + page.fills,
                  !page.requestIDs.isEmpty,
                  page.requestIDs.enumerated().allSatisfy({ offset, id in
                      guard let parsed = parseRegionID(id) else { return false }
                      return parsed.fileIndex == page.fileIndex && parsed.regionIndex == offset
                          && parsed.total == page.requestIDs.count
                  }) else {
                results[key] = failure(page: page, reason: "the saved newspaper region manifest was invalid")
                continue
            }
            let ordered = page.requestIDs.compactMap { parts[$0] }
            guard ordered.count == page.requestIDs.count else { continue }
            if ordered.contains(where: { $0.text == nil || $0.errorCode != nil || $0.errorMessage != nil }) {
                results[key] = failure(page: page, reason: "a newspaper region could not be read")
                continue
            }
            let readings = ordered.map { PageReading(text: $0.text, seconds: 0, detail: $0) }
            results[key] = NewspaperPageReader.combine(readings, regions: page.regions,
                                                      coverage: page.coverage, filled: page.filled).detail
        }
        return results
    }

    private static func failure(page: Page, reason: String) -> OCRResult {
        var result = OCRResult(text: nil, classification: nil, errorMessage: reason, errorCode: failedRegionCode)
        result.newspaperLayout = NewspaperLayoutRecord(regions: page.regions, requests: page.requestIDs.count,
                                                       coverage: page.coverage, filled: page.filled, fallback: reason)
        return result
    }
}
