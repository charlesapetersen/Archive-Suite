import Foundation

/// W46.post-read-quality-flag — "this page probably read poorly", said after processing, for a page Apple Vision read.
/// The signal is Vision's own confidence: the mean of its line confidences, each line weighted by its characters. The
/// cut was fitted on the owner's 96 for at most 5% false alarms among readings at 70 NES or above
/// (`ArchiveProcessor/segbench-results/post-read-flag.md`: in-sample 10 of 21 poor readings caught with 3 false alarms in
/// 75; cross-validated, the estimate for new pages, 46% caught at 5.8% false alarms, 87 in 1,500 pooled over repeats;
/// on the capture ladder's damaged photographs 179 of 231 with 7 in 249). No other
/// reader is flagged: disagreement with Vision did not hold the ceiling on damaged photographs, and no route returns
/// token probabilities. UI only (the run summary and the history); nothing is written to a file.
struct ReadQualityFlag: Codable, Equatable, Sendable {
    /// The reading's character-weighted mean line confidence, 0-1.
    let visionConfidence: Double

    /// Flag a reading whose weighted confidence is under this. Fitted by `post_read_flag.py report` (`app_rule`).
    static let flagBelow = 0.9815

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
}
