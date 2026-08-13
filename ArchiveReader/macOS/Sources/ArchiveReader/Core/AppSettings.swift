import Foundation
import CoreGraphics

/// UserDefaults keys for user options (⌘,). Kept in one place so the Options UI and the models agree.
enum SettingsKey {
    static let linkFormat = "linkFormat"
    static let linkNewlines = "linkNewlines"
    static let copyCollapse = "copyCollapseSingleNewlines"
    static let copyParagraph = "copyParagraphOnBlankLine"
    static let copyDehyphenate = "copyDeHyphenate"
    static let viewerSplit = "viewerSplitFraction"
    static let subjectCombineAny = "subjectCombineAny"
    static let readFilterDefault = "readFilterDefault"
    static let warnNearDuplicate = "warnNearDuplicateTags"
    static let hiddenColumns = "ar.hiddenColumns"    // [String] — column IDs the user has hidden
    static let provenanceColumnPreferenceV1 = "ar.provenanceColumnPreferenceV1"
    // Document-viewer "last used becomes the default" layout (DV-1/DV-2): zoom per pane, window size.
    static let viewerLeftZoom = "viewerLeftZoom"     // scaleFactor; 0 = fit-to-pane
    static let viewerRightZoom = "viewerRightZoom"   // scaleFactor; 0 = fit-to-pane
    static let viewerWinW = "viewerWindowWidth"      // 0 = unset → open maximized
    static let viewerWinH = "viewerWindowHeight"
}

/// Read-side accessors the models consult at point of use, so changes in the Options window take
/// effect on the next action without any observation plumbing. Defaults match a fresh install.
enum AppSettings {
    private static var d: UserDefaults { .standard }
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    static var linkFormatter: FileLinkFormatter {
        let fmt = LinkFormat(rawValue: d.string(forKey: SettingsKey.linkFormat) ?? "") ?? .fileURL
        let n = d.object(forKey: SettingsKey.linkNewlines) as? Int ?? 1
        return FileLinkFormatter(format: fmt, newlinesBetweenLinks: n)
    }

    static var copyOptions: CopyTextOptions {
        CopyTextOptions(collapseSingleNewlines: bool(SettingsKey.copyCollapse, true),
                        paragraphOnBlankLine: bool(SettingsKey.copyParagraph, true),
                        deHyphenate: bool(SettingsKey.copyDehyphenate, true))
    }

    static var viewerSplitFraction: Double {
        let v = d.object(forKey: SettingsKey.viewerSplit) as? Double ?? 0.667
        return min(0.85, max(0.15, v))
    }
    /// The user's last-dragged splitter position becomes the default for the next viewer (DV-2).
    static func setViewerSplitFraction(_ v: Double) {
        d.set(min(0.85, max(0.15, v)), forKey: SettingsKey.viewerSplit)
    }

    /// Per-pane zoom that carries across cycling and becomes the next viewer's default (DV-2).
    /// `0` means "fit to pane" (the initial state). `key` is "left" or "right".
    static func viewerZoom(_ key: String) -> Double {
        d.double(forKey: key == "left" ? SettingsKey.viewerLeftZoom : SettingsKey.viewerRightZoom)
    }
    static func setViewerZoom(_ key: String, _ scale: Double) {
        d.set(scale, forKey: key == "left" ? SettingsKey.viewerLeftZoom : SettingsKey.viewerRightZoom)
    }

    /// Remembered document-window size (DV-1). `nil` when never resized → the window opens maximized.
    static var viewerWindowSize: CGSize? {
        let w = d.double(forKey: SettingsKey.viewerWinW), h = d.double(forKey: SettingsKey.viewerWinH)
        return (w > 200 && h > 200) ? CGSize(width: w, height: h) : nil
    }
    static func setViewerWindowSize(_ s: CGSize) {
        d.set(Double(s.width), forKey: SettingsKey.viewerWinW)
        d.set(Double(s.height), forKey: SettingsKey.viewerWinH)
    }

    static var hiddenColumns: Set<String> {
        hiddenColumns(in: d)
    }
    static func setHiddenColumns(_ hidden: Set<String>) {
        setHiddenColumns(hidden, in: d)
    }
    /// Migrate the new optional column into every pre-W18 layout once. The separate marker distinguishes
    /// an old saved layout from a user who subsequently chose to show every optional column.
    static func hiddenColumns(in defaults: UserDefaults) -> Set<String> {
        var hidden = Set(defaults.stringArray(forKey: SettingsKey.hiddenColumns) ?? [])
        if !defaults.bool(forKey: SettingsKey.provenanceColumnPreferenceV1) {
            hidden.insert("classification")
            defaults.set(Array(hidden).sorted(), forKey: SettingsKey.hiddenColumns)
            defaults.set(true, forKey: SettingsKey.provenanceColumnPreferenceV1)
        }
        return hidden
    }
    static func setHiddenColumns(_ hidden: Set<String>, in defaults: UserDefaults) {
        defaults.set(Array(hidden).sorted(), forKey: SettingsKey.hiddenColumns)
        defaults.set(true, forKey: SettingsKey.provenanceColumnPreferenceV1)
    }

    static var warnNearDuplicateTags: Bool { bool(SettingsKey.warnNearDuplicate, true) }

    static var defaultReadFilter: ReadFilter {
        ReadFilter(rawValue: d.string(forKey: SettingsKey.readFilterDefault) ?? "") ?? .all
    }

    static var defaultSubjectCombine: SubjectCombine {
        bool(SettingsKey.subjectCombineAny, false) ? .any : .all
    }
}
