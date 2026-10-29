#if DEBUG
import AppKit
import Foundation
import PDFKit

/// DEBUG-only launch wiring for the off-screen Processor UI suite. The test runner creates unique
/// temporary input/output directories and passes them explicitly; no test can inherit a remembered
/// production output folder, an API key, or an interactive Keychain prompt.
enum ProcessorUITestConfiguration {
    private static let arguments = ProcessInfo.processInfo.arguments

    static var isActive: Bool { arguments.contains("-APUITestMode") }

    static var inputDirectory: URL? { urlValue(after: "-APUITestInputDirectory") }
    static var outputDirectory: URL? { urlValue(after: "-APUITestOutputDirectory") }
    /// Every UI-test launch gets an app-owned scratch backup, including Live Capture paths. The test runner
    /// cannot create this inside the app sandbox, so derive it from this process's temporary directory.
    static var backupDirectory: URL? {
        guard isActive else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-uitest-backup-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// Opens the real Live Capture view with only its non-writing finishing-scrim state armed. This lets the
    /// VM UI test inspect the focus/AX barrier without starting a receiver, OCR, or a finalize operation.
    static var showsLiveCaptureFinishingScrim: Bool {
        isActive && arguments.contains("-APUITestLiveCaptureFinishingScrim")
    }
    /// Opens the emptied Captured pane with three synthetic staged documents and a partial-finish summary.
    /// The UI test can verify the count, confirmation copy, Cancel, and Clear without OCR or disk output.
    static var showsLiveCaptureEmptyPaneClear: Bool {
        isActive && arguments.contains("-APUITestLiveCaptureEmptyPaneClear")
    }
    /// Opens the review of flagged boundaries (W36.seg-opt-review) on two synthetic gaps, with no run, OCR,
    /// model call or output behind it. The answers land in a DEBUG-only label once Done is pressed.
    static var showsFlaggedReview: Bool {
        isActive && arguments.contains("-APUITestFlaggedReview")
    }
    /// Shows the Interrupted Run box for a synthetic record (W40.fix-processor-resume-run-key):
    /// `-APUITestPendingRun localAgent` or `-APUITestPendingRun <provider rawValue>`. Nothing is written to the
    /// pending-run file, so Resume Run finds no record and does nothing; the test reads only the box.
    static var syntheticPendingRun: (info: String, backend: OCRProcessor.PendingRunBackend)? {
        guard isActive, let index = arguments.firstIndex(of: "-APUITestPendingRun"),
              arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        if value == "localAgent" { return ("Interrupted run (UI test): 0/2 files completed via the Local Agent.", .localAgent) }
        guard let provider = LLMProvider(rawValue: value) else { return nil }
        return ("Interrupted run (UI test): 0/2 files completed via \(provider.rawValue).", .direct(provider))
    }
    static var droppedPDF: URL? {
        if let path = urlValue(after: "-APUITestDroppedPDFPath") { return path }
        guard arguments.contains("-APUITestSyntheticMultiPagePDF") else { return nil }
        return syntheticMultiPagePDF()
    }

    /// W40.e12: realistic volume for the visual review — 60 synthetic page images, some with long archival
    /// file names, built in this app's own temporary directory and admitted like a drop. Never a corpus file.
    static var droppedVolume: [URL]? {
        guard isActive, arguments.contains("-APUITestSyntheticVolume") else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-uitest-volume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for i in 1...60 {
            let name = i % 7 == 0
                ? String(format: "Box 214 Folder 37 — Memorandum for the President from the Director of the Office of Management and Budget re FY1982 deficit projections, page %03d.png", i)
                : String(format: "IMG_%04d.png", 4100 + i)
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 160, bitsPerSample: 8,
                                           samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                rep.flatMap { NSGraphicsContext(bitmapImageRep: $0) }.map { ctx in
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    NSColor(white: 0.93, alpha: 1).setFill()
                    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 160)).fill()
                    "p. \(i)".draw(at: NSPoint(x: 12, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                    NSGraphicsContext.restoreGraphicsState()
                }
                guard let png = rep?.representation(using: .png, properties: [:]),
                      (try? png.write(to: url, options: .atomic)) != nil else { continue }
            }
            urls.append(url)
        }
        return urls
    }

    /// Apply deterministic, no-key defaults before SwiftUI creates any `@AppStorage` view. This is a
    /// launch argument rather than a scheme default so ordinary Debug launches remain unchanged.
    static func installScratchDefaults() {
        guard isActive else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKeys.hasSeenKeyOnboarding)
        defaults.set(true, forKey: DefaultsKeys.keychainExplained)
        defaults.set(false, forKey: DefaultsKeys.useGateway)
        defaults.set(arguments.contains("-APUITestLocalAgent"), forKey: DefaultsKeys.useLocalAgent)
        defaults.set(LocalAgentTool.claude.rawValue, forKey: DefaultsKeys.localAgentTool)
        defaults.set("", forKey: DefaultsKeys.localAgentBinaryPath)
        defaults.set("", forKey: DefaultsKeys.localAgentModel)
    }

    private static func urlValue(after flag: String) -> URL? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// The app sandbox cannot read a temporary file owned by the separate XCUITest runner. Build the
    /// two-page input in this app's own temporary directory, then feed it through OCRView's normal URL
    /// admission path. This runs only under the explicit DEBUG test switch and never touches a corpus.
    private static func syntheticMultiPagePDF() -> URL? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-uitest-two-page.pdf")
        let document = PDFDocument()
        for pageIndex in 1...2 {
            let image = NSImage(size: NSSize(width: 180, height: 240))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 180, height: 240)).fill()
            NSColor.black.setFill()
            "Scratch page \(pageIndex)".draw(at: NSPoint(x: 20, y: 110), withAttributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black
            ])
            image.unlockFocus()
            guard let page = PDFPage(image: image) else { return nil }
            document.insert(page, at: document.pageCount)
        }
        guard let data = document.dataRepresentation() else { return nil }
        do {
            try data.write(to: output, options: .atomic)
            return output
        } catch {
            return nil
        }
    }
}
#endif
