import ArchiveCore
import SwiftUI

/// The words of the Finder mirror's questions (W49.storage-finder-reader-mirror).
enum FinderMirrorWords {
    static func promptTitle(_ prompt: NavigationModel.FinderMirrorPrompt?) -> String {
        switch prompt {
        case .turnOn?: "Mirror this archive's fields to Finder tags?"
        case .turnOff?: "Stop mirroring this archive's fields to Finder tags?"
        case nil: ""
        }
    }

    static func promptMessage(_ prompt: NavigationModel.FinderMirrorPrompt?) -> String {
        switch prompt {
        case .turnOn(let pdfs)?:
            "Each PDF's dates, subjects, quality, read state, item type, checks and colour stay in its catalogue record "
                + "and are also shown as Finder tags, for searching in Finder. The \(pdfs) PDFs here are updated in the "
                + "background; you can stop and resume. Tags you made yourself are kept, and a tag changed in Finder is "
                + "shown in the Inspector to import or put back, never taken on its own. Archive Processor follows this "
                + "choice for output filed into this archive."
        case .turnOff?:
            "Finder tags stop following the records. The tags already on the PDFs stay and may go out of date, unless "
                + "you also remove the suite's tags: that removes only the tags Archive Suite recorded writing, never "
                + "your own, and File ▸ Put Back Suite Tags undoes it."
        case nil: ""
        }
    }

    static func describe(_ divergence: FinderMirror.Divergence) -> String {
        var parts: [String] = []
        if !divergence.removed.isEmpty { parts.append("removed " + divergence.removed.joined(separator: ", ")) }
        if !divergence.added.isEmpty { parts.append("added " + divergence.added.joined(separator: ", ")) }
        if !divergence.addedOther.isEmpty {
            parts.append("added " + divergence.addedOther.joined(separator: ", ")
                         + " (Import adds \(divergence.addedOther.count == 1 ? "it" : "them") as subjects; Re-publish keeps "
                         + "\(divergence.addedOther.count == 1 ? "it" : "them") as your own tags)")
        }
        if divergence.labelChanged {
            let name = FinderLabel(labelNumber: divergence.labelAfter)?.tokenName ?? "none"
            parts.append("colour changed to \(name)")
        }
        return "Finder tags were changed outside Archive Suite: " + parts.joined(separator: "; ") + "."
    }
}

/// In the Inspector, for one PDF of an archive that mirrors: a mirrored tag changed in Finder, with Import (the
/// Finder values become the record's) and Re-publish (the record's values go back). Owner's answer 2b.
struct FinderMirrorDivergenceSection: View {
    @ObservedObject var model: NavigationModel
    let relativePath: String

    var body: some View {
        Group {
            if let divergence = model.finderMirrorDivergences[relativePath] {
                VStack(alignment: .leading, spacing: 6) {
                    Label(FinderMirrorWords.describe(divergence), systemImage: "tag")
                        .font(.callout)
                        .accessibilityIdentifier("ar.finderMirror.divergence")
                    HStack {
                        Button("Import") { model.importFinderMirror(relativePath: relativePath) }
                            .help("Take the Finder tags' values into the catalogue record as your edit.")
                            .accessibilityIdentifier("ar.finderMirror.import")
                        Button("Re-publish") { model.republishFinderMirror(relativePath: relativePath) }
                            .help("Put the catalogue record's values back on the Finder tags.")
                            .accessibilityIdentifier("ar.finderMirror.republish")
                    }
                    .disabled(model.catalogueEditSaving || model.finderMirrorTask != nil)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
        .onAppear { model.checkFinderMirror(relativePath: relativePath) }
        .onChange(of: relativePath) { _, path in model.checkFinderMirror(relativePath: path) }
    }
}
