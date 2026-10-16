import SwiftUI

/// The "Segmentation" setting (W36.seg-opt-chooser): who proposes the run's document boundaries, with each
/// approach's measured figures scaled to the run and its cost. Shown in Settings and in Process Files; both bind
/// the same `DefaultsKeys.segmentationApproach`, so changing either updates both. Live Capture does not show it:
/// the phone already gives the boundaries. (`execution-plans/segmentation/04-options-build.md` Part 3 §1, §3, §4.)
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
                ForEach(rows, id: \.approach) { row in
                    // Every approach is selectable, so its figures, cost and reason (and the key wizard) can be
                    // read before it can run; the card greys out one that cannot. Running it is gated where the
                    // run starts (W36.seg-opt-review).
                    Text(row.canRun ? row.label : "\(row.label) (unavailable)").tag(row.approach.rawValue)
                }
                if rows.isEmpty { Text("Full manual").tag(SegmentationApproach.manual.rawValue) }
            } label: {
                HStack {
                    Text("Segmentation")
                    HelpButton(text: "Who proposes where each document starts. Full manual proposes nothing: you group the pages yourself, as before. Every other choice is a first draft you review: the doubtful boundaries are put in front of you one at a time, and the rest stay visible for a skim. Nothing is filed unseen.\n\nThe figures were measured on real boxes and are scaled to your pages.")
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

            if let row = rows.first(where: { $0.approach == approach }) {
                SegmentationRowCard(row: row, scaleCaption: scaleCaption) {
                    wizardSpecs = row.missingKeys.map(Self.keySpec)
                }
            } else {
                Text("The segmentation figures are missing from this build; only Full manual is offered.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: Binding(get: { !wizardSpecs.isEmpty }, set: { if !$0 { wizardSpecs = [] } })) {
            ProviderKeyWizard(specs: wizardSpecs) {
                wizardSpecs = []
                routes = SegmentationRoutes.current()
            }
        }
    }

    static func keySpec(_ p: WindowProvider) -> ProviderKeySpec {
        switch p {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .openai: return .openai
        case .openrouter: return .openrouter
        }
    }
}

/// One approach's figures and cost. Greyed out, with its reason, when it cannot run.
struct SegmentationRowCard: View {
    let row: SegmentationRow
    let scaleCaption: String
    var onAddKeys: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let reason = row.unavailableReason {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("ap.segmentation.unavailable")
                // ChatGPT's alternative to a key, "Continue with ChatGPT", sits above the card.
                if !row.missingKeys.isEmpty {
                    Button("Add API key…", action: onAddKeys).controlSize(.small)
                }
            }
            if !row.toCheck.isEmpty {
                Group {
                    figure("Right with no checking", row.rightWithNoChecking ?? "nothing is proposed")
                    figure("To check", row.toCheck)
                    figure("Right after checking", row.rightAfterChecking)
                    figure("Errors you will not be shown", row.unshownErrors)
                    ForEach(row.costLines, id: \.self) { line in
                        figure("Cost", line)
                    }
                    ForEach(row.priceNotes, id: \.self) { note in
                        Text(note).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .opacity(row.canRun ? 1 : 0.5)
                Text("Scaled \(scaleCaption). \(row.footnote)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.segmentation.row")
    }

    private func figure(_ label: String, _ value: String) -> some View {
        Text("\(Text(label + ": ").foregroundStyle(.secondary))\(value)")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
    }
}
