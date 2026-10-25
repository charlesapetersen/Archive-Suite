import AppKit

/// NSTextView subclass enforcing TextKit 2. Never access `layoutManager` — it silently
/// downgrades to TextKit 1 and disables NSTextAttachmentViewProvider (future chips).
final class EditorTextView: NSTextView {
    // SwiftUI's Undo/Redo menu can query and invoke the manager directly, bypassing NSTextView's
    // validation. Keep one history for this editor, including across a cancelled selection load.
    private lazy var editingUndoManager = EditorUndoManager(editor: self)
    override var undoManager: UndoManager? { editingUndoManager }

#if DEBUG
    /// A non-interactive AX child that exposes a cached snapshot of this *already-rendered* text storage.
    /// It must not be a SwiftUI button/state value: changing SwiftUI state re-enters
    /// `MarkdownEditorView.updateNSView` and could itself perform the `passageGeneration` re-style the
    /// W21.vmgui-c-fu test is meant to prove.
    private lazy var passageChipStateProbe = PassageChipStateProbe(textView: self)

    // Reads installed views and existing fragments only: no layout request or SwiftUI state mutation.
    private lazy var chipGeometryProbe = ChipGeometryProbe(textView: self)

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
                slot["providers"] = providers.count
                slot["installed"] = providers.filter { $0.view?.superview != nil }.count
            }
            slots.append(slot)
        }
        return slots
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        // Xcode's contrast audit never finishes while these two 1×1 probes are in the tree, and every audit
        // after it in that launch then times out too (W40.e3, measured in the VM 2026-10-16: a 15 s timeout
        // with them, 1.2 s without). The accessibility audit has no use for them, so it launches without them.
        if UserDefaults.standard.bool(forKey: "ANUITestNoEditorProbes") { return children }
        children.append(passageChipStateProbe)
        children.append(chipGeometryProbe)
        return children
    }
