import Foundation

/// A reusable note/extract skeleton (00-overview §3.7). A template **is** a note: it is stored as a
/// real Markdown file with front-matter + body under `<root>/Templates/<uuid>/<Name>.md`, so it can be
/// edited in the normal editor and instantiated by "New from template" (which clones its front-matter
/// defaults + body into a fresh item). This lightweight projection is what folder menus + the template
/// list bind to; the full backing `Item` is loaded from `NoteStore` only when instantiating.
struct Template: Sendable, Equatable, Identifiable {
    /// Stable id — the backing item's `id` (also the `Templates/<uuid>/` folder name and the value
    /// stored in `template_assignments.template_id`, §16.4).
    let id: UUID
    /// Display name = the backing item's title (its filename projection).
    var name: String
    /// note | extract — "New from template" only offers templates matching the active window's default
    /// kind (06-viewers §6).
    var kind: Item.Kind
}

/// Pure nearest-ancestor template resolution + dangling-assignment detection (06-viewers §6, §16.4).
///
/// Template↔folder lives ONLY in `template_assignments` (no `Folder.templateId` field, §16.4). A
/// folder's *effective* template is the assignment on the nearest ancestor (self first) whose template
/// still exists. An assignment that points at a **deleted** template is *dangling*: it is skipped (the
/// walk falls through to the ancestor / "Blank") **and** reported so the caller can lazily clear it
/// (§6 edge case). Total by construction (visited-set + guard cap), so a corrupt parent graph can't
/// spin it.
enum TemplateResolution {
    /// - Parameters:
    ///   - folderId: the folder to resolve from (`nil` = no scope → no template).
    ///   - folders: the full folder set (drives the `parentId` walk).
    ///   - assignments: folder→template links.
    ///   - existingTemplateIDs: ids of templates that currently exist on disk.
    /// - Returns: the resolved template id (`nil` ⟹ "Blank"), plus the folder ids whose assignment is
    ///   dangling (points at a missing template) and should be cleared.
    static func resolve(folderId: UUID?,
                        folders: [VFolder],
                        assignments: [TemplateAssignment],
                        existingTemplateIDs: Set<UUID>) -> (templateId: UUID?, dangling: [UUID]) {
        guard let start = folderId else { return (nil, []) }
        let parentByID = Dictionary(folders.map { ($0.id, $0.parentId) }, uniquingKeysWith: { a, _ in a })
        let templateByFolder = Dictionary(
            assignments.map { ($0.folderId, $0.templateId) }, uniquingKeysWith: { a, _ in a })

        var dangling: [UUID] = []
        var visited = Set<UUID>()
        var cursor: UUID? = start
        var guardCount = 0
        while let f = cursor, guardCount < 100_000, visited.insert(f).inserted {
            guardCount += 1
            if let tid = templateByFolder[f] {
                if existingTemplateIDs.contains(tid) {
                    return (tid, dangling)        // live assignment on the nearest ancestor → resolved
                }
                dangling.append(f)                // deleted template → skip, mark, keep walking up
            }
            cursor = parentByID[f] ?? nil          // flatten UUID?? (missing folder → stop)
        }
        return (nil, dangling)                     // reached the root with no live assignment → Blank
    }
}
