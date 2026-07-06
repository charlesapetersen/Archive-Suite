import SwiftUI

/// End-of-session confirmation: name each collection captured this session, or append it to an
/// existing output folder (fuzzy-suggested). Confirm → the coordinator moves the staged outputs into
/// place, continuing an existing folder's numbering when appending.
struct CollectionFinalizeSheet: View {
    @ObservedObject var liveProc: LiveCaptureProcessor
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [LiveCaptureProcessor.CollectionDraft]

    init(liveProc: LiveCaptureProcessor) {
        _liveProc = ObservedObject(wrappedValue: liveProc)
        _drafts = State(initialValue: liveProc.drafts)
    }

    private var canConfirm: Bool {
        drafts.allSatisfy { $0.chosenExisting != nil || !$0.finalName.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Finish session — name collections").font(.title2).fontWeight(.semibold)
                .padding([.top, .horizontal], 20)
            Text("Confirm a name for each collection, or add it to an existing folder (new photos continue that folder's numbering).")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 10)
            if !liveProc.failedGroupIds.isEmpty {
                Label("\(liveProc.failedGroupIds.count) segment(s) produced no OCR text — they'll be filed as image-only PDFs. You can retry from the Live Capture panel before finalizing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach($drafts) { $draft in
                        card($draft)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if liveProc.isFinalizing { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button("Finalize & move files") { liveProc.finalize(drafts) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm || liveProc.isFinalizing)
            }
            .padding(20)
        }
        .frame(width: 620, height: 560)
    }

    @ViewBuilder private func card(_ draft: Binding<LiveCaptureProcessor.CollectionDraft>) -> some View {
        let d = draft.wrappedValue
        // Suggested folders first, then the remaining existing folders.
        let ordered = d.suggestedFolders + d.existingFolders.filter { e in
            !d.suggestedFolders.contains(where: { $0.path == e.path })
        }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(d.segmentCount) segment\(d.segmentCount == 1 ? "" : "s") · \(d.photoCount) photo\(d.photoCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Add to", selection: Binding(
                    get: { draft.wrappedValue.chosenExisting?.path ?? "__new__" },
                    set: { path in
                        draft.wrappedValue.chosenExisting = (path == "__new__")
                            ? nil : draft.wrappedValue.existingFolders.first { $0.path == path }
                    })) {
                    Text("New collection").tag("__new__")
                    ForEach(ordered, id: \.path) { f in
                        Text(d.suggestedFolders.contains(where: { $0.path == f.path })
                             ? "★ \(f.lastPathComponent)" : f.lastPathComponent)
                            .tag(f.path)
                    }
                }
                .frame(maxWidth: 420)

                if d.chosenExisting == nil {
                    TextField("Collection name", text: draft.finalName)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                } else {
                    Text("Appending to “\(d.chosenExisting!.lastPathComponent)” — new files continue its numbering.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}
