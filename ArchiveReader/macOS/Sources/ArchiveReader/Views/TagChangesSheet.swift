import SwiftUI
import ArchiveCore

/// Tags ▸ Tag Changes from Other Apps… (W40.tag-rename-suite): renames and merges Notes recorded in the archive, each
/// applied to the Reader's files through the ordinary rename (TagWriter, one Undo) or skipped; and undone ones the
/// Reader had applied, shown once. The sheet only chooses; `NavigationModel+TagChanges` writes.
struct TagChangesSheet: View {
    @ObservedObject var model: NavigationModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tag Changes from Other Apps").font(.headline)
            if model.tagChangeOffers.isEmpty {
                Text("Nothing waiting. A tag renamed or merged in Notes shows here, to apply to your files.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ar.tagChanges.none")
            } else {
                Text("Apply renames a tag on your files as Rename Tag… would; Skip leaves them as they are. "
                     + "Either way it is not asked again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.tagChangeOffers) { row($0) }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("ar.tagChanges.done")
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await model.refreshTagChangeInbox() }
    }

    private func row(_ offer: ReaderTagChangeOffer) -> some View {
        HStack(alignment: .top) {
            Text(offer.summary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ar.tagChanges.summary")
            Spacer()
            if offer.isWithdrawal {
                Button("OK") { model.dismissTagChange(offer) }
            } else {
                Button("Skip") { model.dismissTagChange(offer) }
                    .disabled(model.tagBatch != nil || model.catalogueEditSaving)
                    .accessibilityIdentifier("ar.tagChanges.skip")
                // One at a time: each is its own batch and its own Undo.
                Button("Apply") { model.applyTagChange(offer) }
                    .disabled(model.tagBatch != nil || model.catalogueEditSaving)
                    .accessibilityIdentifier("ar.tagChanges.apply")
            }
        }
    }
}
