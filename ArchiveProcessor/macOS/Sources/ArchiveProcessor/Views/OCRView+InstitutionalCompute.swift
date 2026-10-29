import AppKit
import SwiftUI

/// The Files tab's institutional-computing import (W41.app-institutional-compute): pick a bulk run's output folder, and the run takes
/// each matching page's text from it instead of buying it from the run's model. Not persisted: it is chosen per run.
struct InstitutionalComputeImportControl: View {
    @Binding var imported: InstitutionalComputeImport?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let imported {
                    Text("Cluster text: \(imported.count) page\(imported.count == 1 ? "" : "s") from \(imported.folder.lastPathComponent)\(Self.models(imported))")
                        .font(.caption)
                        .accessibilityIdentifier("ap.ocr.institutionalComputeSummary")
                    Button("Clear") { self.imported = nil; problem = nil }
                        .controlSize(.small)
                        .accessibilityIdentifier("ap.ocr.institutionalComputeClear")
                } else {
                    Button(loading ? "Reading cluster folder…" : "Use institutional computing text…") { choose() }
                        .controlSize(.small)
                        .disabled(loading)
                        .accessibilityIdentifier("ap.ocr.institutionalComputeChoose")
                }
            }
            if let imported {
                Text("Pages whose image matches a page the cluster read (by its bytes) take that text and cost only a short classification call; the rest are read by the run's model. The totals above still count every page.\(imported.unmatchable > 0 ? " \(imported.unmatchable) cluster page\(imported.unmatchable == 1 ? "" : "s") have incomplete provenance or missing text and match nothing." : "")")
                    .font(.caption2)
                    .foregroundStyle(.primary)
            } else if let problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("ap.ocr.institutionalComputeProblem")
            }
        }
    }

    /// ` (Qwen3.6-27B-FP8)`, or the number of models when a folder mixes runs.
    private static func models(_ imported: InstitutionalComputeImport) -> String {
        let names = Set(imported.pages.values.map { "\($0.reading.headerSource) · \($0.reading.headerModel)" })
        switch names.count {
        case 0: return ""
        case 1: return " (\(names.first!))"
        default: return " (\(names.count) readers)"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the output folder of an institutional-computing run: the folder that holds its _meta folder."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        loading = true
        problem = nil
        Task {
            let result = await Task.detached { Result { try InstitutionalComputeImport.load(folder: folder) } }.value
            loading = false
            switch result {
            case .success(let loaded) where loaded.count == 0:
                problem = "\(folder.lastPathComponent) has no page with an image hash, cluster name and text to match. Use output from the institutional-computing kit."
            case .success(let loaded):
                imported = loaded
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }
}
