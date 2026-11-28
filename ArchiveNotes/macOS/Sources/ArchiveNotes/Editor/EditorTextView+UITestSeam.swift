import AppKit

// MARK: - DEBUG UI-test seam & accessibility probes (W8-S7 §3.3; split in W49.notes-model-split)

#if DEBUG
extension EditorTextView {
    func uiTestInstalledChipGeometry() -> String? {
        var states: [[String: Any]] = []
        func visit(_ view: NSView) {
            if let chip = view as? BlockHeaderChipView, let id = chip.uiTestSourceNoteID {
                var visible = chip.convert(chip.bounds, to: self).intersection(self.visibleRect)
                var ancestor: NSView? = chip
                var belongsToEditor = false
                while let current = ancestor {
                    if current === self { belongsToEditor = true }
                    visible = visible.intersection(current.convert(current.visibleRect, to: self))
                    ancestor = current.superview
                }
                let frame = chip.convert(chip.bounds, to: self)
                states.append(["id": id, "width": chip.bounds.width, "height": chip.bounds.height,
                               "y": Double(frame.minY), "visibleY": Double(self.visibleRect.minY),
                               "visibleH": Double(self.visibleRect.height), "sel": self.selectedRange().location,
                               "inEditor": belongsToEditor, "hidden": chip.isHiddenOrHasHiddenAncestor,
                               "parent": chip.superview.map { String(describing: type(of: $0)) } ?? "",
                               "visible": chip.window === self.window && !chip.isHiddenOrHasHiddenAncestor && !visible.isEmpty])
            }
            view.subviews.forEach(visit)
        }
        if let root = window?.contentView { visit(root) }
        states += uiTestHeaderSlots()
        states.append(["inlineImages": uiTestInlineImages()])
        // The editor's visible rect, to check a header slot's `slotY` against (W40.notes-w7-gui-checks).
        var visibleEntry: [String: Any] = ["editorVisibleY": Double(visibleRect.minY),
                                           "editorVisibleH": Double(visibleRect.height)]
        // What TextKit draws there: the paragraph at the top of the visible rect and the viewport's character
        // range (W40.fix-notes-jump-scroll-short, where the header slots' y disagreed with the screenshots).
        if let layout = textLayoutManager, let content = layout.textContentManager {
            let origin = content.documentRange.location
            if let top = layout.textLayoutFragment(for: CGPoint(x: 0, y: visibleRect.minY - textContainerOrigin.y)) {
                visibleEntry["editorTopChar"] = content.offset(from: origin, to: top.rangeInElement.location)
                visibleEntry["editorTopFragY"] = Double(top.layoutFragmentFrame.minY + textContainerOrigin.y)
            }
            if let bottom = layout.textLayoutFragment(for: CGPoint(x: 0, y: visibleRect.maxY - 1 - textContainerOrigin.y)) {
                visibleEntry["editorBottomChar"] = content.offset(from: origin, to: bottom.rangeInElement.location)
            }
            if let viewport = layout.textViewportLayoutController.viewportRange {
                visibleEntry["viewportStart"] = content.offset(from: origin, to: viewport.location)
                visibleEntry["viewportEnd"] = content.offset(from: origin, to: viewport.endLocation)
            }
        }
        visibleEntry["blockScroll"] = blockScrollTrace
        states.append(visibleEntry)
        states.append(["relayout": relayoutLastPass, "rebuilds": relayoutRebuilds, "strandedFixes": strandedChipFixes,
                       "layoutPasses": layoutStrandedPasses])
        guard let data = try? JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// One entry per inline image in the TEXT (W9.e2-paste): its `assets/…` path, whether it shows a
    /// placeholder instead of loaded bytes, and how many of its pixels are dark once drawn into a bitmap.
    /// The dark count is the pixel truth a UITest cannot get from the accessibility tree: a page thumbnail
    /// that really drew has dark text on it, and both placeholders and a blank render have almost none.
    private func uiTestInlineImages() -> [[String: Any]] {
        guard let storage = textStorage else { return [] }
        var images: [[String: Any]] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let inline = value as? InlineImageAttachment else { return }
            images.append(["ref": inline.relativePath, "loc": range.location,
                           "placeholder": inline.placeholder != nil,
                           "width": Double(inline.bounds.width), "height": Double(inline.bounds.height),
                           "darkPixels": inline.placeholder == nil ? inline.image.map(Self.uiTestDarkPixelCount) ?? 0 : 0])
        }
        return images
    }

