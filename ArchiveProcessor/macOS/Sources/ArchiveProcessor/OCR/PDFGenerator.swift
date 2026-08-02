import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO

struct PDFGenerator {

    /// W23.h5 — what the written PDF's **image page** actually contains. `generate` succeeds either way (the
    /// 2-page archival contract and `PDFTextExtractor`'s `pageCount >= 2` heuristic are preserved on purpose),
    /// so a caller that only checks "did it throw / does the file exist" cannot tell the two apart. It must:
    /// the placeholder PDF holds **no scan**, which means the source image is still the ONLY copy of the page.
    /// Any caller that retires a source on success (Live Capture finalize) MUST keep the source when this is
    /// `.placeholder`. The bytes are real and the file still counts as filed — only the deletion is withheld.
    enum ImagePageOutcome: Equatable {
        /// The source image was decoded and embedded — the PDF carries the actual scan.
        case embedded
        /// The source image could not be decoded/embedded; the image page is the visible placeholder.
        case placeholder

        var isPlaceholder: Bool { self == .placeholder }
    }

    @discardableResult
    func generate(imageURL: URL, result: OCRResult, model: LLMModel, outputURL: URL, originalFileName: String? = nil, gatewayDisplayName: String? = nil, pdfImageMB: Double = 0, textColumns: Int = 1) throws -> ImagePageOutcome {
        let pdfDocument = PDFDocument()
        let outcome: ImagePageOutcome

        if let imagePage = makeImagePage(imageURL: imageURL, rotationDegrees: result.rotationDegrees, targetMB: pdfImageMB) {
            pdfDocument.insert(imagePage, at: 0)
            outcome = .embedded
        } else {
            // The source image couldn't be decoded/embedded. Insert a visible placeholder rather than
            // silently emitting a 1-page (text-only) PDF — that preserves the 2-page archival contract,
            // keeps PDFTextExtractor's pageCount>=2 heuristic valid, and surfaces the failure.
            pdfDocument.insert(makePlaceholderImagePage(note: "Original image could not be embedded (\(imageURL.lastPathComponent))."), at: 0)
            outcome = .placeholder
        }

        let textPage = makeTextPage(result: result, model: model, originalFileName: originalFileName, gatewayDisplayName: gatewayDisplayName, textColumns: textColumns)
        pdfDocument.insert(textPage, at: pdfDocument.pageCount)

        guard pdfDocument.write(to: outputURL) else {
            throw PDFError.writeFailed
        }
        return outcome
    }

    // MARK: - Image Page

