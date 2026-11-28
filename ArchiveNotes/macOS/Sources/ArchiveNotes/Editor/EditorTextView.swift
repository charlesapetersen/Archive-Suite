import AppKit

/// NSTextView subclass enforcing TextKit 2. Never access `layoutManager` — it silently
/// downgrades to TextKit 1 and disables NSTextAttachmentViewProvider (future chips).
///
/// Domain-scoped behaviors live in sibling extension files (W49.notes-model-split):
/// - `EditorTextView+ChipAccessibility.swift`: chip accessibility children, cursor actions, context menu
/// - `EditorTextView+ListKeyboard.swift`: Tab / Shift-Tab / Return / Backspace list & heading rules
/// - `EditorTextView+PasteAndImages.swift`: copy/paste/drag routing, inline images, raw mode
/// - `EditorTextView+UITestSeam.swift`: `#if DEBUG` UI-test seams and accessibility probes
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
    lazy var passageChipStateProbe = PassageChipStateProbe(textView: self)

    // Reads installed views and existing fragments only: no layout request or SwiftUI state mutation.
    lazy var chipGeometryProbe = ChipGeometryProbe(textView: self)

    /// The list markers the last draw put on screen, `text@offset` each (W40.fix-notes-editor-lines). XCUITest
    /// reads the accessibility tree, not pixels, and a marker is drawn, not text.
    lazy var listMarkerProbe = ListMarkerProbe(textView: self)

    /// The last few `scrollBlockToTop` outcomes, for the chip-geometry probe.
    var blockScrollTrace: [String] = []

    /// How many edits asked for an attachment relayout. Unit tests have no window, so they cannot see a view
    /// load; this is how they prove which edits ask for one.
    private(set) var attachmentRelayoutRequests = 0
    /// For the geometry probe: how many chip rebuilds ran, and the latest relayout pass's attempt number
    /// and short paragraph offsets.
    private(set) var relayoutRebuilds = 0
    private(set) var strandedChipFixes = 0
    private(set) var layoutStrandedPasses = 0
    var relayoutLastPass: [String: Any] = [:]
