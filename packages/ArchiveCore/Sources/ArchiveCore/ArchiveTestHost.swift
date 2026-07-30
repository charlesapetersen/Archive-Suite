// ArchiveTestHost.swift — screen-safety for app-hosted unit tests (ArchiveCore)

import Foundation
#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// Keeps an **app-hosted unit-test run** off whatever display is attached.
///
/// `ArchiveReaderTests` / `ArchiveNotesTests` are `bundle.unit-test` targets that depend on their app
/// target, so XcodeGen emits `TEST_HOST = …/<App>.app/Contents/MacOS/<App>` + `BUNDLE_LOADER`. That is
/// how `@testable import` reaches the app's symbols — and it means every
/// `xcodebuild test -only-testing:<App>Tests` **launches the real app**. Historically the app then
/// opened its `Window` scenes, took focus, and sat on the owner's screen for the whole suite
/// (measured 2026-07-30 from the health gate's `.xcresult`: Reader **2m52s** / 211 tests,
/// Notes **49s** / 709 tests).
///
/// The unattended daemon runs those suites on nearly every session, so this was the single largest
/// source of "the daemon took over my screen". A unit suite gains nothing from being visible — real
/// GUI verification belongs in the headless Tart VM (`ops/gui/vm-gui-runner.sh`, off-screen). So when
/// the process is running purely as a unit-test host, the app shows nothing.
public enum ArchiveTestHost {
    /// True when this process was launched by XCTest as a **unit-test host** (bundle injection).
    ///
    /// `XCTestConfigurationFilePath` is exported by XCTest only into the host process it injects the
    /// unit bundle into. A UITest target's app-under-test is launched separately by `XCUIApplication`
    /// and does **not** inherit it — so UITests (which must render, in the VM) are unaffected by every
    /// suppression keyed off this flag.
    public static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    #if canImport(AppKit)
    /// Call once from the `App`'s `init()`, before any scene is built.
    ///
    /// `.prohibited` drops the Dock icon and makes the process ineligible to activate, so it can never
    /// pull focus from the owner's work. It does **not**, on its own, stop a `Window` scene from being
    /// ordered in — that is what `HiddenWindowStub` (below) is for. Both halves are asserted by
    /// `TestHostWindowSuppressionTests` in each app's unit suite.
    @MainActor public static func suppressWindowsIfUnitTestHost() {
        guard isUnitTestHost else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Stand-in content for a `Window` scene that would otherwise auto-open at launch. Hides its host
    /// window the instant the view is attached — before SwiftUI's own ordering settles.
    ///
    /// Deliberately `orderOut(_:)`, **never** `close()`: closing the last window can trip
    /// `applicationShouldTerminateAfterLastWindowClosed` and kill the process out from under the test
    /// run. Ordering out just takes it off-screen; the window object stays alive and harmless.
    ///
    /// `SceneBuilder` has no `buildEither`, so the app/test branch cannot live at the scene level —
    /// it has to be here, in the `ViewBuilder` content, which does support conditionals.
    public struct HiddenWindowStub: NSViewRepresentable {
        public init() {}

        public func makeNSView(context: Context) -> NSView { HidingView() }
        public func updateNSView(_ nsView: NSView, context: Context) {}

        private final class HidingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                hide()
                // Second pass on the next runloop turn: SwiftUI may order the window in *after* the
                // content view is attached, which would undo the synchronous hide above.
                DispatchQueue.main.async { [weak self] in self?.hide() }
            }

            private func hide() {
                guard let window else { return }
                window.alphaValue = 0          // belt-and-braces against a single-frame flash
                window.orderOut(nil)
            }
        }
    }
    #endif
}
