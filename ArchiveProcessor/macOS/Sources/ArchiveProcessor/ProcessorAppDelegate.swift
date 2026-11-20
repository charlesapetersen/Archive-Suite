import AppKit

/// W49.proc-resume-standard-runs: a quit while a Files run works. The run's finished pages are already in its
/// manifest, so Resume Run continues after relaunch either way; what a quit can still lose is the pages being read at
/// that moment, which would be read (and paid for) again. So it offers to wait for them first.
final class ProcessorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        OCRProcessor.quitApp = { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if OCRProcessor.quitApproved { return .terminateNow }
        let running = OCRProcessor.processorsStillRunning
        guard !running.isEmpty else { return .terminateNow }
#if DEBUG
        // A headless test launch has no one to answer; its scripts end it with a signal anyway.
        if ProcessInfo.processInfo.environment["ARCHIVEPROC_HEADLESS"] == "1" { return .terminateNow }
#endif
        let canWait = running.allSatisfy(\.ocrPhaseActive)
        let alert = NSAlert()
        alert.messageText = "A run is still processing files"
        if canWait {
            alert.informativeText = "The pages read so far are saved: after you open the app again, Resume Run "
                + "continues from the first page not finished. Quitting now loses the pages being read at this "
                + "moment, which would be read (and paid for) again."
            alert.addButton(withTitle: "Quit When Pages Are Saved")
            alert.addButton(withTitle: "Quit Now")
        } else {
            alert.informativeText = "The pages read so far are saved: after you open the app again, Resume Run "
                + "continues the run without reading them again. The step it is in now starts over, and a page "
                + "being read at this moment may be read again."
            alert.addButton(withTitle: "Quit")
        }
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        switch (canWait, answer) {
        case (true, .alertFirstButtonReturn):
            // The run went on while the alert was up, so its OCR pass may have ended meanwhile. Then there is nothing
            // to wait for, and the question is asked again as it now stands rather than answered by a wait that never
            // comes.
            running.forEach { $0.beginQuitWhenPagesSaved() }
            guard running.allSatisfy(\.quitWhenPagesSaved) else {
                running.forEach { $0.quitWhenPagesSaved = false }
                return applicationShouldTerminate(sender)
            }
            return .terminateCancel
        case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn):
            // Stop first, as the Stop button does: the manifest stays, and what was read goes into the ledger.
            running.forEach { $0.cancel() }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