    /// Pixels darker than mid-grey after drawing `image` at its display size over white, capped at 400 pt.
    private static func uiTestDarkPixelCount(_ image: NSImage) -> Int {
        let scale = min(1, 400 / max(image.size.width, image.size.height, 1))
        let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        // Raw bytes, not `colorAt(x:y:)`: this runs inside an AX getter on the main thread, and a colour object
        // per pixel made one 440×570 thumbnail cost tens of milliseconds per probe read.
        guard let bytes = rep.bitmapData else { return 0 }
        let stride = rep.bytesPerRow, channels = rep.samplesPerPixel
        var dark = 0
        for y in 0..<height {
            let row = bytes + y * stride
            for x in 0..<width {
                let pixel = row + x * channels
                if 299 * Int(pixel[0]) + 587 * Int(pixel[1]) + 114 * Int(pixel[2]) < 127_500 { dark += 1 }
            }
        }
        return dark
    }

    /// One entry per passage header in the TEXT, whether or not a view exists (W35.vm-mem-fu1 diagnostics):
    /// `sourceID` (deliberately not `id`, which callers read as "a chip view exists"), character offset,
    /// whether a layout fragment exists, its y, its provider count and how many have an installed view.
    /// Reads existing fragments; asks for no layout.
    private func uiTestHeaderSlots() -> [[String: Any]] {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager
        else { return [] }
        var slots: [[String: Any]] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let header = value as? BlockHeaderAttachment else { return }
            var slot: [String: Any] = ["sourceID": header.sourceBox.anchor.notePassageTarget?.id.uuidString.lowercased() ?? "",
                                       "loc": range.location]
            if let location = content.location(content.documentRange.location, offsetBy: range.location),
               let fragment = layout.textLayoutFragment(for: location) {
                let providers = fragment.textAttachmentViewProviders
                slot["fragY"] = Double(fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
                slot["slotY"] = Double(fragment.frameForTextAttachment(at: location).minY
                                       + fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
                // W40.fix-notes-chip-inline-layout — a chip laid out beside the text before it starts right of
                // the line start and is narrower than the rest.
                let slotFrame = fragment.frameForTextAttachment(at: location)
                slot["slotX"] = Double(slotFrame.minX + fragment.layoutFragmentFrame.minX + textContainerOrigin.x)
                slot["slotW"] = Double(slotFrame.width)
                slot["providers"] = providers.count
                slot["installed"] = providers.filter { $0.view?.superview != nil }.count
            }
            slots.append(slot)
        }
        return slots
    }

    func appendDebugProbes(to children: inout [Any]) {
        // Xcode's contrast audit never finishes while these two 1×1 probes are in the tree, and every audit
        // after it in that launch then times out too (W40.e3, measured in the VM 2026-10-16: a 15 s timeout
        // with them, 1.2 s without). The accessibility audit has no use for them, so it launches without them.
        if UserDefaults.standard.bool(forKey: "ANUITestNoHiddenProbes") { return }
        children.append(passageChipStateProbe)
        children.append(chipGeometryProbe)
        children.append(listMarkerProbe)
    }

    // Driving this TextKit-2 styled NSTextView through XCUITest is a documented weak spot — focusing the
    // field editor and typing styled text is flaky. These DEBUG-only hooks let a UITest commit text and
    // set a selection deterministically WITHOUT relying on field-editor focus. They go through the
    // sanctioned `shouldChangeText`/`didChangeText` editing path so the delegate's `textDidChange` (→
    // debounced write-back to the bound `.md`) fires exactly as for a keystroke, and work regardless of
    // first-responder state. Compiled out of Release; the coordinator parses Markdown into the attributed
    // string it hands here (so styling + serialize-back match the real load path).

    /// Replace the entire document with `attributed` via the standard editing path (registers undo,
    /// notifies the delegate).
    func uiTestReplace(with attributed: NSAttributedString) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: attributed.string) else { return }
        textStorage?.replaceCharacters(in: full, with: attributed)
        didChangeText()
    }

    /// Insert `attributed` over the current selection (grouped for undo) and leave the caret after it.
    func uiTestInsert(_ attributed: NSAttributedString) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return }
        undoManager?.beginUndoGrouping()
        textStorage?.replaceCharacters(in: range, with: attributed)
        didChangeText()
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
    }

    /// Set the selection to a range clamped into the current text (out-of-range never crashes) — used by
    /// the extract-from-selection GUI check (G9).
    func uiTestSetSelection(location: Int, length: Int) {
        setSelectedRange(uiTestClampedRange(location: location, length: length))
        // Focus the editor too, so a following ⌘Z / ⇧⌘Z / Delete keystroke reaches it through the real
        // menu and key path (W9.cand2-fu1) instead of the strip's selection field the seam was typed into.
        window?.makeFirstResponder(self)
    }

    /// Clamp a requested `(location, length)` into `[0, textLength]`. Pure — unit-tested directly.
    func uiTestClampedRange(location: Int, length: Int) -> NSRange {
        let total = (string as NSString).length
        let loc = min(max(location, 0), total)
        let len = min(max(length, 0), total - loc)
        return NSRange(location: loc, length: len)
    }

    /// Drive the REAL image-paste path (`tryPasteImage`) from the general pasteboard, bypassing ⌘V and
    /// field-editor focus (same rationale as the text seams: XCUITest can't reliably focus this styled
    /// NSTextView and route a paste to it). The UITest seeds `NSPasteboard.general` with PNG bytes
    /// cross-process, then triggers this; the production asset-write → attachment-insert → serialize path
    /// runs verbatim (nothing here is stubbed). Returns whether an image was handled. Used by the
    /// paste-image GUI check (G4). The ⌘V user-gesture routing itself is owner-eye (like G2's typing).
    @discardableResult
    func uiTestPasteImage() -> Bool {
        return tryPasteImage(from: NSPasteboard.general)
    }

    /// JSON snapshot of every rendered note-passage chip's source id, resolved label, and missing state.
    /// This reads the current text storage because `MarkdownEditorView.updateNSView` replaces that storage
    /// when `passageGeneration` changes; a model-only probe could pass without the reactive re-style. The
    /// DEBUG-only W21.vmgui-c-fu test consumes this after deleting a cited scratch note in the other window.
    func uiTestPassageChipStates() -> String {
        guard let storage = textStorage else { return "unavailable:noTextStorage" }
        var states: [[String: Any]] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let chip = value as? BlockHeaderAttachment,
                  let target = chip.sourceBox.anchor.notePassageTarget else { return }
            states.append([
                "id": target.id.uuidString.lowercased(),
                "location": range.location,
                "label": chip.passageLiveLabel ?? chip.sourceBox.anchor.display ?? "",
                "missing": chip.passageSourceMissing
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: states, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "unavailable:encoding"
        }
        return json
    }

    /// Cache the storage snapshot at the same point the renderer applies it. The AX child only returns this
    /// `String`; querying it cannot cause a SwiftUI update or a late re-style (W21.vmgui-c-fu).
    func refreshUITestPassageChipStateSnapshot() {
        passageChipStateProbe.snapshot = uiTestPassageChipStates()
    }

    /// Fire the "Jump to Source" action of the FIRST note-passage block chip in the document — via the
    /// SAME `onJump` callback the chip button's `jumpClicked` invokes, with the SAME `SourceAnchor`.
    /// Only the button-CLICK gesture is bypassed: the chip is a TextKit-2 attachment-view-provider
    /// subview XCUITest can't hit-test (the literal click is owner-eye, like G2's typing), so the
    /// jump-to-source GUI check (G10) drives the anchor's callback directly. Returns whether a
    /// note-passage chip was found + fired. Compiled out of Release.
    @discardableResult
    func uiTestJumpFirstPassage() -> Bool {
        guard let storage = textStorage else { return false }
        var fired = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let chip = value as? BlockHeaderAttachment,
                  chip.sourceBox.anchor.notePassageTarget != nil else { return }
            chip.onJump?(chip.sourceBox.anchor)
            fired = true
            stop.pointee = true
        }
        return fired
    }

    /// Fire the "Reveal in Reader" action of the FIRST reader-page source-block chip — via the SAME
    /// `onReveal` callback the chip button's `revealClicked` invokes, with the SAME `SourceAnchor`
    /// (which routes to `openExternalURL` → the `WorkspaceOpenSpy` in a UITest run). Matches a reader
    /// source chip (`link != nil`) but never a note-passage chip (`notePassageTarget == nil`). Only the
    /// button CLICK is bypassed: the chip is a TextKit-2 attachment-view-provider subview XCUITest can't
    /// hit-test (the literal click is owner-eye, like G2), so the reveal GUI check (G6) drives the
    /// anchor's callback directly. Returns whether a reveal-able source chip was found + fired.
    @discardableResult
    func uiTestRevealFirstSource() -> Bool {
        guard let storage = textStorage else { return false }
        var fired = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let chip = value as? BlockHeaderAttachment,
                  chip.sourceBox.anchor.link != nil,
                  chip.sourceBox.anchor.notePassageTarget == nil else { return }
            chip.onReveal?(chip.sourceBox.anchor)
            fired = true
            stop.pointee = true
        }
        return fired
    }

    /// Open the preview popover of the FIRST reader-page source-block chip through the chip's own
    /// `onPreview` callback (W9.e2-paste), anchored on the editor's scroll view. Like `uiTestRevealFirstSource`,
    /// only the un-hit-testable chip-button click is bypassed; the popover, its root-grant button and the
    /// re-resolve it runs are the production ones. Returns whether a previewable chip was found.
    @discardableResult
    func uiTestPreviewFirstSource() -> Bool {
        guard let storage = textStorage else { return false }
        var fired = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let chip = value as? BlockHeaderAttachment,
                  chip.sourceBox.anchor.link != nil,
                  chip.sourceBox.anchor.notePassageTarget == nil,
                  chip.sourceBox.anchor.zoteroSelect == nil,
                  let preview = chip.onPreview else { return }
            // Anchored on the scroll view, whose bounds are what is on screen: the text view's own bounds run
            // past the visible pane, so a popover on its edge could open off-window.
            preview(chip.sourceBox.anchor, enclosingScrollView ?? self)
            fired = true
            stop.pointee = true
        }
        return fired
    }

    /// Fire the "Open in Zotero" action of the FIRST Zotero source-block chip, running the SAME open
    /// path `openZoteroClicked` does (`openExternalURL` → the `WorkspaceOpenSpy` in a UITest run). Only
    /// the button CLICK is bypassed (owner-eye, like G2). Returns whether a Zotero chip was found +
    /// fired. Used by the Zotero-chip GUI check (G11).
    @discardableResult
    func uiTestOpenFirstZotero() -> Bool {
        guard let storage = textStorage else { return false }
        var fired = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let chip = value as? BlockHeaderAttachment,
                  let url = chip.sourceBox.zoteroOpenURL else { return }
            openExternalURL(url)
            fired = true
            stop.pointee = true
        }
        return fired
    }
}

