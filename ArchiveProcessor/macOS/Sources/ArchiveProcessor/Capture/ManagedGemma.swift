import ArchiveCore
import Combine
import Foundation

/// Offers and downloads the pinned label reader after consent. `LocalModelSupervisor` installs and runs it
/// (W49.proc-local-model-supervisor); this keeps what the operator sees: the offer, the download's progress and a
/// failed read's notice.
@MainActor
final class ManagedGemma: ObservableObject {
    static let shared = ManagedGemma()
    static let model = LocalModelSupervisor.gemma3_12b
    static let sizeNote = "About 8 GB to download, 10 GB of disk space with its software, and 9 GB of memory while reading."
    static let requirements = "The app's download needs an Apple silicon Mac with at least 16 GB of memory."
    static var supported: Bool {
#if arch(arm64)
        ProcessInfo.processInfo.physicalMemory >= 16 * 1024 * 1024 * 1024
#else
        false
#endif
    }

    private static let offerSeenKey = "managedGemmaOfferSeen"

    @Published private(set) var offerVisible = false
    @Published private(set) var installStatus: String?
    @Published private(set) var runtimeStatus: String?
    @Published private(set) var installed: Bool
    private(set) var installing = false
    private var installation: Task<Void, Never>?
    private let supervisor: LocalModelSupervisor
    private var nextStart = Date.distantPast
    private var stopGeneration = 0

    private init(supervisor: LocalModelSupervisor = .shared) {
        self.supervisor = supervisor
        installed = supervisor.isInstalled(Self.model)
    }

    func offerIfNeeded() {
        guard Self.supported, ContainerLabelCapture.enabled, !installed, !installing, !offerVisible,
              !KeychainHelper.isHeadlessTestMode, !UserDefaults.standard.bool(forKey: Self.offerSeenKey) else { return }
        offerVisible = true
    }

#if DEBUG
    func showOfferForUITest() {
        if KeychainHelper.isHeadlessTestMode { offerVisible = true }
    }
#endif

    func dismissOffer() {
        if !KeychainHelper.isHeadlessTestMode { UserDefaults.standard.set(true, forKey: Self.offerSeenKey) }
        offerVisible = false
    }

    func download() {
        guard Self.supported, ContainerLabelCapture.enabled, (!installed || runtimeStatus != nil), !installing,
              !KeychainHelper.isHeadlessTestMode else { return }
        dismissOffer()
        installing = true
        installStatus = "Preparing the local label reader…"
        installation = Task {
            defer { installation = nil }
            do {
                try await supervisor.install(Self.model) { [weak self] step in
                    self?.installStatus = switch step {
                    case .software: "Installing the local reader’s software…"
                    case .model: "Downloading Gemma 3 12B (about 8 GB)…"
                    }
                }
                installing = false
                installed = true
                nextStart = .distantPast
                runtimeStatus = nil
                installStatus = nil
            } catch {
                installing = false
                installStatus = Task.isCancelled ? "Download paused. Resume it in Settings → Capture."
                    : Self.installFailure(error)
            }
        }
    }

    func dismissStatus() {
        if !installing { installStatus = nil }
    }

    func pauseDownload() { installation?.cancel() }

    /// The label reader was turned off, or the app is quitting: stop the download and the loaded model.
    func stop() {
        stopGeneration += 1
        nextStart = .distantPast
        pauseDownload()
        supervisor.evict(Self.model)
        offerVisible = false
    }

    private static func installFailure(_ error: Error) -> String {
        let reason: String
        switch error as? LocalModelSupervisor.Failure {
        case .runtime, .installer: reason = "The label reader installer could not be prepared."
        case .software: reason = "The local reader's software could not be installed."
        case .model: reason = "The Gemma model could not be downloaded."
        default: reason = "The local label reader could not be set up."
        }
        return reason + " Check your connection and free disk space, then try again in Settings → Capture."
    }

    func read(jpeg: Data) async -> String? {
        guard installed, !installing, ContainerLabelCapture.enabled, Self.supported, !KeychainHelper.isHeadlessTestMode,
              !NetworkSession.testTransportIsActive, !Task.isCancelled, Date() >= nextStart else { return nil }
        let generation = stopGeneration
        do {
            // Asked again once the read has its turn: the reader may have been turned off or set up again meanwhile,
            // or a read before this one failed.
            let text = try await supervisor.read(Self.model, image: jpeg, prompt: ContainerLabelReader.localModelPrompt,
                                                 maxTokens: ContainerLabelGemma.maxTokens,
                                                 timeout: ContainerLabelGemma.timeout) { [unowned self] in
                generation == stopGeneration && installed && !installing && ContainerLabelCapture.enabled
                    && Date() >= nextStart
            }
            runtimeStatus = nil
            return text
        } catch {
            if generation == stopGeneration, !Task.isCancelled, !(error is CancellationError),
               error as? LocalModelSupervisor.Failure != .stopped {
                nextStart = Date().addingTimeInterval(ContainerLabelGemma.rememberFor)
                runtimeStatus = "Gemma could not complete a read on this Mac. You can retry its setup here."
            }
            return nil
        }
    }
}
