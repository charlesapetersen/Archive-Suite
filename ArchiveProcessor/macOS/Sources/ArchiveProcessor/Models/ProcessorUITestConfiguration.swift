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
    /// Opens the real Live Capture view with only its non-writing finishing-scrim state armed. This lets the
    /// VM UI test inspect the focus/AX barrier without starting a receiver, OCR, or a finalize operation.
    static var showsLiveCaptureFinishingScrim: Bool {
        isActive && arguments.contains("-APUITestLiveCaptureFinishingScrim")
    }
    static var droppedPDF: URL? {
        if let path = urlValue(after: "-APUITestDroppedPDFPath") { return path }
        guard arguments.contains("-APUITestSyntheticMultiPagePDF") else { return nil }
        return syntheticMultiPagePDF()
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