final class ListMarkerProbe: NSAccessibilityElement {
    // Set on the main thread by `EditorTextView.drawListMarkers`; the getter returns the formed String only.
    nonisolated(unsafe) private weak var textView: EditorTextView?
    nonisolated(unsafe) var snapshot = ""
    init(textView: EditorTextView) { self.textView = textView; super.init() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Drawn list markers" }
    override func accessibilityIdentifier() -> String? { "an.editor.test.listMarkers" }
    override func accessibilityParent() -> Any? { textView }
    override func accessibilityFrameInParentSpace() -> NSRect { NSRect(x: 1, y: 1, width: 1, height: 1) }
    override func accessibilityValue() -> Any? { snapshot }
}

/// An accessibility-only child of `EditorTextView`, retained by its owning view for as long as the editor
/// exists. Its value is a renderer-time snapshot of the text storage, with no click handler, binding, or
/// SwiftUI state update. The one-point frame is inside the editor only to give XCUITest a real visible AX
/// frame; it has no backing visual view and is omitted from Release.
final class ChipGeometryProbe: NSAccessibilityElement {
    nonisolated(unsafe) private weak var textView: EditorTextView?
    init(textView: EditorTextView) { self.textView = textView; super.init() }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Installed chip geometry" }
    override func accessibilityIdentifier() -> String? { "an.editor.test.chipGeometry" }
    override func accessibilityParent() -> Any? { textView }
    override func accessibilityFrameInParentSpace() -> NSRect { NSRect(x: 1, y: 1, width: 1, height: 1) }
    override func accessibilityValue() -> Any? {
        guard Thread.isMainThread else { return nil }
        let editor = textView
        return MainActor.assumeIsolated { editor?.uiTestInstalledChipGeometry() }
    }
}

final class PassageChipStateProbe: NSAccessibilityElement {
    // AX getters are synchronous Obj-C entry points. The parent and snapshot are set on the main thread by
    // `EditorTextView`; the getter only returns the already-formed String and never touches AppKit storage.
    nonisolated(unsafe) private weak var textView: EditorTextView?
    nonisolated(unsafe) var snapshot = "[]"

    init(textView: EditorTextView) {
        self.textView = textView
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Rendered passage chip state" }
    override func accessibilityIdentifier() -> String? { "an.editor.test.passageChips" }
    override func accessibilityParent() -> Any? { textView }
    override func accessibilityFrameInParentSpace() -> NSRect {
        NSRect(x: 1, y: 1, width: 1, height: 1)
    }
    override func accessibilityValue() -> Any? {
        return snapshot
    }
}
#endif
