import Foundation
import AppKit
import PDFKit
import CoreText

struct PDFGenerator {

    func generate(imageURL: URL, result: OCRResult, model: LLMModel, outputURL: URL) throws {
        let pdfDocument = PDFDocument()

        // --- Page 1: Image ---
        if let imagePage = makeImagePage(imageURL: imageURL) {
            pdfDocument.insert(imagePage, at: 0)
        }

        // --- Page 2: Text ---
        let textPage = makeTextPage(result: result, model: model)
        pdfDocument.insert(textPage, at: pdfDocument.pageCount)

        guard pdfDocument.write(to: outputURL) else {
            throw PDFError.writeFailed
        }
    }

    // MARK: - Image Page

    private func makeImagePage(imageURL: URL) -> PDFPage? {
        guard let image = NSImage(contentsOf: imageURL) else { return nil }
        let pageSize = CGSize(width: 612, height: 792)
        let imageSize = image.size
        let scale = min(pageSize.width / imageSize.width, pageSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (pageSize.width - scaledSize.width) / 2, y: (pageSize.height - scaledSize.height) / 2)

        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        image.draw(in: CGRect(origin: origin, size: scaledSize))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        return pdfPageFromData(pdfData)
    }

    // MARK: - Text Page (Core Text)

    private func makeTextPage(result: OCRResult, model: LLMModel) -> PDFPage {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "d MMMM yyyy"
        let dateStr = dateFormatter.string(from: Date())

        let headerText = "Extracted text.\n\(model.provider.rawValue) \u{00B7} \(model.displayName) \u{00B7} \(dateStr)\n\n"

        let bodyText: String
        if let text = result.text, !text.isEmpty {
            bodyText = text
        } else {
            var msg = "No text returned by model."
            if let errorMsg = result.errorMessage { msg += "\n\n\(errorMsg)" }
            if let code = result.errorCode { msg += "\n\nError code: \(code)" }
            bodyText = msg
        }

        // Build attributed string
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

        fullString.append(NSAttributedString(string: headerText, attributes: headerAttr))
        fullString.append(NSAttributedString(string: bodyText, attributes: bodyAttr))

        // Measure required height
        let pageWidth: CGFloat = 612
        let margin: CGFloat = 54
        let textWidth = pageWidth - 2 * margin

        let framesetter = CTFramesetterCreateWithAttributedString(fullString as CFAttributedString)
        let constraintSize = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRangeMake(0, fullString.length), nil, constraintSize, nil)

        // Page height: content + margins, minimum letter size
        let pageHeight = max(792, fitSize.height + 2 * margin)
        let pageSize = CGSize(width: pageWidth, height: pageHeight)

        // Create PDF page using Core Text (native bottom-up coordinates — no flipping needed)
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return PDFPage()
        }

        context.beginPDFPage(nil)

        // White background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(origin: .zero, size: pageSize))

        // Text frame: positioned with margin from all sides
        // In PDF coordinates (bottom-up), the text rect starts at margin from bottom
        // and extends up. We want text at the TOP of the page, so:
        //   y origin = pageHeight - margin - fitSize.height
        let textOriginY = pageHeight - margin - fitSize.height
        let textRect = CGRect(x: margin, y: textOriginY, width: textWidth, height: fitSize.height)
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, fullString.length), path, nil)
        CTFrameDraw(frame, context)

        context.endPDFPage()
        context.closePDF()

        return pdfPageFromData(pdfData) ?? PDFPage()
    }

    // MARK: - Helpers

    private func pdfPageFromData(_ data: NSMutableData) -> PDFPage? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        data.write(to: tempURL, atomically: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let doc = PDFDocument(url: tempURL) else { return nil }
        return doc.page(at: 0)
    }
}

enum PDFError: Error {
    case writeFailed
}
