import SwiftUI
import Combine

/// Which layer the Settings window edits (W49.proc-settings-redesign-core, `processor-settings-redesign.md` §5.1): the
/// general defaults, or the collection Process Files writes into (its output folder). The layered settings (`SettingsKey`)
/// follow it, read live through the collection's project and the general layer; the rest are this Mac's and apply to
/// every run. Shared by every tab, so a change in one shows in the others.
@MainActor
final class SettingsScopeModel: ObservableObject {
    enum Scope: Hashable { case general, collection }

    @Published var scope: Scope = .collection
    @Published private(set) var doc: CollectionSettingsDocument?
    @Published private(set) var problem: String?
    @Published private(set) var runCount = 0

    let store: SettingsLayerStore
    private var watching: AnyCancellable?

    init(store: SettingsLayerStore = .shared) {
        self.store = store
        // A write by another view (Process Files, the settings sheet) redraws the window and rereads the collection.
        watching = store.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        reload()
    }

    /// The folder Process Files writes into, resolved exactly as it resolves it (the saved folder, else Downloads; the
    /// UI suite's own folder under test).
    var folder: URL? {
        #if DEBUG
        if let folder = ProcessorUITestConfiguration.outputDirectory { return folder }
        #endif
        return ModelSelectionStore.savedOutputDirectory()
    }

    /// The scope actually edited: the general layer when there is no collection to edit.
    var effectiveScope: Scope { folder == nil ? .general : scope }

    /// The layers as a batch in this scope sees them.
    var resolver: SettingsResolver {
        effectiveScope == .general ? store.resolver(for: nil) : store.resolver(for: doc)
    }

    func resolve(_ key: SettingsKey) -> ResolvedSetting { resolver.resolve(key) }

    /// Whether the edited layer holds its own value for `key` (so its row offers Reset).
    func holdsOwn(_ key: SettingsKey) -> Bool {
        if key.allowed(in: .collection) == false || effectiveScope == .general { return store.general.entry(key) != nil }
        return doc?.collection.entry(key) != nil
    }

    /// The value the edited layer would inherit if it held none of its own.
    func inherited(_ key: SettingsKey) -> ResolvedSetting {
        var r = resolver
        if key.allowed(in: .collection) == false || effectiveScope == .general {
            r.collection = nil
            r.project = nil
            r.general.reset(key)
        } else {
            r.collection = nil
        }
        return r.resolve(key)
    }

    /// Store `value` in the edited layer. A key only the general layer may hold always goes there.
    func set(_ key: SettingsKey, _ value: SettingsValue) {
        let source = SettingsSource.setByUser(Date())
        if effectiveScope == .general || !key.allowed(in: .collection) {
            problem = store.setGeneral(key, value, source: source) ? nil : (store.lastProblem ?? "The change could not be saved.")
            return
        }
        guard let folder else { return }
        if let written = store.updateCollection(in: folder, { _ = $0.collection.set(key, value, source: source) }) {
            doc = written
            problem = nil
        } else {
            problem = store.lastProblem ?? "The change could not be saved."
        }
    }

    /// Remove the edited layer's own value, so the inherited one applies again.
    func reset(_ key: SettingsKey) {
        if effectiveScope == .general || !key.allowed(in: .collection) {
            problem = store.resetGeneral(key) ? nil : store.lastProblem
            return
        }
        updateCollection { $0.collection.reset(key) }
    }

    func updateCollection(_ change: (inout CollectionSettingsDocument) -> Void) {
        guard let folder else { return }
        if let written = store.updateCollection(in: folder, change) {
            doc = written
            problem = nil
        } else {
            problem = store.lastProblem
        }
    }

    /// Reread the collection's document (on a change of folder, or after another view wrote it).
    func reload() {
        guard let folder else { doc = nil; problem = nil; runCount = 0; return }
        runCount = CollectionSettingsFile.runCount(in: folder)
        switch CollectionSettingsFile.read(in: folder) {
        case .document(let d): doc = d; problem = nil
        case .missing: doc = nil; problem = nil
        case .unreadable:
            doc = nil
            problem = "This collection's settings file could not be read. It will be set aside, not deleted, when the collection's settings are next saved."
        case .refused(let e): doc = nil; problem = "This collection's settings were left alone: \(e.description)."
        }
    }

    /// The values the collection holds itself, for the scope bar's list.
    var heldKeys: [SettingsKey] {
        guard let doc else { return [] }
        return doc.collection.entries.keys.map(SettingsKey.init(rawValue:))
            .filter { doc.collection.entry($0) != nil }
            .sorted { $0.label < $1.label }
    }
}

/// The line under a layered row: where its value comes from, with Reset when the edited layer holds its own.
struct LayeredSourceLine: View {
    @EnvironmentObject private var scope: SettingsScopeModel
    let key: SettingsKey

    var body: some View {
        let resolved = scope.resolve(key)
        // Nothing set in any layer: the built-in value, said plainly rather than as the interview's skip answer.
        let source = resolved.layer == nil ? "Default" : resolved.sourceText.prefix(1).uppercased() + resolved.sourceText.dropFirst()
        HStack(alignment: .firstTextBaseline) {
            Text(source + ".")
                .font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ap.settings.source.\(key.rawValue)")
            Spacer()
            if scope.holdsOwn(key) {
                let above = scope.inherited(key)
                Button("Reset") { scope.reset(key) }
                    .controlSize(.small)
                    .help("Go back to \(key.describe(above.value)), \(above.sourceText).")
                    .accessibilityIdentifier("ap.settings.reset.\(key.rawValue)")
            }
        }
    }
}

/// A switch kept in the settings layers: it reads the edited scope's value and writes the edited layer.
struct LayeredToggle<Label: View>: View {
    @EnvironmentObject private var scope: SettingsScopeModel
    let key: SettingsKey
    var identifier: String? = nil
    @ViewBuilder var label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { scope.resolve(key).value.bool ?? false },
                                 set: { scope.set(key, .bool($0)) })) { label() }
                .accessibilityIdentifier(identifier ?? "ap.settings.\(key.rawValue)")
            LayeredSourceLine(key: key)
        }
    }
}

extension LayeredToggle where Label == Text {
    init(_ title: String, key: SettingsKey, identifier: String? = nil) {
        self.init(key: key, identifier: identifier) { Text(title) }
    }
}

/// A title with its "?" popover, for a row's label.
struct HelpLabel: View {
    let title: String
    let help: String
    let handbook: Handbook.Section?

    init(_ title: String, help: String, handbook: Handbook.Section? = nil) {
        self.title = title
        self.help = help
        self.handbook = handbook
    }

    var body: some View {
        HStack {
            Text(title)
            HelpButton(text: help, handbook: handbook)
        }
    }
}
