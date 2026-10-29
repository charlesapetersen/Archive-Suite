// W46.ent-score: Apple NLTagger's name spans for each document, for ent_score.py's position rule.
// stdin: JSON lines {"id": ..., "text": ...}; stdout: JSON lines {"id": ..., "spans": [{"tag", "start", "end", "text"}]}
// offsets in Unicode scalars, which are Python string indices. Run: swift nltag_names.swift < in > out
import Foundation
import NaturalLanguage

let tags: [NLTag] = [.personalName, .placeName, .organizationName]
while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = obj["id"] as? String, let text = obj["text"] as? String else { continue }
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    // Fixed, not guessed: noisy OCR of an English letter can be taken for another language and lose every name.
    tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
    var spans: [[String: Any]] = []
    let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
    tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                         options: opts) { tag, range in
        if let tag, tags.contains(tag) {
            spans.append(["tag": tag.rawValue,
                          "start": text.unicodeScalars.distance(from: text.startIndex, to: range.lowerBound),
                          "end": text.unicodeScalars.distance(from: text.startIndex, to: range.upperBound),
                          "text": String(text[range])])
        }
        return true
    }
    let out = try! JSONSerialization.data(withJSONObject: ["id": id, "spans": spans])
    print(String(data: out, encoding: .utf8)!)
}