    private func makeImagePage(imageURL: URL, rotationDegrees: Int = 0, targetMB: Double = 0) -> PDFPage? {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        let sourceType = CGImageSourceGetType(imageSource) as? String
        let noRotation = rotationDegrees == 0 || rotationDegrees % 360 == 0

        // Is the source already within the PDF image-size target? (targetMB <= 0 means no limit.)
        let underTarget: Bool = {
            guard targetMB > 0 else { return true }
            let size = ((try? FileManager.default.attributesOfItem(atPath: imageURL.path))?[.size] as? NSNumber)?.intValue ?? Int.max
            return Double(size) <= targetMB * 1_000_000
        }()

        let jpegData: Data
        let embedWidth: Int
        let embedHeight: Int
        let colorSpace: String

        // The verbatim fast path embeds the original JPEG bytes with a /ColorSpace derived from the
        // file header. Only take it for definitively RGB/Gray JPEGs — CMYK/YCCK/unknown headers can
        // disagree with the DCTDecode stream's component count and render page 1 with wrong colors,
        // so those fall through to the decode+re-encode path where /ColorSpace matches the real image.
        let headerColorModel = properties?[kCGImagePropertyColorModel] as? String
        let fastPathColorSafe = headerColorModel == (kCGImagePropertyColorModelRGB as String)
            || headerColorModel == (kCGImagePropertyColorModelGray as String)

        if noRotation && sourceType == "public.jpeg" && orientation == 1 && underTarget && fastPathColorSafe {
            // Verbatim fast path: unrotated, normal-orientation JPEG already within target → embed the
            // original bytes as-is (no decode, no re-encode). Dims/color-model come from the file header.
            guard let data = try? Data(contentsOf: imageURL),
                  let w = properties?[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties?[kCGImagePropertyPixelHeight] as? Int else { return nil }
            jpegData = data
            embedWidth = w
            embedHeight = h
            colorSpace = Self.pdfColorSpace(forColorModel: headerColorModel)
        } else {
            // Decode, resolve EXIF orientation, apply any LLM rotation, then encode toward the PDF image
            // size target (targetMB <= 0 → full-resolution encode at quality 0.90, i.e. prior behavior).
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
            let imageWidth = cgImage.width
            let imageHeight = cgImage.height

            let baseImage: CGImage
            if sourceType == "public.jpeg" && orientation == 1 {
                baseImage = cgImage
            } else {
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: max(imageWidth, imageHeight),
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let oriented = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) else { return nil }
                baseImage = oriented
            }

            let finalImage: CGImage
            if noRotation {
                finalImage = baseImage
            } else {
                guard let rotated = ImageEncoding.rotate(baseImage, byDegreesClockwise: rotationDegrees) else { return nil }
                finalImage = rotated
            }

            // Size toward the target on the FINAL oriented/rotated image (so the long edge is correct).
            guard let enc = ImageEncoding.encodeToTargetMB(finalImage, targetMB: targetMB, quality: 0.90) else { return nil }
            jpegData = enc.data
            embedWidth = enc.width
            embedHeight = enc.height

            // Detect color space from the final (possibly rotated) image; dimensions may be downscaled
            // but the component count is preserved, so the embedded /ColorSpace stays correct.
            let numComponents = finalImage.colorSpace?.numberOfComponents ?? 3
            switch numComponents {
            case 1: colorSpace = "/DeviceGray"
            case 4: colorSpace = "/DeviceCMYK"
            default: colorSpace = "/DeviceRGB"
            }
        }

        guard !jpegData.isEmpty else { return nil }

        // Calculate positioning centered on letter-size page
        let pageWidth = 612.0
        let pageHeight = 792.0
        let scale = min(pageWidth / Double(embedWidth), pageHeight / Double(embedHeight))
        let drawWidth = Double(embedWidth) * scale
        let drawHeight = Double(embedHeight) * scale
        let drawX = (pageWidth - drawWidth) / 2
        let drawY = (pageHeight - drawHeight) / 2

        // Build a minimal PDF with JPEG bytes embedded via DCTDecode
        let pdfBytes = buildPDFWithJPEG(
            jpegData: jpegData, colorSpace: colorSpace,
            imageWidth: embedWidth, imageHeight: embedHeight,
            pageWidth: pageWidth, pageHeight: pageHeight,
            drawX: drawX, drawY: drawY,
            drawWidth: drawWidth, drawHeight: drawHeight
        )

        guard let doc = PDFDocument(data: pdfBytes) else { return nil }
        return doc.page(at: 0)
    }

    /// Maps a CGImageSource color model (kCGImagePropertyColorModel*) to the PDF /ColorSpace name.
    /// Equivalent to the decoded-image `numberOfComponents` mapping used on the slow path
    /// (Gray→1, CMYK→4, RGB/other→3), but derived from the file header without a full decode.
    private static func pdfColorSpace(forColorModel model: String?) -> String {
        guard let model else { return "/DeviceRGB" }
        if model == (kCGImagePropertyColorModelGray as String) { return "/DeviceGray" }
        if model == (kCGImagePropertyColorModelCMYK as String) { return "/DeviceCMYK" }
        return "/DeviceRGB"
    }

