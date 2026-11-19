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

    /// The parser's reader when the photo's own Vision lines could not be had and the run's OCR text stood in: a route
    /// the bench has not scored (an LLM transcript may join or reflow the label's lines).
    static let ocrTextReader = "ocr-text+parser"

    /// One label photo's proposals: Vision + parser on the photo's own Apple Vision lines (accurate, as `ct-read.md`
    /// scored it; the run's OCR text if Vision reads nothing), and a model's reading of the image: GPT 5.6 Luna when
    /// the session reads text through the gateway, else (no gateway, or a local model on it, which cannot serve Luna)
    /// Gemma 3 12B when a server on this Mac lists it (`ContainerLabelGemma`, W47.ct-capture-gemma). A failed call, no
    /// such server, or a photo that is not an image, leaves the parser's values.
    static func read(type: ItemType, text: String, photo: URL, rotation: Int,
                     gateway: GatewayConfig?) async -> ContainerFieldSet {
        let vision = try? await VisionClient(settings: .default).ocr(imageURL: photo)
        let visionText = vision?.text ?? ""
        let lines = (visionText.isEmpty ? text : visionText).components(separatedBy: .newlines)
        let parserReader = visionText.isEmpty ? ocrTextReader : ContainerLabelReader.visionReader
        var model: [ContainerField: String]?
        var modelReader = gatewayReader
        if gateway == nil || gateway?.isLocalModel == true {
            model = await ContainerLabelGemma.read(photo: photo, rotation: rotation, gateway: gateway)
            modelReader = ContainerLabelReader.localModelReader
        } else if let gateway, let jpeg = ImageEncoding.uprightJPEG(url: photo, rotationDegrees: rotation, longEdge: imageLongSide) {
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
                                              modelReader: model == nil ? nil : modelReader,
                                              parserReader: parserReader, at: Date())
    }

    /// One filed marker, for the finalize write.
    struct FiledMarker: Sendable {
        let folder: URL
        let fileName: String
        let type: ItemType
        let fields: ContainerFieldSet
        let text: String
        /// The type came from the companion's Box or Folder button (`ContainerMarker.startedByUser`).
        let startedByUser: Bool
        /// The names this filing put into `folder` (`ContainerInference.recordMarkers`' `filedNow`); nil when unknown.
        var filedNow: Set<String>? = nil
    }

    /// Applies each collection folder's markers to its container file (new files only, inside `.archivesuite`).
    /// Returns one line for the operator when something was not written or wants a look (the SPEC's warnings), else nil.
    nonisolated static func record(_ markers: [FiledMarker]) -> String? {
        var problems: [String] = []
        var warnings: [ContainerWarning] = []
        for (folder, group) in Dictionary(grouping: markers, by: { $0.folder.standardizedFileURL }) {
            let list = group.map {
                ContainerMarker(fileName: $0.fileName, type: $0.type, read: $0.fields, text: $0.text,
                                startedByUser: $0.startedByUser)
            }
            do {
                switch try ContainerInference.recordMarkers(list, in: folder, filedNow: group.first?.filedNow) {
                case .leftAlone(let why): problems.append("\(folder.lastPathComponent): \(why)")
                case .wrote(let w), .unchanged(let w): warnings += w
                }
            } catch {
                problems.append("\(folder.lastPathComponent): \(error)")
            }
        }
        var lines: [String] = []
        if !problems.isEmpty {
            lines.append("Box and folder labels were not recorded for " + problems.sorted().joined(separator: "; ") + ".")
        }
        if let note = warningNote(warnings) { lines.append(note) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The warnings `applyMarkers` gave, counted by kind, for the summary (`SPEC/containers.md` §Warnings).
    nonisolated static func warningNote(_ warnings: [ContainerWarning]) -> String? {
        var empty = 0, againstUser = 0, insideUser = 0
        for w in warnings {
            switch w.kind {
            case .markerWithoutRead: empty += 1
            case .readDisagreesWithUser: againstUser += 1
            case .markerInsideUserRun: insideUser += 1
            default: break
            }
        }
        func n(_ k: Int, _ one: String, _ many: String) -> String? { k == 0 ? nil : "\(k) \(k == 1 ? one : many)" }
        let parts = [n(empty, "label photo read nothing", "label photos read nothing"),
                     n(againstUser, "label read differs from a value you set (yours kept)",
                       "label reads differ from values you set (yours kept)"),
                     n(insideUser, "label photo fell inside a run you set and started none",
                       "label photos fell inside runs you set and started none")].compactMap { $0 }
        return parts.isEmpty ? nil : "Box and folder labels: " + parts.joined(separator: "; ") + " — check them in Archive Reader."
    }
}
