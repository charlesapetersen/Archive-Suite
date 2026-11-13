// PageKinds.swift — the engine's page-kind calls a host app reads (W42.int-s3, Stage 3 of
// execution-plans/integration/00-plan.md).
//
// Two of the engine's detectors, open to the app: a newspaper told by the shape of Vision's lines
// (ocr-newspaper-detect, `Recogniser.pageKind(shape:pasteUp:)`) and a photographed page told by its camera tags or
// its pixels (page-kinds-three, `Recogniser.isPhotograph`). The rules stay in Recogniser; this only opens them, so the
// app's call and the engine's are one rule.

import CoreGraphics
import Foundation

public enum EnginePageKind {
    /// Whether Vision's reading of a page has a newspaper's shape: more lines than a page of print holds, or 200 or
    /// more set five or more columns across. `lines` are the page's upright lines (a sideways line is left out by the
    /// caller, as `Recogniser.pageShape` leaves out a turned one); a line of under four characters is not counted.
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

    /// Whether a page image is a photograph rather than a scan: a camera's tags in `properties` (the image file's
    /// `CGImageSourceCopyPropertiesAtIndex`), else the lighting in its pixels.
    public static func isPhotograph(_ image: CGImage, properties: [CFString: Any]?) -> Bool {
        Recogniser.isPhotograph(cameraExposed: Flattener.cameraExposed(properties), image: image)
    }
}
