import AppKit
import SwiftUI

// MARK: - Formatting state (reported to toolbar / commands)

struct FormattingState: Equatable {
    var isBold = false
    var isItalic = false
    var isCode = false
    var hasLink = false
    var blockKind: BlockKind = .plain

    var headingLevel: Int? {
        if case .heading(let level) = blockKind { return level }
        return nil
    }

    var isUnorderedList: Bool {
        if case .listItem(ordered: false, _, _) = blockKind { return true }
        return false
    }

    var isOrderedList: Bool {
        if case .listItem(ordered: true, _, _) = blockKind { return true }
        return false
    }

    var isBlockquote: Bool { blockKind == .blockquote }

    var isCodeBlock: Bool {
        if case .codeBlock = blockKind { return true }
        return false
    }
}

// MARK: - Formatting context (bridges editor ↔ toolbar / commands)

@MainActor
final class FormattingContext: ObservableObject {
    @Published var state = FormattingState()
    weak var textView: EditorTextView?
    var fontSize: CGFloat = 14

    /// Identity of the note currently loaded in the editor (W7-S1a). W7's Create-Extract reads these to
    /// anchor a passage's provenance — `sourceNoteId` plus the snapshot title/date shown in its chip. A
    /// `nil` id means nothing is single-selected, so Create-Extract is unavailable.
    var currentItemID: UUID?
    var currentItemTitle: String = ""
    var currentItemDateDisplay: String = ""
    /// Kind of the loaded item (W7-S2). Create/Append-Extract and the copy-as-passage representation
    /// source a passage FROM a note, so they are gated on this being `.note`; in the Extracts window
    /// (an extract is loaded) Create-Extract no-ops with a status hint.
    var currentItemKind: Item.Kind?

    var canCopyCurrentItemLink: Bool {
        currentItemID != nil && currentItemKind != nil && notesModel != nil
    }

    /// The shared model, for the extract create/append actions (W7-S2). Weak — the model is an
    /// app-lifetime `@StateObject` that outlives this per-editor context and never references back.
    weak var notesModel: NotesModel?
    /// Item-scoped asset reader for the note currently loaded in the editor. Create/Append Extract
    /// use it to snapshot image bytes alongside the selected Markdown.
    var assetStore: EditorAssetStore?
    /// Shared Zotero client/status bridge. Like `notesModel`, this is app-lifetime and wired by the
    /// hosting editor pane; commands themselves have no environment-object access.
    weak var zoteroStatus: ZoteroStatusModel?
    /// Flushes the live editor through its audited body-write path before auto-fill re-reads the note.
    /// This makes an attachment added moments ago usable without asking the user to change selection.
    var flushCurrentNote: (() async -> Void)?

    @Published var zoteroAutoFillModel: ZoteroAutoFillModel?
    @Published var zoteroAutoFillError: String?
    @Published private(set) var isFetchingZoteroAutoFill = false
    /// Refreshed from the persisted selected item by `NoteEditorPane`. A command stays unavailable for
    /// an unreferenced or ambiguous note instead of pretending it can choose a citation safely.
    @Published private(set) var zoteroAutoFillReference: ZoteroAutoFillReference?
    /// What the last read of the selected note found; `nil` until it is read. Names why the command is greyed.
    @Published private(set) var zoteroAutoFillResolution: ZoteroAutoFillReferenceResolution?

    var zoteroAutoFillMenuState: ZoteroAutoFillMenuState {
        // Selection and the editor's derived kind are published independently. Consult the shared
        // summary here so the command cannot remain disabled in the brief interval between them.
        let kind = currentItemID.flatMap { id in notesModel?.allItems.first(where: { $0.id == id })?.kind } ?? currentItemKind
        return .make(hasItem: currentItemID != nil, kind: kind, isFetching: isFetchingZoteroAutoFill,
                     resolution: zoteroAutoFillResolution)
    }

    var canAutoFillFromZotero: Bool { zoteroAutoFillMenuState.isAvailable }

