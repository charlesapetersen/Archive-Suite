import Foundation
import ArchiveCore

/// The state of the shared Tags window (W40.tag-window-core): the list it shows, what is selected, and the one
/// change in flight. Each app feeds it a `TagInventory` of its own items (and a new one whenever they change) and a
/// writer that runs a `TagChangePlan` over them through the app's own audited writer as ONE Undo step, records it in
/// the suite's change log (`TagChangePlan.logEntries`), and reports what it saved. The window never writes anything.
@MainActor
public final class TagsWindowModel: ObservableObject {
    /// What the app's writer saved: the items changed and those it could not save (named in the status line).
    public struct Outcome: Sendable, Equatable {
        public let changed: Int
        public let failed: Int

        public init(changed: Int, failed: Int = 0) {
            self.changed = changed
            self.failed = failed
        }
    }

    public typealias Writer = @MainActor (TagChangePlan) async -> Outcome

    public enum Sort: String, CaseIterable, Identifiable, Sendable {
        case name, count
        public var id: String { rawValue }
        public var title: String { self == .name ? "Name" : "Items" }
    }

    @Published public private(set) var inventory: TagInventory
    @Published public var search = ""
    @Published public var sort: Sort = .name
    /// Entry ids (`tagKey`s) of the selected subjects.
    @Published public var selection: Set<String> = []
    /// Find Similar: only the subjects that look like near-duplicates of another, grouped.
    @Published public var similarOnly = false
    @Published public private(set) var status: String?
    @Published public private(set) var isWorking = false

    public let noun: TagNoun
    /// Shows the items carrying a tag (the Reader filters its list, Notes its sidebar). Nil hides the command.
    public var showItems: (@MainActor (TagInventory.Entry) -> Void)?
    /// What the count column says for a tag, in place of its count: the Processor names the lists that hold it
    /// (W40.tag-window-processor). Nil shows the count.
    public var itemsLabel: (@MainActor (TagInventory.Entry) -> String)?
    private let writer: Writer
    /// Each subject's Find Similar group; worked out when first needed, or given by the app with the inventory.
    private var clusterIndex: [String: Int]?

    public init(inventory: TagInventory, noun: TagNoun, writer: @escaping Writer) {
        self.inventory = inventory
        self.noun = noun
        self.writer = writer
    }

    /// A new inventory after the app's items changed. The selection keeps the tags that are still carried.
    /// `similarClusters` is the inventory's `similarClusters()` when the app worked it out off the main actor, as it
    /// should for a large library (7,000 subjects took 2.5 s in a Debug build, W40.tag-window-reader); nil leaves it
    /// to be worked out here the first time Find Similar needs it.
    public func update(_ inventory: TagInventory, similarClusters: [[TagInventory.Entry]]? = nil) {
        self.inventory = inventory
        clusterIndex = similarClusters.map(Self.index)
        selection = selection.filter { inventory.entry(forKey: $0) != nil }
    }

    private var clusters: [String: Int] {
        if let clusterIndex { return clusterIndex }
        let index = Self.index(inventory.similarClusters())
        clusterIndex = index
        return index
    }

    private static func index(_ clusters: [[TagInventory.Entry]]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (i, cluster) in clusters.enumerated() {
            for entry in cluster { index[entry.id] = i }
        }
        return index
    }

    // MARK: What the list shows

    /// The subjects to list: those matching the search in any spelling, only the similar ones under Find Similar
    /// (each group together, biggest first), sorted by the chosen column.
    public var rows: [TagInventory.Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = inventory.subjects.filter { entry in
            query.isEmpty || entry.spellings.contains { $0.tag.localizedCaseInsensitiveContains(query) }
        }
        if similarOnly {
            let clusterIndex = clusters
            list = list.filter { clusterIndex[$0.id] != nil }
            return list.sorted { a, b in
                let (ga, gb) = (clusterIndex[a.id]!, clusterIndex[b.id]!)
                if ga != gb { return ga < gb }
                return a.itemCount != b.itemCount ? a.itemCount > b.itemCount : Self.byName(a, b)
            }
        }
        switch sort {
        case .name: return list.sorted(by: Self.byName)
        case .count: return list.sorted { $0.itemCount != $1.itemCount ? $0.itemCount > $1.itemCount : Self.byName($0, $1) }
        }
    }

    /// The suite's own tokens, listed apart and never changed here.
    public var suiteTokens: [TagInventory.Entry] { inventory.suiteTokens }

    /// Which Find Similar group a subject is in, for the list's grouping; nil when it has no near-duplicate.
    public func similarGroup(of entry: TagInventory.Entry) -> Int? { clusters[entry.id] }

    public var selectedEntries: [TagInventory.Entry] {
        rows.filter { selection.contains($0.id) }
    }

    private static func byName(_ a: TagInventory.Entry, _ b: TagInventory.Entry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: Changes

    public func renamePlan(_ entry: TagInventory.Entry, to typed: String) -> TagChangePlan? {
        inventory.renamePlan(entry.name, to: typed)
    }

    public func mergePlan(_ entries: [TagInventory.Entry], into typed: String) -> TagChangePlan? {
        inventory.mergePlan(entries.map(\.name), into: typed)
    }

    public func removePlan(_ entries: [TagInventory.Entry]) -> TagChangePlan? {
        inventory.removePlan(entries.map(\.name))
    }

    /// The existing tag a typed name would merge into, other than `except`: the sheets say so before the user
    /// confirms.
    public func existingTag(named typed: String, except: [TagInventory.Entry] = []) -> TagInventory.Entry? {
        guard let entry = inventory.entry(for: typed), !except.contains(where: { $0.id == entry.id }) else { return nil }
        return entry
    }

    /// Runs one change through the app's writer. One at a time: a second request while one runs is refused, so a
    /// double click never applies a plan twice or a plan made against an inventory the first one changed.
    @discardableResult
    public func perform(_ plan: TagChangePlan) async -> Outcome? {
        guard !isWorking else { return nil }
        isWorking = true
        status = plan.summary(noun: noun) + "…"
        let outcome = await writer(plan)
        isWorking = false
        status = Self.statusLine(plan, outcome, noun: noun)
        // The result stays selected: the target of a rename or merge, nothing after a remove. `update` drops it
        // again if the writer saved nothing.
        if outcome.changed > 0 {
            selection.subtract(plan.sourceKeys)
            if let target = plan.target { selection.insert(tagKey(target)) }
        }
        return outcome
    }

    static func statusLine(_ plan: TagChangePlan, _ outcome: Outcome, noun: TagNoun) -> String {
        let quoted = plan.sources.count == 1 ? "“\(plan.sources[0])”" : "\(plan.sources.count) tags"
        let done: String
        switch plan.kind {
        case .rename: done = "Renamed \(quoted) to “\(plan.target ?? "")” on \(noun.count(outcome.changed))."
        case .merge: done = "Merged \(quoted) into “\(plan.target ?? "")” on \(noun.count(outcome.changed))."
        case .remove: done = "Removed \(quoted) from \(noun.count(outcome.changed))."
        }
        guard outcome.failed > 0 else { return done }
        return done + " \(noun.count(outcome.failed).capitalizedFirst) could not be saved."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
