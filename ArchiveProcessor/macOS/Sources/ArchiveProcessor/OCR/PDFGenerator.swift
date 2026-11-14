import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO
import ArchiveCore
import VisionOCRKit

/// W37.dual-date — the optional source-document date lines of a newly generated PDF's OCR-text header
/// (`Document date: …` / `Sent with: …`). Display strings (`ArchiveDate.display`). These are the
/// document's own dates, distinct from the provider line's OCR processing date, and are an output-time
/// snapshot: the live value is always the Finder tags. Parsed back out by Core `PDFHeaderParser`.
struct PDFSourceDates: Sendable, Equatable {
    var documentDate: String?
    var sentWith: String?
    /// W46.date-route-header — the evidence behind a non-explicit document date (`DateRoute.Decision.headerEvidence`).
    var dateEvidence: String? = nil

    var isEmpty: Bool { documentDate == nil && sentWith == nil && dateEvidence == nil }

    /// The header lines, in SPEC order, each with Core's exact prefix.
    var headerLines: [String] {
        var lines: [String] = []
        if let documentDate { lines.append(PDFHeaderParser.documentDatePrefix + documentDate) }
        if let sentWith { lines.append(PDFHeaderParser.sentWithPrefix + sentWith) }
        if let dateEvidence { lines.append(PDFHeaderParser.dateEvidencePrefix + dateEvidence) }
        return lines
    }
}

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

    /// What `generateOutput` wrote: the image page's verdict and its searchable layer's (W42.int-s5).
    struct Output: Sendable, Equatable {
        var imagePage: ImagePageOutcome
        var layer: TextLayerOutcome
        /// The median line slope the image page was turned level by (`ReadingCopy`); nil when it was left as it was.
        var straightenedDegrees: Double? = nil
    }

    @discardableResult
    func generate(imageURL: URL, result: OCRResult, model: LLMModel, outputURL: URL,
                  originalFileName: String? = nil, gatewayDisplayName: String? = nil,
                  localAgentDisplayName: String? = nil, localAgentModelName: String? = nil,
                  pdfImageMB: Double = 0, textColumns: Int = 1,
                  sourceDates: PDFSourceDates? = nil, pageKind: OCRPageKind? = nil,
                  textLayer: TextLayerOptions? = .standard) throws -> ImagePageOutcome {
        try generateOutput(imageURL: imageURL, result: result, model: model, outputURL: outputURL,
                           originalFileName: originalFileName, gatewayDisplayName: gatewayDisplayName,
                           localAgentDisplayName: localAgentDisplayName, localAgentModelName: localAgentModelName,
                           pdfImageMB: pdfImageMB, textColumns: textColumns, sourceDates: sourceDates,
                           pageKind: pageKind, textLayer: textLayer).imagePage
    }

    /// `generate`, saying also what the image page's searchable layer came to. `textLayer` nil writes no layer.
    func generateOutput(imageURL: URL, result: OCRResult, model: LLMModel, outputURL: URL,
                        originalFileName: String? = nil, gatewayDisplayName: String? = nil,
                        localAgentDisplayName: String? = nil, localAgentModelName: String? = nil,
                        pdfImageMB: Double = 0, textColumns: Int = 1,
                        sourceDates: PDFSourceDates? = nil, pageKind: OCRPageKind? = nil,
                        textLayer: TextLayerOptions? = .standard) throws -> Output {
        let pdfDocument = PDFDocument()
        let outcome: ImagePageOutcome
        var layer = TextLayerOutcome.textPage("no layer asked for")

        var straightened: Double?
        if let image = makeImagePageData(imageURL: imageURL, rotationDegrees: result.rotationDegrees, targetMB: pdfImageMB,
                                         straighten: textLayer?.straighten == true),
           let plain = PDFDocument(data: image.pdf)?.page(at: 0) {
            straightened = image.straightenedDegrees
            var page = plain
            if let textLayer {
                let layered = layeredImagePage(image, result: result, pageKind: pageKind, options: textLayer)
                layer = layered.outcome
                if let p = layered.page { page = p }
            }
            pdfDocument.insert(page, at: 0)
            outcome = .embedded
        } else {
            // The source image couldn't be decoded/embedded. Insert a visible placeholder rather than
            // silently emitting a 1-page (text-only) PDF — that preserves the 2-page archival contract,
            // keeps PDFTextExtractor's pageCount>=2 heuristic valid, and surfaces the failure.
            pdfDocument.insert(makePlaceholderImagePage(note: "Original image could not be embedded (\(imageURL.lastPathComponent))."), at: 0)
            outcome = .placeholder
            layer = .textPage("the image could not be embedded")
        }

        let textPage = makeTextPage(result: result, model: model, originalFileName: originalFileName,
                                    gatewayDisplayName: gatewayDisplayName,
                                    localAgentDisplayName: localAgentDisplayName,
                                    localAgentModelName: localAgentModelName,
                                    textColumns: textColumns, sourceDates: sourceDates, pageKind: pageKind)
        pdfDocument.insert(textPage, at: pdfDocument.pageCount)

        guard pdfDocument.write(to: outputURL) else {
            throw PDFError.writeFailed
        }
        return Output(imagePage: outcome, layer: layer, straightenedDegrees: straightened)
    }

    // MARK: - Searchable layer (W42.int-s5)

    /// What the run tells the image page: the placement switch (`placeHandOnImage`, `05-placement.md` §2) and the
    /// straightening switch (`straightenReadingCopy`, `01-reading-copy.md` §3). Both on by default.
    struct TextLayerOptions: Codable, Sendable, Equatable {
        var placeHandOnImage = true
        var straighten = true
        static let standard = TextLayerOptions()

        /// The two switches as a run's frozen settings hold them (`ResolvedSettingsSnapshot.values`); a key absent
        /// (no settings snapshot) is its built-in default.
        static func from(_ values: [String: ResolvedSetting]) -> TextLayerOptions {
            func flag(_ key: SettingsKey) -> Bool { values[key.rawValue]?.value.bool ?? key.defaultValue.bool ?? true }
            return TextLayerOptions(placeHandOnImage: flag(.placeHandOnImage), straighten: flag(.straightenReadingCopy))
        }
    }

    /// W42.int-s5 — the image page remade from its own JPEG with a layer of `result`'s reading, as one PDF page: what
    /// Improve OCR puts in place of an image page whose text it replaces (`ReOCRJob.remadeImagePage`). The JPEG is
    /// embedded byte for byte (a JPEG that the fast path would re-encode gives nil), never straightened again. `layer`
    /// says whether the page got one; a page that gets none is the plain image page. Off the main thread only.
    func remadeImagePageData(jpeg: Data, result: OCRResult, pageKind: OCRPageKind?,
                             options: TextLayerOptions) -> (pdf: Data, layer: TextLayerOutcome)? {
        guard !Thread.isMainThread else { return nil }
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("ap-remade-" + UUID().uuidString + ".jpg")
        defer { try? fm.removeItem(at: url) }
        guard (try? jpeg.write(to: url)) != nil,
              let image = makeImagePageData(imageURL: url, straighten: false) else { return nil }
        var unstraightened = options
        unstraightened.straighten = false
        let layered = layeredImagePage(image, result: result, pageKind: pageKind, options: unstraightened)
        // Through PDFKit either way, as `generate` writes the page, so a page with no layer is drawn as new output is.
        guard let page = layered.page ?? PDFDocument(data: image.pdf)?.page(at: 0) else { return nil }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard let data = doc.dataRepresentation() else { return nil }
        return (data, layered.outcome)
    }

    /// The image page with its searchable layer, or nil (and why) when it gets none. Never worse than the plain page:
    /// any failure keeps the image page without a layer, and the text page carries the text either way.
    private func layeredImagePage(_ image: ImagePageData, result: OCRResult, pageKind: OCRPageKind?,
                                  options: TextLayerOptions) -> (page: PDFPage?, outcome: TextLayerOutcome) {
        let kind = TextLayerRule.kind(explicit: pageKind, result: result)
        let reading = result.text.flatMap { $0.isEmpty ? nil : $0 }
        let requireAligned: Bool
        switch TextLayerRule.decide(kind: kind, reading: reading, placeHandOnImage: options.placeHandOnImage) {
        case .textPage(let why): return (nil, .textPage(why))
        case .place(let r): requireAligned = r
        }
        // The engine's Vision reading stalls on the main thread (W42.int-s3); a caller there gets no layer.
        guard !Thread.isMainThread else { return (nil, .textPage("written on the main thread")) }
        guard let cg = image.decoded(), cg.width > 0,
              let vision = TextLayer.visionLines(of: cg) else { return (nil, .textPage("Vision could not read the image")) }
        guard !vision.isEmpty else { return (nil, .textPage("Vision found no lines")) }
        let lines = TextLayer.aligned(vision, reading: reading, aspect: Double(cg.height) / Double(cg.width))
        if requireAligned, lines.placement != .aligned {
            return (nil, .textPage("the page's kind is unknown and the reading did not align with Vision's lines"))
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ap-layer-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let plainURL = dir.appendingPathComponent("image.pdf"), layeredURL = dir.appendingPathComponent("layered.pdf")
            try image.pdf.write(to: plainURL)
            let unplaced = try TextLayer.write(imagePage: plainURL, lines: lines, imageFrame: image.frame, to: layeredURL)
            // Read into memory: a PDFDocument opened on a URL reads it lazily, and the directory goes at return.
            guard let page = PDFDocument(data: try Data(contentsOf: layeredURL))?.page(at: 0) else {
                return (nil, .textPage("the layered page could not be read back"))
            }
            let route: TextLayerRoute = lines.placement == .aligned ? .visionLinesAligned : .visionOwn
            return (page, TextLayerOutcome(route: route, reason: nil, lines: lines.lines.count, unplaced: unplaced))
        } catch {
            return (nil, .textPage("the layer could not be written: \(error.localizedDescription)"))
        }
    }

    // MARK: - Image Page

    /// The image page as a one-page PDF, the pixels it shows and where they sit on the page.
    struct ImagePageData {
        var pdf: Data
        /// Decodes the embedded image, as drawn (oriented and turned): what the layer's lines are read from.
        var decoded: () -> CGImage?
        /// Where the image sits on the page, normalised, top-left origin.
        var frame: CGRect
        /// The median line slope the image was turned level by (`ReadingCopy`); nil when it was left as it was.
        var straightenedDegrees: Double? = nil
    }

    /// `straighten` (W42.int-s5, `straightenReadingCopy`): when the oriented, turned image's lines slope by a median of
    /// 1 degree or more, the page shows it turned level on a canvas that holds all of it, encoded once toward the
    /// target like any re-encoded page. A level page, an unreadable angle, or a call on the main thread (Vision reads
    /// the angle) leaves the page as it would be without the switch.
    private func makeImagePageData(imageURL: URL, rotationDegrees: Int = 0, targetMB: Double = 0,
                                   straighten: Bool = false) -> ImagePageData? {
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

        // The image as the page shows it: decoded, EXIF orientation resolved, the app's rotation applied.
        func orientedImage() -> CGImage? {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }
            let baseImage: CGImage
            if sourceType == "public.jpeg" && orientation == 1 {
                baseImage = cgImage
            } else {
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: max(cgImage.width, cgImage.height),
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let oriented = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions as CFDictionary) else { return nil }
                baseImage = oriented
            }
            return noRotation ? baseImage : ImageEncoding.rotate(baseImage, byDegreesClockwise: rotationDegrees)
        }
        func components(_ image: CGImage) -> String {
            switch image.colorSpace?.numberOfComponents ?? 3 {
            case 1: return "/DeviceGray"
            case 4: return "/DeviceCMYK"
            default: return "/DeviceRGB"
            }
        }

        var decoded: CGImage?
        if straighten, !Thread.isMainThread, let image = orientedImage() {
            decoded = image
            if let turn = ReadingCopy.straighteningTurn(for: image), let level = ReadingCopy.straightened(image, by: turn),
               let enc = ImageEncoding.encodeToTargetMB(level, targetMB: targetMB, quality: 0.90),
               var page = imagePageData(jpeg: enc.data, width: enc.width, height: enc.height, colorSpace: components(level)) {
                page.straightenedDegrees = turn
                return page
            }
        }

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
            guard let finalImage = decoded ?? orientedImage() else { return nil }

            // Size toward the target on the FINAL oriented/rotated image (so the long edge is correct).
            guard let enc = ImageEncoding.encodeToTargetMB(finalImage, targetMB: targetMB, quality: 0.90) else { return nil }
            jpegData = enc.data
            embedWidth = enc.width
            embedHeight = enc.height

            // Detect color space from the final (possibly rotated) image; dimensions may be downscaled
            // but the component count is preserved, so the embedded /ColorSpace stays correct.
            colorSpace = components(finalImage)
        }

        return imagePageData(jpeg: jpegData, width: embedWidth, height: embedHeight, colorSpace: colorSpace)
    }

    /// The one-page PDF that shows `jpeg` (`width` x `height` pixels) centred on a letter page.
    private func imagePageData(jpeg jpegData: Data, width embedWidth: Int, height embedHeight: Int,
                               colorSpace: String) -> ImagePageData? {
        guard !jpegData.isEmpty, embedWidth > 0, embedHeight > 0 else { return nil }

        // Calculate positioning centered on letter-size page
        let pageWidth = 612.0
        let pageHeight = 792.0
        let scale = min(pageWidth / Double(embedWidth), pageHeight / Double(embedHeight))
        let drawWidth = Double(embedWidth) * scale
        let drawHeight = Double(embedHeight) * scale
        let drawX = (pageWidth - drawWidth) / 2
        let drawY = (pageHeight - drawHeight) / 2

        // Build a minimal PDF with JPEG bytes embedded via DCTDecode
        let pdfBytes: Data = buildPDFWithJPEG(
            jpegData: jpegData, colorSpace: colorSpace,
            imageWidth: embedWidth, imageHeight: embedHeight,
            pageWidth: pageWidth, pageHeight: pageHeight,
            drawX: drawX, drawY: drawY,
            drawWidth: drawWidth, drawHeight: drawHeight
        )

        let embedded = jpegData
        let frame = CGRect(x: drawX / pageWidth, y: (pageHeight - drawY - drawHeight) / pageHeight,
                           width: drawWidth / pageWidth, height: drawHeight / pageHeight)
        return ImagePageData(pdf: pdfBytes, decoded: {
            guard let src = CGImageSourceCreateWithData(embedded as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }, frame: frame)
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

    /// The text page alone, as a one-page PDF: what Improve OCR puts in place of an old text page
    /// (`ReOCRIncrementalWriter`), made exactly as `generate` makes it. Nil when PDFKit cannot serialize it.
    func textPageData(result: OCRResult, model: LLMModel, originalFileName: String? = nil,
                      gatewayDisplayName: String? = nil, localAgentDisplayName: String? = nil,
                      localAgentModelName: String? = nil, textColumns: Int = 1,
                      sourceDates: PDFSourceDates? = nil, pageKind: OCRPageKind? = nil) -> Data? {
        let doc = PDFDocument()
        doc.insert(makeTextPage(result: result, model: model, originalFileName: originalFileName,
                                gatewayDisplayName: gatewayDisplayName, localAgentDisplayName: localAgentDisplayName,
                                localAgentModelName: localAgentModelName, textColumns: textColumns,
                                sourceDates: sourceDates, pageKind: pageKind), at: 0)
        return doc.dataRepresentation()
    }

    private func makeTextPage(result: OCRResult, model: LLMModel, originalFileName: String? = nil,
                              gatewayDisplayName: String? = nil, localAgentDisplayName: String? = nil,
                              localAgentModelName: String? = nil, textColumns: Int = 1,
                              sourceDates: PDFSourceDates? = nil, pageKind: OCRPageKind? = nil) -> PDFPage {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "d MMMM yyyy"
        let dateStr = dateFormatter.string(from: Date())

        var headerLine = "Extracted text."
        var provenanceRange: NSRange?
        if let fileName = originalFileName {
            headerLine += "\n\(fileName.components(separatedBy: .controlCharacters).joined(separator: " "))"
        }
        // Keep actual-reader precedence, then sanitize both display positions for every backend.
        // A custom gateway/CLI label cannot inject another separator or a Kind/header line.
        let providerName: String
        let modelName: String
        if let imported = result.imported {
            providerName = imported.headerSource; modelName = imported.headerModel
        } else if let reader = result.secondReader {
            providerName = reader.provider; modelName = reader.model
        } else if let routed = result.pageReader, routed.isRouted {
            providerName = routed.provider; modelName = routed.model
        } else if let localName = localAgentDisplayName {
            providerName = localName; modelName = localAgentModelName ?? "CLI default"
        } else if let gwName = gatewayDisplayName {
            providerName = gwName; modelName = model.displayName
        } else {
            providerName = model.provider.rawValue; modelName = model.displayName
        }
        let metaLine = "\(ImportedReading.headerComponent(providerName)) · \(ImportedReading.headerComponent(modelName)) · \(dateStr)"
        provenanceRange = NSRange(location: headerLine.utf16.count + 1, length: metaLine.utf16.count)
        headerLine += "\n\(metaLine)"
        if let classification = result.classification {
            headerLine += "\nClassification: \(classification.displayName)"
        }
        // Kind is distinct from segmentation classification. Validate imported freeform kinds;
        // missing/unknown (including "mixed") stays absent, never guessed printed.
        if let kind = pageKind ?? result.pageReader?.kind.flatMap(PageKindName.init(rawValue:))?.headerKind
            ?? result.imported?.kind.flatMap(OCRPageKind.init(rawValue:)) {
            headerLine += "\n\(PDFHeaderParser.kindPrefix)\(kind.rawValue)"
        }
        // W37.dual-date — the document's own date / covering-letter date, after Classification and
        // before the blank separator, only when known at render time (see `PDFSourceDates`).
        var fitRanges = provenanceRange.map { [$0] } ?? []
        for line in sourceDates?.headerLines ?? [] {
            // W46.date-route-header: the evidence line quotes the document, so it is fitted to one line like provenance.
            if line.hasPrefix(PDFHeaderParser.dateEvidencePrefix) {
                fitRanges.append(NSRange(location: headerLine.utf16.count + 1, length: line.utf16.count))
            }
            headerLine += "\n\(line)"
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
        return layoutTextPage(headerLine: headerLine, fitRanges: fitRanges, bodyText: bodyText, textColumns: textColumns)
    }

    /// Lays out one text page: `headerLine` (ending in its blank separator) above `bodyText`. Each of `fitRanges`
    /// (a whole header line) is shrunk until it fits on one line, so the parser reads it back as one line.
    func layoutTextPage(headerLine: String, fitRanges: [NSRange], bodyText: String, textColumns: Int) -> PDFPage {
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

        let headerString = NSMutableAttributedString(string: headerLine, attributes: headerAttr)
        let bodyString = NSAttributedString(string: bodyText, attributes: bodyAttr)

        let pageWidth: CGFloat = 612
        let margin: CGFloat = 54
        let fullTextWidth = pageWidth - 2 * margin
        // Freeform gateway/CLI/cluster labels can wrap across several extracted lines. Fit every
        // provenance line, preserving its full display labels in the same single-line grammar.
        for range in fitRanges {
            // SF's optical metrics change with point size: a one-shot ratio measured at 11pt
            // can still wrap at the smaller font. Re-measure the actual fitted font before layout.
            var pointSize = headerFont.pointSize
            for _ in 0..<8 {
                let meta = headerString.attributedSubstring(from: range)
                let width = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(meta), nil, nil, nil))
                if width <= fullTextWidth * 0.98 { break }
                pointSize *= fullTextWidth * 0.98 / width
                headerString.addAttribute(.font,
                    value: NSFont.systemFont(ofSize: pointSize, weight: .semibold), range: range)
            }
        }
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
