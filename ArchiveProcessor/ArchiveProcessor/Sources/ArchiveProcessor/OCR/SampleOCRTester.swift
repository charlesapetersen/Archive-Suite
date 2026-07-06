import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
#endif

/// Runs the REAL OCR pipeline on a small synthetic image containing a known token, using a given key —
/// the end-to-end confirmation in the key wizard. Proves the key works for OCR (not just auth) and, for
/// Mistral, surfaces the "OCR needs a paid plan" case that plain auth-validation cannot see.
enum SampleOCRTester {
    /// Rendered into the test image; clear printed text that any OCR model transcribes trivially.
    static let token = "ARCHIVE OCR TEST 2718"

    static func run(account: String, key: String) async -> KeyValidator.KeyStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }
        guard let url = writeSampleImage() else { return .unknown("sample-image") }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let result: OCRResult
            switch account {
            case LLMProvider.gemini.rawValue:
                let model = LLMModel.geminiModels.first { $0.id == "gemini-2.5-flash-lite" } ?? LLMModel.geminiModels[0]
                result = try await GeminiClient(apiKey: trimmed, model: model, thinkingLevel: nil).ocr(imageURL: url)
            case LLMProvider.mistral.rawValue:
                guard let model = LLMModel.mistralModels.first else { return .unknown("model") }
                result = try await MistralClient(apiKey: trimmed, model: model).ocr(imageURL: url)
            default:
                return .unknown("provider")
            }
            if let text = result.text, !text.isEmpty { return .works }
            return KeyValidator.classifySampleOCR(errorCode: result.errorCode, errorMessage: result.errorMessage)
        } catch {
            return .offline
        }
    }

    #if canImport(AppKit)
    private static func writeSampleImage() -> URL? {
        let size = NSSize(width: 900, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        (token as NSString).draw(at: NSPoint(x: 40, y: 110), withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkeytest-\(UUID().uuidString).jpg")
        do { try jpeg.write(to: url); return url } catch { return nil }
    }
    #else
    // iOS/other: implemented when the core is extracted into the ArchiveCore package (Phase 3).
    private static func writeSampleImage() -> URL? { nil }
    #endif
}
