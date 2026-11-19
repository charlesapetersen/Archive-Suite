import Foundation
import ArchiveCore

/// W47.ct-processor-capture — Route A in Process Files: each box or folder label the run classified is read into
/// container fields (as at capture, `ContainerLabelCapture`) and written into the folder its output PDF ended in, as
/// proposals (source `label`) for the operator to confirm in Archive Reader. Process Files has no card to confirm
/// them on during the run.
extension OCRProcessor {
    /// Call once the run's outputs are in their final place. `moves` is what collection organisation moved
    /// (`CollectionSegmenter.organizeOutput`), empty when it did not run. Writes only for an output this run wrote
    /// inside `outputDirectory` (never a source: the pre-OCRed route's outputs are its inputs, so it reads no labels).
    /// Returns one line for the run's summary when something was not recorded or wants a look, else nil. Stops,
    /// writing nothing, when the run is cancelled.
    func recordContainerLabels(moves: [URL: URL], outputDirectory: URL, preOCRedInput: Bool) async -> String? {
        guard ContainerLabelCapture.enabled, !preOCRedInput, !Task.isCancelled else { return nil }
        let root = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        struct Label { let type: ItemType; let source: URL; let output: URL; let text: String; let rotation: Int }
        var labels: [Label] = []
        var seenOutputs = Set<URL>()
        var skipped = 0
        for job in jobs where job.status == .succeeded {
            let type: ItemType
            switch job.classification {
            case .boxLabel?: type = .box
            case .folderLabel?: type = .folder
            default: continue
            }
            guard let written = outputURLMap[job.sourceURL] else { skipped += 1; continue }
            let output = (moves[written] ?? written).standardizedFileURL
            let resolved = output.resolvingSymlinksInPath().standardizedFileURL
            guard output != job.sourceURL.standardizedFileURL,
                  resolved.pathComponents.count > root.count,
                  Array(resolved.pathComponents.prefix(root.count)) == root,
                  FileManager.default.fileExists(atPath: output.path),
                  seenOutputs.insert(output).inserted else { skipped += 1; continue }
            labels.append(Label(type: type, source: job.sourceURL, output: output, text: job.result?.text ?? "",
                                rotation: job.result?.rotationDegrees ?? 0))
        }
        let skippedNote = skipped == 0 ? nil
            : "\(skipped) box or folder label\(skipped == 1 ? " was" : "s were") not recorded: \(skipped == 1 ? "its PDF was" : "their PDFs were") not where the run left \(skipped == 1 ? "it" : "them"), or shared one with another label."
        guard !labels.isEmpty else { return skippedNote }
        let gateway = currentGateway
        statusMessage = "Reading \(labels.count) box and folder label\(labels.count == 1 ? "" : "s")…"
        var markers: [ContainerLabelCapture.FiledMarker] = []
        for label in labels {
            guard !Task.isCancelled else { return nil }
            let fields = await ContainerLabelCapture.read(type: label.type, text: label.text, photo: label.source,
                                                          rotation: label.rotation, gateway: gateway)
            markers.append(ContainerLabelCapture.FiledMarker(folder: label.output.deletingLastPathComponent(),
                                                             fileName: label.output.lastPathComponent, type: label.type,
                                                             fields: fields, text: label.text, startedByUser: false))
        }
        guard !Task.isCancelled else { return nil }
        let problem = await Task.detached(operation: { ContainerLabelCapture.record(markers) }).value
        let lines = [problem, skippedNote].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
