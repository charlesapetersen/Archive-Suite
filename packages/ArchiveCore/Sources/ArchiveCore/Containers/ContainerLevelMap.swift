import Foundation

// MARK: - The level map, Route B (W47.ct-spec; `SPEC/containers.md` §The level map)
//
// What each depth of a folder tree names, confirmed once per root and stored at
// `<root>/.archivesuite/container-levels.json`. Pre-filling it from the names, and splitting a name into fields, are
// `W47.ct-infer`'s.

/// What a directory in the tree names.
public enum ContainerLevelRole: String, Sendable, CaseIterable, Codable {
    case repository, collection, accession, series, box, folder
    /// Names no field. In `levels` it occupies its depth; as an override it is a workflow folder and does not count.
    case ignore

    /// The field the directory's name fills (a collection's number and a folder's title are split out by
    /// `W47.ct-infer`).
    public var field: ContainerField? {
        switch self {
        case .repository: return .repository
        case .collection: return .collectionTitle
        case .accession: return .accession
        case .series: return .series
        case .box: return .container
        case .folder: return .folder
        case .ignore: return nil
        }
    }
}

public struct ContainerLevelMap: Equatable, Sendable {
    public static let fileName = "container-levels.json"
    public static let schemaVersion = 1

    public struct Override: Equatable, Sendable, Codable {
        public var role: ContainerLevelRole
        /// The role of the subfolders' depth, one of `levels`.
        public var children: ContainerLevelRole?

        public init(role: ContainerLevelRole, children: ContainerLevelRole? = nil) {
            self.role = role
            self.children = children
        }
    }

    /// The role of each depth below the root, the first for its direct subfolders.
    public var levels: [ContainerLevelRole]
    /// Relative directory path (names joined by `/`, as written) to its own role.
    public var overrides: [String: Override]
    public var updatedAt: Date?

    public init(levels: [ContainerLevelRole], overrides: [String: Override] = [:], updatedAt: Date? = nil) {
        self.levels = levels
        self.overrides = overrides
        self.updatedAt = updatedAt
    }

    /// The role of each directory on `components` (the path below the root, top first); nil past the map.
    public func roles(for components: [String]) -> [ContainerLevelRole?] {
        var next = 0   // index in `levels` of the next counted depth
        var roles: [ContainerLevelRole?] = []
        for i in components.indices {
            let path = components[0...i].joined(separator: "/")
            if let o = overrides[path] {
                roles.append(o.role)
                if let children = o.children, let at = levels.firstIndex(of: children) {
                    next = at
                } else if o.role != .ignore {
                    next = (levels.firstIndex(of: o.role) ?? next) + 1
                }
            } else {
                roles.append(next < levels.count ? levels[next] : nil)
                next += 1
            }
        }
        return roles
    }
}

extension ContainerLevelMap: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, levels, overrides, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A level this build does not know names nothing but keeps its depth; an unknown override is dropped.
        let levels = try c.decode([String].self, forKey: .levels)
        self.levels = levels.map { ContainerLevelRole(rawValue: $0) ?? .ignore }
        let raw = (try? c.decodeIfPresent([String: LenientOverride].self, forKey: .overrides)) ?? [:]
        self.overrides = raw.compactMapValues(\.value)
        self.updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ContainerLevelMap.schemaVersion, forKey: .schemaVersion)
        try c.encode(levels, forKey: .levels)
        try c.encode(overrides, forKey: .overrides)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    private struct LenientOverride: Decodable {
        let value: Override?
        init(from decoder: Decoder) throws { value = try? Override(from: decoder) }
    }
}
