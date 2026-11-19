import Foundation
import ArchiveCore

/// W47.ct-processor-capture — Route A in Process Files: each box or folder label the run classified is read into
/// container fields (as at capture, `ContainerLabelCapture`) and written into the folder its output PDF ended in, as
/// proposals (source `label`) for the operator to confirm in Archive Reader. Process Files has no card to confirm
/// them on during the run.
extension OCRProcessor {
    /// Call once the run's outputs are in their final place. `moves` is what collection organisation moved
    /// (`CollectionSegmenter.organizeOutput`), empty when it did not run. Returns one line for the run's summary when
    /// a container file was not written, else nil.
    func recordContainerLabels(moves: [URL: URL]) async -> String? {
        guard ContainerLabelCapture.enabled else { return nil }
        let gateway = currentGateway
        var markers: [ContainerLabelCapture.FiledMarker] = []
        var seenOutputs = Set<URL>()
        for job in jobs where job.status == .succeeded {
            let type: ItemType
            switch job.classification {
            case .boxLabel?: type = .box
            case .folderLabel?: type = .folder
            default: continue
            }
            guard let written = outputURLMap[job.sourceURL] else { continue }
            let output = moves[written] ?? written
            guard seenOutputs.insert(output).inserted,
                  FileManager.default.fileExists(atPath: output.path) else { continue }
            let text = job.result?.text ?? ""
            let fields = await ContainerLabelCapture.read(type: type, text: text, photo: job.sourceURL,
                                                          rotation: job.result?.rotationDegrees ?? 0, gateway: gateway)
            markers.append(ContainerLabelCapture.FiledMarker(folder: output.deletingLastPathComponent(),
                                                             fileName: output.lastPathComponent, type: type,
                                                             fields: fields, text: text, startedByUser: false))
        }
        guard !markers.isEmpty else { return nil }
        return await Task.detached(operation: { ContainerLabelCapture.record(markers) }).value
    }
}
