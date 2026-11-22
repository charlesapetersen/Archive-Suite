import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

/// Settings › Documents (W47.settings-panels): the segmentation card and its routes, the tagging mode, vocabulary and
/// colours, collection ID and filing, merging, the review pause and the custom prompt.
struct SettingsDocumentsPanel: View {
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage(DefaultsKeys.itemTypeColourBox) private var itemTypeColourBox: Int = 0
    @AppStorage(DefaultsKeys.itemTypeColourFolder) private var itemTypeColourFolder: Int = 0
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @AppStorage(DefaultsKeys.confirmCollectionIDs) private var confirmCollectionIDs: Bool = false
    @AppStorage(DefaultsKeys.reviewDocumentSegmentation) private var reviewDocumentSegmentation: Bool = false
    @AppStorage(DefaultsKeys.enableSegmentJSON) private var enableSegmentJSON: Bool = true
    @AppStorage(DefaultsKeys.sendPreviousImage) private var sendPreviousImage: Bool = false
    @AppStorage(DefaultsKeys.tagVocabulary) private var tagVocabulary: String = ""
    @AppStorage(DefaultsKeys.mergeDocuments) private var mergeDocuments: Bool = false
    @AppStorage(DefaultsKeys.customOCRPrompt) private var customOCRPrompt: String = ""

    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }

    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationApproachRaw: String =
        SegmentationApproach.defaultApproach.rawValue

    /// Who segments with the current settings (W36.seg-opt-review).
    private var segmentationPlan: SegmentationPlan {
        SegmentationPlan.resolve(tagging: taggingMode,
                                 approach: SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach)
    }

    /// Which keys / `claude` the segmentation approaches can use; read on appear, never while rendering.
    @State private var segmentationRoutes = SegmentationRoutes.none

    var body: some View {
        Form {
            Section {
                SettingsStageCards(cards: ["segmentation"])
            } header: { Text("The app's pick") }
            SettingsLevelSection([.segmentationApproach, .localSegmenter]) { segmentationSection }
            taggingSection
        }
        .formStyle(.grouped)
        .onAppear { segmentationRoutes = SegmentationRoutes.currentPreselecting() }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            segmentationRoutes = SegmentationRoutes.currentPreselecting()
        }
    }

    @ViewBuilder private var segmentationSection: some View {
        Section {
            SegmentationChooserView(pageCount: 1000, scaleCaption: "per 1,000 pages",
                                    routes: $segmentationRoutes)
        } header: { Text("Segmentation") }
    }

    /// W40.suite-item-types: a box or folder photo is tagged "Box" or "Folder"; its Finder colour is optional.
    private func itemTypeColourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(selection: selection) {
            Text("None").tag(0)
            ForEach(FinderLabel.allCases, id: \.self) { Text($0.tokenName).tag($0.rawValue) }
        } label: {
            HStack {
                Text(title)
                HelpButton(text: "Box and folder photos are always tagged “Box” or “Folder”. A colour here is also written as the file's Finder colour label, for your own browsing; it is not what marks the type.")
            }
        }
    }

    @ViewBuilder private var taggingSection: some View {
        Section {
            Picker(selection: $taggingModeRaw) {
                ForEach(TaggingMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                HStack {
                    Text("Tagging mode")
                    HelpButton(text: "\(taggingMode.detail)\n\nProcess Files' Tagging dropdown is a shortcut to this setting: changing either changes both. The estimate in Settings › Collection shows each mode's cost and time.")
                }
            }
            SettingsLevelRows(.vocabularyColours, changed: SettingsLevels.changed(.vocabularyColours)) {
                itemTypeColourPicker("Box colour", selection: $itemTypeColourBox)
                itemTypeColourPicker("Folder colour", selection: $itemTypeColourFolder)
            }
            SettingsLevelRows(.collectionID, changed: SettingsLevels.changed(.collectionID)
                              || SettingsLevels.changed(DefaultsKeys.reviewDocumentSegmentation)) {
                Toggle(isOn: $enableCollectionSegmentation) {
                    HStack {
                        Text("Collection ID + file renaming")
                        HelpButton(text: "Identify archival collections from box-label photos and organize outputs into per-collection folders with sequential names (e.g. “000001 Collection Name.pdf”).")
                    }
                }
                if enableCollectionSegmentation {
                    Toggle(isOn: $confirmCollectionIDs) {
                        HStack {
                            Text("Confirm identifications before organizing")
                            HelpButton(text: "Pause before filing so you can review and correct the collection names the model extracted from box labels.")
                        }
                    }
                    Toggle(isOn: $reviewDocumentSegmentation) {
                        HStack {
                            Text("Review document segmentation")
                            HelpButton(text: "Pause after OCR to review and correct each page's classification (document start / continuation / box / folder) before tagging. Only applies when a model proposes the segmentation (Automatic tagging, or any Segmentation approach other than Manual).")
                        }
                    }
                    .disabled(!segmentationPlan.reviewShowsDocumentClasses)
                .settingsLevel(.segmentationReview)
                }
            }
            Toggle(isOn: $enableSegmentJSON) {
                HStack {
                    Text("Export segment JSON metadata")
                    HelpButton(text: "Write a .json file beside the PDF when the run collects metadata. This also controls whether low-confidence name mentions are saved during OCR-only runs.")
                }
            }
            .settingsLevel(.segmentationReview)
            if taggingMode.enablesTagging && taggingMode != .copySource {
                Toggle(isOn: $sendPreviousImage) {
                    HStack {
                        Text("Send previous page image")
                        HelpButton(text: "Gives the model the previous page's full image as segmentation context (~2× image cost) while keeping OCR parallel. Only used when the OCR model's own per-page tags segment the run (Automatic tagging with Manual segmentation); otherwise, and in pre-OCRed mode, it's ignored, so it adds no cost. Gemini/Anthropic only.")
                    }
                }
                .disabled(!segmentationPlan.usesPerPageClassifier || preOCRedInput)
                .settingsLevel(.previousImage)
                if taggingMode == .automatic {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Tag vocabulary (optional)").font(.caption)
                            HelpButton(text: "One tag per line. When set, the model chooses subject tags only from this controlled vocabulary. Leave blank for free-form tagging.")
                            Spacer()
                            Button("Import from CSV…") { importTagVocabularyCSV() }
                                .font(.caption)
                                .help("Load a controlled vocabulary from a .csv or .txt file (comma- or line-separated). You can also drag a file onto the box below.")
                        }
                        TextEditor(text: $tagVocabulary).font(.caption).frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadTagVocabularyFromDrop(providers) }
                    }
                    .settingsLevel(.vocabularyColours)
                }
            }
            Toggle(isOn: $mergeDocuments) {
                HStack {
                    Text("Merge multi-page documents")
                    HelpButton(text: "Combine a document's continuation pages into one multi-page PDF (each page's image followed by its text) instead of a separate PDF per page.")
                }
            }
            .settingsLevel(.segmentationReview)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Custom prompt (optional)").font(.caption)
                    HelpButton(text: "Extra instructions appended to the OCR prompt — e.g. “This collection is 1950s legal correspondence.” Helps with unusual documents, languages, or formats.")
                }
                TextEditor(text: $customOCRPrompt).font(.caption).frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
            .settingsLevel(.customPrompt)
        } header: {
            Text("Tagging and filing")
        }
    }

    // MARK: - Tag-vocabulary CSV import

    /// Open a .csv/.txt file and load it into the controlled tag vocabulary (one tag per line).
    private func importTagVocabularyCSV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.message = "Choose a CSV or text file of subject tags (comma- or line-separated)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadTagVocabulary(from: url)
    }

    /// Handle a file dropped onto the vocabulary editor. Returns true if a file was accepted.
    private func loadTagVocabularyFromDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { loadTagVocabulary(from: url) }
        }
        return true
    }

    /// Parse a CSV/text file into a newline-separated vocabulary: split on newlines and commas,
    /// trim, drop blanks, de-dupe case-insensitively (keep first-seen), preserve order.
    private func loadTagVocabulary(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var seen = Set<String>()
        var tags: [String] = []
        for token in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," }) {
            let tag = token.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag)
        }
        guard !tags.isEmpty else { return }
        tagVocabulary = tags.joined(separator: "\n")
    }
}
