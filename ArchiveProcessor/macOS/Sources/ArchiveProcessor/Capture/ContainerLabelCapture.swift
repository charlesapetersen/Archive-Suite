import Foundation
import ArchiveCore

/// W47.ct-processor-capture — Route A at capture: a box or folder label photo read into container fields, shown on
/// the marker card for correction, and written into the collection folder's `.archivesuite/containers.json` at
/// finalize (`SPEC/containers.md`; the readers per field are the owner's of 2026-11-13, `segbench-results/ct-read.md`).
enum ContainerLabelCapture {
    /// The gateway model for a label's titles, accession and missed box numbers (`W47.ct-read-paid`).
    static let gatewayModel = "gpt-5.6-luna"
    static let gatewayReader = "gpt-5.6-luna"
    /// Luna spends reasoning tokens first (`W46.gateway-models-ok`), so the cap leaves room for them.
    static let maxTokens = 1200
    static let timeout: TimeInterval = 60
    static let imageLongSide = 1600

    /// Whether labels are read at all (Settings → Live Capture). On unless the operator turned it off.
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.readContainerLabels) as? Bool ?? true
    }

    /// One label photo's proposals: Vision + parser from its OCR text, and the gateway's reading of the image when
    /// the session reads text through the gateway. A failed gateway call leaves the parser's values.
    static func read(type: ItemType, text: String, photo: URL, rotation: Int,
                     gateway: GatewayConfig?) async -> ContainerFieldSet {
        let lines = text.components(separatedBy: .newlines)
        var model: [ContainerField: String]?
        if let gateway, let jpeg = ImageEncoding.uprightJPEG(url: photo, rotationDegrees: rotation, longEdge: imageLongSide) {
            let content: [[String: Any]] = [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ["type": "text", "text": ContainerLabelReader.modelPrompt],
            ]
            if let raw = await DateRoute.gatewayChat(content: content, gateway: gateway, model: gatewayModel,
                                                     maxTokens: maxTokens, timeout: timeout) {
                model = ContainerLabelReader.modelFields(fromReply: raw)
            }
        }
        return ContainerLabelReader.proposals(lines: lines, type: type, model: model,
                                              modelReader: model == nil ? nil : gatewayReader, at: Date())
    }

    /// One filed marker, for the finalize write.
    struct FiledMarker: Sendable {
        let folder: URL
        let fileName: String
        let type: ItemType
        let fields: ContainerFieldSet
        let text: String
    }

    /// Applies each collection folder's markers to its container file (new files only, inside `.archivesuite`).
    /// Returns one line for the operator when something was not written, else nil.
    nonisolated static func record(_ markers: [FiledMarker]) -> String? {
        var problems: [String] = []
        for (folder, group) in Dictionary(grouping: markers, by: { $0.folder.standardizedFileURL }) {
            let list = group.map {
                ContainerMarker(fileName: $0.fileName, type: $0.type, read: $0.fields, text: $0.text)
            }
            do {
                if case .leftAlone(let why) = try ContainerInference.recordMarkers(list, in: folder) {
                    problems.append("\(folder.lastPathComponent): \(why)")
                }
            } catch {
                problems.append("\(folder.lastPathComponent): \(error)")
            }
        }
        guard !problems.isEmpty else { return nil }
        return "Box and folder labels were not recorded for " + problems.sorted().joined(separator: "; ") + "."
    }
}
