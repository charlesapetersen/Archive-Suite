import Foundation
import Combine

/// A per-file note + flag the historian adds. Stored OUTSIDE the corpus.
struct FileAnnotation: Codable, Sendable, Equatable {
    var note: String = ""
    var flagged: Bool = false
    var isEmpty: Bool { note.isEmpty && !flagged }
}

/// App-side notes & flags, persisted in UserDefaults (NOT in the files) so the archive is never
/// written to — the historian can annotate/bookmark documents while the corpus stays untouched.
/// Keyed by file path. (Path-keyed for v1; a moved file loses its note — noted as a known limitation.)
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var annotations: [String: FileAnnotation] = [:]

    private let defaults: UserDefaults
    private let key = "fileAnnotations"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func annotation(for path: String) -> FileAnnotation { annotations[path] ?? FileAnnotation() }
    func isFlagged(_ path: String) -> Bool { annotations[path]?.flagged ?? false }

    func setNote(_ note: String, for path: String) {
        var a = annotation(for: path); a.note = note; store(a, path)
    }
    func setFlag(_ flagged: Bool, for path: String) {
        var a = annotation(for: path); a.flagged = flagged; store(a, path)
    }
    /// Flag all given paths if any is currently unflagged; otherwise unflag all (group toggle).
    func toggleFlag(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let target = paths.contains { !isFlagged($0) }
        for p in paths { var a = annotation(for: p); a.flagged = target; annotations[p] = a.isEmpty ? nil : a }
        save()
    }

    private func store(_ a: FileAnnotation, _ path: String) {
        annotations[path] = a.isEmpty ? nil : a
        save()
    }
    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: FileAnnotation].self, from: data) else { return }
        annotations = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(annotations) { defaults.set(data, forKey: key) }
    }
}
