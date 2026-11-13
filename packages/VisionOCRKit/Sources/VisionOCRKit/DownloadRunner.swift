import Combine
import Foundation

// Moved out of SettingsView.swift into the engine (W42.int-s1): ModelDownloads names it, and the
// package carries no screens.

/// The accurate mode's downloads (`ModelDownloads`), one item at a time, kept outside the panel
/// so that closing Settings neither stops them nor lets a second copy of one start beside it.
@MainActor
final class DownloadRunner: ObservableObject {
    static let shared = DownloadRunner()
    private let timing: TimingRunner
    private var readersToTime: Set<Prefs.AccurateReader> = []

    init(timing: TimingRunner? = nil) { self.timing = timing ?? .shared }

    /// What is downloading, and how far it has got, 0...1.
    @Published private(set) var current: ModelDownloads.Item?
    @Published private(set) var fraction = 0.0
    /// What the download is doing, or how the last one ended; nil before any.
    @Published private(set) var status: String?
    /// The item the last download failed on, with why; cleared when one is started again.
    @Published private(set) var failed: (item: ModelDownloads.Item, why: String)?
    private var queue: [ModelDownloads.Item] = []
    private var task: Task<Void, Never>?
    /// Which run is current: a stopped one may take seconds to unwind (hashing a 1 GB file),
    /// and must neither report nor clear what a run started after it is doing.
    private var generation = 0
    private var swept = false

    func start(_ items: [ModelDownloads.Item], reader: Prefs.AccurateReader? = nil) {
        if let reader, !items.isEmpty { readersToTime.insert(reader) }
        for item in items where item != current && !queue.contains(item) { queue.append(item) }
        guard task == nil, !queue.isEmpty else { return }
        if !swept {
            ModelDownloads.sweep(home: ModelRuntime.home())
            swept = true
        }
        failed = nil
        generation += 1
        let mine = generation
        task = Task { await drain(mine) }
    }

    /// Stops at once, as far as the panel is concerned; nothing stopped is installed.
    func stop() {
        guard task != nil || !queue.isEmpty else { return }
        queue = []
        readersToTime = []
        task?.cancel()
        task = nil
        generation += 1
        if let current { status = "Stopped; \(current.name) was not installed." }
        current = nil
    }

    /// Whether every one of `items` is downloading or waiting to.
    func covers(_ items: [ModelDownloads.Item]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0 == current || queue.contains($0) }
    }

    private func drain(_ mine: Int) async {
        // The mode can be turned off where this panel cannot see it, by an imported settings file.
        while mine == generation, !queue.isEmpty, Prefs.store.bool(forKey: Prefs.accurateMode) {
            let item = queue.removeFirst()
            if item.installed() { continue }
            current = item
            fraction = 0
            status = "Downloading \(item.name), \(Self.size([item]))…"
            let total = Double(item.plan.bytes)
            do {
                try await ModelDownloads.install(item.plan, home: ModelRuntime.home(),
                                                 source: .current()) { bytes in
                    let f = min(1, Double(bytes) / total)
                    DispatchQueue.main.async {
                        let me = self
                        if me.generation == mine, f - me.fraction >= 0.005 || f == 1 { me.fraction = f }
                    }
                }
                guard mine == generation else { return }
                status = "Downloaded \(item.name)."
            } catch {
                // Stopped: `stop` has said so, and a later run may be under way.
                guard mine == generation else { return }
                // Readers already complete keep their check; `afterDownload` skips the one that
                // is still missing a part.
                queue = []
                let why = error.localizedDescription
                failed = (item, why)
                status = "\(item.name) could not be downloaded: \(why)."
            }
        }
        guard mine == generation else { return }
        queue = []
        current = nil
        task = nil
        let ready = readersToTime
        readersToTime = []
        // Only readers requested by this download: installing a shared part must not
        // re-time an unrelated reader that was already available on this Mac.
        for reader in Prefs.AccurateReader.downloadable where ready.contains(reader) {
            timing.afterDownload(reader)
        }
    }

    /// Why the last download of one of `items` failed, as a sentence; nil if none did.
    func failure(_ items: [ModelDownloads.Item]) -> String? {
        guard let failed, items.contains(failed.item) else { return nil }
        return "The last try failed: \(failed.why)."
    }

    /// The download size of `items`, as the table states it.
    nonisolated static func size(_ items: [ModelDownloads.Item]) -> String {
        let mb = items.reduce(0) { $0 + $1.downloadMB }
        return mb < 1000 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1000)
    }
}
