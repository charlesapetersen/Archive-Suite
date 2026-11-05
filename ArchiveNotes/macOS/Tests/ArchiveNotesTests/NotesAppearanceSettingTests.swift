import Testing
import AppKit
import ArchiveCore
@testable import ArchiveNotes

// W48.appearance-notes — the Notes side of the Appearance setting: its stored value and default in a scratch
// defaults suite, the UI-test reset that keeps one test's choice out of the next, and the one AppKit colour Notes
// resolves itself (the source chip's fill), which has to follow the appearance it is shown in. The shared value
// type and `apply` are covered in ArchiveCore (`AppAppearanceTests`).

@Suite("Notes Appearance setting")
@MainActor
struct NotesAppearanceSettingTests {

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "notes-appearance-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("nothing stored reads as System; a stored choice reads back")
    func storedValueAndDefault() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppAppearance.stored(in: defaults) == .system)
        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
        #expect(AppAppearance.stored(in: defaults) == .dark)
        defaults.set(AppAppearance.light.rawValue, forKey: AppAppearance.defaultsKey)
        #expect(AppAppearance.stored(in: defaults) == .light)
    }

    @Test("a fixture UI-test launch starts from System unless it asks to keep the choice")
    func uiTestResetClearsOnlyFixtureLaunches() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let key = AppAppearance.defaultsKey

        defaults.set("dark", forKey: key)
        NotesAppearanceUITestDefaults.clearStoredChoiceIfUITest(arguments: ["ArchiveNotes"], defaults: defaults)
        #expect(defaults.string(forKey: key) == "dark", "a real launch never loses the owner's choice")

        NotesAppearanceUITestDefaults.clearStoredChoiceIfUITest(
            arguments: ["ArchiveNotes", "-ANUITestStorePath", "/tmp/x", "-ANUITestKeepAppearance", "YES"],
            defaults: defaults)
        #expect(defaults.string(forKey: key) == "dark", "the relaunch check keeps the choice")

        NotesAppearanceUITestDefaults.clearStoredChoiceIfUITest(
            arguments: ["ArchiveNotes", "-ANUITestStorePath", "/tmp/x"], defaults: defaults)
        #expect(defaults.string(forKey: key) == nil)
        #expect(AppAppearance.stored(in: defaults) == .system)
    }

    @Test("the source chip's fill is resolved in the appearance it is shown in, and again on a change")
    func chipFillFollowsAppearance() throws {
        let reader = SourceAnchor(
            link: "archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=test.pdf", display: "Doc")
        let passage = SourceAnchor.notePassage(sourceNoteId: UUID(), sourceBlockIndex: 0, sourceTitle: "Gone",
                                               sourceDateDisplay: "")
        // A source chip is tinted with the accent colour; a passage whose source note is gone with the secondary
        // label colour, which is far lighter in Dark, so that one also proves the appearance changes the fill.
        let cases: [(BlockHeaderChipView, NSColor, Bool)] = [
            (BlockHeaderChipView(box: SourceAnchorBox(anchor: reader, kind: .readerDoc), onReveal: nil),
             .controlAccentColor, false),
            (BlockHeaderChipView(box: SourceAnchorBox(anchor: passage, kind: .readerDoc), onReveal: nil,
                                 sourceMissing: true), .secondaryLabelColor, true),
        ]
        for (chip, tint, mustDiffer) in cases {
            #expect(chip.wantsUpdateLayer)
            var fills: [NSAppearance.Name: CGColor] = [:]
            for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                chip.appearance = appearance
                chip.updateLayer()
                var expected: CGColor?
                appearance.performAsCurrentDrawingAppearance { expected = tint.withAlphaComponent(0.12).cgColor }
                let fill = try #require(chip.layer?.backgroundColor)
                #expect(fill == expected, "\(name.rawValue): the chip's fill should be this appearance's tint")
                fills[name] = fill
            }
            if mustDiffer {
                #expect(fills[.aqua] != fills[.darkAqua], "the light and dark fills should differ")
            }
        }
    }

    // W48.appearance-verify: the Missing and Blocked tiles are the other thing Notes draws itself, and no tour reaches
    // one. The same shared image is drawn in Dark, Light and Dark again; its label and fill are label colours, so
    // the drawn pixels are far lighter in Dark, and a tile drawn once into a bitmap would read the same in both.
    @Test("the Missing and Blocked tiles are drawn in the appearance they are shown in")
    func placeholderTilesFollowAppearance() throws {
        for kind in [InlineImageAttachment.Placeholder.missing, .outOfBounds] {
            let image = try #require(InlineImageAttachment(relativePath: "assets/gone.png", placeholder: kind).image)
            var drawn: [Double] = []
            for name in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
                drawn.append(try luminanceOfOpaquePixels(image, in: #require(NSAppearance(named: name))))
            }
            #expect(drawn[0] > drawn[1] + 0.3, "\(kind): Dark \(drawn[0]) should be far lighter than Light \(drawn[1])")
            #expect(abs(drawn[2] - drawn[0]) < 0.01, "\(kind): Dark again \(drawn[2]) should match Dark \(drawn[0])")
        }
    }

    /// The alpha-weighted mean luminance, 0 to 1, of `image` drawn into a clear 64×64 bitmap in `appearance`.
    private func luminanceOfOpaquePixels(_ image: NSImage, in appearance: NSAppearance) throws -> Double {
        let side = 64
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.bitmapData)
        var light = 0.0, alpha = 0.0
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            // Premultiplied, so the colour channels already carry the alpha weighting.
            light += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
            alpha += Double(data[i + 3])
        }
        return alpha > 0 ? light / alpha : 0
    }
}
