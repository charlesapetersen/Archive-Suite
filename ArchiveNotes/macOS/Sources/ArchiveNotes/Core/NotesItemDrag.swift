import AppKit

/// Pasteboard payload for dragging item rows from the table onto folder-tree rows (06-viewers §5,
/// W6-S5). The payload is **ids only** — a JSON `[uuidString]`, no file bytes — so a drag can never
/// carry or corrupt corpus data (Prime Directive #1). Local-only (`forLocal:`); a foreign drag whose
/// bytes don't decode to UUIDs yields `[]`, so a stray drop is a safe no-op.
///
/// The canonical representation is the custom pasteboard type `com.archivenotes.item-ids`; the drag
/// source also writes the same JSON as `.string`; folder rows explicitly decode either bytes or text
/// through their drop delegate (see `NotesFolderTreeView`).
enum NotesItemDrag {
    static let folderTypeIdentifier = "com.archivenotes.folder-id"
    /// Custom pasteboard type carrying the id list (matches the app's other `com.archivenotes.*` UTIs).
    static let pasteboardType = NSPasteboard.PasteboardType("com.archivenotes.item-ids")

    /// Encode item ids to a deterministic JSON `[uuidString]`. Order is preserved.
    static func encode(_ ids: [UUID]) -> Data {
        (try? JSONEncoder().encode(ids.map { $0.uuidString })) ?? Data("[]".utf8)
    }

    /// Encode as a UTF-8 JSON string (the `.string` pasteboard representation).
    static func encodedString(_ ids: [UUID]) -> String {
        String(data: encode(ids), encoding: .utf8) ?? "[]"
    }

    /// Decode a payload back to item ids. Returns `[]` for malformed / foreign data or any string that
    /// isn't a UUID (a stray/foreign drop must be an inert no-op, never a partial mutation).
    static func decode(_ data: Data) -> [UUID] {
        guard let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap { UUID(uuidString: $0) }
    }

    /// Decode from the `.string` representation (the SwiftUI drop path).
    static func decode(string: String) -> [UUID] {
        decode(Data(string.utf8))
    }

    /// The drag operation implied by the modifier keys held at drop: **⌥ Option = replicate** (`.copy`,
    /// the DevonThink replicant — add-only, source untouched); anything else = **move** (`.move`).
    /// Kept pure so the MOVE-vs-REPLICATE decision is unit-testable without a live drag session.
    static func operation(optionHeld: Bool) -> NSDragOperation {
        optionHeld ? .copy : .move
    }

    /// Folder reparents always move; only item placements can replicate with Option.
    static func operation(isFolder: Bool, optionHeld: Bool) -> NSDragOperation {
        isFolder ? .move : operation(optionHeld: optionHeld)
    }

    /// What a drag in flight carries, as a folder row needs to know it while the pointer is still moving
    /// (W40.fix-notes-folder-drag). The item providers only load asynchronously, at the drop, so the row
    /// reads the drag pasteboard, which answers at once: note rows from the table, one folder, or
    /// something from outside the app.
    enum DragKind: Equatable { case items, folder(UUID), other }

    static func dragKind(on pasteboard: NSPasteboard) -> DragKind {
        let types = pasteboard.types ?? []
        if types.contains(pasteboardType) { return .items }
        // A SwiftUI folder drag lists the `.ownProcess` folder type but answers nil for its data (measured
        // in the VM), so the id is read from the text when the folder type gives nothing.
        let folderType = NSPasteboard.PasteboardType(folderTypeIdentifier)
        let candidates = [pasteboard.data(forType: folderType).flatMap { String(data: $0, encoding: .utf8) },
                          pasteboard.string(forType: .string)]
        for case let text? in candidates {
            if let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return .folder(id) }
        }
        return .other
    }

    /// Where on a folder row a drop lands: beside it (`before` / `after`, a reorder) or `into` it. A folder
    /// on the top or bottom quarter of the row goes beside it (W9.e2-fu1); everything else, and anything
    /// over a row not yet measured, goes into it. The row's highlight and its drop both come from here.
    enum DropZone: Equatable { case before, into, after }

    static func dropZone(y: CGFloat, rowHeight: CGFloat, isFolder: Bool) -> DropZone {
        guard isFolder, rowHeight > 0 else { return .into }
        let band = rowHeight / 4
        if y <= band { return .before }
        if y >= rowHeight - band { return .after }
        return .into
    }

    @MainActor
    static func folderProvider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider(object: id.uuidString as NSString)
        let bytes = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: folderTypeIdentifier, visibility: .ownProcess) { completion in
            completion(bytes, nil)
            return nil
        }
        return provider
    }
}
