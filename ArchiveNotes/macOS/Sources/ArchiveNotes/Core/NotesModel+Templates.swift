import Foundation
import ArchiveCore

// MARK: - Templates (W6-S6 — §3.7, §6, §16.4; split in W49.notes-model-split)

extension NotesModel {
    func hasFailedTemplateBodyLoad(_ id: UUID) -> Bool {
        failedTemplateBodyLoads.contains(id)
    }

    func hasFailedTemplateBodySave(_ id: UUID) -> Bool {
        failedTemplateBodySaves.contains(id)
    }

    func claimTemplateEdit(_ id: UUID, pane: UUID) -> Bool {
        guard templates.contains(where: { $0.id == id }) else { return false }
        if let owner = templateEditOwners[id], owner != pane { return false }
        templateEditOwners[id] = pane
        return true
    }

    func releaseTemplateEdit(_ id: UUID, pane: UUID) {
        if templateEditOwners[id] == pane { templateEditOwners[id] = nil }
    }

    func isTemplateEditedElsewhere(_ id: UUID, pane: UUID) -> Bool {
        if let owner = templateEditOwners[id] { return owner != pane }
        return false
    }

    /// Reload the template list from the store. A no-op with no `noteStore` (an injected test store
    /// built without one); template tests inject a scratch `noteStore`.
    func reloadTemplates() async {
        guard let noteStore else { return }
        templates = await noteStore.allTemplates()
    }

    /// Templates whose kind matches `kind` — the offering set for "New from template" (§6).
    func templates(matching kind: Item.Kind) -> [Template] {
        templates.filter { $0.kind == kind }
    }

    /// Assign `templateId` to `folderId` (`nil` clears it). Persisted atomically via `OrganizationStore`
    /// (DB + organization.json). Template↔folder lives only in `template_assignments` (§16.4).
    func assignTemplate(_ templateId: UUID?, to folderId: UUID) async {
        do {
            if let templateId { try await organization.assignTemplate(templateId, to: folderId) }
            else { try await organization.removeTemplateAssignment(folder: folderId) }
            adoptMirrorFailure()
        } catch { report(error, "assign the template") }
    }

    /// The effective template for `folderId`: the nearest ancestor's live assignment (self first),
    /// else `nil` ("Blank"). An assignment pointing at a deleted template is skipped **and** lazily
    /// cleared (§6 dangling edge case), off the resolve path so this stays a pure read.
    func effectiveTemplate(for folderId: UUID?) -> Template? {
        let existing = Set(templates.map(\.id))
        let (tid, dangling) = TemplateResolution.resolve(
            folderId: folderId, folders: organization.folders,
            assignments: organization.assignments, existingTemplateIDs: existing)
        if !dangling.isEmpty { Task { await clearDanglingAssignments(dangling) } }
        guard let tid else { return nil }
        return templates.first { $0.id == tid }
    }

    /// The template a plain New uses for a `kind` item in `folderId`: the folder's effective template when it makes
    /// that kind, else none (Blank). New Note never starts from an extract template, nor New Extract from a note
    /// template, since a template makes its own kind (W40.fix-notes-new-note).
    func defaultTemplateID(for kind: Item.Kind, in folderId: UUID?) -> UUID? {
        guard let template = effectiveTemplate(for: folderId), template.kind == kind else { return nil }
        return template.id
    }

    private func clearDanglingAssignments(_ folderIds: [UUID]) async {
        for f in folderIds { try? await organization.removeTemplateAssignment(folder: f) }
        rebuild()
        adoptMirrorFailure()
    }

    /// Create a new template of `kind` named `name` (empty body). Returns the new id.
    @discardableResult
    func createTemplate(name rawName: String, kind: Item.Kind) async -> UUID? {
        guard let noteStore else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A template needs a name."; return nil }
        let item = blankItem(kind: kind, title: uniqueTemplateName(name))
        do {
            _ = try await noteStore.createTemplate(item)
            await reloadTemplates()
            return item.id
        } catch { report(error, "create the template"); return nil }
    }