#endif

    /// Detached chip view retained when a keyboard/menu action fires for a chip scrolled out of the viewport.
    var detachedChipView: BlockHeaderChipView?

    /// Font size for formatting actions triggered from keyboard overrides (Tab/Return/Backspace).
    var configuredFontSize: CGFloat = 14

    // MARK: - Paste / Drag handlers (wired by coordinator; used in `EditorTextView+PasteAndImages`)

    /// The asset store used for persisting pasted/dragged images.
    /// Set by the coordinator when wiring the editor.
    weak var assetStore: EditorAssetStore?

    /// Handler for pasting archive-link payloads as source blocks.
    /// Set by the coordinator; returns true if handled.
    var sourceBlockPasteHandler: (([SourceBlockPaster.PasteEntry]) -> Bool)?

    /// Handler for pasting `zotero://select/…` links as Zotero source blocks (W40.fix-notes-zotero-paste).
    /// Set by the coordinator; returns true if handled.
    var zoteroPasteHandler: (([ZoteroRef]) -> Bool)?

    /// W7-S2: copy the selection as a `com.archivenotes.passage` payload (note editor only). Set by the
    /// coordinator; returns true when it wrote a passage (so the default RTF/plain copy is skipped).
    var passageCopyHandler: (() -> Bool)?

    /// W7-S2: paste a `com.archivenotes.passage` payload as note-passage block(s) (extract editor only).
    /// Set by the coordinator; returns true when it inserted the passage.
    var passagePasteHandler: (() -> Bool)?
    var plainPasteFallbackHandler: (() -> Void)?

    /// Template bodies have no asset-copy route into newly instantiated notes. Refuse an image
    /// before AppKit can insert an unsaved attachment that would disappear on the next reload.
    var rejectImagePaste = false

    // MARK: - TextKit 2 layout & relayout state

    /// Relayout chains still to finish. Each pass invalidates the whole document, and the viewport then places
    /// its fragments by estimate around the scroll offset, so a scroll measured before the chain ends is lost.
    private var relayoutChains = 0
    private var settleWaiters: [@MainActor () -> Void] = []
    /// Chip views `installStrandedChipViews` hosts in the text view itself, until TextKit takes them back.
    private let rehostedChipViews = NSHashTable<NSView>.weakObjects()
    private var installChipViewsAtNextLayout = false
    private var strandedCheckQueued = false
    private var layoutStrandedFixesInARow = 0
    private static let maxLayoutStrandedFixes = 4
    private weak var observedClipView: NSClipView?
    /// Suppresses `storageDidProcessEditing` attachment relayouts during full loads and `insertStyled`.
    private var suppressAttachmentRelayout = false
    /// Where `shouldChangeText` found a kept empty-line kind that the change in flight ends; cleared in `didChangeText`.
    private var staleNextLineKind: Int?

    // MARK: - Init & lifecycle

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

    // MARK: - Document load, scroll & TextKit 2 chip view hosting

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

    /// Scroll so the start of `range` (a source block's header) sits at the top of the view, and say whether it
    /// could be placed (W40.fix-notes-jump-scroll-short). `scrollRangeToVisible` alone landed short: a load
    /// invalidates the whole document's layout, and TextKit 2 puts the fragments not yet laid out at estimated
    /// heights, so it scrolled to where the block was estimated to be, several paragraphs above it. A y measured
    /// from the top of the document is not enough either: after a long scroll the viewport pass re-anchors on
    /// the new offset by estimate, and the VM's probe showed paragraph 87 drawn at the y the header had been laid
    /// out at. So each pass measures from what the viewport has just laid out (its first fragment, then the
    /// fragments after it, laid out one below another, to the header) and scrolls by that, until a pass finds the
    /// view already there. A relayout pass after it undoes it all the same, so the caller runs it again once they
    /// are done (`whenLayoutSettles`).
    @discardableResult
    func scrollBlockToTop(_ range: NSRange) -> Bool {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length,
              let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let clip = enclosingScrollView?.contentView
        else { return false }
        let viewport = layout.textViewportLayoutController
        var passes: [String] = []
        defer { noteBlockScroll(passes.joined(separator: "; ")) }
        for _ in 0..<4 {
            viewport.layoutViewport()
            guard let first = viewport.viewportRange?.location, let anchor = layout.textLayoutFragment(for: first) else {
                passes.append("no viewport fragment")
                return false
            }
            // Fragments between the anchor and the header can keep frames from an earlier pass, laid out before
            // the viewport re-anchored (measured: the second pass read the first pass's y back). Re-lay them so
            // they follow on from the anchor.
            var options: NSTextLayoutFragment.EnumerationOptions = [.ensuresLayout]
            let between: NSTextRange?
            if start.compare(anchor.rangeInElement.location) == .orderedAscending {
                options.insert(.reverse)
                between = NSTextRange(location: start, end: anchor.rangeInElement.location)
            } else {
                let blockEnd = content.location(content.documentRange.location, offsetBy: NSMaxRange(range))
                between = blockEnd.flatMap { NSTextRange(location: anchor.rangeInElement.endLocation, end: $0) }
            }
            if let between, !between.isEmpty { layout.invalidateLayout(for: between) }
            var header: NSTextLayoutFragment?
            layout.enumerateTextLayoutFragments(from: anchor.rangeInElement.location, options: options) { fragment in
                guard fragment.rangeInElement.contains(start) || fragment.rangeInElement.location.isEqual(start)
                else { return true }
                header = fragment
                return false
            }
            guard let header else {
                passes.append("header fragment not reached")
                return false
            }
            let y = header.layoutFragmentFrame.minY + textContainerOrigin.y
            let target = min(max(0, y - 6), max(0, frame.height - clip.bounds.height))
            if abs(clip.bounds.minY - target) < 1 {
                passes.append("there, header y \(y)")
                return true
            }
            passes.append("header y \(y), \(clip.bounds.minY) → \(target)")
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        viewport.layoutViewport()
        return true
    }

    private func noteBlockScroll(_ outcome: String) {
#if DEBUG
        blockScrollTrace = Array((blockScrollTrace + [outcome]).suffix(4))
#endif
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
        if attempt == 0 { relayoutChains += 1 }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var continues = false
            defer {
                if !continues {
                    self.relayoutChains -= 1
                    self.runSettleWaitersIfIdle()
                }
            }
            guard self.window != nil, let layout = self.textLayoutManager,
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
                continues = true
                self.relayoutViewportSoon(attempt: attempt + 1, then: then)
                return
            }
            self.layoutStrandedFixesInARow = 0
            self.installStrandedChipViews()
            then?()
        }
    }

    /// Run `body` once no relayout chain is pending: at the end of the last one, or on the next turn.
    func whenLayoutSettles(_ body: @escaping @MainActor () -> Void) {
        settleWaiters.append(body)
        if relayoutChains == 0 {
            DispatchQueue.main.async { [weak self] in self?.runSettleWaitersIfIdle() }
        }
    }

    private func runSettleWaitersIfIdle() {
        guard relayoutChains == 0, !settleWaiters.isEmpty else { return }
        let waiters = settleWaiters
        settleWaiters = []
        waiters.forEach { $0() }
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
    @objc private func storageDidProcessEditing(_ note: Notification) {
        layoutStrandedFixesInARow = 0   // an edit, or a document replace, earns layout passes again
        invalidateListMarkers()
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

    // MARK: - Typing attributes & list markers (W40.fix-notes-editor-lines)

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
            // These mark text read from the file, never typed text. Typed at the start of a paragraph, text
            // inherited the separator before it, and a Return typed there was then not written as a
            // paragraph break (W40.fix-notes-return-paragraph).
            clean.removeValue(forKey: .noteBlockSeparator)
            clean.removeValue(forKey: .noteHardLineBreak)
            clean.removeValue(forKey: .noteRawHTML)
            clean.removeValue(forKey: .noteBlockHTML)
            clean.removeValue(forKey: .noteChipLineEnd)
            // On the empty last line, seeded from the newline before it, the line's own kind is on that newline
            // (W49.notes-keep-blank-lines). It is never typed onward.
            if let kind = clean.removeValue(forKey: .noteNextLineKind) as? BlockKind, let storage = textStorage,
               selectedRange() == NSRange(location: storage.length, length: 0) {
                clean = EditorFormatting.typingAttributes(clean, kind: kind, fontSize: configuredFontSize)
            }
            super.typingAttributes = clean
            invalidateListMarkers()   // an empty last line's marker follows the typing kind
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawListMarkers(in: dirtyRect)
    }

    /// Draw each visible list item's bullet or number in the indent before its first line, and the marker of
    /// an empty last line the caret is on. Positions come from `firstRect`, the caret rect at the item's start,
    /// which also exists for the empty last line that no layout fragment covers.
    private func drawListMarkers(in dirtyRect: NSRect) {
        guard let storage = textStorage, let window,
              let layout = textLayoutManager, let content = layout.textContentManager else { return }
        var range = NSRange(location: 0, length: storage.length)
        if let viewport = layout.textViewportLayoutController.viewportRange {
            let origin = content.documentRange.location
            let start = content.offset(from: origin, to: viewport.location)
            let end = content.offset(from: origin, to: viewport.endLocation)
            range = NSRange(location: max(0, start), length: max(0, min(end, storage.length) - max(0, start)))
        }
        var markers = ListMarkers.markers(in: storage, range: range)
        if let trailing = ListMarkers.trailingMarker(in: storage, typingAttributes: typingAttributes,
                                                    caret: selectedRange()) {
            markers.append(trailing)
        }
        var drawn: [String] = []
        let padding = textContainer?.lineFragmentPadding ?? 0
        for marker in markers {
            let screen = firstRect(forCharacterRange: NSRange(location: marker.location, length: 0), actualRange: nil)
            guard screen != .zero else { continue }
            let line = convert(window.convertFromScreen(screen), from: nil)
            let textStart = textContainerOrigin.x + padding + CGFloat(marker.depth + 1) * ListMarkers.levelWidth
            let box = NSRect(x: textStart - ListMarkers.levelWidth, y: line.minY,
                             width: ListMarkers.levelWidth - 6, height: max(line.height, 1))
            guard box.intersects(dirtyRect) else { continue }
            let font = (marker.location < storage.length
                ? storage.attribute(.font, at: marker.location, effectiveRange: nil)
                : typingAttributes[.font]) as? NSFont ?? NSFont.systemFont(ofSize: configuredFontSize)
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            NSAttributedString(string: marker.text, attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize), .foregroundColor: NSColor.textColor,
                .paragraphStyle: style
            ]).draw(with: box, options: [.usesLineFragmentOrigin])
            drawn.append("\(marker.text)@\(marker.location)")
        }
