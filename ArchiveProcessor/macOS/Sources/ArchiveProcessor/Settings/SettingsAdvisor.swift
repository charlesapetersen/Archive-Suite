import Foundation

/// The Advisor sheet, "Compare routes & trade-offs…" (W49.proc-settings-advisor-advanced; `processor-settings-redesign.md`
/// §5.6, Option B, approved by the owner 2026-11-25). It replaces the collection interview and the old settings sheet's
/// Choices and Rules tabs. The user answers what the app cannot see about the material (the kinds of document, the
/// limits, what matters most), sees the solver's picks follow those answers at once, and saves nothing until Save
/// answers or Apply. Everything here is built without a view or the Keychain, so `SettingsSheetTestDriver` checks what
/// the sheet draws and writes.
enum SettingsAdvisor {
    /// The layer the sheet edits: the general defaults, Process Files' collection, or a project.
    enum Target: Hashable, Identifiable {
        case general
        case collection(URL)
        case project(UUID)

        var id: String {
            switch self {
            case .general: return "general"
            case .collection(let url): return "collection:" + url.path
            case .project(let id): return "project:" + id.uuidString
            }
        }
    }

    /// A stage's choice made in the sheet: a route of the stage, or the app's own pick again (which clears the
    /// override wherever it was set, as the old card's way back did).
    enum Choice: Equatable, Sendable {
        case route(String)
        case appPick
    }

    /// What the sheet holds until Save answers or Apply.
    struct Draft: Equatable, Sendable {
        var answers: CollectionInterviewAnswers
        var choices: [String: Choice] = [:]
        /// The batch the figures are for; not stored.
        var pages: Int
    }

    /// What Save answers or Apply did, in words when something went wrong.
    struct Outcome {
        var ok: Bool
        var problem: String?
        var doc: CollectionSettingsDocument?
    }

    // MARK: Reading the layers

    /// The resolver the sheet starts from: the collection through its project, a project alone, or the general layer.
    @MainActor
    static func baseResolver(_ target: Target, store: SettingsLayerStore, doc: CollectionSettingsDocument?) -> SettingsResolver {
        switch target {
        case .general: return SettingsResolver(general: store.general)
        case .collection: return store.resolver(for: doc)
        case .project(let id): return SettingsResolver(general: store.general, project: store.project(id))
        }
    }

    /// The layer the sheet writes, as it stands.
    static func ownLayer(_ target: Target, base: SettingsResolver) -> SettingsLayer? {
        switch target {
        case .general: return base.general
        case .collection: return base.collection
        case .project: return base.project
        }
    }

    /// The answers the sheet opens with: every value as the layers resolve it now, with the target's own values counted
    /// as answered (`CollectionInterviewAnswers`).
    static func draft(_ target: Target, base: SettingsResolver, pages: Int) -> Draft {
        Draft(answers: CollectionInterviewAnswers(resolver: base, own: ownLayer(target, base: base)), pages: max(1, pages))
    }

    /// The layers as they would stand after Apply: the figures the sheet shows follow the draft before anything is saved.
    static func resolver(_ base: SettingsResolver, target: Target, draft: Draft, now: Date = Date()) -> SettingsResolver {
        var r = base
        switch target {
        case .general:
            edit(&r.general, draft: draft, now: now)
        case .collection:
            var layer = r.collection ?? SettingsLayer(kind: .collection, name: "")
            edit(&layer, draft: draft, now: now)
            r.collection = layer
        case .project:
            guard var layer = r.project else { break }
            edit(&layer, draft: draft, now: now)
            r.project = layer
        }
        for (stage, choice) in draft.choices where choice == .appPick {
            let key = SettingsSheetModel.overrideKey(stage)
            r.general.reset(key)
            r.project?.reset(key)
            r.collection?.reset(key)
        }
        return r
    }

