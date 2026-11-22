import Foundation
import NaturalLanguage

/// Calls Apple's on-device name tagger using the settings measured in segbench/nltag_names.swift.
/// The positional rule is from segbench/ent_score.py. Spans and their roles remain low confidence
/// even though each quote is copied exactly from the OCR text.
enum LocalNameFinder {
    struct Span {
        let tag: NLTag
        var range: Range<String.Index>
    }

    static func extract(_ document: String, mode: EntityRunPolicy.LocalMode) -> EntityExtractor.Fields {
        let text = EntityExtractor.sent(document)
        guard !text.isEmpty else { return .init() }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let bounds = text.startIndex..<text.endIndex
        // The correspondence benchmark fixed English because OCR noise often fooled language detection.
        tagger.setLanguage(.english, range: bounds)
        var spans: [Span] = []
        tagger.enumerateTags(in: bounds, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                spans.append(Span(tag: tag, range: range))
            }
            return true
        }
        return fields(in: text, spans: spans, mode: mode)
    }

    static func fields(in text: String, spans: [Span], mode: EntityRunPolicy.LocalMode) -> EntityExtractor.Fields {
        var joined: [Span] = []
        for span in spans {
            if let previous = joined.last, previous.tag == span.tag,
               previous.range.upperBound <= span.range.lowerBound {
                let gap = text[previous.range.upperBound..<span.range.lowerBound]
                let initials = gap.unicodeScalars.count <= 6
                    && gap.range(of: #"^[ \t]*([A-Z]\.?[ \t]*)*$"#, options: .regularExpression) != nil
                let cityRegion = span.tag == .placeName
                    && gap.range(of: #"^[ \t]*,[ \t]*$"#, options: .regularExpression) != nil
                if initials || cityRegion {
                    joined[joined.count - 1].range = previous.range.lowerBound..<span.range.upperBound
                    continue
                }
            }
            joined.append(span)
        }

        func name(_ s: Span) -> EntityExtractor.Name {
            let quote = String(text[s.range])
            let value = quote.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return .init(name: value, quote: quote, evidence: .quoted(distance: 0))
        }

        if mode == .mentions {
            var seen = Set<String>()
            let mentions = joined.map(name).filter { seen.insert($0.name.lowercased()).inserted }
            return .init(mentions: mentions)
        }

        // These roles are meaningful only for known correspondence. Count LF, including in CRLF,
        // to match the line offsets used by the benchmark.
        let lines = text.components(separatedBy: "\n")
        let nonblank = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let top = Set(nonblank.prefix(10))
        let foot = Set(nonblank.suffix(12))
        let salutation = nonblank.prefix(40).first {
            lines[$0].range(of: #"^\s*(dear|my dear|gentlemen|sir|madam|to whom|mr\.? president|memorandum to|to:)"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
        }
        let closing = nonblank.last {
            $0 > (salutation ?? 0) && lines[$0].split(whereSeparator: \.isWhitespace).count <= 8
                && lines[$0].range(of: #"\b(sincerely|faithfully|truly|cordially|respectfully|regards|yours|affectionately|gratefully|best wishes|as ever|love)\b"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil
        }
        let located = joined.map { span in
            (span: span, line: text[..<span.range.lowerBound].utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) })
        }
        let people = located.filter { $0.span.tag == .personalName }
        let signing = closing.flatMap { line in people.first { $0.line >= line } }
            ?? people.last { foot.contains($0.line) && $0.line > (salutation ?? -1) }
            ?? located.first { $0.span.tag == .organizationName && top.contains($0.line) }
        let others = people.filter { $0.span.range != signing?.span.range }
        let addressee = if let salutation {
            others.last { $0.line < salutation } ?? people.first { $0.line == salutation }
        } else {
            others.first { top.contains($0.line) }
        }
        let place = located.first { $0.span.tag == .placeName && top.contains($0.line) }
        return .init(senders: signing.map { [name($0.span)] } ?? [],
                     recipients: addressee.map { [name($0.span)] } ?? [],
                     sendingPlaces: place.map { [name($0.span)] } ?? [])
    }
}
