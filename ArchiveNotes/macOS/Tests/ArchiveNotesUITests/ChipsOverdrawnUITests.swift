import XCTest
import AppKit

/// W40.fix-notes-chips-overdrawn — opening a note with many file chips painted a pale folded-corner document
/// image over each chip, from the middle of its title to past its Preview button. It was AppKit's generic
/// file icon: `BlockHeaderAttachment` is view-backed but had no image, and TextKit drew the nil-data
/// attachment's default icon across the chip's bounds while (re)installing the chip views. The owner saw it
/// appear about two seconds after open; `W40.e11` caught it on open, gone three seconds later.
///
/// XCUITest cannot see it: the chip views and their buttons stay in place underneath, and the attachment
/// subviews are not hit-testable from XCUITest anyway (`VisualReviewUITests`). So this test checks pixels.
/// In dark mode the editor, the chips' tinted pills and the passage text leave no long run of pale pixels on
/// any row; the icon leaves runs of a hundred or more on every chip it covers. The editor is shot straight
/// the moment the note is selected and as fast as XCUITest can shoot for six seconds after, which covers both
/// timings.
final class ChipsOverdrawnUITests: NotesFixtureUITestCase {

    static let idManyChips = "c41c41c4-0000-4000-8000-000000000001"

    override var extraLaunchArguments: [String] { LayoutGuard.darkModeArguments }

