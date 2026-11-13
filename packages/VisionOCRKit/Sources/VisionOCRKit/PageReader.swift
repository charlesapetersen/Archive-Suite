// PageReader.swift — one way to read a page (W42.int-s2, Stage 2 of execution-plans/integration/00-plan.md).
//
// Every reader of a page image sits behind this one protocol: Apple Vision, each local model with its arrangement,
// each paid provider and the gateway, and the subscription command-line tools. A reading takes the page image and
// Vision's lines (Vision is free and gives the geometry; a reader that places its words uses them) and returns the
// text in reading order, the words with their positions where the reader has them, and what the reading cost: the
// seconds it took, the dollars it cost and the memory it used, each nil where the reader cannot say.
//
// The app's own result travels in `detail` (Archive Processor's OCRResult carries its classification, rotation and
// failure code), so a reader adds the measures without the package knowing the app's types.

import CoreGraphics
import Foundation

/// One of Vision's lines on the page: its text, its box (normalised 0...1, origin top-left) and Vision's confidence.
public struct PageLine: Sendable, Equatable {
    public var text: String
    public var box: CGRect
    public var confidence: Float

    public init(text: String, box: CGRect, confidence: Float) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// A word a reader returned, with its box (normalised, origin top-left) when the reader gives positions.
public struct PageWord: Sendable, Equatable {
    public var text: String
    public var box: CGRect?

    public init(text: String, box: CGRect? = nil) {
        self.text = text
        self.box = box
    }
}

/// What a reader is given for one page.
public struct PageReaderInput: Sendable {
    /// The page image on disk.
    public var imageURL: URL
    /// Vision's lines, when the run has them; empty when Vision has not read the page.
    public var visionLines: [PageLine]
    /// The previous page's text and image, for readers that take context.
    public var previousText: String?
    public var previousImageURL: URL?
    /// A prompt that replaces the reader's own, for readers that take one.
    public var customPrompt: String?
    /// The dimension scale the image is sent at (1 = full size).
    public var imageScale: Double

    public init(imageURL: URL, visionLines: [PageLine] = [], previousText: String? = nil,
                previousImageURL: URL? = nil, customPrompt: String? = nil, imageScale: Double = 1) {
        self.imageURL = imageURL
        self.visionLines = visionLines
        self.previousText = previousText
        self.previousImageURL = previousImageURL
        self.customPrompt = customPrompt
        self.imageScale = imageScale
    }
}

/// One reading of one page.
public struct PageReading<Detail: Sendable>: Sendable {
    /// The text in reading order; nil when the reader returned none (the detail says why).
    public var text: String?
    /// The words with positions, when the reader gives them; empty otherwise.
    public var words: [PageWord]
    /// Wall-clock seconds the reading took.
    public var seconds: Double
    /// Dollars the reading cost at the route's prices; nil for a reader that is not money (Vision, a local model,
    /// a subscription tool) or whose price is unknown.
    public var dollars: Double?
    /// Peak resident memory the reading used, in bytes, for readers on this Mac that measure it.
    public var memoryBytes: UInt64?
    /// The app's own result for the page.
    public var detail: Detail

    public init(text: String?, words: [PageWord] = [], seconds: Double, dollars: Double? = nil,
                memoryBytes: UInt64? = nil, detail: Detail) {
        self.text = text
        self.words = words
        self.seconds = seconds
        self.dollars = dollars
        self.memoryBytes = memoryBytes
        self.detail = detail
    }
}

/// A reader of page images. `route` names it the way the measured table and the router do (`Provider|model`).
public protocol PageReader<Detail>: Sendable {
    associatedtype Detail: Sendable
    var route: String { get }
    func read(_ page: PageReaderInput) async throws -> PageReading<Detail>
}
