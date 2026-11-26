import AppKit

// NoteExport.swift — File ▸ Export… and File ▸ Print… for notes and extracts (W49.notes-export-print).
//
// A library is a package whose `.md` files sit in UUID folders, so before this a note could leave the app only
// by copy and paste. Export writes each item as its own file in a folder the user chooses; Print sends the same
// rendering to the print system.
//
// What it writes and where:
//  * Only NEW files and folders, in the chosen folder. Nothing is ever replaced: a name already there gets
//    " 2", " 3"… (`Data.write(.withoutOverwriting)`, `createDirectory` without intermediates), so an export
//    cannot overwrite the user's own file, even one made between the check and the write.
//  * Never inside the library or a granted archive folder (`NoteExportDestination.refusal`): the library holds
//    the notes themselves, and the archive corpus is read-only by the app's Core Directive.
//  * The store is only read (`NotesModel.exportSources`). Images are read through `AssetPathResolver`, the
//    inline-image read seam, so a reference that escapes the item's own `assets/` is never followed.
//
// Every format starts from one Markdown text per item (`NoteExportComposer.markdown`): the title, the date and
// the tags, the leading prose, then each source block with a visible "Source:" line in place of its
// `<!-- block: -->` header, which other Markdown readers hide and Word would show as raw markup.

/// The formats File ▸ Export… offers.
enum NoteExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, plainText, richText, word, pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown, with Images"
        case .plainText: "Plain Text"
        case .richText: "Rich Text (RTF)"
        case .word: "Word Document"
        case .pdf: "PDF"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .richText: "rtf"
        case .word: "docx"
        case .pdf: "pdf"
        }
    }

    /// Where the last choice is remembered.
    static let defaultsKey = "notes.export.format"

    static func remembered(_ defaults: UserDefaults = .standard) -> NoteExportFormat {
        defaults.string(forKey: defaultsKey).flatMap(NoteExportFormat.init(rawValue:)) ?? .markdown
    }
}

/// One item as Export and Print read it: the stored item, its folder in the library (the base its `assets/`
/// references resolve against) and the date as the list shows it.
struct NoteExportSource: Sendable {
    let item: Item
    let itemDirectory: URL
    let dateText: String?

    var displayTitle: String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// The Markdown text every format starts from. Pure: no file system, no AppKit.
enum NoteExportComposer {

    /// The item as one Markdown document. Block text is copied verbatim, so nothing the user wrote is changed.
    static func markdown(_ source: NoteExportSource) -> String {
        let item = source.item
        var head = "# \(escapeInline(source.displayTitle))"
        var meta: [String] = []
        if let date = source.dateText, !date.isEmpty { meta.append("Date: \(escapeInline(date))") }
        if !item.tags.isEmpty { meta.append("Tags: \(item.tags.map(escapeInline).joined(separator: ", "))") }
        if !meta.isEmpty { head += "\n\n" + meta.joined(separator: "  \n") }

        var parts = [head]
        if let leading = trimmedTrailingNewlines(item.trailingBodyRaw ?? ""), !leading.isEmpty {
            parts.append(leading)
        }
        for block in item.blocks {
            if let line = sourceLine(block) { parts.append(line) }
            if let body = trimmedTrailingNewlines(block.markdown), !body.isEmpty { parts.append(body) }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The visible provenance line that stands in for a block's header: its label, page and link.
    static func sourceLine(_ block: Block) -> String? {
        guard let source = block.source, !block.headerless else { return nil }
        var label = [source.display, source.noteRef, source.link]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? kindLabel(block.kind)
        if let page = source.page { label += ", p. \(page)" }
        var line = "> Source: \(escapeInline(label))"
        if let link = source.link, !link.isEmpty, link != source.display {
            line += "  \n> \(escapeInline(link))"
        }
        if let select = source.zoteroSelect, !select.isEmpty {
            line += "  \n> \(escapeInline(select))"
        }
        return line
    }

    private static func kindLabel(_ kind: Block.Kind) -> String {
        switch kind {
        case .readerPage, .readerDoc: "Archive document"
        case .zoteroItem, .zoteroAttachment: "Zotero"
        case .notePassage: "Note"
        case .freeform: "Source"
        }
    }

    /// Every `![alt](path)` in `markdown`, in order, read with the editor's own grammar (`InlineImageMarkdown`).
    static func imageReferences(in markdown: String) -> [(alt: String, path: String)] {
        let ns = markdown as NSString
        return InlineImageMarkdown.pattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            .map { match in
                (InlineImageMarkdown.unescapeAlt(ns.substring(with: match.range(at: 1))),
                 InlineImageMarkdown.decodeDestination(ns.substring(with: match.range(at: 2))))
            }
    }

    /// Backslash-escape the characters that would turn a title, date or label into styling or a link.
    static func escapeInline(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>#|".contains(ch) { out.append("\\") }
            out.append(ch == "\n" || ch == "\r" ? " " : ch)
        }
        return out
    }

    private static func trimmedTrailingNewlines(_ text: String) -> String? {
        var s = Substring(text)
        while let last = s.last, last == "\n" || last == "\r" { s = s.dropLast() }
        return String(s)
    }

    /// A file name for `title`: no path separators or colons, no leading dot, at most 120 characters.
    static func fileName(for title: String) -> String {
        var name = title.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled" : name
    }
}

/// The attributed text Print, PDF, RTF, Word and plain text are made from.
@MainActor
enum NoteExportRenderer {

