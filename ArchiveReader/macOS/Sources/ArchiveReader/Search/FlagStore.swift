import Foundation
import Combine

/// App-side flags, persisted in UserDefaults (NOT in the files) so the archive is never written to —
/// the historian can bookmark documents while the corpus stays untouched. Keyed by file path
/// (a moved file loses its flag — a known limitation). Notes belong to Archive Notes, not here.
@MainActor
final class FlagStore: ObservableObject {
    @Published private(set) var flagged: Set<String> = []

    private let defaults: UserDefaults
    private let key = "flaggedPaths"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func isFlagged(_ path: String) -> Bool { flagged.contains(path) }

    func setFlag(_ isOn: Bool, for path: String) {
        if isOn { flagged.insert(path) } else { flagged.remove(path) }
        save()
    }
    /// Flag all given paths if any is currently unflagged; otherwise unflag all (group toggle).
    func toggleFlag(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        if paths.contains(where: { !isFlagged($0) }) { flagged.formUnion(paths) } else { flagged.subtract(paths) }
        save()
    }

    private func load() {
        flagged = Set(defaults.stringArray(forKey: key) ?? [])
    }
    private func save() {
        defaults.set(flagged.sorted(), forKey: key)
    }
}
