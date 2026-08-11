// UITestText.swift — read an element's on-screen text the way this app actually exposes it.
//
// W26.verify-fu2. A SwiftUI `Text` in these apps surfaces its string as the accessibility **value**,
// and its **label** is EMPTY. Measured in the VM on 2026-08-10, dumping every static text in the
// Reader's navigation window:
//
//     id=<ar.status.message>   label=<>   value=<Marked 2; 1 could not update.>
//     id=<ar.status.scanning>  label=<>   value=<Scanning…>
//     id=<ar.sidebar.allFiles> label=<>   value=<All Files>
//
// The same holds for a `ContentUnavailableView` collapsed with `.accessibilityElement(children:
// .combine)`: the combined string arrives as the value.
//
// WHY THIS FILE EXISTS RATHER THAN A `.label` AT EACH CALL SITE. Two of the three `WarmStartUITests`
// checks read `.label` and asserted on it. They were authored while the VM lane was blind
// (`W26.vmuitest-blind`), so they had never once executed; when the lane could finally see, both failed
// with an assertion message that quoted an EMPTY actual — which reads like the app printed nothing,
// when in fact the app printed exactly the right sentence and the test looked in the wrong property.
// The refusal those tests exist to prove *was* happening the whole time.
//
// The idiom was already in the suite — `ArchiveReaderUITests.testAnUntaggedFolderShowsTheScanned‐
// Denominator` joins label and value, which is precisely why the COLD half of that check passed while
// the WARM half failed. One helper, so the next test cannot pick the wrong half by accident.

import XCTest

extension XCUIElement {

    /// Label and value joined — the element's visible text, wherever AppKit chose to put it.
    ///
    /// Joined rather than "value else label" on purpose: an element may legitimately carry both (a
    /// labelled control with a value), and a `contains` assertion wants the whole sentence. Empty parts
    /// are dropped so the result never has stray padding for a caller comparing exactly.
    var accessibilityText: String {
        [label, (value as? String) ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
