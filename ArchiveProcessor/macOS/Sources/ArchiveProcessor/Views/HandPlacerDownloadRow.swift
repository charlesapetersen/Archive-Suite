import SwiftUI
import VisionOCRKit

/// W42.int-s5-hands — the hand placer's download, which the user starts (nothing is fetched at install): VisionOCRKit's
/// `HandPlacer.download`, checked against the size and SHA-256 the app carries and moved into place whole, so a cancel
/// or a bad file leaves nothing half installed. One download at a time for the whole app.
@MainActor
final class HandPlacerDownload: ObservableObject {
    static let shared = HandPlacerDownload()

    enum State: Equatable {
        case idle
        case fetching(Double)
        case failed(String)
        case installed
    }

    @Published private(set) var state: State
    private var task: Task<Void, Never>?

    init() { state = HandPlacer.isInstalled() ? .installed : .idle }

    func start() {
        guard task == nil, state != .installed else { return }
        state = .fetching(0)
        task = Task { [weak self] in
            do {
                try await HandPlacer.download { share in
                    Task { @MainActor in
                        // A whole percent at a time: the fetch reports every chunk.
                        guard let self, case .fetching(let shown) = self.state, share - shown >= 0.01 else { return }
                        self.state = .fetching(share)
                    }
                }
                self?.finish(HandPlacer.isInstalled() ? .installed : .failed("the download did not install"))
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
    }
}

/// Under the hand placement switch on the settings sheet, while the placer is not downloaded.
struct HandPlacerDownloadRow: View {
    @ObservedObject private var download = HandPlacerDownload.shared

    var body: some View {
        HStack(spacing: 8) {
            switch download.state {
            case .idle:
                Button("Download the handwriting placer (\(HandPlacer.downloadMB) MB)") { download.start() }
            case .fetching(let share):
                ProgressView(value: share).frame(width: 160)
                Text("\(Int(share * 100))%").font(.caption).monospacedDigit()
                Button("Cancel") { download.cancel() }
            case .failed(let why):
                Text("The download failed: \(why).").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { download.start() }
            case .installed:
                Text("The handwriting placer is downloaded.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("ap.sheet.handPlacerDownload")
    }
}
