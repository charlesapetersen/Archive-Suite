import SwiftUI
import VisionOCRKit

/// W46.layout-newspapers — the newspaper detector's download, which the user starts (nothing is fetched at install): VisionOCRKit's
/// `NewspaperLayout.download`, checked against the size and SHA-256 the app carries and moved into place whole, so a cancel
/// or a bad file leaves nothing half installed. One download at a time for each detector.
@MainActor
final class NewspaperLayoutDownload: ObservableObject {
    static let shared = NewspaperLayoutDownload(isInstalled: { NewspaperLayout.isInstalled() },
                                                fetch: { try await NewspaperLayout.download(progress: $0) })
    /// W47.wh-yolo-scans: the scanned-newspaper detector (`ScanNewspaperLayout`), its own download.
    static let scans = NewspaperLayoutDownload(isInstalled: { ScanNewspaperLayout.isInstalled() },
                                               fetch: { try await ScanNewspaperLayout.download(progress: $0) })

    enum State: Equatable {
        case idle
        case fetching(Double)
        case failed(String)
        case installed
    }

    @Published private(set) var state: State
    private var task: Task<Void, Never>?
    private let isInstalled: () -> Bool
    private let fetch: (@escaping @Sendable (Double) -> Void) async throws -> Void
    /// Called once a download installs (W47.wh-mixed-preflag: the file list then reads its pages with the pre-flag).
    private let installed: () -> Void

    init(isInstalled: @escaping () -> Bool, fetch: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void,
         installed: @escaping () -> Void = {}) {
        self.isInstalled = isInstalled
        self.fetch = fetch
        self.installed = installed
        state = isInstalled() ? .installed : .idle
    }

    func start() {
        guard task == nil, state != .installed else { return }
        state = .fetching(0)
        task = Task { [weak self] in
            do {
                try await self?.fetch { share in
                    Task { @MainActor in
                        // A whole percent at a time: the fetch reports every chunk.
                        guard let self, case .fetching(let shown) = self.state, share - shown >= 0.01 else { return }
                        self.state = .fetching(share)
                    }
                }
                self?.finish(self?.isInstalled() == true ? .installed : .failed("the download did not install"))
            } catch is CancellationError {
                self?.finish(.idle)
            } catch {
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ state: State) {
        self.state = state
        task = nil
        if state == .installed { installed() }
    }
}

/// Under the layout rule on the settings sheet, while the detector is not downloaded.
struct NewspaperLayoutDownloadRow: View {
    @ObservedObject private var download = NewspaperLayoutDownload.shared

    var body: some View {
        HStack(spacing: 8) {
            switch download.state {
            case .idle:
                Button("Download the newspaper layout helper (\(NewspaperLayout.downloadMB) MB)") { download.start() }
            case .fetching(let share):
                ProgressView(value: share).frame(width: 160)
                Text("\(Int(share * 100))%").font(.caption).monospacedDigit()
                Button("Cancel") { download.cancel() }
            case .failed(let why):
                Text("The download failed: \(why).").font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { download.start() }
            case .installed:
                Text("The newspaper layout helper is downloaded.").font(.caption).foregroundStyle(.primary)
            }
        }
        .accessibilityIdentifier("ap.sheet.newspaperLayoutDownload")
    }
}

/// W47.wh-yolo-scans — under the scanned-newspaper switch while its detector is not downloaded. Its weights' licence is
/// shown before anything is fetched (owner, call 12): an AGPL-3.0 model is offered only as a separate download.
struct ScanNewspaperLayoutDownloadRow: View {
    @ObservedObject private var download = NewspaperLayoutDownload.scans

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                switch download.state {
                case .idle:
                    Button("Download the scanned-newspaper layout helper (\(ScanNewspaperLayout.downloadMB) MB)") { download.start() }
                case .fetching(let share):
                    ProgressView(value: share).frame(width: 160)
                    Text("\(Int(share * 100))%").font(.caption).monospacedDigit()
                    Button("Cancel") { download.cancel() }
                case .failed(let why):
                    Text("The download failed: \(why).").font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { download.start() }
                case .installed:
                    Text("The scanned-newspaper layout helper is downloaded.").font(.caption).foregroundStyle(.primary)
                }
            }
            Text("Licence: DocLayout-YOLO's weights (juliozhao/DocLayout-YOLO-DocStructBench-imgsz1280-2501) are "
                 + "\(ScanNewspaperLayout.licence). They are downloaded separately and are not part of the app.")
                .font(.caption2).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("ap.sheet.scanNewspaperLayoutDownload")
    }
}
