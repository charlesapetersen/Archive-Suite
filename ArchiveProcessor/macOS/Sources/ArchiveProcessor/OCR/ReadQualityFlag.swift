import Foundation

/// W46.post-read-quality-flag — "this page probably read poorly", said after processing. Two signals, each fitted
/// for at most 5% false alarms among readings at 70 NES or above (`ArchiveProcessor/segbench-results/post-read-flag.md`):
///
/// * a page Apple Vision read: Vision's own confidence, the mean of its line confidences, each line weighted by its
///   characters, fitted on the owner's 96 (in-sample 10 of 21 poor readings caught with 3 false alarms in 75;
///   cross-validated, the estimate for new pages, 46% caught at 5.8% false alarms, 87 in 1,500 pooled over repeats;
///   on the capture ladder's damaged photographs 155 of 207 poor answers with 7 false alarms in 249 good answers;
///   24 images produced no answer);
/// * W47.wh-read-flag-readers (owner, 2026-11-19, call 15): a page another reader read, its disagreement with Apple
///   Vision's reading of the same image, at that reader's own cut (`ReadQualityDisagreement`). A reader with no
///   measured cut is not flagged.
///
/// UI only (the run summary and the history); nothing is written to a file.
struct ReadQualityFlag: Codable, Equatable, Sendable {
    /// Vision's own reading: its character-weighted mean line confidence, 0-1. nil on another reader's flag.
    var visionConfidence: Double?
    /// Another reader's: 1 minus the similarity of its text to Apple Vision's reading of the same image (0 the same,
    /// 1 nothing alike or Vision read nothing). nil on Vision's own flag.
    var disagreement: Double? = nil
    /// The reader whose disagreement cut fired, and what that cut was measured on, for the run summary.
    var reader: String? = nil
    var measuredOn: String? = nil

    /// How far past its signal's cut this flag is: what picks the one a multi-page PDF keeps.
    var concern: Double {
        if let visionConfidence { return Self.flagBelow - visionConfidence }
        return disagreement ?? 0
    }

    /// Flag a reading whose weighted confidence is under this. Fitted by `post_read_flag.py report` (`app_rule`).
    static let flagBelow = 0.9815
    /// What that cut was measured on, in the run summary's words: fitted on the 96, applied once to the ladder.
    static let visionMeasuredOn = "96 plain photographs and 480 damaged copies of 48 of them"

    /// The character-weighted mean confidence of Vision's kept lines; nil when they hold no characters.
    static func weightedConfidence(_ lines: [(text: String, confidence: Float)]) -> Double? {
        let chars = lines.reduce(0) { $0 + $1.text.unicodeScalars.count }
        guard chars > 0 else { return nil }
        return lines.reduce(0.0) { $0 + Double($1.confidence) * Double($1.text.unicodeScalars.count) } / Double(chars)
    }

    /// The flag for a Vision reading made of these lines, or nil when it read confidently (or read nothing: that
    /// page already fails with its own message).
    static func assess(_ lines: [(text: String, confidence: Float)]) -> ReadQualityFlag? {
        guard let c = weightedConfidence(lines), c < flagBelow else { return nil }
        return ReadQualityFlag(visionConfidence: c)
    }

    /// Whether the cut applies under these settings: only those it was fitted with (the bench's `dewarp.swift`: accurate
    /// recognition with language correction, en-US, no minimum confidence). Fast recognition's confidences are
    /// coarser, and a minimum confidence drops the very lines the mean needs, so neither is flagged at all.
    static func applies(to settings: VisionOCRSettings) -> Bool {
        !settings.usesFastRecognition && settings.minimumConfidence == 0
            && settings.languages == VisionOCRSettings.default.languages
    }

    /// The flag a multi-page PDF keeps: its most concerning page's.
    static func worst(_ flags: [ReadQualityFlag]) -> ReadQualityFlag? {
        flags.max { $0.concern < $1.concern }
    }
}
