// ArchiveLinkPayload.swift — pasteboard JSON payload for cross-app archive links (ArchiveCore)
// Used by Reader's "Copy Archive Link(s)" and Notes' paste-to-source-block.

import Foundation

/// The custom pasteboard UTI for rich archive-link data.
/// Both apps declare this as an exported type conforming to `public.data`.
public enum ArchiveLinkUTI {
    public static let type = "com.archivesuite.archive-links"
}

/// A Codable JSON payload placed on the pasteboard alongside the plain-text
/// `archivereader://` URLs. Carries display labels and optional base64 page
/// thumbnails so the receiving app can render source blocks without re-rendering.
public struct ArchiveLinkPayload: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// The canonical `archivereader://reveal?…` URL string.
        public var link: String
        /// Stable display label: `"<name>"` or `"<name> — p.<page>"`.
        public var display: String
        /// 1-based page number, if this is a page-level link.
        public var page: Int?
        /// Base64-encoded PNG thumbnail rendered by Reader for page entries.
        public var thumbPNGBase64: String?

        public init(link: String, display: String, page: Int? = nil, thumbPNGBase64: String? = nil) {
            self.link = link
            self.display = display
            self.page = page
            self.thumbPNGBase64 = thumbPNGBase64
        }
    }

    public var version: Int = 1
    public var entries: [Entry]

    public init(entries: [Entry], version: Int = 1) {
        self.entries = entries
        self.version = version
    }
}