#endif

    /// Notify the TextKit 2 content manager when replacing the styled document.
    func replaceStyledDocument(with attributed: NSAttributedString) {
        // A load is not an edit: the callers lay the new document out themselves (W9.cand2-fu1).
        suppressAttachmentRelayout = true
        defer { suppressAttachmentRelayout = false }
        removeRehostedChipViews()   // they belong to the old document's chips
        layoutStrandedFixesInARow = 0
        performContentEditingTransaction {
            textStorage?.setAttributedString(attributed)
        }
        if let layout = textLayoutManager, let manager = layout.textContentManager {
            layout.invalidateLayout(for: manager.documentRange)
        }
        needsLayout = true
        needsDisplay = true
        installChipViewsAtNextLayout = true
    }

    func performContentEditingTransaction(_ edit: () -> Void) {
        if let manager = textLayoutManager?.textContentManager {
            manager.performEditingTransaction(edit)
        } else {
            edit()
        }
    }

    /// Insert an already-styled `MarkdownBridge.parse` result over `range`, keeping its attributes exactly
    /// (W9.cand2). `insertText(_:replacementRange:)` re-fonts the run from `typingAttributes` — measured: a
    /// pasted 28 pt heading landed at 14 pt — so a fresh paste drew differently from the same markdown
    /// after a reload. This goes through `shouldChangeText`/`didChangeText`, so undo and the delegate's
    /// write-back behave as for a keystroke; the caret ends after the inserted text, scrolled into view once
    /// laid out. It also skips `insertText`'s typingAttributes merge entirely.
    func insertStyled(_ attributed: NSAttributedString, replacementRange range: NSRange) {
        guard isEditable else { return }
        if hasMarkedText() { unmarkText() }   // `insertText` commits an IME composition first
        breakUndoCoalescing()                  // a paste is its own undo step, not part of typing
        guard let storage = textStorage, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: attributed.string) else { return }
        suppressAttachmentRelayout = true   // the relayout below must run first and then scroll
        performContentEditingTransaction {
            storage.replaceCharacters(in: range, with: attributed)
        }
        suppressAttachmentRelayout = false
        didChangeText()
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
        // Scroll only AFTER the relayout: scrolling first left the chip's view installed at a position the
        // later scroll back up never corrected (VM, W9.cand2: inEditor, visible:false).
        relayoutViewportSoon { [weak self] in
            guard let self else { return }
            self.scrollRangeToVisible(self.selectedRange())
        }
    }

    /// Font size for formatting actions triggered from keyboard overrides (Tab/Return/Backspace).
    var configuredFontSize: CGFloat = 14

    init() {
        // Build the TextKit 2 stack explicitly so we guarantee TK2 in all contexts
        // (including unit tests where the default init may fall back to TK1).
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager
        let container = NSTextContainer()
        layoutManager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        assert(textLayoutManager != nil, "EditorTextView must use TextKit 2")
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if let clip = enclosingScrollView?.contentView, clip !== observedClipView {
            if let old = observedClipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            observedClipView = clip
        }
        installChipViewsAtNextLayout = true
        relayoutViewportSoon()
    }

    /// Re-lay the viewport on the next main-queue turn. TextKit 2 installs attachment views (chips, inline
    /// images) only from a viewport layout pass, and an edit's own pass leaves the edited fragments'
    /// providers with no view loaded — measured in the VM for W9.cand2: providers present, views unloaded
    /// with a zero frame, so a pasted chip's slot stayed blank until the editor was rebuilt.
    ///
    /// Two fixed turns were the whole guard until W35.vm-mem-fu1, when the VM showed (G13, after undo/redo
    /// of a paste) a restored chip whose fragment held no installed view however often the viewport was
    /// re-laid, while the probe's header slots proved the chip was in the text. So after each pass this
    /// counts the chips in each viewport fragment against its installed views and, while any is short,
    /// re-lays (at most five more times), rebuilding the short paragraphs from the second pass on.
    private func relayoutViewportSoon(attempt: Int = 0, then: (@MainActor () -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let layout = self.textLayoutManager,
                  let content = layout.textContentManager else { return }
            layout.invalidateLayout(for: content.documentRange)
            layout.textViewportLayoutController.layoutViewport()
            self.needsDisplay = true
            let short = self.viewportParagraphsMissingChipViews()
#if DEBUG
            self.relayoutLastPass = ["attempt": attempt, "short": short.map(\.location)]
#endif
            if attempt < 5, !short.isEmpty {
                if attempt >= 1 { self.rebuildFragments(in: short) }
                self.relayoutViewportSoon(attempt: attempt + 1, then: then)
                return
            }
            self.layoutStrandedFixesInARow = 0
            self.installStrandedChipViews()
            then?()
        }
    }

    /// Marks `ranges` attribute-edited so the content storage rebuilds their elements, and layout their
    /// fragments and chip views. Changes no text and registers no undo; `storageDidProcessEditing` ignores
    /// attribute-only edits, so this cannot re-enter the relayout.
    private func rebuildFragments(in ranges: [NSRange]) {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        for range in ranges where NSMaxRange(range) <= storage.length {
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        storage.endEditing()
#if DEBUG
        relayoutRebuilds += 1
#endif
    }

    /// The last resort after re-laying: install each viewport chip view TextKit left out, and move each one
    /// it left away from its laid-out slot. In the VM (G13, W35.vm-mem-fu1) a chip restored by redo kept a
    /// provider whose loaded view was never installed, and one restored by undo of a delete kept a provider
    /// that never loaded a view — each through five re-lays and four paragraph rebuilds, and through the
    /// viewport passes of later scrolling. TextKit's own later passes still own these views through their
    /// providers, so they can take them back.
    /// Returns whether it installed, moved or removed any view.
    /// `layingOutViews` also lays out each chip's own subviews now, for a caller already inside a layout pass,
    /// where a view it adds would otherwise draw before its label is placed.
    @discardableResult
    private func installStrandedChipViews(layingOutViews: Bool = false) -> Bool {
        guard let layout = textLayoutManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return false }
        var changed = false
        var placements: [(NSView, CGRect)] = []
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let origin = fragment.layoutFragmentFrame.origin
            for provider in fragment.textAttachmentViewProviders where provider.textAttachment is BlockHeaderAttachment {
                let slot = fragment.frameForTextAttachment(at: provider.location)
                guard !slot.isEmpty else { continue }
                // After delete-then-undo the provider had never loaded its view at all (VM, G13).
                if provider.view == nil { provider.loadView() }
                guard let view = provider.view else { continue }
                placements.append((view, slot.offsetBy(dx: origin.x + textContainerOrigin.x,
                                                       dy: origin.y + textContainerOrigin.y)))
            }
            return true
        }
        defer { if layingOutViews { placements.forEach { $0.0.layoutSubtreeIfNeeded() } } }
        for (view, frame) in placements {
            if let parent = view.superview {
                let current = parent.convert(view.frame, to: self)
                if abs(current.minX - frame.minX) < 1, abs(current.minY - frame.minY) < 1 { continue }
            }
            // A slot outside the view's current parent would be clipped by it, so such a view, like one with
            // no parent, is hosted by the text view itself (VM: a view adopted into another chip's
            // container sat at its exact slot and drew nothing).
            if let parent = view.superview, parent !== self, !parent.bounds.contains(parent.convert(frame, from: self)) {
                view.removeFromSuperview()
            }
            if view.superview == nil {
                addSubview(view)
                rehostedChipViews.add(view)
            }
            view.frame = view.superview?.convert(frame, from: self) ?? frame
            changed = true
#if DEBUG
            strandedChipFixes += 1
#endif
        }
        // A view this put in the text view is removed as soon as its provider leaves the viewport — its
        // chip deleted, its paragraph rebuilt with a new provider, or scrolled away (the next pass or
        // TextKit re-installs it when it returns). TextKit takes down only the views it hosts, so without
        // this a deleted chip would stay painted where it was.
        let live = Set(placements.map { ObjectIdentifier($0.0) })
        for view in rehostedChipViews.allObjects where view.superview === self && !live.contains(ObjectIdentifier(view)) {
            view.removeFromSuperview()
            changed = true
        }
        rehostedChipViews.allObjects.filter { $0.superview !== self }.forEach { rehostedChipViews.remove($0) }
        return changed
    }

    /// Chip views `installStrandedChipViews` hosts in the text view itself, until TextKit takes them back.
    private let rehostedChipViews = NSHashTable<NSView>.weakObjects()

    private func removeRehostedChipViews() {
        for view in rehostedChipViews.allObjects where view.superview === self { view.removeFromSuperview() }
        rehostedChipViews.removeAllObjects()
    }

    /// Scrolling lays out newly exposed fragments, which can strand a chip view the same way an edit does.
    @objc private func clipBoundsDidChange(_ note: Notification) {
        scheduleStrandedCheck()
    }

    /// A viewport pass can take down a chip view with no edit or scroll to follow it: in the VM (G13), after
    /// delete-then-undo the chip ABOVE the restored one ended with an unloaded provider once the relayout
    /// chain had finished, and nothing asked again. So every layout asks too. (The exact hook,
    /// `textViewportLayoutControllerDidLayout`, is public only from macOS 27.)
    override func layout() {
        super.layout()
        if installChipViewsAtNextLayout, window != nil, let layout = textLayoutManager {
            // The first layout of a loaded document, or of an editor just put in a window, installs and lays
            // out its chip views itself: the frame after this pass is the first to draw the new text, and the
            // pane builds a new editor for each note, so this is every note switch. Left to TextKit, a chip's
            // view existed only after that frame had drawn its paragraph, and the VM's screen video showed the
            // new body for 2–5 frames under an empty chip slot (W40.fix-notes-chip-first-draw-blank). Once per
            // load, so it cannot feed the loop guarded below.
            installChipViewsAtNextLayout = false
            layout.textViewportLayoutController.layoutViewport()
            createChipViewProvidersInViewport()
            installStrandedChipViews(layingOutViews: true)
        }
        scheduleStrandedCheck(fromLayout: true)
    }
    private var installChipViewsAtNextLayout = false

    /// TextKit 2 makes a fragment's attachment view providers when it first draws the fragment, so a chip's view
    /// can exist only after a frame that showed its paragraph without it. Drawing each viewport fragment that holds
    /// a chip but no provider once into a throwaway bitmap makes them now, before the first real frame.
    private func createChipViewProvidersInViewport() {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let length = content.offset(from: viewport.location, to: viewport.endLocation)
        guard start >= 0, length > 0, start + length <= storage.length else { return }
        var fragments: [NSTextLayoutFragment] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: start, length: length)) { value, range, _ in
            guard value is BlockHeaderAttachment,
                  let location = content.location(content.documentRange.location, offsetBy: range.location),
                  let fragment = layout.textLayoutFragment(for: location),
                  fragment.textAttachmentViewProviders.isEmpty,
                  !fragments.contains(where: { $0 === fragment }) else { return }
            fragments.append(fragment)
        }
        guard !fragments.isEmpty,
              let bitmap = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for fragment in fragments { fragment.draw(at: .zero, in: bitmap) }
    }

    /// One `installStrandedChipViews` pass on the next turn, however many requests arrive before it. A pass
    /// that moves a view may itself cause a layout, so layout-caused passes that keep changing something stop
    /// after `maxLayoutStrandedFixes` in a row; an edit or scroll starts the count again.
    private func scheduleStrandedCheck(fromLayout: Bool = false) {
        if !fromLayout { layoutStrandedFixesInARow = 0 }
        guard !strandedCheckQueued, !fromLayout || layoutStrandedFixesInARow < Self.maxLayoutStrandedFixes else { return }
        strandedCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.strandedCheckQueued = false
            guard self.window != nil else { return }
#if DEBUG
            if fromLayout { self.layoutStrandedPasses += 1 }
#endif
            let changed = self.installStrandedChipViews()
            self.layoutStrandedFixesInARow = changed ? self.layoutStrandedFixesInARow + 1 : 0
        }
    }
    private var strandedCheckQueued = false
    private var layoutStrandedFixesInARow = 0
    private static let maxLayoutStrandedFixes = 4
    private weak var observedClipView: NSClipView?

    /// The character ranges of viewport layout fragments holding more chips (`BlockHeaderAttachment`, the
    /// only view-backed attachment) than installed chip views. Counting the text, not the providers, is the
    /// point: the VM's blank slot had a fragment with no provider at all, which a provider check passes.
    private func viewportParagraphsMissingChipViews() -> [NSRange] {
        guard let storage = textStorage, let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return [] }
        let documentStart = content.documentRange.location
        var short: [NSRange] = []
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let range = fragment.rangeInElement
            let paragraph = NSRange(location: content.offset(from: documentStart, to: range.location),
                                    length: content.offset(from: range.location, to: range.endLocation))
            guard paragraph.location != NSNotFound, NSMaxRange(paragraph) <= storage.length else { return true }
            var chips = 0
            storage.enumerateAttribute(.attachment, in: paragraph) { value, _, _ in
                if value is BlockHeaderAttachment { chips += 1 }
            }
            let installed = fragment.textAttachmentViewProviders.filter { $0.view?.superview != nil }.count
            if installed < chips { short.append(paragraph) }
            return true
        }
        return short
    }

    /// Every other edit that lands an attachment has the same unloaded-view gap as `insertStyled` (W9.cand2-fu1):
    /// chip and image inserts through `insertText`, and NSTextView's own undo/redo putting a deleted chip back.
    /// So the relayout hangs off the storage's own edit notification, not `didChangeText`: measured in the
    /// unit bundle, undo restores the chip WITHOUT calling `didChangeText`. A keystroke in a paragraph with
    /// no attachment does not qualify; one in a paragraph that shares a line with an attachment can, since
    /// the storage widens the edited range to the paragraph (measured). Attribute-only changes are skipped.
    private var suppressAttachmentRelayout = false

    @objc private func storageDidProcessEditing(_ note: Notification) {
        layoutStrandedFixesInARow = 0   // an edit, or a document replace, earns layout passes again
        guard !suppressAttachmentRelayout, let storage = note.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        // Any text edit — a deletion too, which the attachment test below skips — can delete or move a chip
        // whose view this class hosts itself, so re-place or remove those.
        if rehostedChipViews.count > 0 { scheduleStrandedCheck() }
        let edited = storage.editedRange
        guard edited.location != NSNotFound, edited.length > 0, NSMaxRange(edited) <= storage.length else { return }
        var holdsAttachment = false
        storage.enumerateAttribute(.attachment, in: edited) { value, _, stop in
            if value != nil { holdsAttachment = true; stop.pointee = true }
        }
        guard holdsAttachment else { return }
#if DEBUG
        attachmentRelayoutRequests += 1
#endif
        // One turn later than `insertStyled`'s, then re-scroll. Redo lays out and scrolls on the NEXT turn
        // itself; a pass on that same turn left the redone chip's view installed but stranded below the
        // viewport (VM, W9.cand2-fu1: y=177, visible 0–119, slot blank). Two turns: G13 green.
        DispatchQueue.main.async { [weak self] in
            self?.relayoutViewportSoon { [weak self] in
                guard let self else { return }
                self.scrollRangeToVisible(self.selectedRange())
            }
        }
    }

