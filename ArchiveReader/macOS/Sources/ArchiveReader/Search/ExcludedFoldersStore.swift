import Foundation

/// Persists a set of folder paths (relative to the archive root) that the user wants excluded
/// from both the navigation list and the content index. Paths are stored as root-relative
/// strings (e.g. "Unsorted/Temp") so they survive a root-path rename/move.
///
/// Shared instance so the Settings scene and NavigationModel observe the same state.
@MainActor
final class ExcludedFoldersStore: ObservableObject {
    static let shared = ExcludedFoldersStore()

    @Published private(set) var excludedRelativePaths: [String] = []

    private let key = "ar.excludedFolders"

    /// Injected so a test can exclude a folder without writing the owner's real `ar.excludedFolders`.
    /// The hazard is the same shape as `W26.fixturehang`'s fixture pin: `SymlinkedRootTests` set
    /// `["Box"]` in `.standard` and restored it in a teardown block, and a killed test host runs no
    /// teardown — leaving the owner's Reader silently hiding a folder called `Box`. Production uses
    /// `.shared` (i.e. `.standard`); only tests pass a throwaway suite.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        excludedRelativePaths = defaults.stringArray(forKey: key) ?? []
    }

    /// Add a folder (as a root-relative path). Deduplicates and collapses nested exclusions
    /// to the outermost ancestor.
    func add(_ relativePath: String) {
        guard !relativePath.isEmpty else { return }
        if isExcluded(relativePath) { return }
        // Remove any existing exclusions that are descendants of the new one.
        var updated = excludedRelativePaths.filter { !$0.hasPrefix(relativePath + "/") }
        updated.append(relativePath)
        updated.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        excludedRelativePaths = updated
        persist()
    }

    func remove(_ relativePath: String) {
        excludedRelativePaths.removeAll { $0 == relativePath }
        persist()
    }

    /// Whether an absolute path falls under any excluded folder. Uses component-boundary
    /// matching (a prefix of "/Root/Foo" must not match "/Root/FooBar").
    func isExcludedAbsolute(_ absolutePath: String, rootPath: String) -> Bool {
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        for rel in excludedRelativePaths {
            let excluded = root + "/" + rel
            if absolutePath == excluded || absolutePath.hasPrefix(excluded + "/") {
                return true
            }
        }
        return false
    }

    /// All excluded absolute path prefixes for the given root (with trailing slash for safe matching).
    func absolutePrefixes(rootPath: String) -> [String] {
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        return excludedRelativePaths.map { root + "/" + $0 }
    }

    /// Re-read the persisted list (e.g. after UserDefaults is cleared in tests).
    func reload() {
        excludedRelativePaths = defaults.stringArray(forKey: key) ?? []
    }

    // MARK: - Private

    private func persist() {
        defaults.set(excludedRelativePaths, forKey: key)
    }

    private func isExcluded(_ path: String) -> Bool {
        excludedRelativePaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
