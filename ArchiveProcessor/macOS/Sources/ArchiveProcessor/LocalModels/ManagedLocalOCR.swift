import Combine
import Foundation

/// W49.proc-managed-local-ocr — the page readers the app downloads and runs itself, with no server to install. The
/// curated set is the local route's measured picks (`LocalModelRoute.picks`), each pinned to the revision the bench
/// read: Qwen3.5 9B (91.95 NES on the owner's 96, the best reader measured on a Mac) and Qwen3-VL 8B (89.68), against
/// Apple Vision's 83.07. Gemma 3 12B is not offered: it read the 96 at 52.5 (`segbench-results/ocr-gemma3-12b.md`).
/// The raw value is stored in `DefaultsKeys.gatewayManagedModel`.
enum ManagedOCRModel: String, CaseIterable, Identifiable, Sendable {
    case qwen35_9B = "mlx-community/Qwen3.5-9B-4bit"
    case qwen3VL8B = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
    case lightOnOCR3_4B = "prithivMLmods/LightOnOCR-3-4B-MLX/8bit"

    var id: String { rawValue }
    /// For accessibility identifiers.
    var shortID: String {
        switch self {
        case .qwen35_9B: "qwen35-9b"
        case .qwen3VL8B: "qwen3vl-8b"
        case .lightOnOCR3_4B: "lightonocr3-4b"
        }
    }

    /// The address a managed gateway carries. Nothing is sent to it: the supervisor gives each request its worker's.
    static let baseURL = "app-managed://this-mac"

    var pick: LocalModelRoute.Pick {
        switch self {
        case .qwen35_9B: LocalModelRoute.qwen35_9B4
        case .qwen3VL8B: LocalModelRoute.qwen3VL8B4
        case .lightOnOCR3_4B: LocalModelRoute.lightOnOCR3_4B8
        }
    }

