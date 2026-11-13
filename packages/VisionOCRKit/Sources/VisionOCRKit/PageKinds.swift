// PageKinds.swift — the engine's page-kind calls a host app reads (W42.int-s3, Stage 3 of
// execution-plans/integration/00-plan.md).
//
// Two of the engine's detectors, open to the app: a newspaper told by the shape of the engine's reading of the page
// (ocr-newspaper-detect, `Recogniser.pageKind(shape:pasteUp:)`) and a photographed page told by its camera tags or
// its pixels (page-kinds-three, `Recogniser.isPhotograph`). The rules stay in Recogniser; this only opens them, so the
// app's call and the engine's are one rule.

import CoreGraphics
import Foundation

public enum EnginePageKind {
    /// Whether a page's lines have a newspaper's shape: more lines than a page of print holds, or 200 or more set
    /// five or more columns across. `lines` are the page's upright lines (a sideways line is left out by the caller,
    /// as `Recogniser.pageShape` leaves out a turned one); a line of under four characters is not counted. The rule
    /// alone, for checks; a page is called with `readNewspaper`, whose lines are the engine's.
    public static func isNewspaper(lines: [PageLine]) -> Bool {
        Recogniser.pageKind(shape: pageShape(lines), pasteUp: false) == .newspaper
    }

    /// `Recogniser.pageShape`'s two signals for `lines`: how many count, and the 90th-percentile width.
    public static func shape(of lines: [PageLine]) -> (lines: Int, wideWidth: Double) {
        let s = pageShape(lines)
        return (s.lines, s.wideWidth)
    }

    static func pageShape(_ lines: [PageLine]) -> Recogniser.PageShape {
        Recogniser.pageShape(widths: lines.filter { $0.text.filter { !$0.isWhitespace }.count >= 4 }
            .map { Double($0.box.width) })
    }

    /// The engine's reading of a page for the newspaper call, as ocr-newspaper-detect measured it: Vision read in
    /// bands and split at the column gutters (`Recogniser.recognisePage`), the gutters fitted, then the shape. A host
    /// app's own single Vision pass finds a fraction of a newspaper's lines (W42.int-s3: 128 against 615 on one page),
    /// so it does not stand in for this. nil when Vision fails on the image. Seconds a page, synchronous: call it off
    /// the main thread (a host app's measure driver that ran it on the main actor stalled inside Vision).
    public static func readNewspaper(_ image: CGImage) -> (isNewspaper: Bool, lines: Int, wideWidth: Double)? {
        assert(!Thread.isMainThread, "EnginePageKind.readNewspaper on the main thread")
        guard let read = try? Recogniser.recognisePage(image, settings: settings) else { return nil }
        let s = Recogniser.pageShape(of: Recogniser.fittedToGutters(read, of: image))
        return (Recogniser.pageKind(shape: s, pasteUp: false) == .newspaper, s.lines, s.wideWidth)
    }

    /// The engine's default settings, read from a store of its own so the host app's saved values never reach the
    /// reading. `register(defaults:)` writes nothing to disk, but its registration domain is process-wide
    /// (`Prefs.swift`), so the engine's keys also read as registered defaults in the host's standard store.
    static let settings: Prefs.Snapshot = {
        let store = UserDefaults(suiteName: "VisionOCRKit.EnginePageKind") ?? UserDefaults()
        Prefs.register(migrate: false, into: store)
        return Prefs.Snapshot.current(store)
    }()

    /// Whether a page image is a photograph rather than a scan: a camera's tags in `properties` (the image file's
    /// `CGImageSourceCopyPropertiesAtIndex`), else the lighting in its pixels.
    public static func isPhotograph(_ image: CGImage, properties: [CFString: Any]?) -> Bool {
        Recogniser.isPhotograph(cameraExposed: Flattener.cameraExposed(properties), image: image)
    }
}
