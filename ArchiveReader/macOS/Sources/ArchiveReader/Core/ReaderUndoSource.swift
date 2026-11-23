import Foundation

/// Which history Edit ▸ Undo (or Redo) takes next: the newest change, so one ⌘Z reaches a tag change,
/// a viewer's turn and container or catalogue edits alike (W49.reader-undo-menu-names).
enum ReaderUndoSource: Equatable {
    case tag, rotation, container, catalogue

    /// `tag`, `rotation`, `container`, `catalogue`: when each history's next step was made, nil where it has none. A tie goes to
    /// the later in that order: a turn over a tag change, as Undo Rotation did (W40.reader-rotate-undo).
    static func newest(tag: Date?, rotation: Date?, container: Date?, catalogue: Date? = nil) -> ReaderUndoSource? {
        let candidates: [(ReaderUndoSource, Date?)] = [(.tag, tag), (.rotation, rotation), (.container, container), (.catalogue, catalogue)]
        var best: (ReaderUndoSource, Date)?
        for case let (source, date?) in candidates where best.map({ date >= $0.1 }) ?? true { best = (source, date) }
        return best?.0
    }
}
