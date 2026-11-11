import AppKit
import SwiftUI
import XCTest
@testable import ArchiveReader

/// W40.fix-reader-inspector-narrow — the navigation window at its minimum width with the sidebar and Inspector open.
/// At a fixed 900 pt the two panels left the content column less than its minimum, and the row ran past the
/// window's right edge with the Inspector's Close button outside it (VM, macOS 27.2). The whole window is hosted
/// over throwaway defaults at its minimum and its two panel dividers are found: an overflowing row is centred, so
/// the sidebar's divider moves left of the sidebar's width and the Inspector's right of where the Inspector begins.
@MainActor
final class NavigationWindowMinimumWidthTests: XCTestCase {

    private func host(sidebar: Double?, inspector: Double?, tagCloud: Bool, width: CGFloat) -> NSHostingView<AnyView> {
        let defaults = fixtureDefaults()
        defaults.set(sidebar != nil, forKey: "ar.showSidebar")
        defaults.set(sidebar ?? 210, forKey: "ar.sidebarWidth")
        defaults.set(inspector != nil, forKey: "ar.infoVisible")
        defaults.set(inspector ?? 380, forKey: "ar.infoWidth")
        defaults.set(tagCloud, forKey: "ar.showTagCloud")
        let model = NavigationModel(defaults: defaults, thumbnailer: nil)
        model.showingEditor = inspector != nil
        let view = NavigationWindowView(model: model)
            .environmentObject(DeepLinkRouter())
            .environmentObject(ArchiveLinkContext())
            .defaultAppStorage(defaults)   // nothing the window remembers reaches the app's own domain
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// A panel divider's horizontal extent in the host's coordinates.
    private func divider(_ id: String, in host: NSView) -> ClosedRange<CGFloat>? {
        func find(_ v: NSView) -> NSView? {
            if v is PanelDividerView, v.accessibilityIdentifier() == id { return v }
            return v.subviews.lazy.compactMap(find).first
        }
        guard let v = find(host) else { return nil }
        let f = v.convert(v.bounds, to: host)
        return f.minX...f.maxX
    }

    /// Where each divider is and where it should be, at `width`; `nil` for a panel that is not open.
    private func misplacement(sidebar: Double?, inspector: Double?, tagCloud: Bool, width: CGFloat) -> [String] {
        let host = host(sidebar: sidebar, inspector: inspector, tagCloud: tagCloud, width: width)
        var wrong: [String] = []
        if let sidebar {
            let d = divider("ar.divider.sidebar", in: host)
            if d.map({ abs($0.lowerBound - sidebar) > 0.5 }) ?? true {
                wrong.append("sidebar divider at \(String(describing: d)), expected from x=\(sidebar)")
            }
        }
        if let inspector {
            let d = divider("ar.divider.info", in: host)
            if d.map({ abs($0.upperBound - (width - inspector)) > 0.5 }) ?? true {
                wrong.append("Inspector divider at \(String(describing: d)), expected to end at x=\(width - inspector)")
            }
        }
        return wrong
    }

    func testEveryPanelFitsAtTheMinimumWidth() throws {
        let cases: [(sidebar: Double?, inspector: Double?, cloud: Bool)] = [
            (210, 380, false), (350, 480, false), (140, 340, false), (210, 380, true), (350, 480, true),
            (nil, 480, true), (350, nil, true),
        ]
        for c in cases {
            let minimum = NavigationWindowView.minimumWidth(sidebar: c.sidebar.map { CGFloat($0) },
                                                            inspector: c.inspector.map { CGFloat($0) })
            // The filter bar's rows wrap by width, so the column's need is not one number: a few widths above too.
            for width in [minimum, minimum + 7, minimum + 23, minimum + 61] {
                let wrong = misplacement(sidebar: c.sidebar, inspector: c.inspector, tagCloud: c.cloud, width: width)
                XCTAssertEqual(wrong, [], "sidebar \(String(describing: c.sidebar)), Inspector "
                                        + "\(String(describing: c.inspector)), cloud \(c.cloud), at \(width) pt")
            }
        }
        // The picture at the narrowest with both panels open, for a person to look at.
        let minimum = NavigationWindowView.minimumWidth(sidebar: 210, inspector: 380)
        let view = host(sidebar: 210, inspector: 380, tagCloud: false, width: minimum)
        let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: view, size: CGSize(width: minimum, height: 700)))
        writeRenderArtifact(png, named: "navigation-window-minimum-with-inspector.png")
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "navigation window at its minimum with the Inspector")
    }

    /// The control, and the defect: squeezed to the old fixed 900 pt with both panels open, the same check finds
    /// both dividers out of place, so a pass above is the panels fitting and not a check that cannot tell.
    func testTheCheckSeesTheOverflowAtTheOldFixedMinimum() {
        XCTAssertEqual(misplacement(sidebar: 210, inspector: 380, tagCloud: false, width: 900).count, 2)
    }

    func testTheMinimumAddsThePanelsAndKeepsTheFloor() {
        XCTAssertEqual(NavigationWindowView.minimumWidth(sidebar: nil, inspector: nil), 900)
        XCTAssertEqual(NavigationWindowView.minimumWidth(sidebar: 210, inspector: nil), 900)
        XCTAssertEqual(NavigationWindowView.minimumWidth(sidebar: 210, inspector: 380),
                       210 + 380 + 2 * PanelDivider.width + NavigationWindowView.contentColumnMinWidth)
    }
}
