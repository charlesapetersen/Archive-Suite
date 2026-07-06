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
        searches.append(SavedSearch(name: trimmed, filter: filter, fullTextQuery: fullTextQuery))
        save()
    }

    func delete(_ id: UUID) {
        searches.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = searches.firstIndex(where: { $0.id == id }) else { return }
        searches[i].name = trimmed
        save()
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