    func updateZoteroAutoFillReference(from item: Item) {
        guard item.id == currentItemID else { return }
        setZoteroAutoFillResolution(ZoteroAutoFillReferenceResolver.resolve(in: item))
    }

    func clearZoteroAutoFillReference() { setZoteroAutoFillResolution(nil) }

    private func setZoteroAutoFillResolution(_ resolution: ZoteroAutoFillReferenceResolution?) {
        zoteroAutoFillResolution = resolution
        if case let .available(reference) = resolution {
            zoteroAutoFillReference = reference
        } else {
            zoteroAutoFillReference = nil
        }
    }

    func copyCurrentItemLink() {
        guard canCopyCurrentItemLink, let currentItemID else { return }
        _ = notesModel?.copyOpenLink(for: currentItemID)
    }

    func toggleBold() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleBold(tv, fontSize: fontSize)
        updateState()
    }

    func toggleItalic() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleItalic(tv, fontSize: fontSize)
        updateState()
    }

    func toggleInlineCode() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleInlineCode(tv, fontSize: fontSize)
        updateState()
    }

    func insertLink() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.insertLink(tv)
        updateState()
    }

    func setHeading(_ level: Int) {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.setHeading(tv, level: level, fontSize: fontSize)
        updateState()
    }

    func setPlain() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.setPlain(tv, fontSize: fontSize)
        updateState()
    }

    func toggleUnorderedList() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleUnorderedList(tv, fontSize: fontSize)
        updateState()
    }

    func toggleOrderedList() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleOrderedList(tv, fontSize: fontSize)
        updateState()
    }

    func toggleBlockquote() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleBlockquote(tv, fontSize: fontSize)
        updateState()
    }

    func toggleCodeBlock() {
        guard let tv = textView, tv.isEditable else { return }
        EditorFormatting.toggleCodeBlock(tv, fontSize: fontSize)
        updateState()
    }

    func updateState() {
        guard let tv = textView else { return }
        state = EditorFormatting.currentState(for: tv)
    }

    /// W3-S5 seam: the coordinator that owns the editor, used for `insertBlock`.
    weak var coordinator: MarkdownEditorView.Coordinator?

    /// Insert a test source-block chip at the caret (Debug menu).
    func insertTestBlock() {
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=TEST&rel=test.pdf&jpeg=&page=1",
            display: "Test Document - p. 1",
            page: 1
        )
        coordinator?.insertBlock(kind: .readerPage, anchor: anchor)
    }

    /// Paste archive links from the pasteboard as source blocks (Edit menu / ⌘⇧V).
    func pasteSourceBlocks() {
        let entries = SourceBlockPaster.readPasteboard()
        guard !entries.isEmpty else { return }
        _ = coordinator?.handleSourceBlockPaste(entries)
    }

    /// Attach a Zotero reference (Note ▸ Attach Zotero Link… / clipboard banner).
    /// Prefers a `zotero://select/…` link already on the clipboard; otherwise prompts.
    /// Never blocks on Zotero being reachable — it only inserts the durable link.
    func attachZoteroLink() {
        if let clip = NSPasteboard.general.string(forType: .string),
           let ref = ZoteroSelectLink.parse(clip) {
            insertZoteroBlock(ref)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Attach Zotero Link"
        alert.informativeText = "Paste a zotero://select/… link."
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "zotero://select/library/items/ABCD1234"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        alert.presentAsSheet(on: textView?.window ?? NSApp.keyWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let ref = ZoteroSelectLink.parse(input.stringValue) else { return }
            self?.insertZoteroBlock(ref)
        }
    }

    /// Insert a Zotero source block (§6 `zotero:` header) at the caret. The chip
    /// renders with an "Open in Zotero" affordance; the ref persists via the block header.
    func insertZoteroBlock(_ ref: ZoteroRef) {
        let kind: Block.Kind = (ref.kind == .attachment) ? .zoteroAttachment : .zoteroItem
        let anchor = SourceAnchor(display: ref.citation ?? ref.itemKey,
                                  zoteroSelect: ref.selectLink)
        guard let coordinator else { return }
        // The chip goes in at once with the item key; the citation follows when Zotero answers.
        let pendingID = ref.citation == nil && zoteroStatus != nil ? UUID().uuidString : nil
        guard coordinator.insertBlock(kind: kind, anchor: anchor, pendingCitationID: pendingID) else { return }
        if let pendingID { fetchCitation(for: ref, kind: kind, anchor: anchor, pendingID: pendingID) }
        // The block's debounce is flushed before the command reads it. If the note already had a
        // different resolved source, avoid selecting an arbitrary one while the new block is pending;
        // a second block of the same item leaves the note's one source as it was.
        switch zoteroAutoFillResolution {
        case .some(.available(let existing)) where existing.target.selectLink == ref.selectLink:
            break
        case .some(.available), .some(.ambiguous):
            setZoteroAutoFillResolution(.ambiguous)
        case .some(.none), nil:
            setZoteroAutoFillResolution(.available(ZoteroAutoFillReference(
                ref: ref,
                target: ZoteroAutoFillReferenceTarget(selectLink: ref.selectLink,
                                                      noteFrontMatter: false, sourceBlocks: true))))
        }
    }

    /// W40.fix-notes-zotero-fetch: a block attached here showed the bare item key ("GL2HWVUW") for good,
    /// because only the inspector's chips fetched a citation. A failure leaves the key and says why.
    private func fetchCitation(for ref: ZoteroRef, kind: Block.Kind, anchor: SourceAnchor, pendingID: String) {
        let itemID = currentItemID
        Task { [weak self, weak coordinator, weak zoteroStatus] in
            guard let zoteroStatus else { return }
            do {
                let citation = try await zoteroStatus.fetchCitation(for: ref)
                guard !citation.isEmpty, let coordinator else { return }
                var filled = anchor
                filled.display = citation
                coordinator.fillPendingCitation(pendingID: pendingID, kind: kind, anchor: filled, itemID: itemID)
            } catch is CancellationError {
                return
            } catch {
                self?.notesModel?.statusMessage = "The Zotero link is attached, but its citation could not be "
                    + "fetched. \(error.localizedDescription)"
            }
        }
    }

    /// Fetch the selected note's one unambiguous attached Zotero reference and present a fill-empty
    /// confirmation. B2 will add a note-level chip/attach affordance; source-block attachments are the
    /// shipped durable path B1 must already support.
    func autoFillFromZotero() {
        guard let notesModel, let zoteroStatus, let id = currentItemID else { return }
        guard !isFetchingZoteroAutoFill else { return }

        Task { [weak self, weak notesModel, weak zoteroStatus] in
            guard let self, let notesModel, let zoteroStatus else { return }
            await self.flushCurrentNote?()
            guard let item = await notesModel.itemForZoteroAutoFill(id) else { return }
            guard item.kind == .note else {
                self.zoteroAutoFillError = "Zotero auto-fill is available for notes, not extracts."
                return
            }
            let resolution = ZoteroAutoFillReferenceResolver.resolve(in: item)
            let reference: ZoteroAutoFillReference
            switch resolution {
            case let .available(found): reference = found
            case .none:
                notesModel.statusMessage = "This note has no attached Zotero reference to auto-fill from."
                return
            case .ambiguous:
                notesModel.statusMessage = "Auto-fill requires exactly one attached Zotero reference on this note."
                return
            }

            self.isFetchingZoteroAutoFill = true
            defer { self.isFetchingZoteroAutoFill = false }
            do {
                let fetched = try await zoteroStatus.fetchAutoFillData(for: reference.ref)
                self.zoteroAutoFillModel = ZoteroAutoFillModel(
                    item: item,
                    csl: fetched.csl,
                    refSelectLink: reference.ref.selectLink,
                    citation: fetched.citation,
                    referenceTarget: reference.target,
                    save: { [weak notesModel, item] resolved in
                        guard let notesModel else { throw CancellationError() }
                        try await notesModel.applyZoteroAutoFill(resolved, basedOn: item,
                                                                 target: reference.target)
                    })
            } catch is CancellationError {
                return
            } catch {
                // Every client failure is a `ClientError` whose description says what to check.
                let detail = error.localizedDescription
                self.zoteroAutoFillError = "Zotero metadata could not be fetched. \(detail)"
                notesModel.statusMessage = "Couldn't fetch Zotero metadata."
            }
        }
    }

    func dismissZoteroAutoFillError() { zoteroAutoFillError = nil }

    // MARK: - Extracts (W7-S2)

    /// Build a passage-selection source over the LIVE editor for the current note, or nil when no note
    /// is loaded / there is no non-empty selection. Snapshots the text by value (D7 independence) and
    /// resolves referenced image bytes through the current note's item-scoped asset store.
    func makeNotePassageSource() -> EditorPassageSource? {
        guard let tv = textView, currentItemKind == .note, let id = currentItemID else { return nil }
        // NoteEditorPane retargets its live store as selection changes. The passage is consumed by an
        // async command task, so pin production reads to this source item before returning the snapshot.
        let sourceAssetStore: EditorAssetStore?
        if let itemAssetStore = assetStore as? ItemAssetStore {
            sourceAssetStore = itemAssetStore.reader(for: id)
        } else {
            sourceAssetStore = assetStore
        }
        let source = EditorPassageSource(textView: tv,
                                         sourceNoteId: id,
                                         sourceTitle: currentItemTitle,
                                         sourceDateDisplay: currentItemDateDisplay,
                                         assetStore: sourceAssetStore)
        guard source.selectedRanges.contains(where: { $0.length > 0 }) else { return nil }
        return source
    }

    /// Create Extract (⌘⌥E): snapshot the current note selection into a new extract filed under
    /// Extracts. A no-op (with a status hint) when nothing is selected or an extract — not a note — is
    /// loaded (you extract *from* a note).
    func createExtract() {
        guard let model = notesModel else { return }
        guard let source = makeNotePassageSource() else {
            model.statusMessage = "Select text in a note to make an extract."
            return
        }
        Task { await model.createExtract(from: source) }
    }

    /// Append to Extract…: snapshot the current note selection and append it to a chosen existing
    /// extract (cross-note segmentation, §D7). Presents the standard NSAlert picker idiom.
    func appendToExtract() {
        guard let model = notesModel else { return }
        guard let source = makeNotePassageSource() else {
            model.statusMessage = "Select text in a note to append to an extract."
            return
        }
        let extracts = model.existingExtracts
        guard !extracts.isEmpty else {
            model.statusMessage = "There are no extracts yet — use Create Extract first."
            return
        }
        Self.chooseExtract(from: extracts, on: textView?.window ?? NSApp.keyWindow) { [weak model] chosen in
            guard let chosen, let model else { return }
            Task { await model.appendToExtract(chosen, from: source) }
        }
    }

    /// Picker sheet for "Append to Extract…" (mirrors the NSAlert idiom in `attachZoteroLink` /
    /// `insertLink`). Calls back with the chosen extract id, or nil when cancelled / nothing valid picked.
    private static func chooseExtract(from extracts: [(id: UUID, title: String)], on window: NSWindow?,
                                      completion: @escaping (UUID?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Append to Extract"
        alert.informativeText = "Choose the extract to append this passage to."
        alert.addButton(withTitle: "Append")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        for e in extracts { popup.addItem(withTitle: e.title) }
        alert.accessoryView = popup
        alert.presentAsSheet(on: window) { response in
            let idx = popup.indexOfSelectedItem
            guard response == .alertFirstButtonReturn, extracts.indices.contains(idx) else {
                completion(nil); return
            }
            completion(extracts[idx].id)
        }
    }
}

// MARK: - FocusedValue key

struct FormattingContextKey: FocusedValueKey {
    typealias Value = FormattingContext
}

/// Commands are rendered outside the editor's object-observation graph. Publish the availability as a
/// value-type focus key as well, so a persisted attachment resolving after selection refreshes the menu.
struct ZoteroAutoFillAvailabilityKey: FocusedValueKey {
    typealias Value = ZoteroAutoFillMenuState
}

/// Note ▸ Copy Link's enablement, for the same reason (W9.e2-fu2): the context's identity fields are not
/// published, so a menu reading `canCopyCurrentItemLink` off the reference stayed disabled after selection.
struct CopyLinkAvailabilityKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var formattingContext: FormattingContext? {
        get { self[FormattingContextKey.self] }
        set { self[FormattingContextKey.self] = newValue }
    }

    var zoteroAutoFillState: ZoteroAutoFillMenuState? {
        get { self[ZoteroAutoFillAvailabilityKey.self] }
        set { self[ZoteroAutoFillAvailabilityKey.self] = newValue }
    }

    var copyLinkAvailable: Bool? {
        get { self[CopyLinkAvailabilityKey.self] }
        set { self[CopyLinkAvailabilityKey.self] = newValue }
    }
}

