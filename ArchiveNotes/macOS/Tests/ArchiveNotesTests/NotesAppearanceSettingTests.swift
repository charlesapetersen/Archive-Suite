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
}
