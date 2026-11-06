import SwiftUI

/// Note-front-matter references, distinct from the editor's insert-source-block command. The link is
/// saved first, so an offline Zotero never prevents attachment. Every write uses the audited model path.
struct NoteZoteroInspector: View {
    @ObservedObject var model: NotesModel
    let itemID: UUID
    @EnvironmentObject private var status: ZoteroStatusModel
    @State private var refs: [ZoteroRef] = []
    @State private var link = ""
    @State private var fetching: Set<String> = []
    /// selectLink → why its citation could not be fetched, shown under the chip.
    @State private var failed: [String: String] = [:]
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zotero references").font(.subheadline.bold())
            ForEach(refs, id: \.selectLink) { ref in
                HStack {
                    ZoteroChipView(ref: ref, isFetching: fetching.contains(ref.selectLink),
                                   didFail: failed[ref.selectLink] != nil)
                    if failed[ref.selectLink] != nil {
                        Button("Retry citation") { fetch(ref) }
                            .font(.caption)
                            .accessibilityIdentifier("an.zotero.retry.\(ref.itemKey)")
                    }
                }
                if let reason = failed[ref.selectLink] {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("an.zotero.failure.\(ref.itemKey)")
                }
            }
            HStack {
                TextField("zotero://select/…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("an.zotero.note.link")
                    .onSubmit { attach() }
                Button("Attach to note") { attach() }
                    .disabled(saving || ZoteroSelectLink.parse(link) == nil)
                    .accessibilityIdentifier("an.zotero.note.attach")
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: model.itemsGeneration) {
            guard let item = await model.itemForZoteroAutoFill(itemID), !Task.isCancelled else { return }
            refs = item.zotero
        }
    }

    private func attach() {
        guard !saving, let ref = ZoteroSelectLink.parse(link) else { return }
        saving = true
        saveError = nil
        Task { @MainActor in
            let saved = await model.attachZoteroReference(ref, to: itemID)
            saving = false
            guard saved else {
                saveError = "Couldn't attach this reference. Please try again."
                return
            }
            link = ""
            guard let item = await model.itemForZoteroAutoFill(itemID),
                  let stored = item.zotero.first(where: { $0.selectLink == ref.selectLink }) else { return }
            refs = item.zotero
            if stored.citation == nil { fetch(stored) }
        }
    }

    private func fetch(_ ref: ZoteroRef) {
        guard fetching.insert(ref.selectLink).inserted else { return }
        failed[ref.selectLink] = nil
        Task { @MainActor in
            defer { fetching.remove(ref.selectLink) }
            do {
                let citation = try await status.fetchCitation(for: ref)
                if !(await model.cacheZoteroCitation(citation, for: ref, in: itemID)) {
                    failed[ref.selectLink] = "The citation came from Zotero but could not be saved to the note."
                }
            } catch is CancellationError {
                return
            } catch {
                failed[ref.selectLink] = error.localizedDescription
            }
        }
    }
}
