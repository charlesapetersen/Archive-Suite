import SwiftUI

/// While a page waits for the Claude plan's usage window (`LocalAgentClient.usageWindowPause`), says the run is paused
/// and when it goes on (W41.app-claude-plan-reading). The wait is inside a page's call, so nothing else updates the
/// status line meanwhile; this checks every 15 seconds. Draws nothing when no page is waiting.
struct PlanPauseCaption: View {
    var pause: UsageWindowPause = LocalAgentClient.usageWindowPause

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let message = pause.message(now: context.date) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.ocr.planPause")
            }
        }
    }
}
