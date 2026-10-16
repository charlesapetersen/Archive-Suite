import AppKit
import SwiftUI

/// The Files tab's FarmShare import (W41.app-farmshare-import): pick a bulk run's output folder, and the run takes
/// each matching page's text from it instead of buying it from the run's model. Not persisted: it is chosen per run.
struct FarmShareImportControl: View {
    @Binding var imported: FarmShareImport?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let imported {
                    Text("FarmShare text: \(imported.count) page\(imported.count == 1 ? "" : "s") from \(imported.folder.lastPathComponent)\(Self.models(imported))")
                        .font(.caption)
                        .accessibilityIdentifier("ap.ocr.farmShareSummary")
                    Button("Clear") { self.imported = nil; problem = nil }
                        .controlSize(.small)
                        .accessibilityIdentifier("ap.ocr.farmShareClear")
                } else {
                    Button(loading ? "Reading FarmShare folder…" : "Use FarmShare text…") { choose() }
                        .controlSize(.small)
                        .disabled(loading)
                        .accessibilityIdentifier("ap.ocr.farmShareChoose")
                }
            }
            if let imported {
                Text("Pages whose image matches one FarmShare read (by its bytes) take that text and cost only a short classification call; the rest are read by the run's model. The totals above still count every page.\(imported.unmatchable > 0 ? " \(imported.unmatchable) FarmShare page\(imported.unmatchable == 1 ? "" : "s") carry no image hash and match nothing." : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ap.ocr.farmShareProblem")
            }
        }
    }

    /// ` (Qwen3.6-27B-FP8)`, or the number of models when a folder mixes runs.
    private static func models(_ imported: FarmShareImport) -> String {
        let names = Set(imported.pages.values.map { $0.reading.model.split(separator: "/").last.map(String.init) ?? $0.reading.model })
        switch names.count {
        case 0: return ""
        case 1: return " (\(names.first!))"
        default: return " (\(names.count) models)"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use FarmShare Folder"
        panel.message = "Choose a FarmShare bulk run's --out folder (the one holding _meta)."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        loading = true
        problem = nil
        Task {
            let result = await Task.detached { Result { try FarmShareImport.load(folder: folder) } }.value
            loading = false
            switch result {
            case .success(let loaded) where loaded.count == 0:
                problem = "\(folder.lastPathComponent) has no page with an image hash to match: it was read before the kit recorded hashes, or every page failed."
            case .success(let loaded):
                imported = loaded
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }
}