    /// Constructs raw PDF bytes with the JPEG data embedded as a DCTDecode image stream.
    /// This avoids decompressing the JPEG to a bitmap — the PDF size ≈ JPEG size + ~1 KB overhead.
    private func buildPDFWithJPEG(
        jpegData: Data, colorSpace: String,
        imageWidth: Int, imageHeight: Int,
        pageWidth: Double, pageHeight: Double,
        drawX: Double, drawY: Double,
        drawWidth: Double, drawHeight: Double
    ) -> Data {
        // Content stream: transform matrix then draw image
        let contentStream = String(format: "q %.4f 0 0 %.4f %.4f %.4f cm /Im0 Do Q",
                                   drawWidth, drawHeight, drawX, drawY)
        let contentBytes = Data(contentStream.utf8)

        var pdf = Data()
        func append(_ s: String) { pdf.append(Data(s.utf8)) }
        var offsets: [Int] = []

        append("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n")

        // 1: Catalog
        offsets.append(pdf.count)
        append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        // 2: Pages
        offsets.append(pdf.count)
        append("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")

        // 3: Page
        offsets.append(pdf.count)
        append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(Int(pageWidth)) \(Int(pageHeight))] /Contents 5 0 R /Resources << /XObject << /Im0 4 0 R >> >> >>\nendobj\n")

        // 4: Image XObject — raw JPEG with DCTDecode filter
        offsets.append(pdf.count)
        append("4 0 obj\n<< /Type /XObject /Subtype /Image /Width \(imageWidth) /Height \(imageHeight) /ColorSpace \(colorSpace) /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpegData.count) >>\nstream\n")
        pdf.append(jpegData)
        append("\nendstream\nendobj\n")

        // 5: Content stream
        offsets.append(pdf.count)
        append("5 0 obj\n<< /Length \(contentBytes.count) >>\nstream\n")
        pdf.append(contentBytes)
        append("\nendstream\nendobj\n")

        // Cross-reference table
        let xrefOffset = pdf.count
        append("xref\n0 6\n")
        append("0000000000 65535 f \n")
        for offset in offsets {
            append(String(format: "%010d 00000 n \n", offset))
        }

        // Trailer
        append("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n")

