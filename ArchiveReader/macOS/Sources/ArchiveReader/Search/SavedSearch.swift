import Foundation
import Combine

/// A named Advanced Search the user can recall (a "smart folder"). Saving the filter bar stores its state as the
/// equivalent rules (`AdvancedSearch(filter:fullTextQuery:)`), so every smart folder is one rule tree and opens in
/// the Advanced Search form. Before W40.reader-advanced-search it held a `LibraryFilter` and a Find query; no
/// migration is written because there is nothing to migrate (owner, 2026-08-01).
struct SavedSearch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var search: AdvancedSearch
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

    /// The new smart folder's id, or nil for a blank name.
    @discardableResult
    func add(name: String, search: AdvancedSearch) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Disambiguate a duplicate name (rather than silently dropping the user's save).
        let unique = uniqueName(trimmed, excluding: nil)
        let saved = SavedSearch(name: unique, search: search)
        searches.append(saved)
        save()
        return saved.id
    }

    /// Replace a smart folder's rules (Edit Smart Folder), keeping its name and place.
    func update(_ id: UUID, search: AdvancedSearch) {
        guard let i = searches.firstIndex(where: { $0.id == id }), searches[i].search != search else { return }
        searches[i].search = search
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
        // One entry at a time: a smart folder in a shape this build cannot read (one saved before the rule
        // tree) is dropped alone instead of emptying the list.
        if let data = defaults.data(forKey: key),
           let arr = try? JSONDecoder().decode([Lossy].self, from: data) {
            searches = arr.compactMap(\.value)
        }
    }
    private struct Lossy: Decodable {
        let value: SavedSearch?
        init(from decoder: Decoder) throws { value = try? SavedSearch(from: decoder) }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(searches) { defaults.set(data, forKey: key) }
    }
}
