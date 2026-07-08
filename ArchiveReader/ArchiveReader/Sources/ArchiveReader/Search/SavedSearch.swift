import Foundation
import Combine

/// A named filter + full-text query the user can recall (a "smart folder").
struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var filter: LibraryFilter
    var fullTextQuery: String
}

/// Persists saved searches in UserDefaults (app data, not the corpus).
@MainActor
final class SavedSearchStore: ObservableObject {
    @Published private(set) var searches: [SavedSearch] = []

    private let defaults: UserDefaults
    private let key = "savedSearches"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(name: String, filter: LibraryFilter, fullTextQuery: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Disambiguate a duplicate name (rather than silently dropping the user's save).
        let unique = uniqueName(trimmed, excluding: nil)
        searches.append(SavedSearch(name: unique, filter: filter, fullTextQuery: fullTextQuery))
        save()
    }

    func delete(_ id: UUID) {
        searches.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = searches.firstIndex(where: { $0.id == id }) else { return }
        // Keep names unique (case-insensitive); renaming an item to its own name is a no-op-safe keep.
        searches[i].name = uniqueName(trimmed, excluding: id)
        save()
    }

    /// Reorder the saved searches (drag-to-reorder from the sidebar). Foundation-only implementation
    /// so this store stays UI-free; the semantics match SwiftUI's `move(fromOffsets:toOffset:)`
    /// (`destination` is an index into the *pre-removal* array).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !source.isEmpty else { return }
        let moving = source.sorted().map { searches[$0] }
        var result = searches
        for i in source.sorted(by: >) { result.remove(at: i) }
        let adjusted = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: max(0, min(adjusted, result.count)))
        searches = result
        save()
    }

    /// Make `desired` unique among the existing names (case-insensitive), appending " 2", " 3", …
    /// when it collides. `excluding` skips one item's own name (so a self-rename keeps its name).
    private func uniqueName(_ desired: String, excluding id: UUID?) -> String {
        let taken = Set(searches.filter { $0.id != id }.map { $0.name.lowercased() })
        guard taken.contains(desired.lowercased()) else { return desired }
        var n = 2
        while taken.contains("\(desired) \(n)".lowercased()) { n += 1 }
        return "\(desired) \(n)"
    }

    private func load() {
        if let data = defaults.data(forKey: key),
           let arr = try? JSONDecoder().decode([SavedSearch].self, from: data) {
            searches = arr
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(searches) { defaults.set(data, forKey: key) }
    }
}
