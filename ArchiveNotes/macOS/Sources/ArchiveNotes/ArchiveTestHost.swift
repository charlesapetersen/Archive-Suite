// ArchiveTestHost.swift — screen-safety for Archive Notes' app-hosted unit tests

import Foundation
import AppKit
import SwiftUI

/// Keeps this app's unit-test host off whatever display is attached.
///
/// XcodeGen configures `ArchiveNotesTests` as an app-hosted unit bundle, so the actual Notes app
/// process launches for each `xcodebuild test -only-testing:ArchiveNotesTests`. The UI-specific
/// suppression stays in this app target: ArchiveCore is a UI-free shared domain package.
enum ArchiveTestHost {
    /// True only for the host process XCTest injects the unit bundle into, never the UITest app.
    static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Call once from the `App` initializer, before any scene is built.
    @MainActor static func suppressWindowsIfUnitTestHost() {
        guard isUnitTestHost else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Window-scene content that hides the auto-opening host window without closing the test process.
    struct HiddenWindowStub: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { HidingView() }
        func updateNSView(_ nsView: NSView, context: Context) {}

        private final class HidingView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                hide()
                // SwiftUI can order the window after attachment; repeat on the next turn.
                DispatchQueue.main.async { [weak self] in self?.hide() }
            }

            private func hide() {
                guard let window else { return }
                window.alphaValue = 0
                window.orderOut(nil)
            }
        }
    }
}
