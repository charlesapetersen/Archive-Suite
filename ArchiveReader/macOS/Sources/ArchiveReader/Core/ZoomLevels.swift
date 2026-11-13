import CoreGraphics

/// The steps Zoom In and Zoom Out move through, as multiples of actual size (1 = 100%). Shared by the image
/// and text pages (`PDFPaneController`) and the extracted text's size (`DocumentViewerModel.textScale`).
///
/// W40.reader-zoom-levels (owner, 2026-11-13: "More zoom levels for reader"). Each step used to multiply or
/// divide the zoom by 1.25, so from 100% the only stops were 80%, 64%, 51% down and 125%, 156%, 195% up. The
/// ladder below is finer around the sizes a page is read at (10% apart near 100%)
/// and lands on round percentages. A zoom between two levels (a fitted page, a pinch) moves to the next
/// level up or down. Past either end of the ladder a step is 1.25 again; the view's own limits still clamp.
enum ZoomLevels {
    static let levels: [CGFloat] = [
        0.1, 0.125, 0.15, 0.175, 0.2, 0.25, 0.3, 0.33, 0.4, 0.5, 0.6, 0.67, 0.75, 0.8, 0.9,
        1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20,
    ]

    /// Beyond the ladder, and the old step everywhere.
    static let outerStep: CGFloat = 1.25

    /// A level within 1% of the current zoom counts as the current one, so a page PDFKit rescaled slightly
    /// (its scrollers settling) still moves a whole step.
    private static let tolerance: CGFloat = 1.01

    /// The next level above `scale`.
    static func zoomIn(from scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1 }
        return levels.first { $0 > scale * tolerance } ?? scale * outerStep
    }

    /// The next level below `scale`.
    static func zoomOut(from scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 1 }
        return levels.last { $0 < scale / tolerance } ?? scale / outerStep
    }
}
