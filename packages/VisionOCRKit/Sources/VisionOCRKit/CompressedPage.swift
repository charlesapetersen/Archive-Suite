// CompressedPage.swift — Vision OCR's compressed searchable page for a host app's own lines (W42.int-s5-compress,
// Stage 5 of execution-plans/integration/00-plan.md).
//
// The engine's own route (`OCRModel.makeSearchablePDF`, its defaults: rebuilt images, JBIG2): `Flattener` rebuilds the
// page as a 1-bit JBIG2 image or as MRC layers, `JBIG2.assemble` writes the image PDF by hand, `SearchableWriter`
// the text layer, and `qpdf --overlay` lays one on the other. No Quartz redraws the image, which is what keeps the
// JBIG2 streams as jbig2enc wrote them. The lines are the host's: nothing is recognised here.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CompressedPage {
    public enum Failure: LocalizedError {
        /// The tools the compression runs are not on this Mac.
        case missingTools([String])
        case unwritableImage
        /// The engine's own refusal (a line it could not place, a check it failed), in its words.
        case refused(String)
        /// The engine wrote the page without compressing it.
        case notCompressed

        public var errorDescription: String? {
            switch self {
            case .missingTools(let tools): return tools.joined(separator: " and ") + " not found"
            case .unwritableImage: return "the image could not be handed to the compressor"
            case .refused(let why): return why
            case .notCompressed: return "the compressor did not take the JBIG2 route"
            }
        }
    }

    /// The tools the compression needs that this Mac lacks, of `jbig2` (jbig2enc) and `qpdf`, found as Vision OCR
    /// finds them (`Runner.locateTool`: the host app's own Resources, then /opt/homebrew/bin, /usr/local/bin,
    /// /opt/local/bin, then the login shell's PATH). Empty when the page can be compressed.
    public static var missingTools: [String] {
        [("jbig2", JBIG2.encoder), ("qpdf", JBIG2.merger)].compactMap { $0.1 == nil ? $0.0 : nil }
    }

    /// The qpdf the compression uses, for a host that merges or finishes what it wrote without redrawing it.
    public static var qpdf: URL? { JBIG2.merger.map { URL(fileURLWithPath: $0) } }

    /// Whether the image file at `url` is a camera's photo by its tags (a Make or Model and an exposure), as the engine
    /// judges an image it is handed (`Flattener.cameraExposed`). False for a PDF, an unreadable file or a scan.
    public static func isCameraPhoto(_ url: URL) -> Bool {
        Flattener.cameraExposed(CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
    }

    /// The engine's defaults in memory, shared with the page-kind reader; no saved preferences are read.
    static let settings: Prefs.Snapshot = {
        var s = EnginePageKind.settings
        s.mode = .searchablePDF
        s.useJBIG2 = true
        s.preserveAnnotations = false
        return s
    }()

    /// Writes `image` to `destination` as one searchable page the way Vision OCR writes its own, with `lines`
    /// (normalised to the image, top-left origin) as its invisible layer. The page is the image, `pageSize` points.
    /// `ink`: where the words are, when `lines` are not on them (an unplaced layer), so the MRC layering keeps the
    /// text sharp where it really is; nil uses `lines`. Returns what the engine said of the page, to be logged: that ink
    /// outside the lines was stored at a lower resolution (C28), as Vision OCR's run report says it.
    /// `photographed`: the image is a camera's photo (`isCameraPhoto`, or a host that knows it took it), which keeps
    /// the photo's stroke weight in the layering as the engine does for a camera-tagged file
    /// (W42.stroke-weight-photographed); the PNG handed to the engine carries no tags, so it must be told.
    /// Synchronous and seconds a page (jbig2 and qpdf run as children): call it off the main thread. Throws, and
    /// writes nothing, when the tools are missing, a line cannot be placed or the page did not come out compressed.
    @discardableResult
    public static func write(image: CGImage, lines: TextLayer.Lines, ink: TextLayer.Lines? = nil, pageSize: CGSize,
                             photographed: Bool = false, to destination: URL,
                             budget: PDFChildBudget = PDFChildBudget()) throws -> [String] {
        assert(!Thread.isMainThread, "CompressedPage.write on the main thread")
        try budget.check()
        let missing = missingTools
        guard missing.isEmpty else { throw Failure.missingTools(missing) }
        guard image.width > 0, image.height > 0, pageSize.width > 0, pageSize.height > 0 else {
            throw Failure.unwritableImage
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("visionocr-compressed-" + UUID().uuidString)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // A lossless copy whose resolution makes `Flattener.wrapImage`'s page `pageSize` points.
        let png = dir.appendingPathComponent("page.png")
        let dpi: [CFString: Any] = [kCGImagePropertyDPIWidth: Double(image.width) * 72 / Double(pageSize.width),
                                    kCGImagePropertyDPIHeight: Double(image.height) * 72 / Double(pageSize.height)]
        guard let sink = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.unwritableImage
        }
        CGImageDestinationAddImage(sink, image, dpi as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { throw Failure.unwritableImage }

        let out = dir.appendingPathComponent("page.pdf")
        var outcome: Runner.Result.Outcome?
        var message = ""
        var compressed = false
        var notes: [String] = []
        OCRModel.makeSearchablePDF(file: png, output: out, rebuild: true, rebuildMode: .auto, password: nil,
                                   settings: settings, control: RunControl(pdfChildBudget: budget), lines: [1: lines.observations],
                                   inkBoxes: ink.flatMap { $0.isEmpty ? nil : [1: $0.observations.map(\.boundingBox)] },
                                   photographed: photographed,
                                   progress: { _, _ in }, tookJBIG2Route: { compressed = true },
                                   shrunkTextPageNote: { notes.append($0) },
                                   report: { outcome = $0; message = $1 })
        try budget.check()
        guard outcome == .succeeded else { throw Failure.refused(message.isEmpty ? "the page was not written" : message) }
        guard compressed else { throw Failure.notCompressed }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: out)
        } else {
            try fm.moveItem(at: out, to: destination)
        }
        return notes
    }
}