    /// Write the answers, and the stage choices when `choices` is true, into `layer`.
    ///
    /// An answer left as it was keeps its entry, and so its source: a starting point's, a measurement's, or the general
    /// interview's "follows your answer" (whose `staysOnMac` the money habit still moves, `GeneralInterviewAnswers`).
    /// Only a changed value becomes the user's. The general layer's batch ceiling is never written here: it belongs to
    /// Settings › Processing's spending limit, and "no limit" is a project's or a collection's word only
    /// (`ResolvedSetting.hasUnlimitedBatchSpending`).
    static func edit(_ layer: inout SettingsLayer, draft: Draft, choices: Bool = true, now: Date = Date()) {
        let before = layer
        draft.answers.apply(to: &layer, now: now)
        for key in CollectionInterviewAnswers.keys + CollectionInterviewAnswers.mixGroup + [.weights] {
            if let old = before.entries[key.rawValue], layer.entries[key.rawValue]?.value == old.value {
                layer.entries[key.rawValue] = old
            }
        }
        if layer.kind == .general { layer.entries[SettingsKey.batchCeilingUSD.rawValue] = before.entries[SettingsKey.batchCeilingUSD.rawValue] }
        guard choices else { return }
        for (stage, choice) in draft.choices {
            let key = SettingsSheetModel.overrideKey(stage)
            switch choice {
            case .route(let id): _ = layer.set(key, .string(id), source: .setByUser(now))
            case .appPick: layer.reset(key)
            }
        }
    }

    // MARK: Writing

    /// Save the draft into the target's layer: the answers always, the stage choices when `choices` is true (Apply).
    /// The app's pick again clears that stage's override in every layer above too, as the way back always has.
    @MainActor
    static func save(_ draft: Draft, to target: Target, store: SettingsLayerStore, doc: CollectionSettingsDocument?,
                     choices: Bool, now: Date = Date()) -> Outcome {
        var current = doc
        var ok = true
        switch target {
        case .collection(let folder):
            if let written = store.updateCollection(in: folder, { edit(&$0.collection, draft: draft, choices: choices, now: now) }) {
                current = written
            } else {
                ok = false
            }
        case .project(let id):
            ok = store.updateProject(id) { edit(&$0, draft: draft, choices: choices, now: now) }
        case .general:
            var layer = store.general
            edit(&layer, draft: draft, choices: choices, now: now)
            ok = store.replaceGeneral(layer)
        }
        if ok, choices {
            for (stage, choice) in draft.choices where choice == .appPick {
                let key = SettingsSheetModel.overrideKey(stage)
                if case .collection = target, let id = current?.projectID, store.project(id)?.entry(key) != nil {
                    ok = store.updateProject(id) { $0.reset(key) } && ok
                }
                if target != .general, store.general.entry(key) != nil { ok = store.resetGeneral(key) && ok }
            }
        }
        return Outcome(ok: ok, problem: ok ? nil : (store.lastProblem ?? "The settings could not be saved."), doc: current)
    }

    /// The run settings Apply switches on: each stage whose pick Process Files can run but does not run now. Reading and
    /// how document breaks are found are this Mac's settings, for every run (Settings › Processing says so).
    static func runChanges(_ model: SettingsSheetModel) -> [SettingsSheetModel.Apply] {
        model.cards.compactMap(\.apply)
    }

    /// The same, in words: "Reading: Gemini 3.8 Flash; Finding documents: Full manual".
    static func runChangeWords(_ model: SettingsSheetModel) -> String? {
        let words = model.cards.filter { $0.apply != nil }.map { "\($0.title): \($0.routeName)" }
        return words.isEmpty ? nil : words.joined(separator: "; ")
    }

    /// Switch a run setting on. The Claude plan is confirmed first by the caller (`readingByPlan` needs a sign-in
    /// check), so it is written here only once confirmed.
    @MainActor
    static func applyRun(_ a: SettingsSheetModel.Apply, defaults d: UserDefaults = .standard,
                         models: ModelSelectionStore = .shared) {
        switch a {
        case .segmentation(let approach):
            d.set(approach.rawValue, forKey: DefaultsKeys.segmentationApproach)
        case .appleVision(let modelID):
            (modelID == OnDeviceModelClient.modelID ? ReaderChoice.onDevice : .appleVision).apply(d, store: models)
        case .reading(let appRoute):
            let parts = appRoute.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let provider = LLMProvider.allCases.first(where: { $0.rawValue.lowercased() == parts[0] }),
                  provider.models.contains(where: { $0.id == parts[1] }) else { return }
            ReaderChoice.direct(provider, parts[1]).apply(d, store: models)
        case .readingByPlan(let model):
            if d.string(forKey: DefaultsKeys.localAgentTool) != LocalAgentTool.claude.rawValue {
                d.set("", forKey: DefaultsKeys.localAgentBinaryPath)
            }
            d.set(LocalAgentTool.claude.rawValue, forKey: DefaultsKeys.localAgentTool)
            d.set(model, forKey: DefaultsKeys.localAgentModel)
            ReaderChoice.localAgent.apply(d, store: models)
        }
    }

