import ArchiveCore
import SwiftUI

struct CatalogueRepairSection: View {
    @ObservedObject var navigation: NavigationModel
    @Environment(\.undoManager) private var undo
    let reader: CatalogueReader
    let root: URL
    let relativePath: String
    let revision: ItemFacts.SelectionRevision

    @State private var candidate: CatalogueReader.ReassociationCandidate?
    @State private var confirming = false

    private struct Probe: Equatable {
        let occurrence: CatalogueAssociation.Occurrence
        let revision: ItemFacts.SelectionRevision
        let filesRevision: UInt64
    }

    var body: some View {
        // Keep the probe attached while there is no repair button to render yet.
        VStack(alignment: .leading, spacing: 0) {
            if candidate != nil {
                Button("Repair Catalogue Companion…") { confirming = true }
                    .accessibilityIdentifier("ar.catalogueRepair.offer")
            }
        }
        .task(id: Probe(occurrence: .init(rootInstanceID: reader.rootInstanceID, relativePath: relativePath),
                        revision: revision, filesRevision: navigation.library.filesRevision)) {
            confirming = false
            candidate = nil
            let verified = await ReaderCataloguePairMemory.shared.candidate(reader: reader, root: root,
                                                                             relativePath: relativePath)
            guard !Task.isCancelled else { return }
            candidate = verified
        }
        .alert("Repair catalogue companion?", isPresented: $confirming, presenting: candidate) { verified in
            Button("Repair") {
                candidate = nil
                navigation.repairCatalogueCompanion(verified, reader: reader, root: root, undo: undo)
            }
            Button("Cancel", role: .cancel) {}
        } message: { verified in
            let old = (verified.formerRelativePath as NSString).lastPathComponent
            let new = (verified.destination.relativePath as NSString).lastPathComponent
            Text("Reader verified this PDF together with the catalogue companion for “\(old)”. "
                 + "Repair renames the companion to match “\(new)” and leaves the PDF in place.")
        }
    }
}

private enum CatalogueRepairStep: Sendable {
    case undo(CatalogueWriter.ReassociationReceipt)
    case redo(CatalogueReader.ReassociationCandidate)
}

/// How the list catches up after a repair step. FSEvents drops the Reader's own rename, so a verified repair is
/// revised for the two companion names it moved between; a failed one may have left either state, so it takes
/// a full pass (W49.reader-catalogue-edit-revise).
private enum CatalogueRepairRefresh {
    case none, full
    case revise(CatalogueWriter.ReassociationReceipt)

    static func companions(former: String, renamed: String) -> [String] {
        [former, renamed].map { CatalogueRecord.companionFilename(forPDFFilename: $0) }
    }
}

extension NavigationModel {
    fileprivate func repairCatalogueCompanion(_ candidate: CatalogueReader.ReassociationCandidate,
                                               reader: CatalogueReader, root: URL, undo: UndoManager?) {
        guard hasCatalogueRepairScope(reader, root: root) else { return }
        let task = Task.detached(priority: .userInitiated) {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            return Result { try CatalogueWriter(reader: reader).reassociateCompanion(candidate) }
        }
        Task {
            let result = await task.value
            guard hasCatalogueRepairScope(reader, root: root) else { return }
            switch result {
            case .success(let receipt):
                if let undo { registerCatalogueRepairUndo(.undo(receipt), reader: reader, root: root, on: undo) }
                finishCatalogueRepair("Catalogue companion repaired.", refresh: .revise(receipt))
            case .failure(let error):
                finishCatalogueRepair(catalogueRepairError(error, operation: "repair the catalogue companion"))
            }
        }
    }

    private func registerCatalogueRepairUndo(_ step: CatalogueRepairStep, reader: CatalogueReader,
                                             root: URL, on manager: UndoManager) {
        registerContainerUndoAction("Catalogue Companion Repair", on: manager) { model, undo in
            model.takeContainerUndoStep(on: undo)
            guard model.hasCatalogueRepairScope(reader, root: root) else {
                model.finishCatalogueRepair("This repair belongs to another archive. Open that archive to manage its files.")
                return
            }
            let writer = CatalogueWriter(reader: reader)
            do {
                switch step {
                case .undo(let receipt):
                    let restored = try writer.undoReassociation(receipt)
                    model.registerCatalogueRepairUndo(.redo(restored), reader: reader, root: root, on: undo)
                    model.finishCatalogueRepair("Catalogue companion repair undone.", refresh: .none)
                    Task {
                        await ReaderCataloguePairMemory.shared.remember([restored.formerPair], instance: reader.rootInstanceID)
                        if model.hasCatalogueRepairScope(reader, root: root) {
                            model.library.reviseCatalogue(relativePaths: CatalogueRepairRefresh.companions(
                                former: restored.formerRelativePath, renamed: restored.destination.relativePath))
                        }
                    }
                case .redo(let candidate):
                    let receipt = try writer.reassociateCompanion(candidate)
                    model.registerCatalogueRepairUndo(.undo(receipt), reader: reader, root: root, on: undo)
                    model.finishCatalogueRepair("Catalogue companion repair redone.", refresh: .revise(receipt))
                }
            } catch {
                model.finishCatalogueRepair(model.catalogueRepairError(error, operation: undo.isRedoing ? "redo the repair" : "undo the repair"))
            }
        }
    }

    private func hasCatalogueRepairScope(_ reader: CatalogueReader, root: URL) -> Bool {
        rootStore.root == root && catalogueReader?.rootInstanceID == reader.rootInstanceID
    }

    private func finishCatalogueRepair(_ message: String, refresh: CatalogueRepairRefresh = .full) {
        catalogueEditFeedback = message
        statusMessage = message
        announce(message)
        switch refresh {
        case .none: break
        case .full: library.rescan()
        case .revise(let receipt):
            library.reviseCatalogue(relativePaths: CatalogueRepairRefresh.companions(
                former: receipt.formerPDF.relativePath, renamed: receipt.current.pair.occurrence.relativePath))
        }
    }

    private func catalogueRepairError(_ error: Error, operation: String) -> String {
        switch error as? CatalogueWriter.Failure {
        case .some(.recoveryRequired):
            return "Check both companion names in Finder. Reader could not verify the result of the catalogue repair."
        case .some(.busy):
            return "Reader could not \(operation). Another app is saving to this folder."
        default:
            return "Reader could not \(operation). Check the PDF and companion names in Finder."
        }
    }
}
