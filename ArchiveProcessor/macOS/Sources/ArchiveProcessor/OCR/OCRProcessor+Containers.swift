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
    /// Returns a note for the run's summary about unavailable label reading or markers that need review. Stops,
    /// writing nothing, when the run is cancelled.
    /// What the label reads spent goes into the run's history snapshot and `containerLabelSpendNote` (W47.ct-label-cost).
    func recordContainerLabels(moves: [URL: URL], outputDirectory: URL, preOCRedInput: Bool) async -> String? {
        containerLabelSpendNote = nil
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
        let estimate = gateway?.isLocalModel == false
            ? Double(labels.count) * ContainerLabelCapture.gatewayDollarsPerLabel : 0
        guard reserveMonthlySpend(estimate, for: "reading the box and folder labels", whileReading: true) else {
            // The main outputs may already have been organised. Preserve the finished run and tell the
            // operator the optional label proposals are missing, so a resume never recreates moved PDFs.
            monthlyStopMessage = nil
            return "The monthly spending limit left box and folder labels unread."
        }
        // W47.ct-capture-gemma: with Gemma on this Mac the read takes about 13 s a label, so the line says how long.
        var pace = ""
        if gateway == nil || gateway?.isLocalModel == true, await ContainerLabelGemma.prepare(gateway: gateway) {
            let minutes = Int((Double(labels.count) * ContainerLabelGemma.secondsPerLabel / 60).rounded(.up))
            pace = " with Gemma 3 12B on this Mac, about \(minutes) min"
        }
        statusMessage = "Reading \(labels.count) box and folder label\(labels.count == 1 ? "" : "s")\(pace)…"
        var markers: [ContainerLabelCapture.FiledMarker] = []
        var calls = 0
        var successfulReads = 0
        var fallbacks = 0
        var dollars = 0.0
        var modelUnavailable = false
        // The month's ledger gets the calls as a line of their own, Stop or not: a run's own line takes a top-up only
        // above a cent's fraction, which one label's charge may be under.
        defer {
            if !Task.isCancelled { monthlySpend?.reserved -= estimate }
            containerLabelSpendNote = ContainerLabelCapture.spendNote(
                calls: calls, successfulReads: successfulReads, dollars: dollars)
            SettingsLayerStore.shared.recordSpend(usd: dollars, runID: UUID(), outputDirectory: outputDirectory,
                                                  files: calls)
        }
        for label in labels {
            guard !Task.isCancelled else { return nil }
            let r = await ContainerLabelCapture.readLabel(type: label.type, text: label.text, photo: label.source,
                                                          rotation: label.rotation, gateway: gateway)
            guard !Task.isCancelled else {
                if r.gatewayCalled { dollars += r.dollars; calls += 1 }
                return nil
            }
            // W47.ct-label-cost: the call is real money: the history's cost counts it, and the ledger (above).
            if r.gatewayCalled {
                modelUnavailable = modelUnavailable || r.modelUnavailable
                calls += 1
                // A parsed reply can still leave all proposals to the local reader.
                if r.fields.values.values.contains(where: { $0.reader == ContainerLabelCapture.gatewayReader }) {
                    successfulReads += 1
                }
                dollars += r.dollars
                activeRunHistory?.labelCalls += 1
                activeRunHistory?.labelDollars += r.dollars
            }
            if r.fallback != nil { fallbacks += 1 }
            markers.append(ContainerLabelCapture.FiledMarker(folder: label.output.deletingLastPathComponent(),
                                                             fileName: label.output.lastPathComponent, type: label.type,
                                                             fields: r.fields, text: label.text, startedByUser: false))
        }
        guard !Task.isCancelled else { return nil }
        let problem = await Task.detached(operation: { ContainerLabelCapture.record(markers) }).value
        let unavailableNote = modelUnavailable
            ? "The configured gateway reported that GPT 5.6 Luna was unavailable for box and folder label reading."
            : nil
        let fallbackNote = fallbacks == 0 ? nil
            : "No model supplied suggestions for \(fallbacks) box or folder label\(fallbacks == 1 ? "" : "s"). Check the proposals in Archive Reader."
        let lines = [unavailableNote, fallbackNote, problem, skippedNote].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