#if DEBUG
    /// How many edits asked for an attachment relayout. Unit tests have no window, so they cannot see a view
    /// load; this is how they prove which edits ask for one.
    private(set) var attachmentRelayoutRequests = 0
    /// For the geometry probe: how many chip rebuilds ran, and the latest relayout pass's attempt number
    /// and short paragraph offsets.
    private(set) var relayoutRebuilds = 0
    private(set) var strandedChipFixes = 0
    private(set) var layoutStrandedPasses = 0
    private var relayoutLastPass: [String: Any] = [:]
#endif

    private func commonInit() {
        isRichText = true           // W3-S2: rich text for styled mode
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 12, height: 12)
        if let tc = textContainer {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcessEditing(_:)),
                                               name: NSTextStorage.didProcessEditingNotification,
                                               object: textStorage)
    }

    /// `.noteBlockSource` and `.noteImageRelPath` describe ONE attachment character each — they are
    /// IDENTITIES, not styling, and must never continue as the operator types (`MarkdownBridge.swift`
    /// applies each to exactly the 1-char attachment it belongs to; so does `tryPasteImage` below).
    ///
    /// AppKit seeds `typingAttributes` from the character BEFORE the caret — or, at location 0, from the
    /// character AT 0 — and `insertText` then merges them into every inserted run that lacks the key. It
    /// knows to strip `.attachment` and nothing about these two. So a caret adjacent to a block-header chip
    /// (offset 0 of an extract whose body opens with one) stamped that chip's `SourceAnchorBox` onto every
    /// typed or pasted character, and `MarkdownBridge.serialize`'s chip test — which asks only "does this
    /// position carry `.noteBlockSource`?", never "is this THE attachment character?" — then minted one
    /// `<!-- block: … -->` header per stamped character and SWALLOWED each one's text.
    ///
    /// Measured before this override (W3.notes-passage-paste-at-caret): pasting a 62-char passage at caret 0
    /// produced 62 headers, all bodies empty, and **zero** `](assets/…)` references — the imported image
    /// bytes were on disk with nothing in the `.md` pointing at them, the mirror of the W14.3 bug that
    /// `testG13` exists to guard. With no paste at all, typing one plain character at offset 0 in front of a
    /// chip emitted TWO headers and dropped the character; in front of an inline image it duplicated the
    /// asset reference and dropped the character. Silent data loss in ordinary editing, not just under test.
    ///
    /// Fixed HERE, at the single point AppKit sets them, rather than in the serializer or as an offset-0
    /// special case: this keeps the TEXT STORAGE itself correct, which `NotePassageSource.blockRanges`
    /// depends on (it enumerates `.noteBlockSource` RUNS, so a leak would mis-split the copy path too), and
    /// it covers every insertion site plus plain typing at once. `.noteBlockKind` and `.noteInlineCode` are
    /// deliberately NOT stripped — those legitimately continue while typing.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var clean = newValue
            clean.removeValue(forKey: .noteBlockSource)
            clean.removeValue(forKey: .noteImageRelPath)
            super.typingAttributes = clean
        }
    }

    // MARK: - Disabled editor (selection / body load in flight)

    // Menu commands (including Undo/Redo) can bypass keyDown and normal text insertion.
    @objc func undo(_ sender: Any?) {
        guard let manager = undoManager, manager.canUndo else { return }
        manager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard let manager = undoManager, manager.canRedo else { return }
        manager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard isEditable else { return false }
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard isEditable else { return false }
        if menuItem.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if menuItem.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return super.validateMenuItem(menuItem)
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable else { return }
        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        isEditable && super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: - List keyboard behavior (Tab / Return / Backspace)

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        guard let storage = textStorage,
              storage.length > 0,
              let kind = storage.attribute(.noteBlockKind,
                                           at: selectedRange().location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem = kind else {
            super.insertTab(sender)
            return
        }
        EditorFormatting.indentList(self, fontSize: configuredFontSize)
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable else { return }
        guard let storage = textStorage,
              storage.length > 0,
              let kind = storage.attribute(.noteBlockKind,
                                           at: selectedRange().location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem = kind else {
            super.insertBacktab(sender)
            return
        }
        EditorFormatting.outdentList(self, fontSize: configuredFontSize)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else { return }
        guard let storage = textStorage, storage.length > 0 else {
            super.insertNewline(sender)
            return
        }
        let sel = selectedRange()
        guard sel.location <= storage.length else {
            super.insertNewline(sender)
            return
        }
        let paraRange = (string as NSString).paragraphRange(for: sel)
        guard let kind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem(let ordered, let depth, let ordinal) = kind else {
            super.insertNewline(sender)
            return
        }

        // If the current list item is empty, outdent / remove list
        let paraText = (string as NSString).substring(with: paraRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if paraText.isEmpty {
            EditorFormatting.outdentList(self, fontSize: configuredFontSize)
            return
        }

        // Insert newline and apply list item kind to the new paragraph
        super.insertNewline(sender)
        let newSel = selectedRange()
        guard newSel.location <= (string as NSString).length else { return }
        let newParaRange = (string as NSString).paragraphRange(for: newSel)
        let newOrdinal = ordered ? ordinal + 1 : 1
        let newKind = BlockKind.listItem(ordered: ordered, depth: depth, ordinal: newOrdinal)

        undoManager?.beginUndoGrouping()
        storage.beginEditing()
        storage.addAttribute(.noteBlockKind, value: newKind, range: newParaRange)
        let ps = NSMutableParagraphStyle()
        let indent = CGFloat(depth + 1) * 20
        ps.headIndent = indent
        ps.firstLineHeadIndent = max(indent - 16, 0)
        storage.addAttribute(.paragraphStyle, value: ps, range: newParaRange)
        storage.endEditing()
        undoManager?.endUndoGrouping()
    }

    override func deleteBackward(_ sender: Any?) {
        guard isEditable else { return }
        guard let storage = textStorage, storage.length > 0 else {
            super.deleteBackward(sender)
            return
        }
        let sel = selectedRange()
        // Only intercept at paragraph start with no selection
        guard sel.length == 0, sel.location > 0 else {
            super.deleteBackward(sender)
            return
        }
        let paraRange = (string as NSString).paragraphRange(for: sel)
        guard sel.location == paraRange.location else {
            super.deleteBackward(sender)
            return
        }
        guard let kind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                           effectiveRange: nil) as? BlockKind else {
            super.deleteBackward(sender)
            return
        }
        switch kind {
        case .listItem:
            EditorFormatting.outdentList(self, fontSize: configuredFontSize)
        case .blockquote, .heading:
            EditorFormatting.setPlain(self, fontSize: configuredFontSize)
        default:
            super.deleteBackward(sender)
        }
    }

    // MARK: - Paste / Drag (inline images + text)

    /// The asset store used for persisting pasted/dragged images.
    /// Set by the coordinator when wiring the editor.
    weak var assetStore: EditorAssetStore?

    /// Handler for pasting archive-link payloads as source blocks.
    /// Set by the coordinator; returns true if handled.
    var sourceBlockPasteHandler: (([SourceBlockPaster.PasteEntry]) -> Bool)?

    /// W7-S2: copy the selection as a `com.archivenotes.passage` payload (note editor only). Set by the
    /// coordinator; returns true when it wrote a passage (so the default RTF/plain copy is skipped).
    var passageCopyHandler: (() -> Bool)?

    /// W7-S2: paste a `com.archivenotes.passage` payload as note-passage block(s) (extract editor only).
    /// Set by the coordinator; returns true when it inserted the passage.
    var passagePasteHandler: (() -> Bool)?
    var plainPasteFallbackHandler: (() -> Void)?

    /// Image UTIs we accept on the pasteboard.
    private static let imageTypes: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic")
    ]

    override func copy(_ sender: Any?) {
        // W7-S2: a note selection copies as a com.archivenotes.passage payload (+ RTF + plain); an
        // extract paste then restores full provenance. Anything else uses the default RTF/plain copy.
        if passageCopyHandler?() == true { return }
        super.copy(sender)
    }

    /// Template bodies have no asset-copy route into newly instantiated notes. Refuse an image
    /// before AppKit can insert an unsaved attachment that would disappear on the next reload.
    var rejectImagePaste = false

    private func isUnsupportedImage(_ pb: NSPasteboard) -> Bool {
        guard rejectImagePaste else { return false }
        if let types = pb.types, !Self.imageTypes.isDisjoint(with: types) { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, Self.isImageURL(url) { return true }
        return false
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pb = NSPasteboard.general
        if isUnsupportedImage(pb) { NSSound.beep(); return }
        if tryPasteImage(from: pb) { return }
        // W7-S2: in an extract editor, a passage payload pastes as note-passage block(s) (provenance
        // preserved). The handler declines outside an extract editor / without a passage payload.
        if tryPastePassage(from: pb) { return }
        if tryPasteSourceBlocks(from: pb) { return }
        // For text: prefer plain string to avoid importing unmodeled rich styling
        if let str = pb.string(forType: .string), !str.isEmpty {
            insertPlainText(str)
            if PassagePasteboard.hasPassage(pb) || !SourceBlockPaster.readPasteboard(from: pb).isEmpty {
                plainPasteFallbackHandler?()
            }
            return
        }
        // Template mode has no asset destination. An attachment-only RTFD or other rich
        // payload must never reach AppKit's fallback: it could appear in the editor and vanish
        // on Markdown serialization. Text was already handled above.
        if rejectImagePaste { NSSound.beep(); return }
        super.paste(sender)
    }

    /// Delegate a passage-payload paste to the coordinator (extract editor only). No-op when the
    /// pasteboard carries no `com.archivenotes.passage` representation.
    @discardableResult
    private func tryPastePassage(from pb: NSPasteboard) -> Bool {
        guard PassagePasteboard.hasPassage(pb), let handler = passagePasteHandler else { return false }
        return handler()
    }

    /// Check the pasteboard for archive-link payloads and delegate to the source-block handler.
    @discardableResult
    private func tryPasteSourceBlocks(from pb: NSPasteboard) -> Bool {
        guard let handler = sourceBlockPasteHandler else { return false }
        let entries = SourceBlockPaster.readPasteboard(from: pb)
        guard !entries.isEmpty else { return false }
        return handler(entries)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        let pb = sender.draggingPasteboard
        if rejectImagePaste {
            if isUnsupportedImage(pb) { return false }
            guard let text = pb.string(forType: .string), !text.isEmpty else { return false }
            insertPlainText(text)
            return true
        }
        if tryPasteImage(from: pb) { return true }
        return super.performDragOperation(sender)
    }

    /// Attempt to read an image from the pasteboard, persist via assetStore, and insert
    /// an inline image attachment. Returns true if an image was handled.
    @discardableResult
    private func tryPasteImage(from pb: NSPasteboard) -> Bool {
        // Refuse before reserving a filename or writing bytes, including the direct UITest seam.
        guard isEditable, let store = assetStore else { return false }

        // Try reading image data from the pasteboard
        let imageData: Data?
        if let data = pb.data(forType: .png) {
            imageData = data
        } else if let data = pb.data(forType: .tiff) {
            // Convert TIFF to PNG for storage
            imageData = Self.tiffToPNG(data)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  let url = urls.first,
                  Self.isImageURL(url),
                  let data = try? Data(contentsOf: url) {
            imageData = Self.ensurePNG(data)
        } else {
            imageData = nil
        }

        guard let data = imageData else { return false }

        let dateSuffix = Self.pastedImageDateSuffix()
        let preferredName = "pasted-\(dateSuffix).png"

        do {
            let relPath = try store.addAsset(data, preferredName: preferredName)
            let thumbnail = InlineImageAttachment.downsampledThumbnail(from: data)
            let attachment = InlineImageAttachment(
                relativePath: relPath, altText: "", thumbnail: thumbnail
            )
            let attachStr = NSMutableAttributedString(attachment: attachment)
            attachStr.addAttribute(.noteImageRelPath, value: relPath,
                                   range: NSRange(location: 0, length: attachStr.length))
            // Stamp block kind from the current paragraph
            if let storage = textStorage, storage.length > 0 {
                let loc = min(selectedRange().location, storage.length - 1)
                if let kind = storage.attribute(.noteBlockKind, at: loc,
                                                effectiveRange: nil) {
                    attachStr.addAttribute(.noteBlockKind, value: kind,
                                           range: NSRange(location: 0, length: attachStr.length))
                }
            }

            undoManager?.beginUndoGrouping()
            insertText(attachStr, replacementRange: selectedRange())
            undoManager?.endUndoGrouping()
            return true
        } catch {
            return false
        }
    }

    /// Threshold (in characters) above which a styled paste uses deferred Markdown conversion.
    static let largePasteThreshold = 10_000

    /// Insert plain text at the caret, stripping any rich formatting.
    /// For large pastes in styled mode, schedules Markdown conversion after the paste callback.
    /// The conversion still runs on the main actor and may pause the UI for a very large paste.
    func insertPlainText(_ text: String) {
        guard isEditable else { return }
        if isRichText, text.count > Self.largePasteThreshold {
            insertLargeTextAsync(text)
            return
        }
        let font: NSFont = isRichText
            ? .systemFont(ofSize: configuredFontSize)
            : .monospacedSystemFont(ofSize: configuredFontSize, weight: .regular)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        if isRichText {
            attrs[.noteBlockKind] = BlockKind.plain
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        undoManager?.beginUndoGrouping()
        insertText(str, replacementRange: selectedRange())
        undoManager?.endUndoGrouping()
    }

    /// Defer a large paste's parse and insertion to a later main-actor turn.
    private func insertLargeTextAsync(_ text: String) {
        let fontSize = configuredFontSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            let parsed = MarkdownBridge.parse(markdown: text, fontSize: fontSize)
            self.undoManager?.beginUndoGrouping()
            // Read the selection now, not before the hop: an edit in between would make it stale.
            self.insertStyled(parsed, replacementRange: self.selectedRange())
            self.undoManager?.endUndoGrouping()
        }
    }

    // MARK: - Image helpers

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif"].contains(ext)
    }

    private static func tiffToPNG(_ tiffData: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func ensurePNG(_ data: Data) -> Data? {
        // If already PNG (header bytes), return as-is
        if data.count >= 8, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
        // Otherwise try to convert via NSBitmapImageRep
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pastedImageDateSuffix() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    // MARK: - Raw mode

    /// Toggle between styled mode and raw monospaced mode.
    func applyRawMode(_ isRaw: Bool, fontSize: CGFloat) {
        if isRaw {
            isRichText = false
            let font: NSFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            self.font = font
            typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        } else {
            isRichText = true
            let font: NSFont = .systemFont(ofSize: fontSize)
            typingAttributes = [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .noteBlockKind: BlockKind.plain
            ]
        }
    }

    // MARK: - DEBUG test seam (W8-S7 §3.3)

#if DEBUG
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

#if DEBUG
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
#endif

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
                  let select = chip.sourceBox.anchor.zoteroSelect,
                  let url = URL(string: select) else { return }
            openExternalURL(url)
            fired = true
            stop.pointee = true
        }
        return fired
    }
#endif
}

#if DEBUG
/// An accessibility-only child of `EditorTextView`, retained by its owning view for as long as the editor
/// exists. Its value is a renderer-time snapshot of the text storage, with no click handler, binding, or
/// SwiftUI state update. The one-point frame is inside the editor only to give XCUITest a real visible AX
/// frame; it has no backing visual view and is omitted from Release.
private final class ChipGeometryProbe: NSAccessibilityElement {
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

private final class PassageChipStateProbe: NSAccessibilityElement {
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

/// A disabled editor keeps its undo history but cannot expose or execute it until editable again.
@MainActor
private final class EditorUndoManager: UndoManager {
    private weak var editor: EditorTextView?

    init(editor: EditorTextView) {
        self.editor = editor
        super.init()
    }

    override var canUndo: Bool { editor?.isEditable == true && super.canUndo }
    override var canRedo: Bool { editor?.isEditable == true && super.canRedo }

    override func undo() {
        guard editor?.isEditable == true else { return }
        super.undo()
    }

    override func redo() {
        guard editor?.isEditable == true else { return }
        super.redo()
    }

    override func undoNestedGroup() {
        guard editor?.isEditable == true else { return }
        super.undoNestedGroup()
    }
}