        return pdf
    }

    // MARK: - Text Page

    private func makeTextPage(result: OCRResult, model: LLMModel, originalFileName: String? = nil, gatewayDisplayName: String? = nil, textColumns: Int = 1) -> PDFPage {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "d MMMM yyyy"
        let dateStr = dateFormatter.string(from: Date())

        var headerLine = "Extracted text."
        if let fileName = originalFileName {
            headerLine += "\n\(fileName)"
        }
        if let gwName = gatewayDisplayName {
            headerLine += "\n\(gwName) \u{00B7} \(model.displayName) \u{00B7} \(dateStr)"
        } else {
            headerLine += "\n\(model.provider.rawValue) \u{00B7} \(model.displayName) \u{00B7} \(dateStr)"
        }
        if let classification = result.classification {
            headerLine += "\nClassification: \(classification.displayName)"
        }
        headerLine += "\n\n"

        let bodyText: String
        if let text = result.text, !text.isEmpty {
            bodyText = text
        } else {
            var msg = "No text returned by model."
            if let errorMsg = result.errorMessage { msg += "\n\n\(errorMsg)" }
            if let code = result.errorCode { msg += "\n\nError code: \(code)" }
            bodyText = msg
        }

        let headerParaStyle = NSMutableParagraphStyle()
        headerParaStyle.lineSpacing = 4
        headerParaStyle.paragraphSpacing = 2
        headerParaStyle.lineBreakMode = .byCharWrapping

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.lineSpacing = 4
        bodyParaStyle.paragraphSpacing = 6
        bodyParaStyle.lineBreakMode = .byCharWrapping

        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyFont = NSFont(name: "Georgia", size: 11) ?? NSFont.systemFont(ofSize: 11)

        let headerAttr: [NSAttributedString.Key: Any] = [
            .font: headerFont,
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: headerParaStyle
        ]
        let bodyAttr: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: bodyParaStyle
        ]

        let headerString = NSAttributedString(string: headerLine, attributes: headerAttr)
        let bodyString = NSAttributedString(string: bodyText, attributes: bodyAttr)

        let pageWidth: CGFloat = 612
        let margin: CGFloat = 54
        let fullTextWidth = pageWidth - 2 * margin
        let cols = SessionProcessingConfig.clampTextColumns(textColumns)

        // --- Measure the header (always single-column, full width) ---
        let headerFS = CTFramesetterCreateWithAttributedString(headerString as CFAttributedString)
        let headerRange = CFRangeMake(0, headerString.length)
        let headerMeasured = CTFramesetterSuggestFrameSizeWithConstraints(
            headerFS, headerRange, nil, CGSize(width: fullTextWidth, height: .greatestFiniteMagnitude), nil)
        var headerHeight = ceil(headerMeasured.height) + 4
        for _ in 0..<50 {
            let r = CGRect(x: 0, y: 0, width: fullTextWidth, height: headerHeight)
            let f = CTFramesetterCreateFrame(headerFS, headerRange, CGPath(rect: r, transform: nil), nil)
            let v = CTFrameGetVisibleStringRange(f)
            if v.location + v.length >= headerString.length { break }
            headerHeight += 24
        }

        // --- Measure + lay out the body in N columns ---
        let columnGap: CGFloat = cols > 1 ? 18 : 0
        let columnWidth = (fullTextWidth - columnGap * CGFloat(cols - 1)) / CGFloat(cols)

        let bodyFS = CTFramesetterCreateWithAttributedString(bodyString as CFAttributedString)
        let bodyFullRange = CFRangeMake(0, bodyString.length)

        // For single-column, measure the same way as before (one frame, grow until all visible).
        // For multi-column, flow text through column frames of a fixed height, adding rows of
        // columns until all text is placed. Use letter-page-body-height as the column height.
        let bodyHeight: CGFloat
        if cols == 1 {
            let bodyMeasured = CTFramesetterSuggestFrameSizeWithConstraints(
                bodyFS, bodyFullRange, nil, CGSize(width: columnWidth, height: .greatestFiniteMagnitude), nil)
            var h = ceil(bodyMeasured.height) + 4
            for _ in 0..<200 {
                let r = CGRect(x: 0, y: 0, width: columnWidth, height: h)
                let f = CTFramesetterCreateFrame(bodyFS, bodyFullRange, CGPath(rect: r, transform: nil), nil)
                let v = CTFrameGetVisibleStringRange(f)
                if v.location + v.length >= bodyString.length { break }
                h += 24
            }
            bodyHeight = h
        } else {
            // Multi-column: flow through fixed-height column frames.
            // Each "row" of columns is one letter-page-body-height tall.
            let rowHeight: CGFloat = 792 - 2 * margin - headerHeight
            let maxRowHeight = max(rowHeight, 200)
            var charIndex = 0
            var totalRows = 0
            while charIndex < bodyString.length {
                totalRows += 1
                for _ in 0..<cols {
                    if charIndex >= bodyString.length { break }
                    let remaining = CFRangeMake(charIndex, bodyString.length - charIndex)
                    let colRect = CGRect(x: 0, y: 0, width: columnWidth, height: maxRowHeight)
                    let colFrame = CTFramesetterCreateFrame(bodyFS, remaining, CGPath(rect: colRect, transform: nil), nil)
                    let visible = CTFrameGetVisibleStringRange(colFrame)
                    if visible.length == 0 { charIndex = bodyString.length; break }
                    charIndex += visible.length
                }
            }
            bodyHeight = maxRowHeight * CGFloat(totalRows)
        }

        let totalTextHeight = headerHeight + bodyHeight
        let pageHeight = max(792, totalTextHeight + 2 * margin)
        let pageSize = CGSize(width: pageWidth, height: pageHeight)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return PDFPage()
        }

        context.beginPDFPage(nil)
        context.setFillColor(CGColor.white)
        context.fill(CGRect(origin: .zero, size: pageSize))

        // --- Draw the header (single-column, full width, at the top) ---
        let headerOriginY = pageHeight - margin - headerHeight
        let headerRect = CGRect(x: margin, y: headerOriginY, width: fullTextWidth, height: headerHeight)
        let headerFrame = CTFramesetterCreateFrame(headerFS, headerRange, CGPath(rect: headerRect, transform: nil), nil)
        CTFrameDraw(headerFrame, context)

        // --- Draw the body columns ---
        if cols == 1 {
            let bodyOriginY = headerOriginY - bodyHeight
            let bodyRect = CGRect(x: margin, y: bodyOriginY, width: columnWidth, height: bodyHeight)
            let bodyFrame = CTFramesetterCreateFrame(bodyFS, bodyFullRange, CGPath(rect: bodyRect, transform: nil), nil)
            CTFrameDraw(bodyFrame, context)
        } else {
            let rowHeight: CGFloat = 792 - 2 * margin - headerHeight
            let maxRowHeight = max(rowHeight, 200)
            var charIndex = 0
            var currentRow = 0
            while charIndex < bodyString.length {
                let rowTopY = headerOriginY - CGFloat(currentRow) * maxRowHeight
                for col in 0..<cols {
                    if charIndex >= bodyString.length { break }
                    let remaining = CFRangeMake(charIndex, bodyString.length - charIndex)
                    let colX = margin + CGFloat(col) * (columnWidth + columnGap)
                    let colRect = CGRect(x: colX, y: rowTopY - maxRowHeight, width: columnWidth, height: maxRowHeight)
                    let colFrame = CTFramesetterCreateFrame(bodyFS, remaining, CGPath(rect: colRect, transform: nil), nil)
                    CTFrameDraw(colFrame, context)
                    let visible = CTFrameGetVisibleStringRange(colFrame)
                    if visible.length == 0 { charIndex = bodyString.length; break }
                    charIndex += visible.length
                }
                currentRow += 1
            }
        }

        context.endPDFPage()
        context.closePDF()

        return pdfPageFromData(pdfData) ?? PDFPage()
    }

    private func pdfPageFromData(_ data: NSMutableData) -> PDFPage? {
        guard let doc = PDFDocument(data: data as Data) else { return nil }
        return doc.page(at: 0)
    }

    /// A letter-size placeholder used when the original image can't be decoded/embedded, so the
    /// output PDF still has an image page (preserving the 2-page contract) and the failure is visible.
    private func makePlaceholderImagePage(note: String) -> PDFPage {
        let pageSize = CGSize(width: 612, height: 792)
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return PDFPage()
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor.white)
        context.fill(CGRect(origin: .zero, size: pageSize))
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.gray
        ]
        let noteString = NSAttributedString(string: note, attributes: attr)
        let fs = CTFramesetterCreateWithAttributedString(noteString as CFAttributedString)
        let rect = CGRect(x: 54, y: pageSize.height - 120, width: pageSize.width - 108, height: 80)
        let frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, noteString.length), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        return pdfPageFromData(pdfData) ?? PDFPage()
    }

    // MARK: - Multi-page Document Merging

    /// Merge multiple individual per-page PDFs into a single multi-page PDF.
    /// Each source PDF has [image page, text page]. The merged PDF interleaves them:
    /// image1, text1, image2, text2, ...
    /// Throws `PDFError.sourceUnreadable` if any source PDF cannot be loaded (fail-loud
    /// to prevent silent page-drop in this no-undo path).
    func mergeDocumentPDFs(sourcePDFs: [URL], outputURL: URL) throws {
        let merged = PDFDocument()
        var pageIndex = 0

        for pdfURL in sourcePDFs {
            guard let doc = PDFDocument(url: pdfURL) else {
                throw PDFError.sourceUnreadable(pdfURL)
            }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else {
                    throw PDFError.sourceUnreadable(pdfURL)
                }
                merged.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }

        guard merged.pageCount > 0 else { throw PDFError.writeFailed }
        guard merged.write(to: outputURL) else { throw PDFError.writeFailed }
    }
}

enum PDFError: Error {
    case writeFailed
    case sourceUnreadable(URL)
}
