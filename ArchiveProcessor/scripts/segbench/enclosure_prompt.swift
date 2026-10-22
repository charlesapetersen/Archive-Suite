import Foundation

// W46.date-enclosure: the app's own OCR prompt builder and header parser, compiled beside OCRPrompt.swift, so the
// marker is measured with the exact prompt the app sends and read with the exact parser it uses.
//   enclosure-prompt build  < {"id", "previous"} lines  > {"id", "prompt"} lines   (no previous image, no custom prompt)
//   enclosure-prompt parse  < {"id", "raw"} lines       > {"id", "classification", "enclosure"} lines
// Only the classification type is stubbed, as in ocr-prompt-headless.swift.
enum DocumentClassification: String, CaseIterable {
    case boxLabel = "box_label", folderLabel = "folder_label"
    case documentStart = "document_start", documentContinuation = "document_continuation"
}

@main struct EnclosurePrompt {
    static func main() {
        let mode = CommandLine.arguments.dropFirst().first ?? ""
        guard mode == "build" || mode == "parse" else {
            FileHandle.standardError.write("usage: enclosure-prompt build|parse < jsonl\n".data(using: .utf8)!)
            exit(2)
        }
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = row["id"] as? String else { continue }
            var out: [String: Any] = ["id": id]
            if mode == "build" {
                let previous = row["previous"] as? String
                out["prompt"] = OCRPrompt.build(previousText: previous, previousImageIncluded: false)
            } else {
                let raw = row["raw"] as? String ?? ""
                out["classification"] = OCRPrompt.parseResponse(raw).classification?.rawValue ?? NSNull()
                out["enclosure"] = OCRPrompt.parseEnclosureFlag(raw)
            }
            let encoded = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            print(String(data: encoded, encoding: .utf8)!)
        }
    }
}