// MARK: - Formatting actions

@MainActor
enum EditorFormatting {

    // MARK: Inline formatting

    static func toggleBold(_ textView: NSTextView, fontSize: CGFloat) {
        toggleTrait(.boldFontMask, textView: textView, fontSize: fontSize)
    }

    static func toggleItalic(_ textView: NSTextView, fontSize: CGFloat) {
        toggleTrait(.italicFontMask, textView: textView, fontSize: fontSize)
    }

    static func toggleInlineCode(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        if range.length == 0 {
            var attrs = textView.typingAttributes
            if attrs[.noteInlineCode] as? Bool == true {
                attrs.removeValue(forKey: .noteInlineCode)
                attrs.removeValue(forKey: .backgroundColor)
                attrs[.font] = NSFont.systemFont(ofSize: fontSize)
            } else {
                attrs[.noteInlineCode] = true
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            }
            textView.typingAttributes = attrs
            return
        }

        let allCode = isEntireRange(storage, range: range, attribute: .noteInlineCode)

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        if allCode {
            storage.removeAttribute(.noteInlineCode, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.enumerateAttribute(.font, in: range) { val, r, _ in
                if let font = val as? NSFont,
                   NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) {
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize), range: r)
                }
            }
        } else {
            storage.addAttribute(.noteInlineCode, value: true, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            storage.addAttribute(.font,
                                 value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                 range: range)
        }
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    // MARK: Block formatting

    static func setHeading(_ textView: NSTextView, level: Int, fontSize: CGFloat) {
        applyBlockKind(.heading(level), textView: textView, fontSize: fontSize)
    }

    static func setPlain(_ textView: NSTextView, fontSize: CGFloat) {
        applyBlockKind(.plain, textView: textView, fontSize: fontSize)
    }

    static func toggleUnorderedList(_ textView: NSTextView, fontSize: CGFloat) {
        toggleList(ordered: false, textView: textView, fontSize: fontSize)
    }

    static func toggleOrderedList(_ textView: NSTextView, fontSize: CGFloat) {
        toggleList(ordered: true, textView: textView, fontSize: fontSize)
    }

    static func toggleBlockquote(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        let current = blockKind(at: paraRange, in: textView)
        if case .blockquote = current {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        } else {
            applyBlockKind(.blockquote, textView: textView, fontSize: fontSize)
        }
    }

    static func toggleCodeBlock(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        let current = blockKind(at: paraRange, in: textView)
        if case .codeBlock = current {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        } else {
            applyBlockKind(.codeBlock(nil), textView: textView, fontSize: fontSize)
        }
    }

    // MARK: Link

    static func insertLink(_ textView: NSTextView) {
        let range = textView.selectedRange()

        // If selection already has a link, remove it
        if range.length > 0,
           let storage = textView.textStorage,
           storage.attribute(.link, at: range.location, effectiveRange: nil) != nil {
            removeLink(textView)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Insert Link"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "https://"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        alert.presentAsSheet(on: textView.window) { [weak textView] response in
            guard response == .alertFirstButtonReturn, let textView else { return }
            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return }
            applyLink(textView, url: url)
        }
    }

    /// Apply a link attribute (testable, no dialog).
    static func applyLink(_ textView: NSTextView, url: String) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        if range.length > 0 {
            storage.addAttribute(.link, value: url, range: range)
        } else {
            var attrs = textView.typingAttributes
            attrs[.link] = url
            let linkText = NSAttributedString(string: url, attributes: attrs)
            storage.insert(linkText, at: range.location)
            textView.setSelectedRange(NSRange(location: range.location + url.count, length: 0))
        }
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    static func removeLink(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        storage.removeAttribute(.link, range: range)
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    // MARK: List indent / outdent

    static func indentList(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        guard let kind = blockKind(at: paraRange, in: textView),
              case .listItem(let ordered, let depth, let ordinal) = kind else { return }
        let newKind = BlockKind.listItem(ordered: ordered, depth: depth + 1, ordinal: ordinal)
        changeAttributes(textView, in: paraRange) { storage in
            applyBlockKindAndVisuals(storage: storage, range: paraRange, kind: newKind, fontSize: fontSize)
        }
        if textView.selectedRange().length == 0 {
            textView.typingAttributes = typingAttributes(textView.typingAttributes, kind: newKind, fontSize: fontSize)
        }
    }

    static func outdentList(_ textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        guard let kind = blockKind(at: paraRange, in: textView),
              case .listItem(let ordered, let depth, let ordinal) = kind else { return }
        if depth > 0 {
            let newKind = BlockKind.listItem(ordered: ordered, depth: depth - 1, ordinal: ordinal)
            changeAttributes(textView, in: paraRange) { storage in
                applyBlockKindAndVisuals(storage: storage, range: paraRange, kind: newKind, fontSize: fontSize)
            }
            if textView.selectedRange().length == 0 {
                textView.typingAttributes = typingAttributes(textView.typingAttributes, kind: newKind, fontSize: fontSize)
            }
        } else {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        }
    }

    // MARK: State query

    static func currentState(for textView: NSTextView) -> FormattingState {
        guard let storage = textView.textStorage else {
            return FormattingState()
        }
        let range = textView.selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length == 0 {
            attrs = textView.typingAttributes
        } else if range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        return stateFromAttrs(attrs)
    }

    // MARK: - Private helpers

    private static func stateFromAttrs(_ attrs: [NSAttributedString.Key: Any]) -> FormattingState {
        let font = attrs[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let blockKind = attrs[.noteBlockKind] as? BlockKind ?? .plain
        // Headings are structurally bold; don't report as user-toggled bold
        let isBold: Bool
        if case .heading = blockKind {
            isBold = false
        } else {
            isBold = traits.contains(.boldFontMask)
        }
        return FormattingState(
            isBold: isBold,
            isItalic: traits.contains(.italicFontMask),
            isCode: attrs[.noteInlineCode] as? Bool == true,
            hasLink: attrs[.link] != nil,
            blockKind: blockKind
        )
    }

    private static func toggleTrait(_ trait: NSFontTraitMask,
                                    textView: NSTextView,
                                    fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: fontSize)
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(trait) {
                attrs[.font] = NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
            textView.typingAttributes = attrs
            return
        }

        let allHave = isEntireRangeTrait(storage, range: range, trait: trait)

        textView.undoManager?.beginUndoGrouping()
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { val, r, _ in
            let font = val as? NSFont ?? .systemFont(ofSize: fontSize)
            let newFont: NSFont
            if allHave {
                newFont = NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                newFont = NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
            storage.addAttribute(.font, value: newFont, range: r)
        }
        storage.endEditing()
        textView.undoManager?.endUndoGrouping()
    }

    private static func toggleList(ordered: Bool, textView: NSTextView, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)
        let current = blockKind(at: paraRange, in: textView)
        if case .listItem(let ord, _, _) = current, ord == ordered {
            applyBlockKind(.plain, textView: textView, fontSize: fontSize)
        } else {
            applyBlockKind(.listItem(ordered: ordered, depth: 0, ordinal: 1),
                          textView: textView, fontSize: fontSize)
        }
    }

    private static func applyBlockKind(_ kind: BlockKind,
                                       textView: NSTextView,
                                       fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        let paraRange = paragraphRange(for: textView.selectedRange(), in: storage)

        // Detect heading→non-heading: strip structural bold that headings add.
        // User-applied bold within headings has no Markdown representation (the
        // serializer skips ** for heading text), so nothing is lost.
        let oldKind = blockKind(at: paraRange, in: textView)
        let wasHeading: Bool
        if case .heading = oldKind { wasHeading = true } else { wasHeading = false }
        let isHeading: Bool
        if case .heading = kind { isHeading = true } else { isHeading = false }

        changeAttributes(textView, in: paraRange) { storage in
            if wasHeading && !isHeading {
                storage.enumerateAttribute(.font, in: paraRange) { val, r, _ in
                    if let font = val as? NSFont {
                        storage.addAttribute(.font,
                                             value: NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask),
                                             range: r)
                    }
                }
            }
            applyBlockKindAndVisuals(storage: storage, range: paraRange, kind: kind, fontSize: fontSize)
        }
        // What is typed next takes the kind too. An empty last line has no character to carry it, so without
        // this a list or heading toggled on there showed nothing and the next keystroke was plain text
        // (W40.fix-notes-editor-lines).
        if textView.selectedRange().length == 0 {
            textView.typingAttributes = typingAttributes(textView.typingAttributes, kind: kind, fontSize: fontSize)
        }
    }

    /// `attrs` as typing attributes for a paragraph of `kind`: the same visuals `applyBlockKind` gives text.
    static func typingAttributes(_ attrs: [NSAttributedString.Key: Any], kind: BlockKind,
                                 fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var start = attrs
        if case .heading? = attrs[.noteBlockKind] as? BlockKind, let font = attrs[.font] as? NSFont {
            start[.font] = NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        }
        if start[.font] == nil { start[.font] = NSFont.systemFont(ofSize: fontSize) }
        let sample = NSTextStorage(string: " ", attributes: start)
        applyBlockKindAndVisuals(storage: sample, range: NSRange(location: 0, length: 1), kind: kind, fontSize: fontSize)
        return sample.attributes(at: 0, effectiveRange: nil)
    }

    /// Give the paragraph at `location` the kind and visuals of `kind` (W40.fix-notes-editor-lines: text joined
    /// to the paragraph above by Backspace takes that paragraph's kind, as it shows).
    static func restyleParagraph(_ textView: NSTextView, at location: Int, kind: BlockKind, fontSize: CGFloat) {
        guard let storage = textView.textStorage, location < storage.length else { return }
        let range = paragraphRange(for: NSRange(location: location, length: 0), in: storage)
        changeAttributes(textView, in: range) { storage in
            if case .heading = kind {} else {
                storage.enumerateAttribute(.noteBlockKind, in: range) { value, r, _ in
                    guard case .heading? = value as? BlockKind else { return }
                    storage.enumerateAttribute(.font, in: r) { font, fr, _ in
                        guard let font = font as? NSFont else { return }
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask),
                                             range: fr)
                    }
                }
            }
            applyBlockKindAndVisuals(storage: storage, range: range, kind: kind, fontSize: fontSize)
        }
    }

    /// An attribute-only edit of `range`, made through the text view so Undo restores the old attributes and
    /// the delegate saves the note. Done on the storage alone, a block kind change was neither undone (Undo after
    /// a Backspace join left the line below in the kind of the line above, and saved it so) nor saved until the
    /// next keystroke (W40.fix-notes-editor-lines). A disabled editor refuses it, as it refuses typing.
    static func changeAttributes(_ textView: NSTextView, in range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body(storage)
        storage.endEditing()
        textView.didChangeText()
    }

    /// The kind of the paragraph `paraRange`, or for the empty last line (which holds no character) the kind
    /// typing there would get. Reading the attribute at the end of the text raised an exception, which AppKit
    /// swallowed: Return, Backspace and the block toggles did nothing on an empty last line
    /// (W40.fix-notes-editor-lines).
    static func blockKind(at paraRange: NSRange, in textView: NSTextView) -> BlockKind? {
        guard let storage = textView.textStorage else { return nil }
        if paraRange.location < storage.length {
            return storage.attribute(.noteBlockKind, at: paraRange.location, effectiveRange: nil) as? BlockKind
        }
        return textView.typingAttributes[.noteBlockKind] as? BlockKind
    }

    private static func applyBlockKindAndVisuals(storage: NSTextStorage,
                                                  range: NSRange,
                                                  kind: BlockKind,
                                                  fontSize: CGFloat) {
        storage.addAttribute(.noteBlockKind, value: kind, range: range)

        switch kind {
        case .heading(let level):
            let sizes: [CGFloat] = [0, 28, 24, 20, 17, 15, 14]
            let size = (1...6).contains(level) ? sizes[level] : fontSize
            storage.enumerateAttribute(.font, in: range) { val, r, _ in
                var font = NSFont.boldSystemFont(ofSize: size)
                if let existing = val as? NSFont,
                   NSFontManager.shared.traits(of: existing).contains(.italicFontMask) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: font, range: r)
            }
            storage.removeAttribute(.paragraphStyle, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)

        case .blockquote:
            let ps = NSMutableParagraphStyle()
            ps.headIndent = 20
            ps.firstLineHeadIndent = 20
            storage.addAttribute(.paragraphStyle, value: ps, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            restoreBodyFont(storage: storage, range: range, fontSize: fontSize)

        case .codeBlock:
            let font = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
            storage.addAttribute(.font, value: font, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            storage.removeAttribute(.paragraphStyle, range: range)

        case .listItem(_, let depth, _):
            storage.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle(depth: depth), range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            restoreBodyFont(storage: storage, range: range, fontSize: fontSize)

        case .plain:
            storage.removeAttribute(.paragraphStyle, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            restoreBodyFont(storage: storage, range: range, fontSize: fontSize)
        }
    }

    /// Restore body-size fonts while preserving inline bold/italic/code traits.
    private static func restoreBodyFont(storage: NSTextStorage,
                                         range: NSRange,
                                         fontSize: CGFloat) {
        storage.enumerateAttribute(.font, in: range) { val, r, _ in
            guard let font = val as? NSFont else { return }
            // Preserve inline code
            if storage.attribute(.noteInlineCode, at: r.location, effectiveRange: nil) as? Bool == true {
                storage.addAttribute(.font,
                                     value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
                                     range: r)
                return
            }
            let traits = NSFontManager.shared.traits(of: font)
            var newFont = NSFont.systemFont(ofSize: fontSize)
            if traits.contains(.boldFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                newFont = NSFontManager.shared.convert(newFont, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: newFont, range: r)
        }
    }

    private static func isEntireRangeTrait(_ storage: NSTextStorage,
                                           range: NSRange,
                                           trait: NSFontTraitMask) -> Bool {
        var all = true
        storage.enumerateAttribute(.font, in: range) { val, _, stop in
            let font = val as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            if !traits.contains(trait) { all = false; stop.pointee = true }
        }
        return all
    }

    private static func isEntireRange(_ storage: NSTextStorage,
                                      range: NSRange,
                                      attribute: NSAttributedString.Key) -> Bool {
        var all = true
        storage.enumerateAttribute(attribute, in: range) { val, _, stop in
            if val == nil || (val as? Bool) != true { all = false; stop.pointee = true }
        }
        return all
    }

    static func paragraphRange(for selectedRange: NSRange,
                                in storage: NSAttributedString) -> NSRange {
        (storage.string as NSString).paragraphRange(for: selectedRange)
    }
}

extension NSAlert {
    /// Run the alert as a sheet on `window`, so it sits under the window's title bar like the app's
    /// SwiftUI prompts instead of floating off-centre over it (W40.fix-notes-visual-polish). The
    /// sheet is window-modal, and the window's selection cannot move while it is up. With no window,
    /// or one already showing a sheet, it falls back to the app-modal run it replaced.
    func presentAsSheet(on window: NSWindow?,
                        completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(runModal())
        }
    }
}