    /// Body size for printed and exported text; the editor's 14 pt reads large on paper.
    static let fontSize: CGFloat = 12

    /// Every source, in order, separated by a page break. With `embedImages`, each image the item owns is drawn
    /// at up to `imageWidth`; without (RTF, Word, plain text, which cannot carry them), and for an image that is
    /// missing or outside the item's `assets/`, an "[Image: alt]" line keeps its place.
    static func attributed(_ sources: [NoteExportSource], embedImages: Bool,
                           imageWidth: CGFloat = 468) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, source) in sources.enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n\u{0C}")) }
            let parsed = MarkdownBridge.parse(markdown: NoteExportComposer.markdown(source), fontSize: fontSize)
            let text = NSMutableAttributedString(attributedString: parsed)
            replaceAttachments(in: text, source: source, embedImages: embedImages, imageWidth: imageWidth)
            out.append(text)
        }
        resolveColorsForPaper(out)
        return out
    }

    private static func replaceAttachments(in text: NSMutableAttributedString, source: NoteExportSource,
                                           embedImages: Bool, imageWidth: CGFloat) {
        var found: [(NSRange, NSTextAttachment)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment { found.append((range, attachment)) }
        }
        for (range, attachment) in found.reversed() {
            let attrs = text.attributes(at: range.location, effectiveRange: nil)
            let path = attrs[.noteImageRelPath] as? String ?? (attachment as? InlineImageAttachment)?.relativePath
            let alt = (attachment as? InlineImageAttachment)?.altText ?? ""
            var plain = attrs
            plain[.attachment] = nil
            if embedImages, let path,
               case .resolved(let url) = AssetPathResolver.resolve(path, inItemDirectory: source.itemDirectory),
               let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 {
                let picture = NSTextAttachment()
                picture.image = image
                let scale = min(1, imageWidth / image.size.width)
                picture.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                let replacement = NSMutableAttributedString(attachment: picture)
                replacement.addAttributes(plain.filter { $0.key == .paragraphStyle },
                                          range: NSRange(location: 0, length: replacement.length))
                text.replaceCharacters(in: range, with: replacement)
            } else if path != nil {
                let label = alt.isEmpty ? "[Image]" : "[Image: \(alt)]"
                text.replaceCharacters(in: range, with: NSAttributedString(string: label, attributes: plain))
            } else {
                text.replaceCharacters(in: range, with: NSAttributedString(string: "", attributes: plain))
            }
        }
    }

    /// The editor's colours follow Dark Mode; paper is white. Each colour becomes its fixed light-appearance value,
    /// so white-on-dark text does not print white on white.
    static func resolveColorsForPaper(_ text: NSMutableAttributedString) {
        guard let light = NSAppearance(named: .aqua) else { return }
        let whole = NSRange(location: 0, length: text.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineColor, .strikethroughColor] {
            var changes: [(NSRange, NSColor)] = []
            text.enumerateAttribute(key, in: whole) { value, range, _ in
                guard let color = value as? NSColor else { return }
                var fixed = color
                light.performAsCurrentDrawingAppearance { fixed = color.usingColorSpace(.sRGB) ?? color }
                changes.append((range, fixed))
            }
            for (range, color) in changes { text.addAttribute(key, value: color, range: range) }
        }
        var missing: [NSRange] = []
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { missing.append(range) }
        }
        for range in missing { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
    }

    /// A text view laid out at `width` for printing or PDF. TextKit 1, the layout AppKit paginates.
    static func printableView(_ text: NSAttributedString, width: CGFloat) -> NSTextView {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = ExportTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1), textContainer: container)
        view.ownedStorage = storage
        view.isEditable = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.drawsBackground = false
        view.appearance = NSAppearance(named: .aqua)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + 1
        view.setFrameSize(NSSize(width: width, height: max(height, 1)))
        return view
    }

    /// The print settings Export's PDF and Print start from: the user's paper, fitted to the page width.
    static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    static func printableWidth(_ info: NSPrintInfo) -> CGFloat {
        max(200, info.paperSize.width - info.leftMargin - info.rightMargin)
    }

    /// The sources as paginated PDF bytes. A print job saved to a private temporary file, since that is what
    /// paginates (`pdfOperation(with:inside:to:)` draws the whole view as one tall page); the caller writes the
    /// bytes to their new name, so the print system never writes in the user's folder itself.
    static func pdfData(_ sources: [NoteExportSource]) throws -> Data {
        let info = printInfo()
        let width = printableWidth(info)
        let view = printableView(attributed(sources, embedImages: true, imageWidth: width), width: width)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temp
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw CocoaError(.fileWriteUnknown) }
        return try Data(contentsOf: temp)
    }
}

