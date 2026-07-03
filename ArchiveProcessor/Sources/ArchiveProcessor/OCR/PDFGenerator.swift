import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO

struct PDFGenerator {

    func generate(imageURL: URL, result: OCRResult, model: LLMModel, outputURL: URL, originalFileName: String? = nil, gatewayDisplayName: String? = nil, pdfImageMB: Double = 0) throws {
        let pdfDocument = PDFDocument()

        if let imagePage = makeImagePage(imageURL: imageURL, rotationDegrees: result.rotationDegrees, targetMB: pdfImageMB) {
            pdfDocument.insert(imagePage, at: 0)
        }

        let textPage = makeTextPage(result: result, model: model, originalFileName: originalFileName, gatewayDisplayName: gatewayDisplayName)
        pdfDocument.insert(textPage, at: pdfDocument.pageCount)

        guard pdfDocument.write(to: outputURL) else {
            throw PDFError.writeFailed
        }
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

        if noRotation && sourceType == "public.jpeg" && orientation == 1 && underTarget {
            // Verbatim fast path: unrotated, normal-orientation JPEG already within target → embed the
            // original bytes as-is (no decode, no re-encode). Dims/color-model come from the file header.
            guard let data = try? Data(contentsOf: imageURL),
                  let w = properties?[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties?[kCGImagePropertyPixelHeight] as? Int else { return nil }
            jpegData = data
            embedWidth = w
            embedHeight = h
            colorSpace = Self.pdfColorSpace(forColorModel: properties?[kCGImagePropertyColorModel] as? String)
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

    private func makeTextPage(result: OCRResult, model: LLMModel, originalFileName: String? = nil, gatewayDisplayName: String? = nil) -> PDFPage {
        let dateFormatter = DateFormatter()
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

        let fullString = NSMutableAttributedString()

        let headerParaStyle = NSMutableParagraphStyle()
        headerParaStyle.lineSpacing = 4
        headerParaStyle.paragraphSpacing = 2

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.lineSpacing = 4
        bodyParaStyle.paragraphSpacing = 6

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

        fullString.append(NSAttributedString(string: headerLine, attributes: headerAttr))
        fullString.append(NSAttributedString(string: bodyText, attributes: bodyAttr))

        let pageWidth: CGFloat = 612
        let margin: CGFloat = 54
        let textWidth = pageWidth - 2 * margin

        let framesetter = CTFramesetterCreateWithAttributedString(fullString as CFAttributedString)
        let constraintSize = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRangeMake(0, fullString.length), nil, constraintSize, nil)

        let pageHeight = max(792, fitSize.height + 2 * margin)
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

        let textOriginY = pageHeight - margin - fitSize.height
        let textRect = CGRect(x: margin, y: textOriginY, width: textWidth, height: fitSize.height)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, fullString.length), path, nil)
        CTFrameDraw(frame, context)

        context.endPDFPage()
        context.closePDF()

        return pdfPageFromData(pdfData) ?? PDFPage()
    }

    private func pdfPageFromData(_ data: NSMutableData) -> PDFPage? {
        guard let doc = PDFDocument(data: data as Data) else { return nil }
        return doc.page(at: 0)
    }

    // MARK: - Multi-page Document Merging

    /// Merge multiple individual per-page PDFs into a single multi-page PDF.
    /// Each source PDF has [image page, text page]. The merged PDF interleaves them:
    /// image1, text1, image2, text2, ...
    /// Returns the URLs of source PDFs that were merged (for deletion).
    func mergeDocumentPDFs(sourcePDFs: [URL], outputURL: URL) throws {
        let merged = PDFDocument()
        var pageIndex = 0

        for pdfURL in sourcePDFs {
            guard let doc = PDFDocument(url: pdfURL) else { continue }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
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
}
