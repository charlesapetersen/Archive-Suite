import SwiftUI

/// The "Segmentation" setting (W36.seg-opt-chooser): who proposes the run's document boundaries. Shown in Process
/// Files; it binds `DefaultsKeys.segmentationApproach`, which the settings sheet's segmentation card also sets. The
/// measured figures, the cost and the other choices are on the settings sheet (W46.settings-sheet), which the button
/// here opens scaled to the run; this keeps only what the run needs: the choice, how it is paid for, and why it cannot
/// run yet. Live Capture does not show it: the phone already gives the boundaries.
struct SegmentationChooserView: View {
    @AppStorage(DefaultsKeys.segmentationApproach) private var approachRaw =
        SegmentationApproach.defaultApproach.rawValue
    @AppStorage(DefaultsKeys.segmentationClaudeRoute) private var claudeRouteRaw = ClaudeRoute.apiKey.rawValue

    /// The pages the figures are scaled to.
    let pageCount: Int
    /// Says what `pageCount` is, e.g. "per 1,000 pages" or "for the 42 pages dropped".
    let scaleCaption: String
    /// Read by the parent outside the view body (the Keychain is never read while rendering); refreshed here after
    /// the key wizard closes.
    @Binding var routes: SegmentationRoutes
    var options: SegmentationOptions? = SegmentationOptionsStore.shared

    @State private var wizardSpecs: [ProviderKeySpec] = []

    private var approach: SegmentationApproach {
        SegmentationApproach(rawValue: approachRaw) ?? .defaultApproach
    }

    private var rows: [SegmentationRow] {
        guard let options else { return [] }
        return SegmentationRow.all(options: options, pageCount: pageCount, routes: routes)
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $approachRaw) {
                // Every approach is selectable, so its figures, cost and reason (and the key wizard) can be
                // read before it can run; the card greys out one that cannot. Running it is gated where the
                // run starts (W36.seg-opt-review). The ones that cannot run sit apart under their own heading,
                // so they no longer look like the ones that can (W40.fix-processor-start-why).
                ForEach(rows.filter(\.canRun), id: \.approach) { row in
                    Text(row.label).tag(row.approach.rawValue)
                }
                let unavailable = rows.filter { !$0.canRun }
                if !unavailable.isEmpty {
                    Section("Not ready yet. Choose one to see what it needs") {
                        ForEach(unavailable, id: \.approach) { row in
                            Text("\(row.label) (unavailable)").tag(row.approach.rawValue)
                        }
                    }
                }
                if rows.isEmpty { Text("Full manual").tag(SegmentationApproach.manual.rawValue) }
            } label: {
                HStack {
                    Text("Segmentation")
                    HelpButton(text: "Who proposes where each document starts. Full manual proposes nothing: you group the pages yourself, as before. Every other choice is a first draft you review: the doubtful boundaries are put in front of you one at a time, and the rest stay visible for a skim. Nothing is filed unseen.\n\nWhat each choice gets right, what it costs and how long it takes, measured on real boxes and scaled to your pages, is on the settings sheet: “Figures and other choices…”.")
                }
            }
            .accessibilityIdentifier("ap.segmentation.picker")

            // With both an Anthropic key and `claude`, the user chooses how Claude's windows are paid for.
            if routes.offersClaudeRouteChoice, SegmentationRow.planNotionalUSD(approach, options: options, pageCount: 1) != nil {
                Picker("Pay for Claude", selection: $claudeRouteRaw) {
                    Text("By API key").tag(ClaudeRoute.apiKey.rawValue)
                    Text("By your Claude plan").tag(ClaudeRoute.plan.rawValue)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .accessibilityIdentifier("ap.segmentation.claudeRoute")
                .onChange(of: claudeRouteRaw) { _, raw in
                    routes.claudeRoute = ClaudeRoute(rawValue: raw) ?? .apiKey
                }
            }

            // A ChatGPT voter can also run on the user's ChatGPT plan, by Sign in with ChatGPT (W36.seg-opt-siwc).
            if SegmentationRow.providers(approach, options: options).contains(.openai) {
                ChatGPTPlanControls(routes: $routes)
            }

            if SegmentationRow.providers(approach, options: options).contains(.local) {
                LocalSegmenterControls()
            }

            if let row = rows.first(where: { $0.approach == approach }) {
                if let reason = row.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.segmentation.unavailable")
                    // ChatGPT's alternative to a key, "Continue with ChatGPT", sits above.
                    if !row.missingKeys.isEmpty {
                        Button("Add API key…") { wizardSpecs = row.missingKeys.compactMap(Self.keySpec) }
                            .controlSize(.small)
                    }
                }
            } else {
                Text("The segmentation figures are missing from this build; only Full manual is offered.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            SettingsSheetButton(title: "Figures and other choices…", pages: pageCount, pagesCaption: scaleCaption)
                .controlSize(.small)
                .accessibilityIdentifier("ap.segmentation.openSettingsSheet")
        }
        .sheet(isPresented: Binding(get: { !wizardSpecs.isEmpty }, set: { if !$0 { wizardSpecs = [] } })) {
            ProviderKeyWizard(specs: wizardSpecs) {
                wizardSpecs = []
                routes = SegmentationRoutes.currentPreselecting()
            }
        }
    }

    static func keySpec(_ p: WindowProvider) -> ProviderKeySpec? {
        switch p {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .openai: return .openai
        case .openrouter: return .openrouter
        case .local: return nil
        }
    }
}

/// The `local` approach's server and model (W41.app-local-seg), with a check that the server answers.
struct LocalSegmenterControls: View {
    @AppStorage(DefaultsKeys.localSegmenterBaseURL) private var baseURL = LocalSegmenter.defaultBaseURL
    @AppStorage(DefaultsKeys.localSegmenterModelID) private var modelID = LocalSegmenter.defaultModelID
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Server", text: $baseURL, prompt: Text(LocalSegmenter.defaultBaseURL))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityIdentifier("ap.segmentation.local.server")
            TextField("Model", text: $modelID, prompt: Text(LocalSegmenter.defaultModelID))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityIdentifier("ap.segmentation.local.model")
            HStack {
                Button(checking ? "Checking…" : "Check server") { check() }
                    .controlSize(.small).disabled(checking)
                    .accessibilityIdentifier("ap.segmentation.local.check")
                if let checkResult {
                    Text(checkResult).font(.caption2).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(LocalSegmenter.startHint).font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check() {
        checking = true
        // What a run would use: the same trimming and defaults.
        let url = LocalSegmenter.baseURL(), model = LocalSegmenter.modelID()
        Task {
            let text: String
            do {
                let models = try await LocalModelRoute.listModels(baseURL: url)
                // mlx-vlm downloads a model it does not list yet on its first request, so an unlisted one is no fault
                // yet; the run loads it before the first window and stops with the server's reason if it cannot.
                text = models.contains(model) ? "The server answers and has \(model). Ready."
                    : "The server answers but does not list \(model). A run first tries to load it (downloading about "
                        + "2.5 GB if needed) and stops with the reason if it cannot."
            } catch {
                text = "No server answers at \(url): \(error.localizedDescription)"
            }
            await MainActor.run { checkResult = text; checking = false }
        }
    }
}
