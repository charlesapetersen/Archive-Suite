import Foundation

/// App-level registry of "flush my pending edit" closures, one per live editor pane (W7-S6).
///
/// Each `NoteEditorPane`'s body controller (`NoteBodyEditorModel`) autosaves on a ~600 ms debounce and
/// flushes on selection-switch / pane-teardown (`.onDisappear`). But a hard ⌘Q / app terminate does NOT
/// reliably fire SwiftUI's `.onDisappear`, so an edit made within the debounce window can be lost on
/// force-quit. `NotesAppDelegate.applicationShouldTerminate` awaits `flushAll()` (under a bounded timeout
/// — never deadlock quit) so every open editor persists its last keystrokes before the process exits.
///
/// The model is a per-pane `@StateObject` and thus not reachable app-level; this registry is the hoisted
/// handle both windows' panes register into. `@MainActor` — panes register/deregister from
/// `onAppear`/`onDisappear` and the delegate calls `flushAll()` on the main thread; the stored closures
/// are the panes' main-actor flush seams.
@MainActor
final class EditorFlushRegistry: ObservableObject {
    /// Keyed by a stable per-pane id so re-renders don't duplicate entries and a disappear removes
    /// exactly the pane that vanished (never a sibling window's still-live pane).
    private var handles: [UUID: () async -> Void] = [:]

    init() {}

    /// No pane has a live editor → the app can terminate immediately (nothing to persist).
    var isEmpty: Bool { handles.isEmpty }

    /// Register (or re-register — `onAppear` may fire more than once) a pane's flush closure. Idempotent
    /// for a given `id`: the same key is overwritten, never duplicated.
    func register(_ id: UUID, flush: @escaping () async -> Void) {
        handles[id] = flush
    }

    /// Remove a pane's flush closure (called from `.onDisappear` when its window/pane tears down), so a
    /// closed window's now-dead editor isn't flushed on a later quit.
    func deregister(_ id: UUID) {
        handles[id] = nil
    }

    /// Await every registered pending flush. Snapshotted first so a flush that (indirectly) triggers a
    /// deregistration can't mutate the dictionary mid-iteration. Serial: the underlying `NoteStore` is an
    /// actor, so concurrent flushes would serialize on it anyway, and there are at most two windows.
    func flushAll() async {
        let flushes = Array(handles.values)
        for flush in flushes {
            await flush()
        }
    }
}

/// Drives the `applicationShouldTerminate` reply for a bounded editor flush (W7-S6). Fires the injected
/// `reply` **exactly once** — as soon as the flush completes OR `timeout` elapses, whichever is first —
/// and, crucially, does NOT await a wedged flush before replying: the timeout path replies and lets the
/// app terminate independently of any stuck store write, so a force-quit can never deadlock on a flush.
///
/// The `reply` is the tail (`NSApp.reply(toApplicationShouldTerminate: true)`) but is injected so the
/// bound is unit-testable without `NSApp`. `@MainActor` — the once-guard and reply run on the main thread,
/// so the two racing tasks serialize on it (no data race on `fired`).
@MainActor
final class TerminateFlushCoordinator {
    private var fired = false
    private let reply: @MainActor () -> Void

    init(reply: @escaping @MainActor () -> Void) {
        self.reply = reply
    }

    /// Start the bounded flush. Two independent tasks race: one runs `flush` then replies; one sleeps
    /// `timeout` then replies. `fire()`'s once-guard means the loser's reply is a no-op — so a completed
    /// flush replies immediately (the normal case) while a stuck flush still lets quit proceed after
    /// `timeout`. The tasks capture `self` strongly, keeping the coordinator alive until they finish.
    func begin(flush: @escaping () async -> Void, timeout: Duration) {
        Task { @MainActor in
            await flush()
            self.fire()
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            self.fire()
        }
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        reply()
    }
}
