import XCTest
import SwiftUI
import AppKit
@testable import ArchiveNotes

/// W40.fix-notes-tag-fields (owner session notes-2 rows 20, 24): the filter bar's and Advanced Search's tag field is
/// the suite's autocompleting token field at a usable width, and the chosen tags are chips that wrap rather than
/// squeeze it. Lays the real view out headlessly; XCUITest sees no sizes worth trusting here.
@MainActor
final class NoteTagChipsFieldLayoutTests: XCTestCase {
    private struct Harness: View {
        @State var tags: [String]
        @State var draft = ""
        var body: some View {
            NoteTagChipsField(tags: $tags, draft: $draft, identifier: "probe.input", chipIdentifier: "probe.chip",
                              suggestions: { ["Silicon Valley", "Intel"] })
                .frame(width: 300, alignment: .leading)
        }
    }

    private func tokenFields(in view: NSView) -> [NSTokenField] {
        (view as? NSTokenField).map { [$0] } ?? view.subviews.flatMap(tokenFields)
    }

    func testFieldKeepsItsWidthAndChipsWrapAbove() throws {
        let host = NSHostingView(rootView: Harness(tags: ["Computing History", "Corporate Culture", "Intel"]))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.layoutSubtreeIfNeeded()
        let fields = tokenFields(in: host)
        XCTAssertEqual(fields.count, 1, "one token field, the suite's SubjectEntryField")
        let field = try XCTUnwrap(fields.first)
        XCTAssertEqual(field.frame.width, NoteTagChipsField.fieldWidth, accuracy: 1,
                       "the field keeps its width beside three chips, saw \(field.frame.width)")
        XCTAssertGreaterThanOrEqual(field.frame.width, 160, "big enough for a tag and its completion")
        XCTAssertNotNil(field.delegate, "the field autocompletes through its delegate")
        let fitting = host.fittingSize
        XCTAssertGreaterThan(fitting.height, 40, "three chips and the field do not fit one 300-point line, so they "
                             + "wrap to more than one, saw \(fitting.height)")
    }

    func testNoChipsLeavesOneLine() {
        let host = NSHostingView(rootView: Harness(tags: []))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, 40, "only the field, one line, saw \(host.fittingSize.height)")
    }
}
