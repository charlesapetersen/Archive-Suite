// ArchiveTestHost.swift — screen-safety for app-hosted unit tests across the suite (W49.core-ui-dedup).

import Foundation
import AppKit
import SwiftUI

/// Keeps an app's unit-test host off whatever display is attached.
///
/// XcodeGen configures app-hosted unit test bundles (`ArchiveReaderTests`, `ArchiveNotesTests`), so the app process
/// launches for each `xcodebuild test`. Keeping this in `ArchiveCoreUI` leaves `ArchiveCore` UI-free while sharing
/// one copy across apps.
public enum ArchiveTestHost {
    /// True only for the host process XCTest injects the unit bundle into, never the UITest app.
    public static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Call once from the `App` initializer, before any scene is built.
    @MainActor public static func suppressWindowsIfUnitTestHost() {
        guard isUnitTestHost else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// Window-scene content that hides the auto-opening host window without closing the test process.
    public struct HiddenWindowStub: NSViewRepresentable {
        public init() {}

        public func makeNSView(context: Context) -> NSView { HidingView() }
        public func updateNSView(_ nsView: NSView, context: Context) {}

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
