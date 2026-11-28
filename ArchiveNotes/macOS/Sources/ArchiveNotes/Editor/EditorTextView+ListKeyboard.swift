import AppKit

// MARK: - List keyboard behavior (Tab / Return / Backspace; split in W49.notes-model-split)

extension EditorTextView {
    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        guard let storage = textStorage,
              case .listItem? = EditorFormatting.blockKind(
                at: (storage.string as NSString).paragraphRange(for: selectedRange()), in: self) else {
            super.insertTab(sender)
            return
        }
        EditorFormatting.indentList(self, fontSize: configuredFontSize)
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable else { return }
        guard let storage = textStorage,
              case .listItem? = EditorFormatting.blockKind(
                at: (storage.string as NSString).paragraphRange(for: selectedRange()), in: self) else {
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
        let kind = EditorFormatting.blockKind(at: paraRange, in: self)
        if case .heading? = kind {
            // A Return at the end of a heading starts a line of text, as in any editor; one inside it splits it.
            let text = string as NSString
            var contentEnd = NSMaxRange(paraRange)
            while contentEnd > paraRange.location, [0x0A, 0x0D].contains(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
            let atEnd = sel.length == 0 && sel.location >= contentEnd
            let atStart = sel.length == 0 && sel.location == paraRange.location && contentEnd > paraRange.location
            super.insertNewline(sender)
            if atEnd { EditorFormatting.setPlain(self, fontSize: configuredFontSize) }
            // At its start, the empty line left above the heading is text, not an empty heading (`# `).
            if atStart {
                EditorFormatting.restyleParagraph(self, at: paraRange.location, kind: .plain, fontSize: configuredFontSize)
            }
            return
        }
        guard case .listItem(let ordered, let depth, let ordinal)? = kind else {
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

        EditorFormatting.changeAttributes(self, in: newParaRange) { storage in
            storage.addAttribute(.noteBlockKind, value: newKind, range: newParaRange)
            storage.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle(depth: depth),
                                 range: newParaRange)
        }
        // A new empty item at the end is kept as one, as an empty item in the middle is (W49.notes-keep-blank-lines).
        EditorFormatting.keepEmptyLastLineKind(self, kind: newKind)
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
        guard let kind = EditorFormatting.blockKind(at: paraRange, in: self) else {
            super.deleteBackward(sender)
            return
        }
        switch kind {
        case .listItem:
            EditorFormatting.outdentList(self, fontSize: configuredFontSize)
        case .blockquote, .heading:
            EditorFormatting.setPlain(self, fontSize: configuredFontSize)
        default:
            // Joining this line to the one above: the joined line takes that line's kind, as it now shows. Left
            // as it was, text joined to a heading or a list item kept its own kind and was written as a block of
            // its own, so the line break came back on the next reselect (W40.fix-notes-editor-lines).
            let above = EditorFormatting.blockKind(
                at: (string as NSString).paragraphRange(for: NSRange(location: sel.location - 1, length: 0)), in: self)
            super.deleteBackward(sender)
            let joined = selectedRange()
            // Only a real join: with an empty line above (a blank line deleted), the line keeps its own kind.
            guard let above, above != kind, joined.length == 0, joined.location == sel.location - 1,
                  joined.location < storage.length,
                  (string as NSString).paragraphRange(for: joined).location < joined.location else { return }
            EditorFormatting.restyleParagraph(self, at: joined.location, kind: above, fontSize: configuredFontSize)
        }
    }
}
