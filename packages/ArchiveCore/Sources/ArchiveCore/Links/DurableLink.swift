// DurableLink.swift — cross-app deep-link type (ArchiveCore)
// Enables Archive Reader ↔ Archive Notes linking via URL schemes.

import Foundation

/// A typed deep link between Archive Suite apps.
///
/// - `readerReveal`: asks Archive Reader to reveal a document.
///   URL: `archivereader://reveal?root=<lowercased-UUID>&rel=<percent-encoded-path>[&page=<n>]`
/// - `notesOpen`: asks Archive Notes to open a note.
///   URL: `archivenotes://open?id=<lowercased-UUID>[#block-<n>]`
public enum DurableLink: Equatable, Sendable {
    case readerReveal(rootGUID: UUID, relativePath: String, page: Int?)
    case notesOpen(id: UUID, block: Int?)

    // MARK: - URL schemes

    public static let readerScheme = "archivereader"
    public static let notesScheme  = "archivenotes"

    // MARK: - Format to URL

    public var url: URL {
        switch self {
        case .readerReveal(let rootGUID, let relativePath, let page):
            var components = URLComponents()
            components.scheme = Self.readerScheme
            components.host = "reveal"
            var items = [
                URLQueryItem(name: "root", value: rootGUID.uuidString.lowercased()),
                URLQueryItem(name: "rel", value: relativePath),
            ]
            if let page {
                items.append(URLQueryItem(name: "page", value: String(page)))
            }
            components.queryItems = items
            // URLComponents.url should always succeed for a well-formed link
            return components.url!

        case .notesOpen(let id, let block):
            var components = URLComponents()
            components.scheme = Self.notesScheme
            components.host = "open"
            components.queryItems = [
                URLQueryItem(name: "id", value: id.uuidString.lowercased()),
            ]
            if let block {
                components.fragment = "block-\(block)"
            }
            return components.url!
        }
    }

    // MARK: - Parse from URL

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let scheme = components.scheme?.lowercased() ?? ""
        let host = components.host?.lowercased() ?? ""

        switch (scheme, host) {
        case (Self.readerScheme, "reveal"):
            guard let items = components.queryItems,
                  let rootStr = items.first(where: { $0.name == "root" })?.value,
                  let rootGUID = UUID(uuidString: rootStr),
                  let rel = items.first(where: { $0.name == "rel" })?.value
            else { return nil }

            let page: Int?
            if let pageStr = items.first(where: { $0.name == "page" })?.value {
                guard let p = Int(pageStr) else { return nil }
                page = p
            } else {
                page = nil
            }
            self = .readerReveal(rootGUID: rootGUID, relativePath: rel, page: page)

        case (Self.notesScheme, "open"):
            guard let items = components.queryItems,
                  let idStr = items.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: idStr)
            else { return nil }

            let block: Int?
            if let fragment = components.fragment,
               fragment.hasPrefix("block-"),
               let b = Int(fragment.dropFirst("block-".count)) {
                block = b
            } else {
                block = nil
            }
            self = .notesOpen(id: id, block: block)

        default:
            return nil
        }
    }
}
