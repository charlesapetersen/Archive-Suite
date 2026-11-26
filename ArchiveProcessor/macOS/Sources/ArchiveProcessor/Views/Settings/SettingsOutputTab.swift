import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ArchiveCore

/// Settings › Output (W49.proc-settings-redesign-core, §5.2): preservation copies, the PDF's form and sizes, the
/// separate image, straightening and rotation, skipping processed files, Finder colours and the subject vocabulary.
struct SettingsOutputTab: View {
    @EnvironmentObject private var scope: SettingsScopeModel
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput = false
    @AppStorage(DefaultsKeys.skipAlreadyProcessed) private var skipAlreadyProcessed = false
    @AppStorage(DefaultsKeys.outputImageFile) private var outputImageFile = true
    @AppStorage(DefaultsKeys.pdfImageSizeMB) private var pdfImageSizeMB: Double = SessionProcessingConfig.defaultPDFImageMB
    @AppStorage(DefaultsKeys.exportedImageSizeMB) private var exportedImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.textColumns) private var textColumns: Int = 1
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.standard.rawValue
    @AppStorage(DefaultsKeys.reviewRotation) private var reviewRotation = false
    @AppStorage(DefaultsKeys.itemTypeColourBox) private var itemTypeColourBox: Int = 0
    @AppStorage(DefaultsKeys.itemTypeColourFolder) private var itemTypeColourFolder: Int = 0
    @AppStorage(DefaultsKeys.tagVocabulary) private var tagVocabulary: String = ""
    @State private var editingVocabulary = false

    private typealias SizingBounds = SessionProcessingConfig.Bounds
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .standard }

    private var hasMeasuredRotation: Bool {
        guard !useAppleVision, !useGateway || GatewayConfig.fromDefaults() != nil else { return false }
        return LLMRotationDetector.hasMeasuredRoute(provider: selectedProvider, usesGateway: useGateway,
                                                    usesLocalAgent: useLocalAgent, gatewayIsLocal: gatewayLocalModel)
    }

    /// A direct Gemini, Claude or OpenAI key: rotation calls ask the run's own OCR model (owner, 2026-11-24).
    private var asksOCRModelForRotation: Bool {
        !useAppleVision && !useGateway && !useLocalAgent && [.gemini, .anthropic, .openai].contains(selectedProvider)
    }

    var body: some View {
        Form {
            preservationSection
            orientationSection
            filingSection
        }
        .formStyle(.grouped)
        // W16.cfg6-fu3: write back exactly what a run would read, so a typed 500 snaps to the 20 a run uses.
        .onAppear { SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: pdfImageSizeMB) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: exportedImageSizeMB) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .sheet(isPresented: $editingVocabulary) {
            TagVocabularySheet(vocabulary: $tagVocabulary) { editingVocabulary = false }
        }
    }

    // MARK: Preservation and PDF

    private var searchable: [String] { scope.resolve(.searchableFor).value.strings ?? [] }

    private enum PDFForm: Hashable { case imageAndText, searchable, custom }

    private var pdfForm: Binding<PDFForm> {
        Binding(get: {
            let entries = searchable
            if entries.isEmpty { return .imageAndText }
            return entries == SettingsAdvanced.searchableEverywhere ? .searchable : .custom
        }, set: { form in
            switch form {
            case .imageAndText: scope.set(.searchableFor, .strings([]))
            case .searchable: scope.set(.searchableFor, .strings(SettingsAdvanced.searchableEverywhere))
            case .custom: break
            }
        })
    }

    @ViewBuilder private var preservationSection: some View {
        Section("Preservation and PDF") {
            LayeredToggle(key: .keepPreservationCopies) {
                HelpLabel("Keep full-resolution originals in a Preservation folder", help: "The exact originals are kept beside your reading PDFs, in a Preservation folder. This uses extra space. Archive Reader can show the originals; when you share only a PDF, they stay behind.")
            }
            VStack(alignment: .leading, spacing: 2) {
                Picker(selection: pdfForm) {
                    Text("Image + separate text page").tag(PDFForm.imageAndText)
                    Text("One searchable page where possible").tag(PDFForm.searchable)
                    if pdfForm.wrappedValue == .custom { Text("Per format (set in Advanced)").tag(PDFForm.custom) }
                } label: {
                    HelpLabel("PDF format", help: "Image + separate text page: each page image is followed by a page of its text. One searchable page: the reading sits invisibly on the page image, so you can search and select it there. Handwritten, mixed and register pages keep their separate text page either way. Per-format choices are in Settings › Advanced.")
                }
                .accessibilityIdentifier("ap.settings.pdfFormat")
                LayeredSourceLine(key: .searchableFor)
            }
            sizeRow("PDF image target", value: $pdfImageSizeMB, identifier: "ap.settings.pdfImageSize",
                    help: "Target size for the image in each output PDF (default 1.5 MB). Larger images are downscaled toward it; smaller ones are kept as they are. Not used for pre-OCRed input.")
                .disabled(preOCRedInput)
            HStack {
                HelpLabel("Text columns", help: "Columns on the text page of each PDF. Use 2 or 3 for multi-column sources like newspapers.")
                Spacer()
                Picker("Text columns", selection: $textColumns) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .disabled(preOCRedInput)
            Toggle(isOn: $outputImageFile) {
                HelpLabel("Also export a separate JPEG image", help: "On: each document is saved as a PDF and a separate image file. Off: only the PDF.")
            }
            .disabled(preOCRedInput)
            .accessibilityIdentifier("ap.settings.outputImageFile")
            if outputImageFile {
                sizeRow("Exported image target", value: $exportedImageSizeMB, identifier: "ap.settings.exportedImageSize",
                        help: "Target size for the separate image file (default 3 MB). Already-small JPEGs are kept byte for byte.")
                    .disabled(preOCRedInput)
            }
        }
    }

    private func sizeRow(_ title: String, value: Binding<Double>, identifier: String, help: String) -> some View {
        HStack {
            HelpLabel(title, help: help)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                .accessibilityIdentifier(identifier)
            Text("MB").foregroundStyle(.primary)
            Stepper(title, value: value, in: SizingBounds.imageMB, step: 0.5).labelsHidden()
        }
    }

    // MARK: Orientation

    @ViewBuilder private var orientationSection: some View {
        Section("Page orientation and cleanup") {
            LayeredToggle(key: .straightenReadingCopy) {
                HelpLabel("Straighten sloping pages", help: "The copy you read is turned so its lines run level. The preserved original is never changed.")
            }
            Picker(selection: $rotationModeRaw) {
                ForEach(RotationMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                HelpLabel("Detect rotation", help: "\(rotationMode.detail)\n\nThe local checks make no API calls. In the recommended mode, a remote gateway, OpenRouter or a direct Gemini, Claude or OpenAI key (which asks your OCR model) can make one call on about 1 page in 10.")
            }
            .disabled(preOCRedInput)
            .accessibilityIdentifier("ap.settings.rotationMode")
            if rotationMode.orderings > 0, !preOCRedInput, !LLMRotationDetector.hasRoute(
                provider: useAppleVision ? .appleVision : selectedProvider,
                usesGateway: useGateway && GatewayConfig.fromDefaults() != nil, usesLocalAgent: useLocalAgent,
                gatewayIsLocal: gatewayLocalModel) {
                Text("This reader has no LLM rotation check, so pages are checked with Local Vision instead.")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.rotationFallback")
            }
            if rotationMode == .agreement, !preOCRedInput, !hasMeasuredRotation, !asksOCRModelForRotation {
                Text("A page the two local checks disagree on is left as it is and counted in the run’s summary.")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.rotationUnsure")
            }
            if !preOCRedInput, hasMeasuredRotation, !useGateway, rotationMode == .agreement || rotationMode.orderings > 0 {
                Text("Cloud rotation checks use Gemini 3.7 Flash through OpenRouter. The estimate includes these calls.")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.openRouterRotation")
            }
            if !preOCRedInput, asksOCRModelForRotation, rotationMode == .agreement || rotationMode.orderings > 0 {
                Text("Cloud rotation checks ask your OCR model. The estimate includes these calls.")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.ocrModelRotation")
            }
            Toggle(isOn: $reviewRotation) {
                HelpLabel("Review rotation before saving", help: "Pause for a quick pass to check each page's orientation before output, before the document review. For Process Live it runs once at Finish. Needs a rotation mode above.")
            }
            .disabled(rotationMode == .off || preOCRedInput)
            .accessibilityIdentifier("ap.settings.reviewRotation")
        }
    }

    // MARK: Filing

    private func colourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(selection: selection) {
            Text("None").tag(0)
            ForEach(FinderLabel.allCases, id: \.self) { Text($0.tokenName).tag($0.rawValue) }
        } label: {
            HelpLabel(title, help: "Box and folder photos are always tagged “Box” or “Folder”. A colour here is also written as the file's Finder colour label, for your own browsing.")
        }
    }

    @ViewBuilder private var filingSection: some View {
        Section("Filing and subjects") {
            Toggle(isOn: $skipAlreadyProcessed) {
                HelpLabel("Skip files already processed in the output folder", help: "On a re-run, skip any input whose output PDF already exists and is no older than the source. Whenever anything is ambiguous it processes the file rather than risk a silent miss. Ignored for collection-organized or merged runs.")
            }
            .accessibilityIdentifier("ap.settings.skipProcessed")
            colourPicker("Box Finder colour", selection: $itemTypeColourBox)
            colourPicker("Folder Finder colour", selection: $itemTypeColourFolder)
            let tags = tagVocabulary.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            LabeledContent {
                Button("Edit or import…") { editingVocabulary = true }
                    .accessibilityIdentifier("ap.settings.vocabulary.edit")
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HelpLabel("Subject vocabulary", help: "When set, Automatic tagging chooses subject tags only from this list. Leave it empty for free-form tags.")
                    Text(tags.isEmpty ? "Free-form (none set)" : "\(tags.count) tag\(tags.count == 1 ? "" : "s"): "
                         + tags.prefix(3).joined(separator: ", ") + (tags.count > 3 ? "…" : ""))
                        .font(.caption).foregroundStyle(.primary)
                        .accessibilityIdentifier("ap.settings.vocabulary.summary")
                }
            }
        }
    }
}

/// The subject vocabulary's editor: one tag per line, a CSV or text file by Import or by drop.
struct TagVocabularySheet: View {
    @Binding var vocabulary: String
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Subject vocabulary").font(.title3).fontWeight(.semibold)
            Text("One tag per line. Automatic tagging chooses subject tags only from this list; leave it empty for free-form tags. You can also drop a CSV or text file on the box.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $vocabulary)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadFromDrop(providers) }
                .accessibilityIdentifier("ap.settings.vocabulary.editor")
            HStack {
                Button("Import from CSV…") { importCSV() }
                Spacer()
                Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.message = "Choose a CSV or text file of subject tags (comma- or line-separated)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url)
    }

    private func loadFromDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { load(from: url) }
        }
        return true
    }

    /// Split on newlines and commas, trim, drop blanks, de-dupe case-insensitively (keep first seen), keep the order.
    private func load(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var seen = Set<String>()
        var tags: [String] = []
        for token in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," }) {
            let tag = token.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag)
        }
        guard !tags.isEmpty else { return }
        vocabulary = tags.joined(separator: "\n")
    }
}