    func testManyChipNoteIsNeverOverdrawnByAFileIcon() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            try Self.writeManyChipsNote(id: Self.idManyChips, title: "Many chips — overdraw check")
            app.terminate()
            app.launch()
            app.activate()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 20), "main window after relaunch")

            // Measure the editor's on-screen region on a plain note first, so the first shot of the many-chip
            // note can be taken the moment it is selected. The text view is taller than its scroll view, so the
            // region is the smallest scroll view holding the editor; the pale page thumbnails further down the
            // note must stay out of it.
            selectItem(uuid: Self.idPlain)
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor for the plain note")
            let scrolls = mainWindow.scrollViews.containing(.textView, identifier: "an.editor.text").allElementsBoundByIndex
            let visible = scrolls.map(\.frame).filter { !$0.isEmpty }.min { $0.width * $0.height < $1.width * $1.height }
            let region = editor.frame.intersection(visible ?? mainWindow.frame)
            XCTAssertFalse(region.isNull || region.isEmpty, "the editor's visible region")
            let cell = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idManyChips.uppercased())"]
            XCTAssertTrue(cell.waitForExistence(timeout: 25), "row for the many-chip note")
            cell.click()

            var worst = (shot: -1, rows: 0, run: 0)
            let start = Date()
            var k = 0
            while Date().timeIntervalSince(start) < 6 {
                let png = Self.crop(XCUIScreen.main.screenshot(), to: region)
                let (rows, run) = Self.paleRuns(in: png)
                if rows > worst.rows { worst = (k, rows, run) }
                if rows > 0 || k == 0 { Self.save(png, as: k == 0 ? "open" : "overdrawn-\(k)") }
                print(String(format: "[chips-overdrawn] shot %d at %.2fs: %d pale rows, longest %d px",
                             k, Date().timeIntervalSince(start), rows, run))
                k += 1
            }
            Self.save(Self.crop(XCUIScreen.main.screenshot(), to: region), as: "idle")
            print("[chips-overdrawn] worst shot \(worst.shot): \(worst.rows) pale rows, longest run \(worst.run) px")
            XCTAssertEqual(worst.rows, 0,
                           "shot \(worst.shot) after open has \(worst.rows) rows with a pale run of ≥ \(Self.minRun) px "
                           + "(longest \(worst.run)) — an image is painted over the chips")
        }
    }

    /// W40.fix-notes-chip-inline-layout — each reader-page chip after the first, and the note-passage chip,
    /// were laid out beside the short last line of the block before, half a line up, their names cut to
    /// "sample.pdf…". Once the note has settled at its end (the reported place), every laid-out chip must
    /// start at the same x with the same width (the editor's chip-geometry probe, read from TextKit's own
    /// attachment frames). Only chips whose fragment TextKit has laid out report a frame.
    /// Measured in the VM before this check was tightened: x 17, width 309 for all five laid-out chips.
    func testManyChipNoteLaysEachChipOnItsOwnLine() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            try Self.writeManyChipsNote(id: Self.idManyChips, title: "Many chips — layout check")
            app.terminate()
            app.launch()
            app.activate()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 20), "main window after relaunch")
            selectItem(uuid: Self.idManyChips.uppercased(), timeout: 25)
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor for the many-chip note")
            editor.click()
            editor.typeKey(.downArrow, modifierFlags: .command)
            Thread.sleep(forTimeInterval: 3)
            Self.save(XCUIScreen.main.screenshot().pngRepresentation, as: "layout-page-chips")

            let probe = mainWindow.descendants(matching: .any)["an.editor.test.chipGeometry"]
            XCTAssertTrue(probe.waitForExistence(timeout: 5), "chip-geometry probe")
            let data = Data(((probe.value as? String) ?? "[]").utf8)
            let states = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let slots = states.compactMap { slot -> (loc: Int, x: Double, w: Double)? in
                guard let loc = slot["loc"] as? Int, let x = slot["slotX"] as? Double,
                      let w = slot["slotW"] as? Double, w > 0 else { return nil }
                return (loc, x, w)
            }
            print("[chip-layout] \(slots.map { "\($0.loc): x \($0.x) w \($0.w)" }.joined(separator: "; "))")
            // The view is at the note's end, so the last chips — the reported ones — must be among those laid
            // out (the VM's short editor showed five of the 30 in its first run: the top three and the last two).
            let lastHeader = states.compactMap { $0["loc"] as? Int }.max()
            XCTAssertGreaterThanOrEqual(slots.count, 2, "the chips in view must report their slots")
            XCTAssertEqual(slots.map(\.loc).max(), lastHeader, "the last chip, the note-passage one, must be laid out")
            guard let first = slots.first else { return }
            for slot in slots {
                XCTAssertEqual(slot.x, first.x, accuracy: 0.5, "the chip at \(slot.loc) is not at the line start")
                XCTAssertEqual(slot.w, first.w, accuracy: 0.5, "the chip at \(slot.loc) is not full width")
            }
        }
    }

    // MARK: - Pixels

    /// A run this long of pale pixels on one row is no glyph and no chip; the icon makes runs of 100–250.
    static let minRun = 60

    /// Rows holding a horizontal run of at least `minRun` pale (luminance > 0.7) pixels, and the longest run.
    static func paleRuns(in png: Data) -> (rows: Int, longest: Int) {
        guard let cg = NSBitmapImageRep(data: png)?.cgImage else { return (0, 0) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return (0, 0) }
        var rows = 0, longest = 0
        for y in 0..<h {
            var run = 0, rowLongest = 0
            for x in 0..<w {
                let i = (y * w + x) * 4
                let luma = (299 * Int(px[i]) + 587 * Int(px[i + 1]) + 114 * Int(px[i + 2])) / 1000
                run = luma > 178 ? run + 1 : 0
                rowLongest = max(rowLongest, run)
            }
            longest = max(longest, rowLongest)
            if rowLongest >= minRun { rows += 1 }
        }
        return (rows, longest)
    }

    /// `shot` cropped to `rect` (screen points), as PNG data.
    private static func crop(_ shot: XCUIScreenshot, to rect: CGRect) -> Data {
        guard let cg = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.screens.first?.frame, screen.width > 0 else { return shot.pngRepresentation }
        let scale = CGFloat(cg.width) / screen.width
        let r = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
        guard let cropped = cg.cropping(to: r),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        else { return shot.pngRepresentation }
        return png
    }

    private static func save(_ png: Data, as moment: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-chips-overdrawn-\(moment).png")
        try? png.write(to: url, options: .atomic)
        print("[shot] chips-overdrawn-\(moment): wrote \(url.path)")
    }

    // MARK: - The note

    /// 24 reader-doc chips (the owner's note had ~25 `00984 — Apple Inc` chips), five reader-page chips with
    /// thumbnails and one note-passage chip, written into the canonical scratch fixture. The next test's
    /// pristine restore removes it. `VisualReviewUITests` seeds the same body.
    static func writeManyChipsNote(id: String, title: String, tags: [String] = ["apple inc"]) throws {
        let items = URL(fileURLWithPath: canonicalFixturePath).appendingPathComponent("items")
        let link = "archivereader://reveal?root=\(corpusRootGUID)&rel=sample.pdf&jpeg="
        var body = "---\nschema: 1\nid: \(id)\nkind: note\ntitle: \"\(title)\"\n"
            + "authors: [Gordon E. Moore, Robert N. Noyce]\ndate: 1968-07\ndate_precision: month\n"
            + "date_uncertain: false\nquality: 2\ntags: [\(tags.joined(separator: ", "))]\nroundup: false\n"
            + "created: 2026-07-14T09:00:00Z\nmodified: 2026-07-14T09:00:00Z\n---\n"
        for k in 1...24 {
            body += "<!-- block: reader-doc\n     link: \(link)\n     display: \"00984 — Apple Inc, folder \(k).pdf\" -->\n"
                + "Passage \(k) from the Apple Inc correspondence.\n\n"
        }
        for p in 1...5 {
            body += "<!-- block: reader-page\n     link: \(link)&page=1\n     display: \"sample.pdf — p. \(p)\"\n"
                + "     page: 1\n     thumb: assets/p\(p)-thumb.png -->\n![sample.pdf — p. \(p)](assets/p\(p)-thumb.png)\n\n"
                + "Page passage \(p).\n\n"
        }
        body += "<!-- block: note-passage\n     display: \"Moore on Intel culture — 1968\"\n"
            + "     note: archivenotes://open?id=\(idReader)#block-0 -->\nMoore on the early culture.\n"
        let dir = items.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: dir.appendingPathComponent("\(title).md"))
        let thumb = items.appendingPathComponent(idReader).appendingPathComponent("assets/p1-thumb.png")
        if let png = try? Data(contentsOf: thumb) {
            for p in 1...5 { try png.write(to: dir.appendingPathComponent("assets/p\(p)-thumb.png")) }
        }
    }
}
