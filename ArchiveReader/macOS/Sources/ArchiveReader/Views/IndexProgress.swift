import SwiftUI

/// The index pass's count, published apart from `NavigationModel` (W40.fix-reader-selection-at-size): a pass ticks
/// many times a second, and on the model each tick re-ran every view that observes it, the list window and the
/// inspector included. Only the status bar's label observes this.
@MainActor
final class IndexProgress: ObservableObject {
    @Published var value: (done: Int, total: Int)?
}

/// The status bar's "Indexing n/m", the one view that redraws on each tick.
struct IndexingProgressLabel: View {
    @ObservedObject var progress: IndexProgress

    var body: some View {
        if let p = progress.value {
            ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 70)
            Text("Indexing \(p.done)/\(p.total)").foregroundStyle(.primary)
        }
    }
}
