// UITestRelaunchArguments.swift — W49.notes-relaunch-args-flake: a UI test's harness arguments survive Restart and Switch.
//
// Restart and Switch relaunches through `NSWorkspace.openApplication`, and a sandboxed app's relaunch starts with no
// arguments at all: the configuration's `arguments` never reach the new process (measured in the VM guest, argc 1).
// So the relaunched app came up as a bare first launch, without `-ANUITestStorePath` or the bookmark suite, and
// `ChooseStoreFolderUITests` passed only when XCUITest's `activate()` started an instance of its own.
//
// A harness launch therefore saves its arguments in the app's own defaults just before the relaunch, and the next
// launch takes them, once, into the argument domain, where every harness check reads them as if they had been passed.
// Saved only by a launch that is itself a harness launch, and taken only within `maxAge`, so a normal launch never
// picks up a test's scratch store. DEBUG-only: Release has neither half.

#if DEBUG
import Foundation

enum UITestRelaunchArguments {
    static let key = "ANUITestRelaunchArguments"
    static let savedAtKey = "ANUITestRelaunchArgumentsSavedAt"
    /// The relaunch is started as the old instance quits; a handover older than this is left over, not ours.
    static let maxAge: TimeInterval = 60

    /// The arguments this launch was given, or handed over from the instance that relaunched it. Written only by
    /// `adoptIfHandedOver`, on the main thread, before anything reads it.
    nonisolated(unsafe) private(set) static var arguments: [String] = Array(CommandLine.arguments.dropFirst())

    /// The gate every UITest seam uses (`NoteEditorPane.isUITestHarness`).
    static var isHarnessLaunch: Bool { !(UserDefaults.standard.string(forKey: "ANUITestStorePath") ?? "").isEmpty }

    /// Before Restart and Switch's relaunch: save this launch's arguments, if it is a harness launch.
    static func saveForRelaunch(_ own: [String] = arguments, isHarnessLaunch: Bool = isHarnessLaunch,
                                defaults: UserDefaults = .standard, now: Date = Date()) {
        guard isHarnessLaunch, !own.isEmpty else { return }
        defaults.set(own, forKey: key)
        defaults.set(now.timeIntervalSince1970, forKey: savedAtKey)
    }

    /// First thing at launch: take a handover, if one is waiting, into the argument domain.
    static func adoptIfHandedOver() {
        guard let saved = take(own: arguments, defaults: .standard, now: Date()) else { return }
        install(saved, in: .standard)
        arguments = saved
    }

    /// The handed-over arguments this launch should use, if any. The handover is removed either way, and a launch
    /// that was given arguments of its own keeps them.
    static func take(own: [String], defaults: UserDefaults, now: Date) -> [String]? {
        guard let saved = defaults.stringArray(forKey: key) else { return nil }
        let savedAt = defaults.double(forKey: savedAtKey)
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: savedAtKey)
        guard own.isEmpty, !saved.isEmpty, abs(now.timeIntervalSince1970 - savedAt) <= maxAge else { return nil }
        return saved
    }

    /// Adds `arguments` to the argument domain, as if they had been passed on the command line.
    static func install(_ arguments: [String], in defaults: UserDefaults) {
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain.merge(argumentDomain(arguments)) { _, handedOver in handedOver }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// `-key value` pairs, as the argument domain reads a command line; a value stays a string.
    static func argumentDomain(_ arguments: [String]) -> [String: Any] {
        var domain: [String: Any] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index)
            if argument.hasPrefix("-"), argument.count > 1, next < arguments.endIndex {
                domain[String(argument.dropFirst())] = arguments[next]
                index = arguments.index(after: next)
            } else {
                index = next
            }
        }
        return domain
    }
}
#endif
