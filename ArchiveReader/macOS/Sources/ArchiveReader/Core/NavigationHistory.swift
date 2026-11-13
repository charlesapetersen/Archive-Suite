import Foundation

/// W40.reader-back-forward (owner, 2026-11-13): Go ▸ Back and Forward (⌘[ / ⌘]), as in Finder and Preview. One
/// history per window: the document window's and the preview sheet's page jumps, the navigation window's folders.
///
/// The window records the place it is LEAVING each time a jump takes it somewhere else; going back returns to the
/// last such place and puts the place left on the forward list, so Forward retraces it. A new jump after going back
/// drops the forward list, as a browser does. A place that no longer exists (a deleted smart folder, a file no
/// longer open) is skipped when stepped to, never shown. UI-free so the rules are unit-tested.
struct NavigationHistory<Entry> {
    private(set) var back: [Entry] = []
    private(set) var forward: [Entry] = []
    /// The places kept behind; the oldest go first.
    let limit: Int

    init(limit: Int = 100) { self.limit = max(1, limit) }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// A jump left `place`: it becomes the place Back returns to, and the forward list ends.
    mutating func record(leaving place: Entry) {
        back.append(place)
        if back.count > limit { back.removeFirst(back.count - limit) }
        forward.removeAll()
    }

    /// The place before `current`, which goes on the forward list. Places `isAvailable` rejects are dropped on the
    /// way; `nil`, with nothing changed but the dropped places, when none is left.
    mutating func goBack(from current: Entry, isAvailable: (Entry) -> Bool = { _ in true }) -> Entry? {
        while let place = back.popLast() {
            guard isAvailable(place) else { continue }
            forward.append(current)
            return place
        }
        return nil
    }

    /// The place `goBack` left, which goes back on the back list.
    mutating func goForward(from current: Entry, isAvailable: (Entry) -> Bool = { _ in true }) -> Entry? {
        while let place = forward.popLast() {
            guard isAvailable(place) else { continue }
            back.append(current)
            return place
        }
        return nil
    }

    /// Forget the places that no longer exist, so Back and Forward are not offered for nothing.
    mutating func removeAll(where gone: (Entry) -> Bool) {
        back.removeAll(where: gone)
        forward.removeAll(where: gone)
    }

    mutating func clear() { back.removeAll(); forward.removeAll() }
}
