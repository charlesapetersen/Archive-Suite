import Combine
import Foundation

enum ClaudeCLIBilling: Sendable {
    case subscription
    case apiKey
    case unknown

    static func parse(status: String) -> Self {
        struct Status: Decodable {
            let loggedIn: Bool
            let authMethod: String?
            let apiProvider: String?
            let apiKeySource: String?
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: Data(status.utf8)),
              status.loggedIn, status.apiProvider == "firstParty" else { return .unknown }
        if status.authMethod == "api_key" || status.authMethod == "api_key_helper"
            || usesAPIKey(source: status.apiKeySource) { return .apiKey }
        return status.authMethod == "claude.ai" ? .subscription : .unknown
    }

    static func usesAPIKey(source: String?) -> Bool {
        switch source {
        case "/login managed key", "ANTHROPIC_API_KEY", "apiKeyHelper": return true
        default: return false
        }
    }

    static func binaryPath(tool: LocalAgentTool, override: String) -> String? {
        LocalAgentClient.resolveBinaryPath(tool: .claude, override: tool == .claude ? override : "")
    }

    static func binaryPath(_ defaults: UserDefaults = .standard) -> String? {
        let tool = defaults.string(forKey: DefaultsKeys.localAgentTool).flatMap(LocalAgentTool.init(rawValue:)) ?? .claude
        return binaryPath(tool: tool, override: defaults.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? "")
    }

    static func detect(binary: String) async -> Self {
        let result = await LocalAgentClient.runAsync(binaryPath: binary, args: ["auth", "status", "--json"],
                                                     stdinText: "", timeout: 5,
                                                     currentDirectory: LocalAgentClient.claudeWorkingDirectory,
                                                     unsetEnvironment: LocalAgentClient.claudeAPICredentialVariables)
        guard result.exitCode == 0, !result.cancelled, !result.timedOut else { return .unknown }
        return parse(status: result.stdout)
    }
}

/// Sign-in category and reported usage, kept in memory per executable. Raw auth output is never retained or shown.
@MainActor
final class ClaudeCLIUsage: ObservableObject {
    static let shared = ClaudeCLIUsage()

    @Published private var methods: [String: ClaudeCLIBilling] = [:]
    @Published private var apiUSD: [String: Double] = [:]
    private var checkedAt: [String: Date] = [:]
    private var checks: [String: Task<ClaudeCLIBilling, Never>] = [:]

    func refresh(config: LocalAgentConfig?) async -> ClaudeCLIBilling {
        guard let config, config.tool == .claude else { return .unknown }
        return await refresh(binary: ClaudeCLIBilling.binaryPath(tool: config.tool, override: config.binaryPath), force: true)
    }

    func billing(for binary: String?) -> ClaudeCLIBilling {
        binary.flatMap { methods[$0] } ?? .unknown
    }

    @discardableResult
    func refresh(binary: String?, force: Bool = false) async -> ClaudeCLIBilling {
        guard let binary else { return .unknown }
        if let check = checks[binary] { return await check.value }
        if !force, let checkedAt = checkedAt[binary], Date().timeIntervalSince(checkedAt) < 30 {
            return billing(for: binary)
        }
        let check = Task { await ClaudeCLIBilling.detect(binary: binary) }
        checks[binary] = check
        let billing = await check.value
        if methods[binary] != billing { methods[binary] = billing }
        checkedAt[binary] = Date()
        checks[binary] = nil
        return billing
    }

    func reportAPIUsage(_ usd: Double?, binary: String) {
        guard let usd, usd.isFinite, usd >= 0 else { return }
        apiUSD[binary, default: 0] += usd
    }

    func costHeadline(binary: String?, tool: LocalAgentTool) -> String {
        switch tool == .claude ? billing(for: binary) : .subscription {
        case .subscription: return "Included in your subscription — usage limits apply."
        case .apiKey: return "Claude Code bills its API key."
        case .unknown: return "Claude Code billing could not be confirmed."
        }
    }

    func costDetail(binary: String?, tool: LocalAgentTool) -> String {
        switch tool == .claude ? billing(for: binary) : .subscription {
        case .subscription:
            return "The \(tool.displayName) CLI uses your subscription. If you hit its usage limit, the app paces and resumes when it resets."
        case .apiKey:
            if let usd = binary.flatMap({ apiUSD[$0] }) {
                return "Claude Code reports \(CostEstimate.money(usd)) in API usage since this app opened. Your Anthropic bill may differ."
            }
            return "Charges depend on the model and tokens used. The app shows the cost Claude Code reports after requests finish."
        case .unknown:
            return "Check the sign-in with claude auth status. Requests may incur charges."
        }
    }
}
