#if DEBUG // a test driver, compiled out of Release
import Foundation

/// W49.proc-suspects-messages (S-024): what the key row in Settings shows after the guided wizard's live check
/// passes and the Keychain refuses the key. Runs the wizard's own `recordUsableKey` and the row's own `keyChip`, with
/// the row's `hasKey` read as `SettingsAccountsPanel.reloadKeys` reads it (the Keychain, after `.apiKeyChanged`).
/// Headless mode is required: `KeychainHelper.save` then refuses every write, as a locked or denying Keychain does,
/// and nothing reads or writes the real Keychain. The flags go to a scratch defaults suite, never the app's own.
///
///   KEYWIZARD_TESTMODE=1 ARCHIVEPROC_HEADLESS=1 KEYWIZARD_OUT=<file> ArchiveProcessor
@MainActor
enum KeyWizardTestDriver {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["KEYWIZARD_TESTMODE"] == "1", let out = env["KEYWIZARD_OUT"] else { return }
        var lines: [String] = []
        defer { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        guard KeychainHelper.isHeadlessTestMode else { lines.append("ERROR: needs ARCHIVEPROC_HEADLESS"); return }
        let suite = "W49.proc-suspects-messages.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else { lines.append("ERROR: no scratch defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        for account in [LLMProvider.gemini.rawValue, LLMProvider.openai.rawValue] {
            let saved = KeychainHelper.save(account: account, password: "stand-in-key-\(account)")
            ProviderKeyWizard.recordUsableKey(account: account, key: "stand-in-key-\(account)", defaults: defaults)
            let field = KeychainHelper.load(account: account) ?? ""
            let chip = SettingsAccountsPanel.keyChip(account: account, hasKey: !field.isEmpty, defaults: defaults)
            lines.append("account=\(account)\tsave_returned=\(saved)\tfield_after_reload=\(field.isEmpty ? "empty" : "set")"
                         + "\tkeyValidated=\(defaults.bool(forKey: "keyValidated_\(account)"))\tchip=\(chip.rawValue)")
        }
    }
}
#endif
