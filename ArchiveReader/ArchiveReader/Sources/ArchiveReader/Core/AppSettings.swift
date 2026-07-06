import Foundation

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

    static var warnNearDuplicateTags: Bool { bool(SettingsKey.warnNearDuplicate, true) }

    static var defaultReadFilter: ReadFilter {
        ReadFilter(rawValue: d.string(forKey: SettingsKey.readFilterDefault) ?? "") ?? .all
    }

    static var defaultSubjectCombine: SubjectCombine {
        bool(SettingsKey.subjectCombineAny, false) ? .any : .all
    }
}
