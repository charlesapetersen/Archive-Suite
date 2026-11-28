import AppKit

// MARK: - Paste, drag, inline images & raw mode (split in W49.notes-model-split)

extension EditorTextView {
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
        if tryPasteZoteroLinks(from: pb) { return }
        // For text: prefer plain string to avoid importing unmodeled rich styling
        if let str = pb.string(forType: .string), !str.isEmpty {
            insertPlainText(str)
            if PassagePasteboard.hasPassage(pb) || !SourceBlockPaster.readPasteboard(from: pb).isEmpty
                || !ZoteroClipboardDetect.pastedLinks(in: str).isEmpty {
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

    /// A paste made only of Zotero links becomes Zotero source blocks, as Note ▸ Attach Zotero Link… makes.
    @discardableResult
    private func tryPasteZoteroLinks(from pb: NSPasteboard) -> Bool {
        guard let handler = zoteroPasteHandler, let text = pb.string(forType: .string) else { return false }
        let refs = ZoteroClipboardDetect.pastedLinks(in: text)
        guard !refs.isEmpty else { return false }
        return handler(refs)
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

    /// Save a pasted or dropped image through assetStore and insert its reference.
    /// Raw mode inserts Markdown source. Styled mode inserts an inline attachment.
    @discardableResult
    func tryPasteImage(from pb: NSPasteboard) -> Bool {
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

        let preferredName = Self.pastedImageName()

        do {
            let relPath = try store.addAsset(data, preferredName: preferredName)
            if !isRichText {
                insertPlainText(InlineImageMarkdown.emit(alt: "", path: relPath))
                return true
            }
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

    /// `pasted-<yyyyMMdd-HHmmss-SSS>-<4 hex>.png` (W49.notes-paste-name). Each window's `ItemAssetStore`
    /// keeps its own reserved names, so two windows on one note pasting in the same second used to pick
    /// the same name, and the second write was refused (a Missing placeholder). The milliseconds and the
    /// random part make that clash vanishingly unlikely; the per-store `-N` disambiguator still covers
    /// same-window repeats. Only `[A-Za-z0-9-]`, so the Markdown destination stays bare.
    static func pastedImageName(at date: Date = Date(),
                                random: UInt16 = UInt16.random(in: .min ... .max)) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "pasted-\(df.string(from: date))-\(String(format: "%04x", random)).png"
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
}
