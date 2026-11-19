import Foundation

// MARK: - Add to Zotero (W47.ct-zotero-tags; `SPEC/containers.md` §Zotero "Add to Zotero")
//
// Zotero's CSL-JSON importer takes no tags, so the export file carries the subjects only as text. A running Zotero
// (7 or later) takes items over its connector endpoint on this Mac, `POST /connector/saveItems`, the one the browser
// connector saves through: no key, no setting to turn on, saved into the library or collection selected in Zotero.
// Those items are in the translator form `itemFromCSLJSON` makes from the CSL-JSON item, so `connectorItem` makes
// exactly what Zotero's own importer would make of `ZoteroExport.item` (checked against Zotero 10.0.9's importer,
// `Tools/zotero-import`), and adds the subjects as tags.

extension ZoteroExport {
    /// How a CSL type imports in Zotero 10: the Zotero type, and which of the type-dependent variables it keeps.
    struct ConnectorType {
        var itemType: String
        /// `genre` → the base field `type` (Letter Type, Report Type, Presentation Type).
        var genre = false
        /// `publisher-place` → `place`.
        var place = false
        /// `container-title` → `publicationTitle`.
        var publication = false
        /// `medium` (Artwork's Medium).
        var medium = false
        /// `archive`, `archive_location`, `call-number` (every type here but Presentation).
        var archive = true
        /// The creator type an author takes (Artwork's Artist, Presentation's Presenter).
        var authorType = "author"
        /// Letter has a recipient creator; elsewhere a recipient becomes the type's primary creator.
        var recipient = false
    }

    static func connectorType(csl: String) -> ConnectorType {
        switch csl {
        case "personal_communication": return ConnectorType(itemType: "letter", genre: true, recipient: true)
        case "report": return ConnectorType(itemType: "report", genre: true, place: true)
        case "speech": return ConnectorType(itemType: "presentation", genre: true, place: true, archive: false,
                                            authorType: "presenter")
        case "article-newspaper": return ConnectorType(itemType: "newspaperArticle", place: true, publication: true)
        case "article-magazine": return ConnectorType(itemType: "magazineArticle", publication: true)
        case "article-journal": return ConnectorType(itemType: "journalArticle", publication: true)
        case "graphic": return ConnectorType(itemType: "artwork", medium: true, authorType: "artist")
        default: return ConnectorType(itemType: "document")
        }
    }

    /// The Zotero item for a CSL-JSON item `item` made, as Zotero's importer makes it, with `subjects` as its tags.
    static func connectorItem(csl: [String: Any], subjects: [String]) -> [String: Any] {
        let type = connectorType(csl: csl["type"] as? String ?? "document")
        var out: [String: Any] = ["id": csl["id"] ?? "", "itemType": type.itemType]
        var fields: [(String, String)] = [("title", "title"), ("note", "extra"), ("URL", "url")]
        if type.archive {
            fields += [("archive", "archive"), ("archive_location", "archiveLocation"), ("call-number", "callNumber")]
        }
        if type.genre { fields.append(("genre", "type")) }
        if type.place { fields.append(("publisher-place", "place")) }
        if type.publication { fields.append(("container-title", "publicationTitle")) }
        if type.medium { fields.append(("medium", "medium")) }
        for (variable, field) in fields { if let v = csl[variable] as? String { out[field] = v } }

        var creators: [[String: Any]] = []
        for (variable, creatorType) in [("author", type.authorType),
                                        ("recipient", type.recipient ? "recipient" : type.authorType)] {
            for name in csl[variable] as? [[String: String]] ?? [] {
                guard let literal = name["literal"] else { continue }
                creators.append(["creatorType": creatorType, "lastName": literal, "fieldMode": 1])
            }
        }
        out["creators"] = creators
        if let issued = csl["issued"] as? [String: Any], let date = zoteroDate(issued) { out["date"] = date }
        out["tags"] = subjects.map { ["tag": $0] }
        return out
    }

    /// `issued` as Zotero writes it (`Zotero.Date.formatDate`, en-US): "1959", "March 1959", "March 12, 1959"; a
    /// literal as written.
    static func zoteroDate(_ issued: [String: Any]) -> String? {
        if let literal = issued["literal"] as? String { return literal }
        guard let parts = (issued["date-parts"] as? [[Int]])?.first, let year = parts.first else { return nil }
        guard parts.count > 1, (1...12).contains(parts[1]) else { return "\(year)" }
        let month = zoteroMonths[parts[1] - 1]
        return parts.count > 2 ? "\(month) \(parts[2]), \(year)" : "\(month) \(year)"
    }

    /// The Zotero items for `sources`, in order, ids as `export` numbers them.
    public static func connectorItems(_ sources: [ZoteroSource]) -> [[String: Any]] {
        var seen: [String: Int] = [:]
        return sources.map { source in
            let n = seen[source.fileName, default: 0] + 1
            seen[source.fileName] = n
            let csl = item(source, id: n == 1 ? source.fileName : "\(source.fileName) (\(n))")
            return connectorItem(csl: csl, subjects: source.tags.map(Self.subjects) ?? [])
        }
    }
}

private let zoteroMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                             "October", "November", "December"]

/// Saves items into the Zotero running on this Mac. Only loopback is ever contacted.
public struct ZoteroConnector: Sendable {
    public enum Failure: Error, Equatable {
        /// Nothing answers on Zotero's port: Zotero is not open.
        case notRunning
        /// Zotero answered, but did not save (a read-only library is selected, say).
        case refused(status: Int)
    }

    /// Zotero's connector server (`extensions.zotero.httpServer.port`, 23119 by default).
    public static let defaultPort = 23119
    /// The most items one request carries.
    static let batchSize = 50

    let base: URL
    let session: URLSession

    public init(port: Int = ZoteroConnector.defaultPort, session: URLSession = .shared) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        self.session = session
    }

    /// Whether a Zotero answers on this Mac (`GET /connector/ping`).
    public func isRunning() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("connector/ping"), timeoutInterval: 3)
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The request bodies for `items`, `batchSize` items each, one save session each.
    static func bodies(_ items: [[String: Any]]) throws -> [Data] {
        try stride(from: 0, to: items.count, by: batchSize).map { start in
            let batch = Array(items[start..<min(start + batchSize, items.count)])
            return try JSONSerialization.data(withJSONObject: ["sessionID": UUID().uuidString, "items": batch],
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        }
    }

    /// Saves `sources` into the library or collection selected in Zotero. Throws `Failure`; a batch that failed
    /// leaves the batches before it saved.
    public func save(_ sources: [ZoteroSource]) async throws {
        for body in try Self.bodies(ZoteroExport.connectorItems(sources)) {
            var request = URLRequest(url: base.appendingPathComponent("connector/saveItems"), timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("3", forHTTPHeaderField: "X-Zotero-Connector-API-Version")
            request.httpBody = body
            let response: URLResponse
            do { (_, response) = try await session.data(for: request) } catch { throw Failure.notRunning }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 201 else { throw Failure.refused(status: status) }
        }
    }
}
