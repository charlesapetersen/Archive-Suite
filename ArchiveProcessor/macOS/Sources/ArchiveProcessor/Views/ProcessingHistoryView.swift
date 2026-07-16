import SwiftUI

/// A simple, read-only log of completed Process-Files runs: when each ran, with which provider/model,
/// how many files succeeded/failed, and its estimator-derived cost. Backed by `ProcessingHistoryStore`
/// (JSON in UserDefaults — never the corpus). Presented as a sheet from the Tools tab.
///
/// The cost shown is the SAME per-model pricing math the pre-run estimator uses, applied to each run's
/// ACTUAL parameters (no provider returns per-call token usage) — a close estimate of real spend, not a
/// billed figure. The footnote says so.
struct ProcessingHistoryView: View {
    @ObservedObject private var store = ProcessingHistoryStore.shared
    let onDismiss: () -> Void

    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.runs.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.runs) { run in
                        ProcessingHistoryRow(run: run)
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Processing History").font(.title2).fontWeight(.bold)
                if !store.runs.isEmpty {
                    Text("\(store.runs.count) \(store.runs.count == 1 ? "run" : "runs") · \(store.totalFiles) files · \(Self.moneyTotal(store.totalCost)) est. total")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
            Text("No processing runs yet").font(.headline)
            Text("Completed Process-Files runs will appear here with their cost estimate.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack {
            Text("Cost is estimated from each run's settings using per-model pricing — a close estimate, not a billed figure.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(store.runs.isEmpty)
            .confirmationDialog("Clear all processing history?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { store.clear() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes the local run log only. It does not affect any files, output, or the archive.")
            }
        }
        .padding(16)
    }

    /// Aggregate total: two decimal places (cents) for a running sum across many runs.
    static func moneyTotal(_ v: Double) -> String { "$" + String(format: "%.2f", v) }
}

/// One row in the processing-history list: provider·model + date on the left, cost + file counts on the right.
private struct ProcessingHistoryRow: View {
    let run: ProcessingRun

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(run.providerLabel) · \(run.modelName)").font(.headline).lineLimit(1)
                    Text(run.modeLabel)
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.money(run.cost)).font(.headline).monospacedDigit()
                fileCounts
            }
        }
        .padding(.vertical, 4)
    }

    private var fileCounts: some View {
        HStack(spacing: 6) {
            Text("\(run.fileCount) \(run.fileCount == 1 ? "file" : "files")")
            if run.failed > 0 {
                Text("· \(run.succeeded) ✓  \(run.failed) ✗").foregroundStyle(.orange)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    /// Per-run cost: four decimal places, matching the pre-run cost-estimate pane's precision.
    static func money(_ v: Double) -> String { "$" + String(format: "%.4f", v) }
}