    /// The sheet's title for its target.
    static func title(_ target: Target, projectName: String?) -> String {
        switch target {
        case .general: return "Compare routes & trade-offs: your general defaults"
        case .collection(let folder): return "Compare routes & trade-offs: the collection “\(folder.lastPathComponent)”"
        case .project: return "Compare routes & trade-offs: the project “\(projectName ?? "")”"
        }
    }

    /// The Apply button's words: where the choices go.
    static func applyTitle(_ target: Target) -> String {
        switch target {
        case .general: return "Apply to General defaults"
        case .collection: return "Apply to this collection"
        case .project: return "Apply to this project"
        }
    }

    /// The document mix in one line, e.g. "Typewritten 50% · Printed 28% · Handwritten 16%".
    static func mixSummary(_ a: CollectionInterviewAnswers) -> String {
        let measured = CollectionInterviewAnswers.measuredKinds.compactMap { k -> String? in
            guard let v = a.measuredShares[k], v > 0 else { return nil }
            return "\(PageKindName.label(k)) \(String(format: "%g", v.rounded()))%"
        }
        let asked = CollectionInterviewAnswers.unmeasuredKinds.compactMap { k -> String? in
            guard let v = a.unmeasuredShares[k], v > 0 else { return nil }
            return "\(CollectionInterviewAnswers.unmeasuredLabel(k)) \(String(format: "%g", v.rounded()))%"
        }
        let all = measured + asked
        return all.isEmpty ? "Not given: the app's test-page mix is used" : all.joined(separator: " · ")
    }

    /// What the reading runs now, for the model's cards, read by the caller outside any view body. Moved here from the
    /// old settings sheet (W46.settings-sheet).
    static func running(segmentation: SegmentationApproach, useAppleVision: Bool, useGateway: Bool,
                        useLocalAgent: Bool, provider: LLMProvider, model: LLMModel,
                        table: SettingsRouteTable?, localAgentTool: LocalAgentTool = .claude,
                        localAgentModel: String = "", appleVisionModelID: String = "macos-vision",
                        claudeBilling: ClaudeCLIBilling = .unknown) -> SettingsSheetModel.Running {
        if useAppleVision {
            // W47.wh-readers-lost-clients: the Mac's reader is Vision unless the reading card chose the on-device model.
            if appleVisionModelID == OnDeviceModelClient.modelID {
                return .init(readingRouteID: SettingsSheetModel.onDeviceRouteID, readingName: "the macOS on-device model on this Mac",
                             segmentation: segmentation)
            }
            return .init(readingRouteID: "apple-vision", readingName: "Apple Vision on this Mac", segmentation: segmentation)
        }
        if useLocalAgent {
            // `claude` at a measured Anthropic model is that row read by the plan (W41.app-claude-plan-reading).
            let model = localAgentModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if localAgentTool == .claude, claudeBilling == .subscription, !model.isEmpty,
               let r = table?.stage("reading")?.routes.first(where: { $0.appRoute == "anthropic|\(model)" && $0.needs.plan == ["claude"] }) {
                return .init(readingRouteID: r.id, readingName: "your Claude plan (\(model))", segmentation: segmentation,
                             onPlan: true)
            }
            let name = localAgentTool == .claude && claudeBilling == .apiKey
                ? "Claude Code on its API key" : "your signed-in command-line agent"
            return .init(readingRouteID: nil, readingName: name, segmentation: segmentation)
        }
        if useGateway {
            return .init(readingRouteID: nil, readingName: "the model on your API gateway", segmentation: segmentation)
        }
        // A maker's model through OpenRouter is the measured row of its maker (W41.app-openrouter-any).
        let route = (provider == .openrouter ? OpenRouterRoute.forModel(model.id)?.makerAppRoute : nil)
            ?? "\(provider.rawValue.lowercased())|\(model.id)"
        let id = table?.stage("reading")?.routes.first { $0.appRoute == route }?.id
        return .init(readingRouteID: id, readingName: model.displayName, segmentation: segmentation)
    }
}

extension KindMeasurement {
    /// The chosen files and the immediate contents of any chosen folder, for "Measure from files…".
    static func inputFiles(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        return urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            guard isDir.boolValue else { return [url] }
            let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false }
        }
    }
}
