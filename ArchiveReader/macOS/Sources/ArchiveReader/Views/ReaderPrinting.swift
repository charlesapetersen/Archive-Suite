import AppKit
import PDFKit

/// File ▸ Print… (W49.reader-print-open-app): the archival file itself, a PDF with all its pages or a JPEG original
/// fitted to the paper. Read-only — the file is opened for drawing and never written. It takes the place of the
/// system's Print… item, which sends `print(_:)` to whichever view has the keyboard and prints only that view.
@MainActor
enum ReaderPrinting {
    /// A print operation for the file, with the print panel, or the reason it cannot be printed.
    static func operation(for url: URL, printInfo: NSPrintInfo = .shared) -> Result<NSPrintOperation, Refusal> {
        let info = printInfo.copy() as? NSPrintInfo ?? printInfo
        let operation: NSPrintOperation
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { return .failure(.unreadable(url.lastPathComponent)) }
            guard !document.isLocked, document.allowsPrinting else { return .failure(.notPrintable(url.lastPathComponent)) }
            guard let pdfOperation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
                return .failure(.notPrintable(url.lastPathComponent))
            }
            operation = pdfOperation
        } else {
            guard let image = NSImage(contentsOf: url), image.isValid,
                  let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
                return .failure(.unreadable(url.lastPathComponent))
            }
            // Drawn at its pixel size and scaled down onto one page; the view never joins a window.
            let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            image.size = size
            let view = NSImageView(frame: NSRect(origin: .zero, size: size))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            info.orientation = size.width > size.height ? .landscape : .portrait
            operation = NSPrintOperation(view: view, printInfo: info)
        }
        operation.jobTitle = url.deletingPathExtension().lastPathComponent
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return .success(operation)
    }

    /// Shows the print panel for the file, as a sheet on `window` when there is one. Returns the status line's text
    /// when the file cannot be printed, else nil.
    @discardableResult static func print(_ url: URL, from window: NSWindow? = NSApp.keyWindow) -> String? {
        switch operation(for: url) {
        case .failure(let refusal): return refusal.message
        case .success(let operation):
            if let window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { operation.run() }
            return nil
        }
    }

    enum Refusal: Error, Equatable {
        case unreadable(String), notPrintable(String)

        var message: String {
            switch self {
            case .unreadable(let name): return "“\(name)” could not be opened for printing."
            case .notPrintable(let name): return "“\(name)” does not allow printing."
            }
        }
    }
}
