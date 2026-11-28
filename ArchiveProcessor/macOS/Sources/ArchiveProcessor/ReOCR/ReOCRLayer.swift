import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import VisionOCRKit

/// A transparent text-only PDF in the coordinates of the scan as displayed. Its transform maps those coordinates
/// back to the original page, so the writer can leave the original page and every visible object in place.
struct ReOCRLayer: Sendable {
    let pdf: Data
    let intoPage: CGAffineTransform
    let reading: String

    @concurrent
    static func make(from original: Data, pageIndex: Int, reading: String, required: Bool, scratch: URL,
                     placement: TextLayerRule.Decision = .place(requireAligned: true)) async throws -> Self? {
        if !required, case .textPage = placement { return nil }
        try Task.checkCancellation()
        guard let doc = ReOCRPreservationCheck.document(original), let page = doc.page(at: pageIndex + 1) else {
            if required { throw ReOCRPairs.Refusal.layerNotMade(page: pageIndex) }
            return nil
        }
        defer { withExtendedLifetime(doc) {} }
        let size = ReOCRJob.displaySize(page)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            if required { throw ReOCRPairs.Refusal.layerNotMade(page: pageIndex) }
            return nil
        }
        var box = CGRect(origin: .zero, size: size)
        let transform = page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true)
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let image: CGImage?
        let frame: CGRect
        if let jpeg = ReOCRJob.embeddedJPEGWithBounds(original, pageIndex: pageIndex),
           let source = CGImageSourceCreateWithData(jpeg.data as CFData, nil) {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            let imageBox = jpeg.bounds.applying(transform)
            frame = CGRect(x: imageBox.minX / size.width, y: 1 - imageBox.maxY / size.height,
                           width: imageBox.width / size.width, height: imageBox.height / size.height)
        } else {
            image = ReOCRJob.renderedImage(page)
            frame = fullFrame
        }
        let blank = scratch.appendingPathComponent(UUID().uuidString + ".pdf")
        let layer = scratch.appendingPathComponent(UUID().uuidString + ".pdf")
        defer {
            try? FileManager.default.removeItem(at: blank)
            try? FileManager.default.removeItem(at: layer)
        }
        guard let context = CGContext(blank as CFURL, mediaBox: &box, nil) else {
            if required { throw ReOCRPairs.Refusal.layerNotMade(page: pageIndex) }
            return nil
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()

        func write(_ lines: TextLayer.Lines, frame: CGRect, checkReadingOrder: Bool = false) -> Self? {
            guard !lines.isEmpty,
                  let missed = try? TextLayer.write(imagePage: blank, lines: lines, imageFrame: frame, to: layer),
                  let data = try? Data(contentsOf: layer),
                  let text = PDFDocument(data: data)?.page(at: 0)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if checkReadingOrder && (missed != 0 || !TextLayerRule.preservesReadingOrder(reading, placed: text)) { return nil }
            if required && (missed != 0 || !OutputForm.holds(text, every: reading)) { return nil }
            return Self(pdf: data, intoPage: transform.inverted(), reading: required ? reading : text)
        }

        if let image {
            switch placement {
            case .place(let requireAligned):
                if let vision = TextLayer.visionLines(of: image) {
                    let aligned = TextLayer.aligned(vision, reading: reading, aspect: Double(image.height) / Double(image.width))
                    if aligned.placement == .aligned || (!required && !requireAligned),
                       let made = write(aligned, frame: frame) { return made }
                }
            case .placeHands:
                if let hands = try? await LocalModelSupervisor.serving.withExternalModel(named: "hand-placer", { cancelled in
                    try HandPlacer.place(image: image, reading: reading, isCancelled: cancelled)
                }),
                   TextLayerRule.handPlacementRefusal(hands, reading: reading) == nil,
                   let made = write(hands.lines, frame: frame, checkReadingOrder: true) { return made }
            case .textPage:
                break
            }
        }
        // Where full placement is unavailable, the accepted reading still replaces existing search text.
        // On a pair with no existing layer, leave the transcription on its separate text page.
        guard required else { return nil }
        try Task.checkCancellation()
        let lines = TextLayer.lines(OutputForm.unplacedLines(reading))
        guard let made = write(lines, frame: fullFrame) else { throw ReOCRPairs.Refusal.layerNotMade(page: pageIndex) }
        return made
    }
}
