import Foundation

/// The pasteboard payload for copy-in-Notes → paste-into-Extract (W7 §5): the snapshot bytes that
/// let provenance survive a pasteboard round-trip into an extract. Written under the custom UTI
/// `com.archivenotes.passage` (declared in Info.plist by W7-S2), mirroring the Reader's
/// Copy-Archive-Link custom-UTI JSON idiom (00-overview §8.4).
///
/// Decode defensively (Prime Directive / §Risks): a malformed payload degrades to a plain-text
/// freeform paste, never a crash — hence `init?(data:)` returns nil rather than throwing.
struct NotesPassagePayload: Codable, Sendable, Equatable {

    /// The source note every segment was copied from (segments always share one source note; a
    /// cross-note extract is assembled by *appending* separate payloads — segmentation, §D7).
    var sourceNoteId: UUID
    var sourceTitle: String
    var sourceDateDisplay: String
    var segments: [Segment]

    struct Segment: Codable, Sendable, Equatable {
        /// Ordinal of the covered block in the source note at snapshot time (§8.2 `#block-<n>`).
        var sourceBlockIndex: Int
        var markdown: String
        /// Inline-image bytes referenced by `markdown` (`![alt](assets/<filename>)`), keyed by the
        /// bare filename. Copied — not referenced — so the extract is self-contained (D7 snapshot).
        var assetPNGs: [String: Data]

        init(sourceBlockIndex: Int, markdown: String, assetPNGs: [String: Data] = [:]) {
            self.sourceBlockIndex = sourceBlockIndex
            self.markdown = markdown
            self.assetPNGs = assetPNGs
        }
    }

    init(sourceNoteId: UUID, sourceTitle: String, sourceDateDisplay: String, segments: [Segment]) {
        self.sourceNoteId = sourceNoteId
        self.sourceTitle = sourceTitle
        self.sourceDateDisplay = sourceDateDisplay
        self.segments = segments
    }

    /// Custom pasteboard type identifier (declared in Info.plist `UTExportedTypeDeclarations`, W7-S2).
    static let uti = "com.archivenotes.passage"

    /// JSON encoding for the pasteboard; nil only if encoding unexpectedly fails.
    var data: Data? { try? JSONEncoder().encode(self) }

    /// Tolerant decode from pasteboard bytes; nil on any malformed input (caller degrades to text).
    init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}
