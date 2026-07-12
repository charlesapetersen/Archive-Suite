import Foundation

/// The editor's view of a note body as ordered blocks (00-overview §3.2/§6).
/// Wraps the same domain concept as the storage-layer `Block` / `BlockParser`,
/// but is the editor's own Sendable value type for the bridge layer.
struct NoteBody: Sendable, Equatable {
    var blocks: [NoteBlock]

    init(blocks: [NoteBlock] = []) {
        self.blocks = blocks
    }
}

struct NoteBlock: Sendable, Equatable {
    var source: SourceAnchor?
    var bodyMarkdown: String
    var unknownHeaderFields: [(String, String)]

    init(source: SourceAnchor? = nil, bodyMarkdown: String = "",
         unknownHeaderFields: [(String, String)] = []) {
        self.source = source
        self.bodyMarkdown = bodyMarkdown
        self.unknownHeaderFields = unknownHeaderFields
    }

    static func == (lhs: NoteBlock, rhs: NoteBlock) -> Bool {
        lhs.source == rhs.source &&
        lhs.bodyMarkdown == rhs.bodyMarkdown &&
        lhs.unknownHeaderFields.count == rhs.unknownHeaderFields.count &&
        zip(lhs.unknownHeaderFields, rhs.unknownHeaderFields)
            .allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}