/// Keeps its text storage alive: a TextKit 1 text view does not own the storage behind its container.
final class ExportTextView: NSTextView {
    var ownedStorage: NSTextStorage?
}

/// Where Export may write.
enum NoteExportDestination {

    /// Why `folder` is refused, or nil when Export may write there: never inside the library (`storeRoot`) or a
    /// granted archive folder. Paths are compared canonically, component by component, so a symlink or a
    /// `/private/var` spelling cannot slip a folder past the check.
    static func refusal(for folder: URL, storeRoot: URL?, archiveRoots: [URL]) -> String? {
        let target = canonicalComponents(folder)
        if let storeRoot, isWithin(target, canonicalComponents(storeRoot)) {
            return "That folder is inside this library. Choose a folder outside it, such as Documents."
        }
        if archiveRoots.contains(where: { isWithin(target, canonicalComponents($0)) }) {
            return "That folder is inside an archive folder, which Archive Notes never writes to. Choose another folder."
        }
        return nil
    }

    private static func canonicalComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" }
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    private static func isWithin(_ path: [String], _ base: [String]) -> Bool {
        !base.isEmpty && path.count >= base.count && Array(path.prefix(base.count)) == base
    }
}

/// Writes the files. Each item becomes one file named after its title; a Markdown note that has images becomes a
/// folder holding the `.md` and an `assets/` folder, so its `assets/…` links keep working unchanged.
@MainActor
enum NoteExportWriter {

    enum ExportError: LocalizedError {
        case refused(String)
        case noName(String)

