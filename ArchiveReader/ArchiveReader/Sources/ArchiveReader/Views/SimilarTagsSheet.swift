import SwiftUI

/// Read-only near-duplicate subject-tag finder. Lists clusters of tags that look like typo / case /
/// spacing variants of one another (from `TagSimilarity.clusters`), and lets the historian pick a
/// canonical form and **Merge** the other variants into it. Merging drives the EXISTING corpus-wide
/// rename flow (`RenameTagSheet` → `NavigationModel.renameTag`, audited by `TagWriter`) — this view
/// itself never writes a tag. The finder is purely advisory; nothing changes until the user confirms
/// a rename in the sheet it opens.
struct SimilarTagsSheet: View {
    @ObservedObject var model: NavigationModel
    @Environment(\.dismiss) private var dismiss

    @State private var clusters: [[TagSimilarity.TagVariant]] = []
    @State private var canonicalChoice: [String: String] = [:]   // stable cluster key → chosen canonical
    @State private var mergeTarget: MergeTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Similar tags").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Groups of subject tags that look like near-duplicates — typos, or case/spacing variants. Pick the correct spelling to keep, then **Merge** the others into it (renames every file that carries them). Nothing changes until you confirm the rename.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if clusters.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(clusters.enumerated()), id: \.offset) { _, cluster in
                            clusterCard(cluster)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .frame(width: 520, height: 580)
        .onAppear { refresh() }
        .onChange(of: model.undoDepth) { refresh() }   // a merge (or undo) changed the corpus → recompute
        .sheet(item: $mergeTarget) { t in
            RenameTagSheet(model: model, oldTag: t.variant, initialNewName: t.canonical)
        }
    }

    // MARK: Cluster card

    @ViewBuilder
    private func clusterCard(_ cluster: [TagSimilarity.TagVariant]) -> some View {
        let key = clusterKey(cluster)
        let chosen = canonicalChoice[key] ?? cluster.first?.tag ?? ""
        let files = cluster.reduce(0) { $0 + $1.count }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(cluster.count) similar tags").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(files) file\(files == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Keep", selection: Binding(get: { chosen }, set: { canonicalChoice[key] = $0 })) {
                ForEach(cluster, id: \.tag) { v in
                    Text("\(v.tag)  ·  \(v.count) file\(v.count == 1 ? "" : "s")").tag(v.tag)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            HStack {
                Text("Merges \(cluster.count - 1) other variant\(cluster.count - 1 == 1 ? "" : "s") into “\(chosen)”.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { startMerge(cluster, canonical: chosen) } label: {
                    Label("Merge…", systemImage: "arrow.triangle.merge")
                }
                .disabled(cluster.count < 2)
                .help("Rename the other variant(s) to “\(chosen)” across the whole corpus — you confirm the file count first.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("No near-duplicate tags found").font(.headline)
            Text("Every subject tag looks distinct.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    /// Open the existing rename sheet seeded to merge the highest-count NON-canonical variant into
    /// the chosen canonical. On confirm, `NavigationModel.renameTag` runs (via `TagWriter`); the
    /// corpus change bumps `undoDepth`, `refresh()` recomputes, and any remaining variants stay
    /// grouped for another Merge until the cluster is gone.
    private func startMerge(_ cluster: [TagSimilarity.TagVariant], canonical: String) {
        guard let variant = cluster.first(where: { $0.tag != canonical })?.tag else { return }
        mergeTarget = MergeTarget(variant: variant, canonical: canonical)
    }

    private func refresh() {
        clusters = TagSimilarity.clusters(subjectCounts: model.subjectFileCounts)
    }

    /// Stable identity for a cluster (independent of order / index), so a canonical choice survives a
    /// re-sort but naturally resets once the cluster's membership changes after a merge.
    private func clusterKey(_ cluster: [TagSimilarity.TagVariant]) -> String {
        cluster.map(\.tag).sorted().joined(separator: "\u{1}")
    }
}

/// A pending merge: rename `variant` → `canonical` via the existing rename sheet.
private struct MergeTarget: Identifiable, Equatable {
    let variant: String
    let canonical: String
    var id: String { variant + "\u{1}" + canonical }
}
