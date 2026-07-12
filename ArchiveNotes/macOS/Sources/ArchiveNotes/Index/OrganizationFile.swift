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
    static func export(folders: [VFolder], memberships: [Membership],
                       assignments: [TemplateAssignment], to storeRoot: URL) {
        let payload = Payload(folders: folders, memberships: memberships, assignments: assignments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(payload) else { return }
        let url = storeRoot.appendingPathComponent("organization.json")
        try? data.write(to: url, options: .atomic)
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
