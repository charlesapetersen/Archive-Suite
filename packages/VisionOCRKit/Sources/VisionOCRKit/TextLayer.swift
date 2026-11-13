// TextLayer.swift — the searchable layer a host app lays on its page image (W42.int-s5, Stage 5 of
// execution-plans/integration/00-plan.md).
//
// Three of the engine's steps, open to the app, so the app's layer and Vision OCR's are one rule
// (`execution-plans/processing-review/13-stage-rules/05-placement.md` §3, print): Vision's lines as the engine reads
// them (`Recogniser.recognisePage`), the chosen reader's words aligned onto them (`Recogniser.alignedReading`, which
// keeps Vision's words on a page where under half of them anchor), and the lab writer drawing one invisible run per
// line (`SearchableWriter.compose`). Which pages get a layer is the app's rule; this only places one.

import CoreGraphics
import Foundation

public enum TextLayer {
    /// What a page's layer was built from.
    public enum Placement: String, Sendable {
        /// Vision's lines with the reader's words aligned onto them (`vision-lines-aligned`); also a reading that
        /// says what Vision says, so the words stay.
        case aligned
        /// Vision's own words: no reading was given, or under half of Vision's words anchored in it (`vision-own`,
        /// the table's fallback).
        case visionOwn
    }

    /// A page's lines as the engine holds them: each line's turn and pasted-up strip travel with it, since the
    /// aligner and the writer order by them. Normalised to the image, top-left origin.
    public struct Lines: @unchecked Sendable {
        let observations: [SearchableWriter.Observation]
        public let placement: Placement
        /// Each line's text and box, for a caller that reports or checks them.
        public var lines: [PageLine] {
            observations.map {
                PageLine(text: $0.text, box: CGRect(x: $0.boundingBox.x, y: $0.boundingBox.y,
                                                    width: $0.boundingBox.width, height: $0.boundingBox.height),
                         confidence: Float($0.confidence))
            }
        }
        /// Every line's words, in Vision's order, for a caller that counts them.
        public var words: [String] { observations.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) } }
        public var isEmpty: Bool { observations.isEmpty }
    }

    /// Vision's lines on `image` as the engine reads them (in bands, split at column gutters). nil when Vision fails.
    /// Synchronous and seconds a page: call it off the main thread.
    public static func visionLines(of image: CGImage) -> Lines? {
        assert(!Thread.isMainThread, "TextLayer.visionLines on the main thread")
        guard let read = try? Recogniser.recognisePage(image, settings: EnginePageKind.settings) else { return nil }
        return Lines(observations: read, placement: .visionOwn)
    }

    /// Lines from plain text and boxes, for a check or a caller with lines of its own (no turn, no strip).
    public static func lines(_ lines: [PageLine]) -> Lines {
        Lines(observations: lines.map {
            SearchableWriter.Observation(boundingBox: .init(x: $0.box.minX, y: $0.box.minY,
                                                            width: $0.box.width, height: $0.box.height),
                                         text: $0.text, confidence: Double($0.confidence))
        }, placement: .visionOwn)
    }

    /// `lines` with `reading`'s words aligned onto them. A nil or empty reading, or one under half of whose words
    /// anchor (the aligner's own guard), keeps Vision's words. `aspect` is the image's height over its width.
    public static func aligned(_ lines: Lines, reading: String?, aspect: Double) -> Lines {
        let words = reading.map(Recogniser.modelWords) ?? []
        guard !lines.isEmpty, !words.isEmpty else { return Lines(observations: lines.observations, placement: .visionOwn) }
        let after = Recogniser.alignedReading(of: lines.observations, from: words, aspect: aspect)
        let changed = zip(lines.observations, after).contains { $0.text != $1.text }
        // Unchanged lines are either a reading that says what Vision says or one the aligner's guard refused; the
        // two are told apart by the share of Vision's words the reading holds, the guard's own half.
        return Lines(observations: after, placement: changed || sharesHalf(lines.words, words) ? .aligned : .visionOwn)
    }

    /// Whether at least half of `vision`'s words are among `reading`'s, compared as the aligner compares them.
    static func sharesHalf(_ vision: [String], _ reading: [String]) -> Bool {
        let keys = vision.map(Recogniser.alignmentKey).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return false }
        var pool: [String: Int] = [:]
        for w in reading { pool[String(Recogniser.alignmentKey(w)), default: 0] += 1 }
        var held = 0
        for k in keys.map({ String($0) }) where (pool[k] ?? 0) > 0 { pool[k]! -= 1; held += 1 }
        return 2 * held >= keys.count
    }

    /// Writes `imagePage` (a one-page PDF holding the page image) to `destination` with an invisible text layer of
    /// `lines` over it. `imageFrame` is where the image sits on the page, normalised to the page with a top-left
    /// origin (the whole page when the image fills it). Returns how many lines the writer could not place (0 when
    /// every line landed).
    @discardableResult
    public static func write(imagePage: URL, lines: Lines, imageFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                             to destination: URL) throws -> Int {
        let onPage = lines.observations.map { o in
            SearchableWriter.Observation(
                boundingBox: .init(x: imageFrame.minX + o.boundingBox.x * imageFrame.width,
                                   y: imageFrame.minY + o.boundingBox.y * imageFrame.height,
                                   width: o.boundingBox.width * imageFrame.width,
                                   height: o.boundingBox.height * imageFrame.height),
                text: o.text, confidence: o.confidence, quarterTurns: o.quarterTurns, region: o.region)
        }
        return try SearchableWriter.compose(visible: imagePage, observations: [1: onPage], to: destination).count
    }
}