#if DEBUG
        listMarkerProbe.snapshot = drawn.joined(separator: " ")
#endif
    }

    /// The strip the markers are drawn in, redrawn after an edit or a caret move: TextKit 2 redraws only the
    /// fragments it changed, and an item's number or an empty line's marker can change with an edit elsewhere.
    func invalidateListMarkers() {
        let width = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) + 8 * ListMarkers.levelWidth
        setNeedsDisplay(NSRect(x: 0, y: visibleRect.minY, width: width, height: visibleRect.height))
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        invalidateListMarkers()
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
        guard isEditable, super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        // W49.notes-keep-blank-lines — text inserted on the empty last line ends it being empty: the kind kept for it
        // on the newline before goes, or it would come back as an empty item once that text is deleted.
        if let storage = textStorage, replacementString?.isEmpty == false, affectedCharRange.location > 0,
           affectedCharRange.location == storage.length,
           storage.attribute(.noteNextLineKind, at: storage.length - 1, effectiveRange: nil) != nil {
            staleNextLineKind = storage.length - 1
        }
        return true
    }

    override func didChangeText() {
        if let location = staleNextLineKind, let storage = textStorage, location < storage.length {
            staleNextLineKind = nil
            storage.removeAttribute(.noteNextLineKind, range: NSRange(location: location, length: 1))
        }
        super.didChangeText()
    }
}

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
