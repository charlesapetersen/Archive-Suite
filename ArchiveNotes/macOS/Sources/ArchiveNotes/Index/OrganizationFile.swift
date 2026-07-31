import Foundation

/// Atomic export/import of the organizational graph to `organization.json` (§4).
/// The JSON file is the durable mirror: it survives DB wipes and computer moves.
/// Authoritative for folder/membership/assignment data (the DB is the disposable cache — §11).
enum OrganizationFile {
    private struct Payload: Codable {
        var schema: Int = 1
        var folders: [VFolder]
        var memberships: [Membership]
        var assignments: [TemplateAssignment]
    }

    /// Atomically write the current organizational state to `<storeRoot>/organization.json`.
    ///
    /// **Throws — deliberately (W23.m10).** This file is what the graph is rebuilt from after a DB wipe
    /// or a move to another Mac, so an encode or write failure means the durable record no longer
    /// matches what the app just committed. The pre-W23.m10 shape swallowed both (`try?` + a `Void`
    /// return), so on a full, read-only or vanished volume every folder / membership / template change
    /// was reported as saved while the mirror stayed **stale** — and a later DB loss restored the
    /// obsolete organization. The failure is not "the file is missing": a failed atomic write leaves the
    /// PREVIOUS contents in place, which is exactly why it can go unnoticed.
    static func export(folders: [VFolder], memberships: [Membership],
                       assignments: [TemplateAssignment], to storeRoot: URL) throws {
        let payload = Payload(folders: folders, memberships: memberships, assignments: assignments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        let url = storeRoot.appendingPathComponent("organization.json")
        try data.write(to: url, options: .atomic)
    }

    /// Load the organizational graph from `<storeRoot>/organization.json`, if it exists.
    static func load(from storeRoot: URL) -> (folders: [VFolder], memberships: [Membership],
                                               assignments: [TemplateAssignment])? {
        let url = storeRoot.appendingPathComponent("organization.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        return (folders: payload.folders, memberships: payload.memberships,
                assignments: payload.assignments)
    }
}