        var errorDescription: String? {
            switch self {
            case .refused(let why): why
            case .noName(let title): "No free file name was found for “\(title)”."
            }
        }
    }

    /// Write every source into `folder` as `format`. Returns what was written, in order.
    static func export(_ sources: [NoteExportSource], as format: NoteExportFormat, into folder: URL,
                       storeRoot: URL?, archiveRoots: [URL],
                       fileManager: FileManager = .default) throws -> [URL] {
        if let why = NoteExportDestination.refusal(for: folder, storeRoot: storeRoot, archiveRoots: archiveRoots) {
            throw ExportError.refused(why)
        }
        var written: [URL] = []
        for source in sources {
            let base = NoteExportComposer.fileName(for: source.displayTitle)
            switch format {
            case .markdown:
                written.append(try writeMarkdown(source, base: base, into: folder, fileManager: fileManager))
            case .pdf:
                written.append(try writeNew(try NoteExportRenderer.pdfData([source]), base: base, ext: "pdf", into: folder))
            case .plainText:
                let text = NoteExportRenderer.attributed([source], embedImages: false).string
                written.append(try writeNew(Data(text.utf8), base: base, ext: "txt", into: folder))
            case .richText, .word:
                let text = NoteExportRenderer.attributed([source], embedImages: false)
                let type: NSAttributedString.DocumentType = format == .word ? .officeOpenXML : .rtf
                let data = try text.data(from: NSRange(location: 0, length: text.length),
                                         documentAttributes: [.documentType: type])
                written.append(try writeNew(data, base: base, ext: format.fileExtension, into: folder))
            }
        }
        return written
    }

    /// A free name for `base` in `folder`: "Name.ext", then "Name 2.ext", … The caller's write is what claims it.
    private static func candidate(_ base: String, ext: String?, attempt: Int, in folder: URL) -> URL {
        let name = attempt == 1 ? base : "\(base) \(attempt)"
        return folder.appendingPathComponent(ext.map { "\(name).\($0)" } ?? name, isDirectory: ext == nil)
    }

    private static let maxAttempts = 999

    /// Write `data` to a new file; a name already taken moves on to the next.
    private static func writeNew(_ data: Data, base: String, ext: String, into folder: URL) throws -> URL {
        for attempt in 1...maxAttempts {
            let url = candidate(base, ext: ext, attempt: attempt, in: folder)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
                continue
            }
        }
        throw ExportError.noName(base)
    }

    /// A new, empty folder for `base`.
    private static func makeNewFolder(_ base: String, in folder: URL, fileManager: FileManager) throws -> URL {
        for attempt in 1...maxAttempts {
            let url = candidate(base, ext: nil, attempt: attempt, in: folder)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw ExportError.noName(base)
    }

    private static func writeMarkdown(_ source: NoteExportSource, base: String, into folder: URL,
                                      fileManager: FileManager) throws -> URL {
        let markdown = NoteExportComposer.markdown(source)
        // Only the images this item owns: a reference outside its `assets/` (or a missing file) is left as written.
        var assets: [(path: String, url: URL)] = []
        for ref in NoteExportComposer.imageReferences(in: markdown) where !assets.contains(where: { $0.path == ref.path }) {
            if case .resolved(let url) = AssetPathResolver.resolve(ref.path, inItemDirectory: source.itemDirectory) {
                assets.append((ref.path, url))
            }
        }
        guard !assets.isEmpty else {
            return try writeNew(Data(markdown.utf8), base: base, ext: "md", into: folder)
        }
        let noteFolder = try makeNewFolder(base, in: folder, fileManager: fileManager)
        _ = try writeNew(Data(markdown.utf8), base: base, ext: "md", into: noteFolder)
        for asset in assets {
            // The path passed the resolver's syntactic gate: `assets/`-rooted, no `..`, not absolute.
            var target = noteFolder
            for component in asset.path.split(separator: "/") { target.appendPathComponent(String(component)) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: asset.url, to: target)
        }
        return noteFolder
    }
}