    /// Revisions as `ocr_mac_local.py` and `rotation_routes.py` read them; peaks the whole process's on the 18 GB M3
    /// Pro (`ocr-mac-local*.md`, 99 full pages; in-app 4-line scratch proofs peaked at 7.95 GB for Qwen3.5 9B,
    /// 7.71 GB for Qwen3-VL 8B, and 7.24 GB for LightOnOCR-3 4B); downloads measured on this Mac (Qwen3.5 9B: 5.98 GB /
    /// 5.57 GiB, W49.proc-managed-ocr-9b-check; Qwen3-VL 8B: 5.8 GB / 5.4 GiB; LightOnOCR-3 4B 8-bit: 5.16 GB / 4.81 GiB,
    /// W49.proc-kind-split-mac-fu).
    var model: LocalModelSupervisor.Model {
        switch self {
        case .qwen35_9B:
            LocalModelSupervisor.Model(name: "Qwen3.5 9B", repo: rawValue,
                                       revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53", peakGB: 9.1, downloadGB: 6.0)
        case .qwen3VL8B:
            LocalModelSupervisor.Model(name: "Qwen3-VL 8B", repo: rawValue,
                                       revision: "defcdea7cc7a4b0858fea563cbbce171d328e457", peakGB: 8.4, downloadGB: 5.8)
        case .lightOnOCR3_4B:
            LocalModelSupervisor.Model(name: "LightOnOCR-3 4B", repo: "prithivMLmods/LightOnOCR-3-4B-MLX",
                                       revision: "e93084acf44a380776866b23b122f48fe47cab7f", peakGB: 7.9, downloadGB: 5.2,
                                       subpath: "8bit")
        }
    }

    /// Plain words for the first-run interview (W49.proc-local-ocr-onboarding), from the scores in this type's header.
    var plainNote: String {
        switch self {
        case .qwen35_9B:
            "The most accurate reader measured on a Mac: it scored 92 out of 100 on the app's test pages, against Apple "
                + "Vision's 83. Handwriting still reads better with an online reader."
        case .qwen3VL8B:
            "Close behind at 90 out of 100 on the same pages, but it gives up on more of them."
        case .lightOnOCR3_4B:
            "The best handwriting reader measured on a Mac (90 out of 100 on handwritten test pages, 89 overall, 0 "
                + "failed), with a smaller download and memory footprint."
        }
    }

    /// The shared software (uv, Python and mlx-vlm), measured: about 1.3 GB, once for every model.
    static let softwareGB = 1.3

    /// What it needs, said before the download starts.
    var sizeNote: String {
        let m = model
        return "About \(Self.gb(m.downloadGB)) GB to download and \(Self.gb(m.downloadGB + Self.softwareGB)) GB of disk "
            + "space with its software (less if another model is installed), and \(Self.gb(m.peakGB)) GB of memory while "
            + "reading, about \(Int(pick.secondsPerPage.rounded())) s a page."
    }

    private static func gb(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The models this Mac can run, recommended first; none below 16 GB, or on an Intel Mac.
    static func offered(memoryGB: Double? = nil) -> [ManagedOCRModel] {
        guard ManagedGemma.supportedArchitecture else { return [] }
#if DEBUG
        let memoryGB = memoryGB ?? ProcessorUITestConfiguration.managedOCRMemoryGB ?? LocalModelRoute.thisMacMemoryGB
#else
        let memoryGB = memoryGB ?? LocalModelRoute.thisMacMemoryGB
#endif
        return LocalModelRoute.picks(memoryGB: memoryGB).compactMap { p in allCases.first { $0.pick == p } }
    }

    static func stored(_ d: UserDefaults = .standard) -> ManagedOCRModel? {
        ManagedOCRModel(rawValue: d.string(forKey: DefaultsKeys.gatewayManagedModel) ?? "")
    }

    /// W49.proc-managed-mac-image-calls — the Mac's page-image calls to Qwen3-VL 8B (the date search in
    /// `DateRoute.runLocal`, the image half of `ItemFieldExtractor`'s `.mac` call). With the app's own copy installed,
    /// the request goes to its worker through `LocalModelSupervisor.withEndpoint` (its secret, one model loaded, one
    /// request at a time); otherwise to the mlx-vlm server at the request's own address, as before. The body and its
    /// limits are the caller's either way. A managed failure throws, which the callers read as no reply.
    static func sendImageCall(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let supervisor = await LocalModelSupervisor.serving
        let model = qwen3VL8B.model
        guard await supervisor.isInstalled(model) else {
            return try await NetworkSession.data(for: request, policy: .nonIdempotent, maxRetries: 0, followRedirects: false)
        }
        return try await supervisor.withEndpoint(model) { url, secret in
            var pointed = request
            pointed.url = url
            pointed.setValue(secret, forHTTPHeaderField: "Authorization")
            return try await NetworkSession.data(for: pointed, policy: .nonIdempotent, maxRetries: 0, followRedirects: false)
        }
    }
}

/// The downloads, removals and failures the operator sees for the managed page readers. `LocalModelSupervisor` installs
/// and runs them; this keeps each one's state for Settings › Accounts.
@MainActor
final class ManagedLocalOCR: ObservableObject {
    static let shared = ManagedLocalOCR()

    enum State: Equatable {
        case notInstalled
        case installing(String, Double?)
        case failed(String)
        case installed
        case removing
    }

    @Published private(set) var states: [ManagedOCRModel: State] = [:]
    /// Models with a download's files left on disk but not installed (a cancel or a failure): Remove deletes them.
    @Published private(set) var partial: Set<ManagedOCRModel> = []
    private var installations: [ManagedOCRModel: Task<Void, Never>] = [:]
    private let supervisor: LocalModelSupervisor

    init(supervisor: LocalModelSupervisor = .shared) {
        self.supervisor = supervisor
        for m in ManagedOCRModel.allCases {
            states[m] = supervisor.isInstalled(m.model) ? .installed : .notInstalled
            if states[m] == .notInstalled, supervisor.downloadedBytes(m.model) > 0 { partial.insert(m) }
        }
    }

    func state(_ m: ManagedOCRModel) -> State { states[m] ?? .notInstalled }

    /// Downloads the model (and the shared software, if it is missing). Also the retry after a failure: the installer
    /// keeps what already arrived and fetches the rest.
    func download(_ m: ManagedOCRModel) {
        guard installations[m] == nil, state(m) != .removing, ManagedOCRModel.offered().contains(m) || KeychainHelper.isHeadlessTestMode else { return }
        states[m] = .installing("Preparing the download…", nil)
        installations[m] = Task {
            defer { installations[m] = nil }
            do {
#if DEBUG
                if ProcessorUITestConfiguration.standsInManagedDownload {
                    states[m] = .installing("Downloading \(m.model.name)…", 0)
                    try await Task.sleep(for: .seconds(24 * 3600))
                }
#endif
                try await supervisor.install(m.model) { step in
                    guard case .installing = self.states[m] else { return }
                    self.states[m] = switch step {
                    case .waiting: .installing("Waiting for another model’s download to finish…", nil)
                    case .software: .installing("Installing the reader’s software…", nil)
                    case .model(let share): .installing("Downloading \(m.model.name)…", share)
                    }
                }
                states[m] = .installed
                partial.remove(m)
            } catch {
                if supervisor.downloadedBytes(m.model) > 0 { partial.insert(m) }
                // A Reader chosen before its download finished (Local HD) is not left on a model that never arrived.
                let d = UserDefaults.standard
                if ManagedOCRModel.stored(d) == m, d.bool(forKey: DefaultsKeys.useGateway), !supervisor.isInstalled(m.model) {
                    ReaderChoice.appleVision.apply(d)
                }
                states[m] = Task.isCancelled || error is CancellationError
                    ? .failed("Download cancelled. What arrived is kept; Download again resumes it.")
                    : .failed(Self.failure(error))
            }
        }
    }

    func cancel(_ m: ManagedOCRModel) { installations[m]?.cancel() }

    /// Cancels every in-flight download task (e.g. on app termination, S-058).
    func cancelAll() { for m in Array(installations.keys) { installations[m]?.cancel() } }

    /// Removes the model's files. If it was the Reader, Apple Vision becomes the Reader, so a run never waits on a model
    /// that is gone.
    func remove(_ m: ManagedOCRModel, defaults d: UserDefaults = .standard) async {
        guard installations[m] == nil, state(m) != .removing else { return }
        let before = state(m)
        states[m] = .removing
        do {
            try await supervisor.remove(m.model)
            states[m] = .notInstalled
            partial.remove(m)
        } catch LocalModelSupervisor.Failure.installing {
            states[m] = before
            return
        } catch {
            states[m] = supervisor.isInstalled(m.model) ? before
                : .failed("The model could not be removed completely. Quit the app and try again.")
            if supervisor.isInstalled(m.model) { return }
        }
        if ManagedOCRModel.stored(d) == m {
            if d.bool(forKey: DefaultsKeys.useGateway) { ReaderChoice.appleVision.apply(d) }
            d.set("", forKey: DefaultsKeys.gatewayManagedModel)
        }
    }

    /// Makes the installed model the Reader.
    func use(_ m: ManagedOCRModel, defaults d: UserDefaults = .standard) {
        guard state(m) == .installed else { return }
        ReaderChoice.managed(m).apply(d)
    }

    private static func failure(_ error: Error) -> String {
        let reason = switch error as? LocalModelSupervisor.Failure {
        case .runtime, .installer: "The installer could not be prepared."
        case .software: "The reader's software could not be installed."
        case .model: "The model could not be downloaded."
        case .tooLarge: "The model needs more memory than this Mac can spare."
        default: "The model could not be set up."
        }
        return reason + " Check your connection and free disk space, then try again. Apple Vision still reads pages meanwhile."
    }
}
