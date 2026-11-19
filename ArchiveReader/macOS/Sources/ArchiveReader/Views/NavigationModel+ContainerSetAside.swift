import Foundation
import ArchiveCore

// MARK: - Setting aside a container file the Reader cannot overwrite (W49.reader-ct-set-aside, Tier-2)
//
// `SPEC/containers.md` §Setting aside: a `containers.json` that is unreadable or holds values this build drops, and an
// unreadable `container-names.json`, is replaced only on the user's explicit say-so. The edit is refused first with
// `ContainerSetAsideNeeded`; the Inspector offers to set the file aside, naming it, what reads and what would be
// dropped, and the rename. Accepting runs the same edit again with that file's consent (`ContainerSetAsideConsent`),
// and the store renames the old document to `<name>.set-aside-<UTC stamp>-<id>` (never deleted) before writing the new
// one. Undo swaps the two back (`ContainerFileStore.putBackSetAside`), so it too deletes nothing. A newer document is
// never offered: it stays `refusedExisting`.

/// An edit refused because `fileName` in `directory`'s `.archivesuite` would have to be set aside first.
struct ContainerSetAsideNeeded: Error, Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// Not a document this build reads, with the store's reason.
        case unreadable(String)
        /// Reads, but holds values this build drops: how many runs and values it reads.
        case drops(runs: Int, values: Int)
    }
    let directory: URL
    let fileName: String
    let reason: Reason

    /// The document's path, the key the user's consent is given under.
    var documentPath: String { Self.documentPath(directory, fileName) }

    static func documentPath(_ directory: URL, _ fileName: String) -> String {
        directory.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(fileName).standardizedFileURL.path
    }

    /// What the Inspector says when the edit is refused.
    var refusal: String {
        "\(what) \(state), so it is left as it is and nothing was changed. It can be set aside to save the change."
    }

    /// The offer's text: the file, what reads, what would be dropped, and the rename.
    var offerMessage: String {
        let carried: String
        switch reason {
        case .unreadable: carried = "None of it carries over to the new file."
        case let .drops(runs, values):
            carried = "What this version reads (\(runs) run\(runs == 1 ? "" : "s") and \(values) value"
                + "\(values == 1 ? "" : "s")) carries over to the new file; the values it does not read do not."
        }
        return "\(what.prefix(1).uppercased() + what.dropFirst()) (“\(path)”) \(state). \(carried) To save the change "
            + "it is renamed to “\(fileName).set-aside-<date and time>-<id>” in the same “\(ContainerFile.folderName)” "
            + "folder, never deleted, and a new file is written in its place. Undo puts it back."
    }

    private var what: String {
        fileName == ContainerNames.fileName ? "the standard names file for this part of the archive"
                                            : "this folder's container file"
    }

    private var state: String {
        switch reason {
        case .unreadable(let why): return "cannot be read by this version (\(why))"
        case .drops: return "holds values this version does not read (a newer version's fields or levels)"
        }
    }

    private var path: String {
        "\(directory.lastPathComponent)/\(ContainerFile.folderName)/\(fileName)"
    }
}

/// The documents the user has said may be set aside, for the edit being run (bound around its work).
enum ContainerSetAsideConsent {
    @TaskLocal static var paths: Set<String> = []

    static func given(_ directory: URL, _ fileName: String) -> Bool {
        paths.contains(ContainerSetAsideNeeded.documentPath(directory, fileName))
    }
}

/// The Inspector's offer to set a file aside and save the refused edit again.
struct ContainerSetAsideOffer: Identifiable {
    let id = UUID()
    let needed: ContainerSetAsideNeeded
    let treePath: String?
    /// The window the edit was made in, whose Inspector asks; nil asks in any.
    let window: ObjectIdentifier?
    /// Runs the refused edit again with this file's consent added to `consent`.
    let retry: @MainActor (_ consent: Set<String>) -> Void
    let consent: Set<String>

    var title: String {
        needed.fileName == ContainerNames.fileName ? "Set Aside the Standard Names File?"
                                                   : "Set Aside This Folder's Container File?"
    }
}

extension NavigationModel {
    /// The user said yes: the edit runs again and the file is set aside.
    func acceptContainerSetAside(_ offer: ContainerSetAsideOffer) {
        containerSetAsideOffer = nil
        guard offer.treePath == containerTree?.path else {
            containerEditError = "That change was made in another archive, so it was not saved."
            return
        }
        // The refused edit's catalog read may still be running; the editor is off until it lands (`finishEdit`).
        Task { [weak self] in
            for _ in 0..<100 where self?.containerEditSaving == true { try? await Task.sleep(for: .milliseconds(50)) }
            guard let self, offer.treePath == self.containerTree?.path else { return }
            offer.retry(offer.consent.union([offer.needed.documentPath]))
        }
    }
}
