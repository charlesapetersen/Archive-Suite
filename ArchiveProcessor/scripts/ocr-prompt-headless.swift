import Foundation

// Only the classification type is stubbed; the builder and response parser are production code.
enum DocumentClassification: String, CaseIterable {
    case boxLabel = "box_label", folderLabel = "folder_label"
    case documentStart = "document_start", documentContinuation = "document_continuation"
}

@main struct OCRPromptCheck {
    static func main() {
        var failed = 0
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failed += 1; print("FAIL: \(name)") }
        }

        // These are the owner's panel rulings, applied to TASK 3 in every context variant.
        let rules = [
            "Transcribe everything on this sheet of paper, including headers, footers, citations, stamps and copyright lines that a database or archive added to the page.",
            "Leave out only text on a different sheet that shows in the photograph: a page underneath or beside this one, or a folder behind it.",
            "Write each bullet point as \"*\". Leave out empty checkboxes and other symbols that are not text.",
            "Write [illegible] for a word that cannot be read."
        ]
        for previous in [nil, "", "Earlier page ended here."] as [String?] {
            for imageIncluded in [false, true] {
                for custom in [nil, "", "  \n", "Collection context."] as [String?] {
                    let prompt = OCRPrompt.build(previousText: previous,
                                                 previousImageIncluded: imageIncluded, customPrompt: custom)
                    let task3 = prompt.components(separatedBy: "TASK 3 —").last?
                        .components(separatedBy: "FORMAT —").first ?? ""
                    for rule in rules { check("TASK 3 includes: \(rule)", task3.contains(rule)) }
                    check("foreground labels still transcribed", task3.contains("For a box-label or folder-label photograph, transcribe the foreground box or folder label."))
                    check("foreground scope retained", prompt.contains("focus ONLY on the foreground page"))
                    check("no KIND field", !prompt.contains("KIND"))
                    check("response shape retained", prompt.contains("[classification_tag]\n[rotate_N]\n(transcribed text)"))
                    check("custom context retained", prompt.contains("ADDITIONAL CONTEXT") == (custom == "Collection context."))
                    check("previous text retained", prompt.contains("Previous page's text ended with:") == (previous == "Earlier page ended here."))
                }
            }
        }

        // Text which the new instruction asks for must survive the existing response parser verbatim.
        let body = "ARCHIVE HEADER\nDear Reader,\n* First point\n* [illegible] word\nCopyright database footer"
        for classification in DocumentClassification.allCases {
            for rotation in [0, 90, 180, 270] {
                let parsed = OCRPrompt.parseResponse("[\(classification.rawValue)]\n[rotate_\(rotation)]\n\(body)")
                check("classification \(classification) / \(rotation)", parsed.classification == classification)
                check("rotation \(classification) / \(rotation)", parsed.rotationDegrees == rotation)
                check("transcription \(classification) / \(rotation)", parsed.text == body)
            }
        }
        let enclosure = "[document_start] [enclosure]\n[rotate_90]\n\(body)"
        check("enclosure marker retained", OCRPrompt.parseEnclosureFlag(enclosure))
        check("enclosure text retained", OCRPrompt.parseResponse(enclosure).text == body)
        print("OCR PROMPT: \(checks - failed)/\(checks) checks passed")
        if failed > 0 { exit(1) }
    }
}