    /// Read the full Markdown body of a template for the detail editor.
    func loadTemplateBody(for id: UUID) async -> String? {
        guard let noteStore else {
            failedTemplateBodyLoads.insert(id)
            return nil
        }
        do {
            let item = try await noteStore.loadTemplate(id)
            failedTemplateBodyLoads.remove(id)
            if let draft = failedTemplateBodyDrafts[id] { return draft }
            return BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)
        } catch {
            failedTemplateBodyLoads.insert(id)
            report(error, "load the template body")
            return nil
        }
    }

    /// Save body edits against a freshly loaded template so a concurrent rename or metadata edit
    /// survives. The template remains under its own store directory; this never writes the corpus.
    @discardableResult
    func setTemplateBody(_ markdown: String, for id: UUID) async -> Bool {
        guard let noteStore else { return false }
        let parsed = BlockParser.parse(markdown)
        // Saves of one template run one after another, in call order, and each settles the refused-body
        // state inside its own task: the disk and that state always end at the LAST save, and an older
        // body never lands after a newer one (W40.fix-notes-failed-save-close-fu1).
        let previous = templateBodySaveTail[id]
        let save = Task { @MainActor () -> Bool in
            _ = await previous?.value
            do {
                _ = try await noteStore.withTemplate(id) { item in
                    item.trailingBodyRaw = parsed.leadingText
                    item.blocks = parsed.blocks
                    item.modified = Date()
                }
                failedTemplateBodySaves.remove(id)
                failedTemplateBodyDrafts[id] = nil
                return true
            } catch {
                report(error, "save the template body")
                // A template trashed meanwhile has nowhere to save to; holding its body would refuse
                // every quit.
                guard !deletedTemplateIDs.contains(id) else { return false }
                failedTemplateBodySaves.insert(id)
                failedTemplateBodyDrafts[id] = markdown
                return false
            }
        }
        templateBodySaveTail[id] = save
        let saved = await save.value
        if templateBodySaveTail[id] == save { templateBodySaveTail[id] = nil }
        return saved
    }

    /// The template was deleted in this session; any refused body it held was dropped with it.
    func templateWasDeleted(_ id: UUID) -> Bool { deletedTemplateIDs.contains(id) }

    /// A refused template body this model still holds, named for an emergency copy
    /// (W40.fix-notes-failed-save-close-fu1). Nil once it saves or the template is deleted.
    func unsavedTemplateBody(_ id: UUID) -> EditorDraft? {
        guard let markdown = failedTemplateBodyDrafts[id] else { return nil }
        let title = templates.first { $0.id == id }?.name ?? "Untitled template"
        return EditorDraft(itemID: id, title: title, markdown: markdown)
    }

    /// Save a held refused template body again (close Retry, quit). True when none is left unsaved. Saves
    /// of this template already running finish first, so the body retried is the newest one held.
    func retryTemplateBody(_ id: UUID) async -> Bool {
        while let pending = templateBodySaveTail[id] {
            _ = await pending.value
            if templateBodySaveTail[id] == pending { break }   // settled; its caller has not cleared it yet
        }
        guard let markdown = failedTemplateBodyDrafts[id] else { return true }
        return await setTemplateBody(markdown, for: id)
    }

    /// Duplicate a template (fresh id + " copy" name), preserving kind + front-matter defaults + body.
    @discardableResult
    func duplicateTemplate(_ id: UUID) async -> UUID? {
        guard let noteStore else { return nil }
        do {
            var item = try await noteStore.loadTemplate(id)
            item.id = UUID()
            item.title = uniqueTemplateName("\(item.title) copy")
            item.created = Date(); item.modified = Date()
            _ = try await noteStore.createTemplate(item)
            await reloadTemplates()
            return item.id
        } catch { report(error, "duplicate the template"); return nil }
    }

    /// Rename a template (its title = its display name = its filename).
    func renameTemplate(_ id: UUID, to rawName: String) async {
        guard let noteStore else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A template needs a name."; return }
        do {
            // W23.h2: one atomic transaction, not load + save — two windows renaming the same
            // template would otherwise let the later whole-item save drop the other's edit.
            _ = try await noteStore.withTemplate(id) { item in
                item.title = name; item.modified = Date()
            }
            await reloadTemplates()
        } catch { report(error, "rename the template") }
    }

    // The fields a note made from a template starts with (W40.fix-notes-template-fields, notes-2 row 18), set in
    // the template's inspector. They are normalized as a note's are, so `newItem` copies values a note could hold.
    // A template's file gets no Finder tags: only notes are mirrored.

    @discardableResult
    func setTemplateDate(_ date: String?, precision: Item.DatePrecision?, for id: UUID) async -> Bool {
        let n = Item.normalizedDate(date, precision: precision)
        return await mutateTemplate(id, "set the template's date") { item in
            item.date = n.date
            item.datePrecision = n.precision
            if n.date == nil { item.dateUncertain = false }
        }
    }

    @discardableResult
    func setTemplateDateUncertain(_ uncertain: Bool, for id: UUID) async -> Bool {
        await mutateTemplate(id, "set the template's date uncertainty") { $0.dateUncertain = $0.date != nil && uncertain }
    }

    @discardableResult
    func setTemplateQuality(_ quality: Int?, for id: UUID) async -> Bool {
        let canonical = quality.flatMap { (1...3).contains($0) ? $0 : nil }
        return await mutateTemplate(id, "set the template's quality") { $0.quality = canonical }
    }

    /// Tag edits are deltas, as a note's are (`addTag`/`removeTag`): two quick edits, or two windows, cannot erase
    /// each other through a stale list.
    @discardableResult
    func addTemplateTag(_ tag: String, to id: UUID) async -> Bool {
        guard let tag = NotesTagVocabulary.normalizedSubjects([tag]).first else { return false }
        return await mutateTemplate(id, "add the template's tag") {
            $0.tags = NotesTagVocabulary.normalizedSubjects($0.tags + [tag])
        }
    }

    @discardableResult
    func removeTemplateTag(_ tag: String, from id: UUID) async -> Bool {
        guard let token = NotesTagVocabulary.normalizedSubjects([tag]).first else { return false }
        return await mutateTemplate(id, "remove the template's tag") {
            $0.tags = NotesTagVocabulary.normalizedSubjects($0.tags).filter { $0 != token }
        }
    }

    /// One atomic fresh-load edit of a template's front matter, as `renameTemplate` does it (W23.h2).
    private func mutateTemplate(_ id: UUID, _ action: String,
                                _ mutate: @Sendable (inout Item) -> Void) async -> Bool {
        // A field left with an edit as its template is deleted applies on disappearing; there is nothing to save to.
        guard let noteStore, !deletedTemplateIDs.contains(id) else { return false }
        do {
            _ = try await noteStore.withTemplate(id) { item in
                mutate(&item)
                item.modified = Date()
            }
            await reloadTemplates()
            return true
        } catch { report(error, action); return false }
    }

    /// The folders assigned `templateId` directly, in sidebar order. A subfolder of one inherits it unless it
    /// has its own (§16.4), so these are the places to change it.
    func foldersAssigned(_ templateId: UUID) -> [NotesFolderNode] {
        let ids = Set(organization.assignments.filter { $0.templateId == templateId }.map(\.folderId))
        return assignableFolders.map(\.node).filter { ids.contains($0.id) }
    }

    /// Every normal folder, depth-first in sidebar order with its depth — what a template can be assigned to.
    var assignableFolders: [(node: NotesFolderNode, depth: Int)] {
        var result: [(node: NotesFolderNode, depth: Int)] = []
        func walk(_ nodes: [NotesFolderNode], _ depth: Int) {
            for n in nodes { result.append((n, depth)); walk(n.children, depth + 1) }
        }
        walk(normalTree, 0)
        return result
    }

    /// The template assigned directly to `folderId` (not inherited); nil if none.
    func assignedTemplateID(_ folderId: UUID) -> UUID? {
        organization.assignments.first { $0.folderId == folderId }?.templateId
    }

    /// Delete a template (to Trash) and clear every folder assignment that pointed at it (batched, §6).
    ///
    /// **The trash goes FIRST, and the assignments are only cleared once it succeeded (W23.m13).** The
    /// old order cleared every assignment before attempting the trash, so a refused trash reported a
    /// failure about a template that was still there while its folder assignments were already,
    /// silently and unrecoverably, gone. Reversed, a refused trash changes nothing at all. The cost of
    /// the other direction — trashed, then the clear fails — is only a dangling assignment, which
    /// `TemplateResolution.resolve` already skips and `effectiveTemplate` lazily clears; and the clear
    /// is itself one transaction, so it can't half-apply across folders.
    func deleteTemplate(_ id: UUID) async {
        guard let noteStore else { return }
        do { try await noteStore.deleteTemplate(id) }
        catch {
            report(error, "delete the template")
            await reloadTemplates(); rebuild(); adoptMirrorFailure()
            return
        }
        // Read AFTER the trash, not before: this method is `@MainActor` but reentrant at that await, so
        // an assignment made to this template while the trash was in flight would be missed by a set
        // captured earlier — and by then it is already an assignment to a trashed template.
        let referencing = organization.assignments.filter { $0.templateId == id }.map(\.folderId)
        do { try await organization.removeTemplateAssignments(folders: referencing) }
        catch { report(error, "clear the deleted template's folder assignments") }
        deletedTemplateIDs.insert(id)
        failedTemplateBodySaves.remove(id)
        failedTemplateBodyDrafts[id] = nil
        await reloadTemplates()
        rebuild()
        adoptMirrorFailure()
    }

    /// A name-unique template name (case-insensitive), appending " 2", " 3", … if taken.
    private func uniqueTemplateName(_ base: String) -> String {
        let taken = Set(templates.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}
