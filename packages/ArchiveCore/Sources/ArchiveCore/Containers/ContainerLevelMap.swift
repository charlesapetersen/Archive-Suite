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

        private enum CodingKeys: String, CodingKey { case role, children }

        public init(from decoder: Decoder) throws {
            try decoder.refuseUnknownKeys(["role", "children"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(role: try c.decode(ContainerLevelRole.self, forKey: .role),
                      children: try c.decodeIfPresent(ContainerLevelRole.self, forKey: .children))
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
                // The depth after the override's own; an ignored folder holds no depth of its own.
                let after = o.role == .ignore ? next : (index(of: o.role, from: next) ?? next) + 1
                if let children = o.children, let at = index(of: children, from: after) {
                    next = at
                } else {
                    next = after
                }
            } else {
                roles.append(next < levels.count ? levels[next] : nil)
                next += 1
            }
        }
        return roles
    }

    /// The first depth at or after `from` with `role`, else the first anywhere (a role repeated in `levels`, such as
    /// two series depths, resolves to the one at hand).
    private func index(of role: ContainerLevelRole, from: Int) -> Int? {
        levels.indices.first { $0 >= from && levels[$0] == role } ?? levels.firstIndex(of: role)
    }
}

extension ContainerLevelMap: Codable {
    private enum CodingKeys: String, CodingKey { case schemaVersion, levels, overrides, updatedAt }

    // Strict: a role or key this build does not know makes the whole map unreadable, so it is left alone rather than
    // read wrongly or overwritten.
    public init(from decoder: Decoder) throws {
        try decoder.refuseUnknownKeys(["schemaVersion", "levels", "overrides", "updatedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.levels = try c.decode([ContainerLevelRole].self, forKey: .levels)
        self.overrides = try c.decodeIfPresent([String: Override].self, forKey: .overrides) ?? [:]
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ContainerLevelMap.schemaVersion, forKey: .schemaVersion)
        try c.encode(levels, forKey: .levels)
        try c.encode(overrides, forKey: .overrides)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}
