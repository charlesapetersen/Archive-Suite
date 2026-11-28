#if DEBUG // a test driver, compiled out of Release
import Foundation
import ArchiveCore
import CoreGraphics
import ImageIO
import PDFKit

/// Headless, key-free ($0) self-test of the dating route (W46.date-route), gated by `DATE_ROUTE_TEST=1`
/// (`scripts/test-date-route.sh`). No real network: every request goes to `NetworkSession.testTransport`, and the driver
/// stops before any call if that seam is not active. No Keychain read, no window, never the corpus: the end to end part
/// writes scratch images, PDFs and sidecars under a temporary folder and removes it.
///
///   1. The bench's cases (`segbench/fixtures/date-route-cases.json`, path in `DATE_ROUTE_CASES`; written by
///      `segbench/date_route_cases.py`): rule candidates and pick, the trace prompt byte for byte, the parsed reply, the
///      evidence check, the image reading and the route. `DATE_ROUTE_REAL_CASES` adds the same check on every
///      W46.date-route-pipeline document (the private bench cache; skipped when absent).
///   2. The decision on the tags and the sidecar object.
///   3. End to end through `performTaggingPhase` on scratch outputs: a remote gateway (the measured route, image pass on
///      the no-year documents only, then on every document with the switch on) and a direct key (no image pass).
///   4. W46.date-route-header: the `Date evidence:` header line, the rewrite of a generated PDF and its safe replace.
///   5. W46.date-route-other-paths: the manual tagging sheet's auto-date and the manual segment card take the route.
///   6. W46.date-route-other-paths: Live Capture's automatic tagging takes the route through the real ingest → finalize
///      path with the $0 OCR stand-in; the staging manifest keeps the decision for a regeneration.
private extension DateRoute.Decision {
    func with(measured: Bool) -> Self { var d = self; d.measured = measured; d.route = "r"; return d }
    /// The line for the decision's own date tags, as a document with no tagging-call date is given.
    var headerEvidence: String? { headerEvidence(giving: dateTags) }
}

@MainActor
enum DateRouteTestDriver {
    nonisolated static let envKey = "DATE_ROUTE_TEST"
    private static var didRun = false
    private static var lines: [String] = []
    private static var failures = 0

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        lines.append("\(ok ? "PASS" : "FAIL"): \(name)\(ok || detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        cases(path: env["DATE_ROUTE_CASES"], label: "1", required: true)
        if let real = env["DATE_ROUTE_REAL_CASES"], FileManager.default.fileExists(atPath: real) {
            cases(path: real, label: "1r", required: true, summarize: true)
        } else {
            lines.append("SKIP: 1r the pipeline's own documents (DATE_ROUTE_REAL_CASES not present)")
        }
        decision()
        await headerLine()
        await localImage()
        await endToEnd()
        await liveCapture()
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = env["DATE_ROUTE_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 1. The bench's cases

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber).map(\.intValue) }

    private static func cases(path: String?, label: String, required: Bool, summarize: Bool = false) {
        guard let path, let data = FileManager.default.contents(atPath: path),
              let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !all.isEmpty else {
            check("\(label) the bench's cases load", !required, path ?? "no path")
            return
        }
        var bad: [String: Int] = [:]
        var firstBad: [String: String] = [:]
        func note(_ part: String, _ id: String, _ ok: Bool, _ detail: String) {
            if summarize {
                if !ok { bad[part, default: 0] += 1; if firstBad[part] == nil { firstBad[part] = "\(id): \(detail)" } }
            } else {
                check("\(label) \(id): \(part)", ok, detail)
            }
        }
        for c in all {
            let id = c["id"] as? String ?? "?"
            let input = c["input"] as? [String: Any] ?? [:], want = c["expect"] as? [String: Any] ?? [:]
            let text = input["text"] as? String ?? ""
            let near = (input["near"] as? [[String: Any]] ?? []).map {
                DateRoute.Neighbour(label: $0["label"] as? String ?? "", dist: int($0["dist"]) ?? 0,
                                    text: $0["text"] as? String ?? "", file: nil)
            }
            let traceRaw = input["trace_raw"] as? String, imageRaw = input["image_raw"] as? String

            let cands = DateRoute.candidates(text)
            let got = cands.map {
                "\($0.year)|\($0.month.map(String.init) ?? "-")|\($0.kind)|\($0.lineNo)|\($0.line)|\($0.day.map(String.init) ?? "-")"
            }
            let wantC = (want["candidates"] as? [[Any]] ?? []).map { a in
                "\(int(a[0]) ?? -1)|\(int(a[1]).map(String.init) ?? "-")|\(a[2])|\(int(a[3]) ?? -1)|\(a[4])|"
                    + (a.count > 5 ? int(a[5]).map(String.init) ?? "-" : "?")
            }
            note("candidates", id, got == wantC, "got \(got.prefix(4)) want \(wantC.prefix(4))")
            let pick = DateRoute.rulePick(cands)
            let wp = want["pick"] as? [Any] ?? []
            note("rule pick", id, pick?.year == int(wp.first) && DateRoute.pickMonth(pick) == int(wp.last),
                 "got \(pick?.year ?? -1)/\(DateRoute.pickMonth(pick) ?? -1)")
            let prompt = DateRoute.tracePrompt(text: text, near: near)
            let wantPrompt = want["prompt"] as? String ?? ""
            note("trace prompt byte for byte", id, prompt == wantPrompt,
                 "first difference at \(zip(prompt, wantPrompt).prefix { $0 == $1 }.count)")
            let tr = DateRoute.parseTrace(traceRaw), wt = want["trace"] as? [String: Any] ?? [:]
            note("parsed reply", id, tr.parsed == (wt["parsed"] as? Bool) && tr.year == int(wt["year"])
                 && tr.lo == int(wt["lo"]) && tr.hi == int(wt["hi"]) && tr.uncertain == (wt["uncertain"] as? Bool),
                 "got \(tr)")
            let chk = tr.parsed ? DateRoute.evidenceCheck(year: tr.year, evidence: tr.evidence,
                                                          context: DateRoute.context(text: text, near: near))
                : DateRoute.Check(verdict: "none", reason: "unparsed")
            let wc = want["check"] as? [String] ?? []
            note("evidence check", id, [chk.verdict, chk.reason] == wc, "got \(chk) want \(wc)")
            var image: DateRoute.ImageReading? = nil
            if let imageRaw {
                let r = DateRoute.readImage(imageRaw)
                image = r
                let wi = want["image"] as? [String: Any] ?? [:]
                note("image reading", id, r.ok == (wi["ok"] as? Bool) && r.ownYear == int(wi["own"])
                     && r.secondRole.count == int(wi["stamps"]),
                     "got ok \(r.ok) own \(r.ownYear ?? -1) stamps \(r.secondRole.count)")
            }
            // The route is sent the image only where the text has no candidate, as the bench sent it.
            let sent = cands.isEmpty ? image : nil
            let d = DateRoute.decide(text: text, near: near, traceRaw: traceRaw, image: sent, imageNote: "")
            let wr = want["route"] as? [String: Any] ?? [:]
            note("route", id, d.year == int(wr["year"]) && d.evidenceClass.rawValue == wr["cls"] as? String
                 && d.step == int(wr["step"]) && d.dateUncertain == (wr["du"] as? Bool)
                 && d.month == int(wr["month"]) && d.day == int(wr["day"]),
                 "got \(d.year ?? -1)-\(d.month ?? -1)-\(d.day ?? -1) \(d.evidenceClass) \(d.step ?? -1) du \(d.dateUncertain) want \(wr)")
        }
        if summarize {
            for part in ["candidates", "rule pick", "trace prompt byte for byte", "parsed reply", "evidence check",
                         "image reading", "route"] {
                check("\(label) \(part) on the pipeline's \(all.count) documents", bad[part] == nil,
                      "\(bad[part] ?? 0) differ; first \(firstBad[part] ?? "")")
            }
        }
    }

    // MARK: 2. The decision on the tags and the sidecar

    private static func decision() {
        let near = [DateRoute.Neighbour(label: "P1", dist: 1, text: "Memo\nJune 2, 1957\nfile", file: "P1.pdf")]
        let letter = "Washington\nMarch 3, 1947\nDear Sir"
        let explicit = DateRoute.decide(text: letter, near: near, traceRaw: #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
                                        image: nil, imageNote: DateRoute.imageNotNeeded)
        var t = GeneratedTags(year: "1947", month: "3 March", day: "Day 3", dateUncertain: true)
        explicit.apply(to: &t)
        check("2 explicit text year: the tagging call's month and day kept when it read the same year, no flag",
              t.year == "1947" && t.month == "3 March" && t.day == "Day 3" && !t.dateUncertain)
        var t2 = GeneratedTags(year: "1950", month: "5 May", day: "Day 9")
        explicit.apply(to: &t2)
        check("2 explicit text year: another year's month and day replaced by the dated form's month and day",
              t2.year == "1947" && t2.month == "3 March" && t2.day == "Day 3", "\(t2.allTags)")
        // W46.date-full-date: the dated form's month wins over the tagging call's; its day is kept only for that month.
        let monthYear = DateRoute.decide(text: "Washington\nMarch 1947\nDear Sir", near: near, traceRaw: #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "March 1947"}}"#,
                                         image: nil, imageNote: DateRoute.imageNotNeeded)
        var t2a = GeneratedTags(year: "1947", month: "3 March", day: "Day 12")
        monthYear.apply(to: &t2a)
        var t2b = GeneratedTags(year: "1947", month: "4 April", day: "Day 12")
        monthYear.apply(to: &t2b)
        check("2 full date: a month-year form keeps the tagging call's day for the same month only",
              monthYear.month == 3 && monthYear.day == nil && t2a.month == "3 March" && t2a.day == "Day 12"
              && t2b.month == "3 March" && t2b.day == nil, "\(t2a.allTags) \(t2b.allTags)")
        let febYear = DateRoute.decide(text: "Memo\nFebruary 1950\nfile", near: near, traceRaw: #"{"year": 1950, "lo": 1950, "hi": 1950, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "February 1950"}}"#,
                                       image: nil, imageNote: DateRoute.imageNotNeeded)
        var t2e = GeneratedTags(year: "1950", month: "2 February", day: "Day 30")
        febYear.apply(to: &t2e)
        check("2 full date: the tagging call's day is dropped when the month does not have it (30 February)",
              t2e.month == "2 February" && t2e.day == nil, "\(t2e.allTags)")
        let yearOnly = DateRoute.decide(text: "Report for 1947\nfigures", near: near, traceRaw: #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "Report for 1947"}}"#,
                                        image: nil, imageNote: DateRoute.imageNotNeeded)
        var t2c = GeneratedTags(year: "1947", month: "6 June", day: "Day 2")
        yearOnly.apply(to: &t2c)
        var t2d = GeneratedTags(year: "1948", month: "6 June", day: "Day 2")
        yearOnly.apply(to: &t2d)
        check("2 full date: with no dated form, the tagging call's month and day only when it read the same year",
              t2c.month == "6 June" && t2c.day == "Day 2" && t2d.year == "1947" && t2d.month == nil && t2d.day == nil,
              "\(t2c.allTags) \(t2d.allTags)")
        var leap = DateRoute.monthDay(DateRoute.datedIn("Feb. 29, 1948", year: 1948))
        var noLeap = DateRoute.monthDay(DateRoute.datedIn("Feb. 29, 1949", year: 1949))
        check("2 full date: a day the month has (29 February 1948, not 1949)",
              leap.month == 2 && leap.day == 29 && noLeap.month == 2 && noLeap.day == nil)
        leap = DateRoute.monthDay(DateRoute.datedIn("4/31/62", year: 1962))
        noLeap = DateRoute.monthDay(DateRoute.datedIn("12/4/58", year: 1958))
        check("2 full date: a numeric date is month-first (12/4/58 is 4 December), 31 April has no day",
              leap.month == 4 && leap.day == nil && noLeap.month == 12 && noLeap.day == 4)
        // Owner, 2026-11-24 (W49.proc-pipeline-prune-ok 5): a collection whose numeric dates are day first.
        let us = DateRoute.monthDay(DateRoute.datedIn("Sent 04/07/1962.", year: 1962))
        let intl = DateRoute.$dayFirst.withValue(true) { DateRoute.monthDay(DateRoute.datedIn("Sent 04/07/1962.", year: 1962)) }
        let intlDay = DateRoute.$dayFirst.withValue(true) { DateRoute.monthDay(DateRoute.datedIn("Sent 25/12/1950.", year: 1950)) }
        let intlUS = DateRoute.$dayFirst.withValue(true) { DateRoute.monthDay(DateRoute.datedIn("Sent 12/25/1950.", year: 1950)) }
        check("2 numeric order: 04/07/1962 is 7 April month first and 4 July day first, a part over 12 the day either way",
              us.month == 4 && us.day == 7 && intl.month == 7 && intl.day == 4 && intlDay.month == 12 && intlDay.day == 25
                && intlUS.month == 12 && intlUS.day == 25, "\(us) \(intl) \(intlDay) \(intlUS)")
        let ocrIntl = DateRoute.$dayFirst.withValue(true) { DateRoute.ocrDated("dated 4 - 7 - 62", year: 1962) }
        check("2 numeric order: the OCR-damaged form follows it too", ocrIntl?.month == 7 && ocrIntl?.day == 4,
              "\(String(describing: ocrIntl))")
        check("2 numeric order: the image prompt says so only when day first",
              DateRoute.imagePromptForOrder == DateRoute.imagePrompt
                && DateRoute.$dayFirst.withValue(true) { DateRoute.imagePromptForOrder.contains("day first (DD/MM/YYYY)") })
        let orderValues = [SettingsKey.numericDatesDayFirst.rawValue: ResolvedSetting(value: .bool(true), layer: .collection)]
        check("2 numeric order: month first unless a layer sets day first",
              !DateRoute.dayFirstSetting(nil) && DateRoute.dayFirstSetting(orderValues)
                && SettingsKey.numericDatesDayFirst.allowed(in: .collection))
        liveRecordOrder(orderValues)
        let o = explicit.with(measured: true).sidecarObject()
        check("2 sidecar, explicit: class, step, the quote and its line", o["class"] as? String == "text"
              && o["step"] as? Int == 1 && o["quote"] as? String == "March 3, 1947" && o["line"] as? Int == 2
              && o["interval_90"] == nil && o["image_pass"] as? String == DateRoute.imageNotNeeded)

        let memo = "MEMO\nTo: Files"
        let est = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "lo": 1956, "hi": 1958, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "June 2, 1957"}}"#,
                                   image: nil, imageNote: DateRoute.imageNoRoute)
        var t3 = GeneratedTags(year: "1957", month: "6 June", day: "Day 2")
        est.apply(to: &t3)
        check("2 estimate: the year with Date Uncertain, never a month or day", t3.year == "1957" && t3.dateUncertain
              && t3.month == nil && t3.day == nil)
        let eo = est.with(measured: true).sidecarObject()
        let iv = eo["interval_90"] as? [String: Any] ?? [:]
        check("2 sidecar, estimate: the neighbour's file, the check and the measured interval",
              eo["class"] as? String == "estimate" && eo["source"] as? String == "P1.pdf"
              && eo["quote"] as? String == "June 2, 1957" && iv["lo"] as? Int == 1956 && iv["hi"] as? Int == 1958
              && iv["measured"] != nil && (eo["check"] as? String)?.hasPrefix("quote found") == true)
        check("2 sidecar, estimate on an unmeasured route: no interval",
              est.with(measured: false).sidecarObject()["interval_90"] == nil)

        let failed = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "lo": 1957, "hi": 1957, "evidence": {"neighbour": "P1", "quote": "July 9, 1957"}}"#,
                                      image: nil, imageNote: DateRoute.imageNoRoute)
        var t4 = GeneratedTags(year: "1957", dateUncertain: false)
        failed.apply(to: &t4)
        let fo = failed.with(measured: true).sidecarObject()
        check("2 an estimate whose evidence fails: no year written, Date Uncertain, nothing of it shown",
              t4.year == nil && t4.dateUncertain && fo["class"] as? String == "none" && fo["quote"] == nil
              && fo["interval_90"] == nil && fo["reason"] as? String == "no year with checked evidence")

        var inherited = failed
        inherited.inherit(fromCover: GeneratedTags(year: "1958", month: "3 March"), coverFile: "L.pdf")
        var t5 = GeneratedTags()
        inherited.apply(to: &t5)
        check("2 step 3a: an enclosure with no own date takes the cover's year, Date Uncertain, no month",
              t5.year == "1958" && t5.dateUncertain && t5.month == nil
              && inherited.with(measured: true).sidecarObject()["source"] as? String == "L.pdf")
        var keeps = explicit
        keeps.inherit(fromCover: GeneratedTags(year: "1958"), coverFile: "L.pdf")
        check("2 step 3a: an enclosure's own explicit date wins", keeps.year == 1947 && keeps.evidenceClass == .text)

        let flagged = DateRoute.decide(text: letter, near: near, traceRaw: #"{"year": 1947, "date_uncertain": true, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
                                       image: nil, imageNote: "")
        check("2 owner call (a): the model's flag adds Date Uncertain to an explicit text year, the year kept",
              flagged.year == 1947 && flagged.dateUncertain && flagged.evidenceClass == .text
              && flagged.with(measured: true).sidecarObject()["uncertain_because"] != nil)

        let img = DateRoute.readImage(#"{"dates": [{"quote": "RECEIVED APR 4 1961", "page": 1, "where": "stamp", "kind": "stamped", "year": 1961}, {"quote": "March 30, 1961", "page": 1, "where": "dateline", "kind": "typed", "year": 1961, "month": 3}], "document_date": {"year": 1961, "month": 3, "quote": "March 30, 1961"}}"#)
        let byImage = DateRoute.decide(text: memo, near: [], traceRaw: nil, image: img, imageNote: DateRoute.imageSent)
        var t6 = GeneratedTags()
        byImage.apply(to: &t6)
        let io = byImage.with(measured: true).sidecarObject()
        let roles = io["second_role_dates"] as? [[String: Any]] ?? []
        check("2 image: the document's own quoted date, its month, no flag; the stamp kept as a second-role date",
              t6.year == "1961" && t6.month == "3 March" && t6.day == "Day 30" && !t6.dateUncertain
              && io["class"] as? String == "image"
              && io["quote"] as? String == "March 30, 1961" && io["where"] as? String == "dateline"
              && roles.count == 1 && roles[0]["quote"] as? String == "RECEIVED APR 4 1961" && roles[0]["role"] as? String == "stamp")

        // W46.date-stamp-fallback: no own date on the page, a stamp: its year with Date Uncertain, before the estimate.
        let stampOnly = DateRoute.readImage(#"{"dates": [{"quote": "RECEIVED MAY 2 1960", "page": 1, "where": "stamp", "kind": "stamped", "year": 1960, "month": 5}], "document_date": null}"#)
        let byStamp = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "lo": 1956, "hi": 1958, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "June 2, 1957"}}"#,
                                       image: stampOnly, imageNote: DateRoute.imageSent)
        var t7 = GeneratedTags(year: "1958", month: "1 January", day: "Day 9")
        byStamp.apply(to: &t7)
        let so = byStamp.with(measured: true).sidecarObject()
        check("2 stamp: the stamp's year over the estimate, Date Uncertain, its month and day; its quote in the sidecar and header",
              t7.year == "1960" && t7.dateUncertain && t7.month == "5 May" && t7.day == "Day 2" && byStamp.evidenceClass == .stamp
              && so["class"] as? String == "stamp" && so["quote"] as? String == "RECEIVED MAY 2 1960"
              && so["where"] as? String == "stamp" && so["page"] as? Int == 1 && so["interval_90"] == nil
              && byStamp.with(measured: true).headerEvidence == "stamp; page 1; stamp; \"RECEIVED MAY 2 1960\"; gave 1960-05-02, Date Uncertain",
              "\(t7.allTags) \(so) \(String(describing: byStamp.headerEvidence))")
        var stampCovered = byStamp
        stampCovered.inherit(fromCover: GeneratedTags(year: "1958"), coverFile: "L.pdf")
        check("2 stamp: a covering document's year wins over a stamp (step 3a)",
              stampCovered.year == 1958 && stampCovered.evidenceClass == .inherited && stampCovered.quote == nil)

        // W47.ct-folder-date (owner, 2026-11-19): the folder run's confirmed date, step 3b.
        func folder(_ s: String) -> ContainerFolderDate { ContainerFolderDate.parse(s, start: "00012.pdf")! }
        var single = failed
        single.inherit(fromFolder: folder("Feb. 1970"))
        var t8 = GeneratedTags(year: "1958", month: "1 January", day: "Day 9")
        single.apply(to: &t8)
        let fo8 = single.with(measured: true).sidecarObject()
        check("2 folder: a single year with its month, no Date Uncertain, no day; the folder photo and its date as evidence",
              t8.year == "1970" && t8.month == "2 February" && t8.day == nil && !t8.dateUncertain
              && single.evidenceClass == .folder && fo8["class"] as? String == "folder"
              && fo8["source"] as? String == "00012.pdf" && fo8["folder_date"] as? String == "Feb. 1970"
              && single.headerEvidence == "folder; from 00012.pdf; \"Feb. 1970\"; gave 1970-02",
              "\(t8.allTags) \(fo8) \(String(describing: single.headerEvidence))")
        var mid = est
        mid.inherit(fromFolder: folder("1965-1967"))
        var t9 = GeneratedTags()
        mid.apply(to: &t9)
        check("2 folder: a range under 8 years is its mid-point year with Date Uncertain, ahead of an estimate",
              t9.year == "1966" && t9.dateUncertain && t9.month == nil && t9.day == nil && mid.evidenceClass == .folder)
        for date in ["Feb. 1960", "1965-1967", "1958-1969"] {
            let resolved = DateRoute.Inheritance(base: byStamp, folder: folder(date)).resolve(cover: nil)
            check("2 stamp: keeps its date and evidence ahead of folder date \(date)", resolved == byStamp)
        }
        let stampedEnclosure = DateRoute.Inheritance(base: byStamp, folder: folder("Feb. 1970"))
        let cover1970 = (tags: GeneratedTags(year: "1970", month: "2 February"), file: Optional("L.pdf"))
        check("2 stamp: a cover's folder date does not override the enclosure's stamp",
              stampedEnclosure.resolve(cover: cover1970, coverDatedByFolder: true) == byStamp)
        check("2 stamp: a genuine cover year still wins even when the folder names the same year",
              stampedEnclosure.resolve(cover: cover1970).evidenceClass == .inherited)
        var dec = failed
        dec.inherit(fromFolder: folder("1958-1969"))
        var t10 = GeneratedTags(year: "1958")
        dec.apply(to: &t10)
        check("2 folder: 8 to 19 years is the decade with Date Uncertain",
              t10.year == "1960s" && t10.dateUncertain && t10.month == nil && dec.year == nil
              && dec.headerEvidence == "folder; from 00012.pdf; \"1958-1969\"; gave 1960s, Date Uncertain"
              && dec.sidecarObject()["decade"] as? String == "1960s")
        var wide = failed
        wide.inherit(fromFolder: folder("1939-1978"))
        check("2 folder: 20 years or more dates nothing", wide == failed)
        var ownWins = explicit
        ownWins.inherit(fromFolder: folder("1971"))
        var coverWins = inherited
        coverWins.inherit(fromFolder: folder("1971"))
        var imageWins = byImage
        imageWins.inherit(fromFolder: folder("1971"))
        check("2 folder: the document's own date, from its text or image, and a cover's year win",
              ownWins == explicit && coverWins == inherited && imageWins == byImage)
        var sameFolder = failed
        sameFolder.inherit(fromCover: GeneratedTags(year: "1970", month: "2 February"), coverFile: "L.pdf")
        sameFolder.inherit(fromFolder: folder("Feb. 1970"))
        var t11 = GeneratedTags()
        sameFolder.apply(to: &t11)
        var rangeCover = failed
        rangeCover.inherit(fromCover: GeneratedTags(year: "1966"), coverFile: "L.pdf")
        rangeCover.inherit(fromFolder: folder("1965-1967"))
        check("2 folder: an enclosure whose cover took the folder's single year takes the folder's form (month, no flag); "
              + "a range's mid-point through the cover stays the cover's",
              t11.year == "1970" && t11.month == "2 February" && !t11.dateUncertain && sameFolder.evidenceClass == .folder
              && rangeCover.evidenceClass == .inherited && rangeCover.year == 1966 && rangeCover.dateUncertain)

        let url = URL(fileURLWithPath: "/scratch/page1.jpg")
        let tags = GeneratedTags(year: "1958", subjectTags: ["Harbours"], format: "letter")
        check("2 no dating object: the sidecar is unchanged",
              SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags)
              == SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, dating: nil))
        let withData = SegmentJSONBuilder.buildData(fileURLs: [url], texts: ["t"], tags: tags, dating: o) ?? Data()
        let w = (try? JSONSerialization.jsonObject(with: withData) as? [String: Any]) ?? [:]
        check("2 with a dating object: written beside the date", (w["dating"] as? [String: Any])?["class"] as? String == "text"
              && w["date"] as? String == "1958")
    }

    // MARK: 4. The PDF header line (W46.date-route-header)

    private static func headerLine() async {
        let fm = FileManager.default
        let near = [DateRoute.Neighbour(label: "P1", dist: 1, text: "Memo\nJune 2, 1957\nfile", file: "P1.pdf")]
        let memo = "MEMO\nTo: Files"
        let est = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "lo": 1956, "hi": 1958, "evidence": {"neighbour": "P1", "quote": "June 2, 1957"}}"#,
                                   image: nil, imageNote: "")
        check("4 estimate, measured: class, source, quote and interval",
              est.with(measured: true).headerEvidence == "estimate; from P1.pdf; \"June 2, 1957\"; 90% interval 1956-1958; gave 1957, Date Uncertain",
              "\(String(describing: est.with(measured: true).headerEvidence))")
        check("4 estimate, unmeasured: no interval", est.with(measured: false).headerEvidence == "estimate; from P1.pdf; \"June 2, 1957\"; gave 1957, Date Uncertain")
        let letter = "Washington\nMarch 3, 1947\nDear Sir:"
        let explicit = DateRoute.decide(text: letter, near: [], traceRaw: #"{"year": 1947, "date_uncertain": true, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
                                        image: nil, imageNote: "")
        let failed = DateRoute.decide(text: memo, near: near, traceRaw: #"{"year": 1957, "evidence": {"neighbour": "P1", "quote": "July 9, 1957"}}"#,
                                      image: nil, imageNote: "")
        check("4 an explicit text year (even flagged) and no year: no line",
              explicit.headerEvidence == nil && explicit.evidenceClass == .text && failed.headerEvidence == nil)
        var inherited = failed
        inherited.inherit(fromCover: GeneratedTags(year: "1958"), coverFile: "L.pdf")
        check("4 inherited: the cover's file, no quote", inherited.headerEvidence == "inherited; from L.pdf; gave 1958, Date Uncertain")
        var hostile = est.with(measured: false)
        hostile.quote = "Line one\nKind: printed \u{00B7} " + String(repeating: "x", count: 200)
        hostile.sourceFile = "a\u{0007}b.pdf"
        let h = hostile.headerEvidence ?? ""
        check("4 header-safe: one line, no provenance separator, the quote cut with an ellipsis",
              !h.contains("\n") && !h.contains("\u{00B7}") && !h.contains("\u{0007}") && h.contains("from a b.pdf")
              && h.contains("\u{2026}\"") && h.count < 120, h)

        // The rewrite of a generated pair, on scratch files only.
        let tmp = fm.temporaryDirectory.appendingPathComponent("APDateHeader-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard let model = OpenRouterRoute.catalog.first?.model else { check("4 a model", false); return }
        let image = tmp.appendingPathComponent("scan_001.jpg")
        writeJPEG(image, width: 120, marked: true)
        let text = "MEMORANDUM\nTo: Files\n\nThe harbour works continue."
        let result = OCRResult(text: text, classification: .documentStart, errorMessage: nil, errorCode: nil)
        let pdf = tmp.appendingPathComponent("scan_001.pdf")
        _ = try? PDFGenerator().generate(imageURL: image, result: result, model: model, outputURL: pdf,
                                         originalFileName: "scan_001.jpg", pageKind: .typewritten)
        guard let original = try? Data(contentsOf: pdf),
              let oldHeader = PDFDocument(data: original)?.page(at: 1).map({ PDFHeaderParser.parse($0) })?.header else {
            check("4 a generated pair", false); return
        }
        let gen = PDFGenerator()
        // W49.storage-drop-dead-copies: no step adds dates to a generated header any more (the catalogue record holds
        // them). An older file can still carry the lines, and a header rewrite must keep them: generate one directly.
        let line = est.with(measured: true).headerEvidence
        let fields = PDFSourceDates(documentDate: "1957", sentWith: "Mar 12, 1958", dateEvidence: line)
        let datedURL = tmp.appendingPathComponent("dated.pdf")
        _ = try? gen.generate(imageURL: image, result: result, model: model, outputURL: datedURL,
                              originalFileName: "scan_001.jpg", sourceDates: fields, pageKind: .typewritten)
        guard let added = try? Data(contentsOf: datedURL) else { check("4 an older dated pair", false); return }
        let back = PDFDocument(data: added)?.page(at: 1).map { PDFHeaderParser.parse($0) }
        var expected = oldHeader
        expected.documentDate = fields.documentDate
        expected.sentWith = fields.sentWith
        expected.dateEvidence = line
        check("4 an older file's dates and evidence parse; every other line and the body as generated",
              back?.header == expected && PDFGenerator.squashed(back?.body ?? "") == PDFGenerator.squashed(text) && PDFDocument(data: added)?.pageCount == 2,
              "\(String(describing: back))")
        let image0 = PDFDocument(data: original)?.page(at: 0)?.bounds(for: .mediaBox)
        check("4 the same class again: unchanged",
              gen.classificationRewrite(of: added, sourceName: "scan_001.jpg", classification: oldHeader.classification,
                                        body: text, textColumns: 1) == .unchanged)
        let longURL = tmp.appendingPathComponent("long.pdf")
        _ = try? gen.generate(imageURL: image, result: result, model: model, outputURL: longURL, originalFileName: "scan_001.jpg",
                              textColumns: 2, sourceDates: PDFSourceDates(dateEvidence: h), pageKind: .typewritten)
        if let longData = try? Data(contentsOf: longURL),
           case .rewrite(let long) = gen.classificationRewrite(of: longData, sourceName: "scan_001.jpg", classification: "Box",
                                                               body: text, textColumns: 2) {
            let lp = PDFDocument(data: long)?.page(at: 1).map { PDFHeaderParser.parse($0) }
            check("4 an older long line is kept fitted to one line and reads back whole (two text columns)",
                  lp?.header?.dateEvidence == h && PDFGenerator.squashed(lp?.body ?? "") == PDFGenerator.squashed(text), "\(String(describing: lp))")
        } else { check("4 an older long line is kept fitted to one line and reads back whole (two text columns)", false) }
        if case .skipped = gen.classificationRewrite(of: original, sourceName: "scan_001.jpg", classification: "Box", body: "Some other text.", textColumns: 1) {
            check("4 a page whose text is not the run's is left alone", true)
        } else { check("4 a page whose text is not the run's is left alone", false) }
        let two = tmp.appendingPathComponent("two.pdf")
        try? gen.mergeDocumentPDFs(sourcePDFs: [pdf, pdf], outputURL: two)
        if case .skipped = gen.classificationRewrite(of: Data("%PDF-1.4\n%%EOF\n".utf8), sourceName: "scan_001.jpg", classification: "Box", body: text, textColumns: 1) {
            check("4 an unreadable file is left alone", true)
        } else { check("4 an unreadable file is left alone", false) }

        // The safe replace: Finder tags and other attributes carried, the source never written.
        _ = try? MacOSTagger.applyTags(["1957", "Date Uncertain"], to: pdf, appColor: nil, colorIsAuthoritative: false,
                                       stampUnread: false)
        _ = setxattr(pdf.path, "com.archivesuite.test", "kept", 4, 0, XATTR_NOFOLLOW)
        var replaced = true
        do { try OutputFileSafety.replaceGeneratedOutput(pdf, for: image, with: added) } catch { replaced = false }
        var buf = [UInt8](repeating: 0, count: 4)
        let attr = getxattr(pdf.path, "com.archivesuite.test", &buf, 4, 0, XATTR_NOFOLLOW)
        let tagsAfter = (try? MacOSTagger.readTags(from: pdf)) ?? []
        check("4 replace: the new bytes, the Finder tags and other attributes kept, no sibling left",
              replaced && (try? Data(contentsOf: pdf)) == added && tagsAfter.contains("Date Uncertain")
              && attr == 4 && buf == Array("kept".utf8)
              && ((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []).allSatisfy { !$0.hasSuffix(".tmp") }, "\(tagsAfter)")
        let imageBytes = try? Data(contentsOf: image)
        var refused = false
        do { try OutputFileSafety.replaceGeneratedOutput(image, for: image, with: added) }
        catch { refused = (error as? OutputFileSafety.ReplaceError) == .aliasesSource }
        check("4 replace refuses an output that is its own source, and leaves it untouched",
              refused && (try? Data(contentsOf: image)) == imageBytes)
        var missing = false
        do { try OutputFileSafety.replaceGeneratedOutput(tmp.appendingPathComponent("gone.pdf"), for: image, with: added) }
        catch { missing = (error as? OutputFileSafety.ReplaceError) == .missing }
        check("4 replace never creates a missing output", missing && !fm.fileExists(atPath: tmp.appendingPathComponent("gone.pdf").path))

        var staleRefused = false
        do { try OutputFileSafety.replaceGeneratedOutput(pdf, for: image, with: original, replacing: original) }
        catch { staleRefused = (error as? OutputFileSafety.ReplaceError) == .outputChanged }
        check("4 replace refuses to overwrite bytes changed since the rewrite began",
              staleRefused && (try? Data(contentsOf: pdf)) == added)

        // W40.fix-processor-review-classification-stale — the Classification line follows a review's class.
        if case .rewrite(let boxed) = gen.classificationRewrite(of: added, sourceName: "scan_001.jpg", classification: "Box",
                                                                 body: text, textColumns: 1) {
            let bp = PDFDocument(data: boxed)?.page(at: 1).map { PDFHeaderParser.parse($0) }
            var want = expected
            want.classification = "Box"
            check("4c rewrite changes the Classification line; the evidence, every other line and the body read back unchanged",
                  bp?.header == want && PDFGenerator.squashed(bp?.body ?? "") == PDFGenerator.squashed(text)
                  && PDFDocument(data: boxed)?.page(at: 0)?.bounds(for: .mediaBox) == image0, "\(String(describing: bp))")
            check("4c the same class again: unchanged",
                  gen.classificationRewrite(of: boxed, sourceName: "scan_001.jpg", classification: "Box", body: text,
                                            textColumns: 1) == .unchanged)
        } else { check("4c rewrite changes the Classification line", false) }
        if case .rewrite(let bare) = gen.classificationRewrite(of: added, sourceName: "scan_001.jpg", classification: nil,
                                                                body: text, textColumns: 1) {
            check("4c nil removes the line",
                  PDFDocument(data: bare)?.page(at: 1).map { PDFHeaderParser.parse($0) }?.header?.classification == nil)
        } else { check("4c nil removes the line", false) }
        if let twoData = try? Data(contentsOf: two), case .skipped = gen.classificationRewrite(
            of: twoData, sourceName: "scan_001.jpg", classification: "Box", body: text, textColumns: 1) {
            check("4c an ambiguous duplicate source name is left alone", true)
        } else { check("4c an ambiguous duplicate source name is left alone", false) }

        // Through the processor: the file pane's edit, then a review that set the class on the job alone (the per-page
        // review, Segment & Tag) and the pass before merge. The Finder tags stay.
        let p = OCRProcessor()
        p.taggingMode = .automatic
        var job = OCRJob(sourceURL: image)
        job.classification = .documentStart
        job.result = OCRResult(text: text, classification: .documentStart, errorMessage: nil, errorCode: nil)
        job.appliedTags = ["1957", "Date Uncertain"]
        p.jobs = [job]
        p.outputURLMap = [image: pdf]
        func pageTwo(_ url: URL) -> PDFPageHeader? { PDFDocument(url: url)?.page(at: 1).flatMap { PDFHeaderParser.parse($0).header } }
        p.updateClassification(at: 0, to: .boxLabel)
        let edited = pageTwo(pdf)
        check("4c an edit rewrites page 2's Classification, the evidence line kept",
              edited?.classification == "Box" && edited?.dateEvidence == line, "\(String(describing: edited))")
        check("4c ...and the file keeps its Finder tags", ((try? MacOSTagger.readTags(from: pdf)) ?? []).contains("1957"))
        p.jobs[0].classification = .folderLabel
        p.jobs[0].result = p.jobs[0].result?.with(classification: .folderLabel, rotationDegrees: 0)
        await p.writeClassificationHeaders(runConfig: nil)
        check("4c the pass before merge writes a class set on the job alone", pageTwo(pdf)?.classification == "Folder")
        await p.writeClassificationHeaders(runConfig: nil)
        check("4c ...and leaves a page that already agrees as it is", pageTwo(pdf)?.classification == "Folder")
        let secondImage = tmp.appendingPathComponent("scan_002.jpg")
        let secondPDF = secondImage.deletingPathExtension().appendingPathExtension("pdf")
        writeJPEG(secondImage, width: 140, marked: true)
        let secondText = "The next page has a different reading."
        let secondResult = OCRResult(text: secondText, classification: .documentContinuation, errorMessage: nil, errorCode: nil)
        _ = try? gen.generate(imageURL: secondImage, result: secondResult, model: model, outputURL: secondPDF,
                              originalFileName: secondImage.lastPathComponent, pageKind: .typewritten,
                              textLayer: .init(searchableFor: ["jpeg/typewritten"]))
        let merged = tmp.appendingPathComponent("mixed.pdf")
        try? gen.mergeDocumentPDFs(sourcePDFs: [pdf, secondPDF], outputURL: merged)
        _ = try? MacOSTagger.applyTags(["1957"], to: merged, appColor: nil, colorIsAuthoritative: false, stampUnread: false)
        var secondJob = OCRJob(sourceURL: secondImage)
        secondJob.classification = .documentContinuation
        secondJob.result = secondResult
        secondJob.appliedTags = ["1957"]
        p.jobs.append(secondJob)
        p.outputURLMap = [image: merged, secondImage: merged]
        let before = PDFHeaderParser.extract(merged)
        let scansBefore = [0, 2].map { renderedScan(in: merged, at: $0) }
        p.updateClassification(at: 1, to: .documentStart)
        let afterSearchable = PDFHeaderParser.extract(merged)
        check("4c a post-merge edit updates the selected searchable page only",
              before?.pageRoles == [.image, .text, .searchable]
              && afterSearchable?.textPages.map { $0.header?.classification } == ["Folder", "Document Start"])
        p.updateClassification(at: 0, to: .boxLabel)
        let afterPair = PDFHeaderParser.extract(merged)
        check("4c a post-merge edit updates the selected text page only, keeping both readings, evidence and Finder tags",
              afterPair?.pageRoles == before?.pageRoles
              && afterPair?.textPages.map { $0.header?.classification } == ["Box", "Document Start"]
              && afterPair?.textPages.first?.header?.dateEvidence == line
              && afterPair?.strippedBody == before?.strippedBody
              && PDFDocument(url: merged)?.page(at: 2).map { OutputForm.holds($0.string ?? "", every: secondText) } == true
              && ((try? MacOSTagger.readTags(from: merged)) ?? []).contains("1957"))
        check("4c both scans still render with the same visible marks after both edits",
              scansBefore.allSatisfy { $0?.contains(where: { $0 < 128 }) == true }
              && [0, 2].map { renderedScan(in: merged, at: $0) } == scansBefore)

        let secondPair = tmp.appendingPathComponent("second-pair.pdf")
        _ = try? gen.generate(imageURL: secondImage, result: secondResult, model: model, outputURL: secondPair,
                              originalFileName: secondImage.lastPathComponent, pageKind: .typewritten)
        let mergedPairs = tmp.appendingPathComponent("pairs.pdf")
        try? gen.mergeDocumentPDFs(sourcePDFs: [pdf, secondPair], outputURL: mergedPairs)
        p.outputURLMap = [image: mergedPairs, secondImage: mergedPairs]
        p.updateClassification(at: 1, to: .folderLabel)
        let afterPairs = PDFHeaderParser.extract(mergedPairs)
        check("4c a post-merge edit finds the later text page in a file of pairs",
              afterPairs?.pageRoles == [.image, .text, .image, .text]
              && afterPairs?.textPages.map { $0.header?.classification } == ["Folder", "Folder"])

        let repeatedName = tmp.appendingPathComponent("other").appendingPathComponent(secondImage.lastPathComponent)
        p.outputURLMap = [image: merged, secondImage: merged, repeatedName: merged]
        let mergedBefore = try? Data(contentsOf: merged)
        p.updateClassification(at: 1, to: .boxLabel)
        check("4c duplicate source names in the merge prevent a rewrite even with one matching header",
              mergedBefore != nil && (try? Data(contentsOf: merged)) == mergedBefore
              && p.statusMessage.contains("merged PDF's classification header could not be updated"))

        let ambiguous = try? Data(contentsOf: two)
        p.outputURLMap = [image: two, secondImage: two]
        p.updateClassification(at: 0, to: .folderLabel)
        check("4c an ambiguous merged header keeps the PDF bytes and reports the skipped edit",
              ambiguous != nil && (try? Data(contentsOf: two)) == ambiguous
              && p.statusMessage.contains("merged PDF's classification header could not be updated"))
        let filed = tmp.appendingPathComponent("filed.pdf")
        let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
        try? gen.mergeDocumentPDFs(sourcePDFs: [pdf, secondPDF], outputURL: filed, catalogueIdentity: identity)
        let filedBefore = try? Data(contentsOf: filed)
        p.outputURLMap = [image: filed, secondImage: filed]
        p.updateClassification(at: 1, to: .documentStart)
        check("4c a filed merge preserves the PDF and explicitly reports a working-list-only edit",
              filedBefore != nil && (try? Data(contentsOf: filed)) == filedBefore
              && p.jobs[1].classification == .documentStart
              && p.statusMessage.contains("The filed PDF still has its saved classification."))
        p.outputURLMap = [image: image]
        await p.writeClassificationHeaders(runConfig: nil)
        check("4c an output that is its own source is never written", (try? Data(contentsOf: image)) == imageBytes)
    }

    // MARK: 3. End to end

    /// Called from up to six concurrent requests, so every access holds the lock.
    private final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var tagging = 0
        var trace: [String] = []
        /// The image calls by the documents' page widths, and the model each call asked for.
        var images: [[Int]] = []
        /// W47.item-fields-build's calls (answered "{}"), counted apart from the dating calls.
        var itemFields = 0
        var models: Set<String> = []
        var taggingReply: [String: String] = [:]
        var traceReply: [String: String] = [:]
        var imageReply: [Int: String] = [:]
        /// The gateway does not serve the measured model: a 404 for it.
        var refuseMeasured = false
    }

    nonisolated private static let markers = ["DOCA", "DOCE", "DOCB", "DOCC", "DOCD"]
    nonisolated private static let receivedStamp = #"{"dates":[{"quote":"RECEIVED MAY 2 1960","page":1,"where":"stamp","kind":"stamped","year":1960}],"document_date":null}"#

    private static func install(_ wire: Wire) {
        NetworkSession.testTransport = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let message = (body?["messages"] as? [[String: Any]])?.first
            let refused = wire.lock.withLock { wire.refuseMeasured && body?["model"] as? String == DateRoute.gatewayModel }
            if refused {
                return (Data(#"{"error": "model not found"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
            let content: String = wire.lock.withLock {
                if let model = body?["model"] as? String { wire.models.insert(model) }
                if let parts = message?["content"] as? [[String: Any]] {
                    // W47.item-fields-build's call sends the page images too; it is not the dating image pass.
                    if (parts.last?["text"] as? String)?.hasPrefix("You are labelling catalogue fields") == true {
                        wire.itemFields += 1
                        return "{}"
                    }
                    let widths = parts.compactMap { p -> Int? in
                        guard let u = (p["image_url"] as? [String: Any])?["url"] as? String,
                              let b64 = u.components(separatedBy: "base64,").last, let d = Data(base64Encoded: b64),
                              let src = CGImageSourceCreateWithData(d as CFData, nil),
                              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                        return props[kCGImagePropertyPixelWidth] as? Int
                    }
                    wire.images.append(widths)
                    return wire.imageReply[widths.first ?? 0] ?? "{}"
                }
                let prompt = message?["content"] as? String ?? ""
                let marker = markers.compactMap { m in prompt.range(of: m).map { (m, $0.lowerBound) } }
                    .min { $0.1 < $1.1 }?.0 ?? ""
                if prompt.contains("You are a metadata tagging assistant") {
                    wire.tagging += 1
                    return wire.taggingReply[marker] ?? "{}"
                }
                if prompt.hasPrefix("You are dating a document") {
                    wire.trace.append(marker)
                    return wire.traceReply[marker] ?? "no"
                }
                return "unexpected"
            }
            let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func renderedScan(in url: URL, at index: Int) -> [UInt8]? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: index)?.pageRef,
              let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(frame)
        ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: frame, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return (0..<64).flatMap { row in
            Array(UnsafeBufferPointer(start: pixels + row * ctx.bytesPerRow, count: 64))
        }
    }

    private static func writeJPEG(_ url: URL, width: Int, marked: Bool = false) {
        guard let ctx = CGContext(data: nil, width: width, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 60))
        if marked {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 10, width: 45, height: 30))
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func localImage() async {
        check("local image requires the switch and at least 16 GB",
              !DateRoute.localImageEnabled(.bool(false), memoryGB: 16)
                && !DateRoute.localImageEnabled(.bool(true), memoryGB: 8)
                && DateRoute.localImageEnabled(.bool(true), memoryGB: 16))

        let image = FileManager.default.temporaryDirectory.appendingPathComponent("APDateLocal-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: image) }
        writeJPEG(image, width: 1700)
        let prior = DateRoute.Neighbour(label: "P2", dist: 2, text: "March 3, 1947", file: "prior.jpg")
        let future = DateRoute.Neighbour(label: "N1", dist: -1, text: "March 3, 1948", file: "future.jpg")
        let pages = [(image, 0), (image, 0), (image, 0)]
        let reply = #"{"dates":[{"quote":"June 9, 1961","year":1961,"page":1,"where":"dateline"}],"document_date":null}"#

        func standIn(_ content: String, finish: String) {
            NetworkSession.testTransport = { request in
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let message = (body?["messages"] as? [[String: Any]])?.first
                let parts = message?["content"] as? [[String: Any]]
                let images = (parts ?? []).compactMap { part -> String? in
                    (part["image_url"] as? [String: String])?["url"]
                }
                let jpeg = images.first?.components(separatedBy: "base64,").last.flatMap { Data(base64Encoded: $0) }
                let source = jpeg.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                let size = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
                let conforms = request.url?.absoluteString == "http://127.0.0.1:8080/v1/chat/completions"
                    && request.value(forHTTPHeaderField: "Authorization") == "Bearer local"
                    && body?["model"] as? String == LocalModelRoute.qwen3VL8B4.modelID(for: .mlxVLM)
                    && body?["max_tokens"] as? Int == 700 && body?["temperature"] as? Int == 0
                    && parts?.count == 3 && images.count == 2 && size?[kCGImagePropertyPixelWidth] as? Int == 1400
                    && parts?.last?["text"] as? String == DateRoute.imagePrompt
                let bytes = try JSONSerialization.data(withJSONObject: [
                    "choices": [["finish_reason": finish, "message": ["content": content]]],
                ])
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: conforms ? 200 : 400,
                                                                           httpVersion: nil, headerFields: nil)
                else { throw URLError(.badURL) }
                return (bytes, response)
            }
        }
        defer { NetworkSession.testTransport = nil }
        standIn(reply, finish: "stop")
        guard NetworkSession.testTransportIsActive else { check("local image stub installed", false); return }
        let text = await DateRoute.runLocal(.init(text: "June 7, 1950", near: [prior], pages: pages))
        check("local image skips documents with a text year", text.year == 1950 && text.imageNote == DateRoute.imageNotNeeded)
        // The order the callers hand in (Process Files' and Live Capture's `run(…, dayFirst:)`) reaches the whole route.
        let dayFirst = await DateRoute.runLocal(.init(text: "Sent 04/07/1962.", near: [prior], pages: pages), dayFirst: true)
        let monthFirst = await DateRoute.runLocal(.init(text: "Sent 04/07/1962.", near: [prior], pages: pages), dayFirst: false)
        check("local route: a day-first collection dates 04/07/1962 4 July, a month-first one 7 April",
              dayFirst.year == 1962 && dayFirst.month == 7 && dayFirst.day == 4
                && monthFirst.year == 1962 && monthFirst.month == 4 && monthFirst.day == 7 && !DateRoute.dayFirst)
        let read = await DateRoute.runLocal(.init(text: "Nothing printed", near: [prior], pages: pages))
        check("local image requests two resized pages and accepts the only quoted year",
              read.year == 1961 && read.month == 6 && read.day == 9 && read.evidenceClass == .image
                && read.imageNote == DateRoute.imageSent && read.route == DateRoute.localImageRoute && !read.measured)

        let card = OCRProcessor()
        var config = SessionProcessingConfig.fromProcessFilesRunStart()
        config.provider = .appleVision
        config.model = LLMModel.appleVisionModels[0]
        config.dateLocalImage = true
        card.activeRunConfig = config
        card.manualSegAutoDate = true
        card.manualSegProvider = .appleVision
        card.manualSegModel = config.model
        let secondPage = image.deletingLastPathComponent().appendingPathComponent("APDateLocal-2-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: secondPage) }
        writeJPEG(secondPage, width: 1700)
        card.manualSegImages = [image, secondPage].enumerated().map {
            ManualSegImage(fileIndex: $0.offset, url: $0.element, rotationDegrees: 0, kind: .document)
        }
        await card.fetchManualSegDate(forIndices: [0, 1])
        check("local image fills the actual Vision Auto Date card even when OCR returned no text",
              card.manualSegDraftTags.year == "1961"
                && card.manualSegDraftTags.standingDating?.route == DateRoute.localImageRoute)

        standIn(reply, finish: "length")
        let cut = await DateRoute.runLocal(.init(text: "", near: [future, prior], pages: pages))
        check("local image discards a cut reply and propagates only from earlier documents",
              cut.year == 1947 && cut.month == nil && cut.day == nil && cut.dateUncertain
                && cut.imageNote == DateRoute.imageFailed && cut.sourceFile == "prior.jpg"
                && cut.headerEvidence?.contains("90% interval") == false)

        standIn(#"{"dates":[{"quote":"June 9, 1961","year":1961},{"quote":"June 9, 1962","year":1962}],"document_date":null}"#,
                finish: "stop")
        let ambiguous = await DateRoute.runLocal(.init(text: "", near: [future], pages: pages))
        check("local image leaves ambiguous quotes and later documents undated",
              ambiguous.year == nil && ambiguous.imageNote == DateRoute.imageSent && ambiguous.dateUncertain
                && ambiguous.sidecarObject()["reason"] as? String == "no year with checked evidence")
        var priorJob = OCRJob(sourceURL: image)
        priorJob.result = OCRResult(text: "March 3, 1947", classification: .documentStart,
                                    errorMessage: nil, errorCode: nil)
        card.jobs = [priorJob]
        card.manualSegCompleted = [CompletedManualSegment(indices: [0], tags: SegmentTagData())]
        card.manualSegImages.append(ManualSegImage(fileIndex: 2, url: secondPage, rotationDegrees: 0, kind: .document))
        card.manualSegDraftTags = SegmentTagData()
        await card.fetchManualSegDate(forIndices: [1, 2])
        check("local manual card can propagate a year within the same tree folder",
              card.manualSegDraftTags.year == "1947" && card.manualSegDraftTags.dateUncertain)
        card.manualSegImages[1].startsTreeFolder = true
        card.manualSegDraftTags = SegmentTagData()
        await card.fetchManualSegDate(forIndices: [1, 2])
        check("local manual card never propagates a year across a tree folder boundary",
              card.manualSegDraftTags.year.isEmpty && card.manualSegDraftTags.dateUncertain)
    }

    private static func endToEnd() async {
        let fm = FileManager.default
        check("3 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("3 the injected transport is active", false, "stopping before any request")
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APDateRoute-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // In folder order: A, a letter with its date in the text · E, an enclosure of A with no date of its own ·
        // B, no year in the text, dated on the page image · C, no year anywhere, a neighbour's date with checked
        // evidence · D, no year, an estimate whose quote is not in the neighbour. Each page's width names its document.
        let texts = ["DOCA Washington\nMarch 3, 1947\nDear Mr. Hale:", "DOCE Enclosed: the list",
                     "DOCB MEMORANDUM\nTo: Files", "DOCC Note to the files", "DOCD Another note"]
        let widths = [110, 150, 120, 130, 140]
        let anyYear = #"{"year": "1950", "month": "05 May", "day": "Day 9", "date_uncertain": false, "format": "memo"}"#
        wire.taggingReply = Dictionary(uniqueKeysWithValues: markers.map { ($0, anyYear) })
        wire.taggingReply["DOCA"] = #"{"year": "1947", "month": "03 March", "day": "Day 3", "date_uncertain": false, "format": "letter"}"#
        wire.traceReply = [
            "DOCA": #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
            "DOCB": #"{"year": 1947, "lo": 1946, "hi": 1948, "date_uncertain": true, "evidence": {"neighbour": "P2", "quote": "March 3, 1947"}}"#,
            "DOCC": #"{"year": 1947, "lo": 1946, "hi": 1949, "date_uncertain": true, "evidence": {"neighbour": "P3", "quote": "March 3, 1947"}}"#,
            "DOCD": #"{"year": 1951, "lo": 1950, "hi": 1952, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "June 1951"}}"#,
            "DOCE": "I cannot tell.",
        ]
        wire.imageReply = [120: #"{"dates": [{"quote": "RECEIVED APR 4 1961", "page": 1, "where": "stamp", "kind": "stamped", "year": 1961}, {"quote": "March 30, 1961", "page": 1, "where": "dateline", "kind": "typed", "year": 1961, "month": 3}], "document_date": {"year": 1961, "month": 3, "quote": "March 30, 1961"}}"#,
                           110: #"{"dates": [{"quote": "Rec'd MAR 9 1947", "page": 1, "where": "stamp", "kind": "stamped", "year": 1947}], "document_date": {"year": 1947, "quote": "March 3, 1947"}}"#]

        func processor(gateway: GatewayConfig?, out: String, imageEvery: Bool = false) -> (OCRProcessor, [URL], [String: URL]) {
            let outDir = tmp.appendingPathComponent(out, isDirectory: true)
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let p = OCRProcessor()
            p.taggingMode = .automatic
            p.currentGateway = gateway
            let files = markers.map { tmp.appendingPathComponent("\(out)-\($0).jpg") }
            for (i, f) in files.enumerated() { writeJPEG(f, width: widths[i]) }
            p.jobs = texts.enumerated().map { i, t in
                var job = OCRJob(sourceURL: files[i])
                job.result = OCRResult(text: t, classification: .documentStart, errorMessage: nil, errorCode: nil,
                                       enclosure: i == 1)
                job.classification = .documentStart
                return job
            }
            var outputs: [String: URL] = [:]
            var map: [URL: URL] = [:]
            for (i, m) in markers.enumerated() {
                let pdf = outDir.appendingPathComponent("\(m).pdf")
                // A real pair, so the header line can be checked on the written file.
                if let model = OpenRouterRoute.catalog.first?.model, let result = p.jobs[i].result {
                    _ = try? PDFGenerator().generate(imageURL: files[i], result: result, model: model, outputURL: pdf,
                                                     originalFileName: files[i].lastPathComponent)
                }
                outputs[m] = pdf.deletingPathExtension().appendingPathExtension("json")
                map[files[i]] = pdf
            }
            p.outputURLMap = map
            p.rebuildSegments(files: files)
            p.activeResolvedSettings = ResolvedSettingsSnapshot(
                runID: UUID(), resolvedAt: Date(), collectionID: nil, projectID: nil, projectName: nil, macMemoryGB: 16,
                values: [SettingsKey.dateImageEveryDocument.rawValue: ResolvedSetting(value: .bool(imageEvery))])
            return (p, files, outputs)
        }
        func json(_ u: URL?) -> [String: Any] {
            guard let u, let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        func applied(_ p: OCRProcessor, _ f: URL) -> [String] { p.jobs.first { $0.sourceURL == f }?.appliedTags ?? [] }
        guard let route = OpenRouterRoute.catalog.first else { check("3 an OpenRouter route", false); return }

        // A remote gateway: the measured route.
        let gw = GatewayConfig(baseURL: "https://gateway.test/v1", modelID: "some-tagging-model", displayName: "Gateway")
        let (g, gFiles, gOut) = processor(gateway: gw, out: "gateway")
        check("3 five segments, E an enclosure of A", g.segments.count == 5 && g.segments[1].enclosureOf == 0,
              "\(g.segments.map(\.enclosureOf))")
        await g.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                    enableSegmentJSON: true)
        check("3 gateway: every document tagged and dated once", wire.tagging == 5 && wire.trace.sorted() == markers.sorted(),
              "\(wire.tagging) \(wire.trace)")
        check("3 gateway: the image pass only on the documents whose text has no year (B C D E, not A)",
              wire.images.map { $0.first ?? 0 }.sorted() == [120, 130, 140, 150], "\(wire.images)")
        check("3 gateway: the dating calls ask for the measured model", wire.models.contains(DateRoute.gatewayModel))
        let a = applied(g, gFiles[0]), aj = json(gOut["DOCA"])
        check("3 A: 1947 from its text with the tagging call's month and day, no Date Uncertain",
              a.contains("1947") && a.contains("3 March") && a.contains("Day 3") && !a.contains("Date Uncertain"), "\(a)")
        check("3 A: the sidecar's dating object names the class, the quote and its line",
              (aj["dating"] as? [String: Any])?["class"] as? String == "text"
              && (aj["dating"] as? [String: Any])?["line"] as? Int == 2 && aj["date_uncertain"] as? Bool == false)
        let b = applied(g, gFiles[2]), bd = json(gOut["DOCB"])["dating"] as? [String: Any] ?? [:]
        check("3 B: 1961 from the page image, its month, no flag (not the tagging call's 1950, not the estimate)",
              b.contains("1961") && b.contains("3 March") && !b.contains("1950") && !b.contains("Date Uncertain"), "\(b)")
        check("3 B: the stamp is a second-role date in the sidecar, not a second year tag",
              (bd["second_role_dates"] as? [[String: Any]])?.first?["quote"] as? String == "RECEIVED APR 4 1961"
              && !b.contains("Sent With 1961") && bd["image_pass"] as? String == DateRoute.imageSent)
        let c = applied(g, gFiles[3]), cd = json(gOut["DOCC"])["dating"] as? [String: Any] ?? [:]
        check("3 C: the neighbour's 1947, always Date Uncertain, never a month",
              c.contains("1947") && c.contains("Date Uncertain") && !c.contains("5 May") && !c.contains("1950"), "\(c)")
        check("3 C: the estimate cites A's output file, the check and the measured interval",
              cd["class"] as? String == "estimate" && cd["source"] as? String == "gateway-DOCA.jpg"
              && (cd["interval_90"] as? [String: Any])?["hi"] as? Int == 1949)
        let dTags = applied(g, gFiles[4]), dd = json(gOut["DOCD"])
        check("3 D: an estimate that fails its check writes no year and shows nothing of it",
              !dTags.contains("1951") && !dTags.contains("1950") && dTags.contains("Date Uncertain")
              && (dd["dating"] as? [String: Any])?["class"] as? String == "none" && dd["date"] == nil, "\(dTags)")
        func header(_ out: [String: URL], _ m: String) -> ParsedPDFTextPage? {
            guard let pdf = out[m]?.deletingPathExtension().appendingPathExtension("pdf"),
                  let doc = PDFDocument(url: pdf), doc.pageCount == 2, let page = doc.page(at: 1) else { return nil }
            return PDFHeaderParser.parse(page)
        }
        // W49.storage-drop-dead-copies: page 2 carries no date lines; the dates and their evidence are catalogue facts,
        // which `rememberCatalogueFields` builds from the tags and the decision the processor holds for each page.
        func noDateLines(_ out: [String: URL], _ m: String) -> Bool {
            guard let h = header(out, m)?.header else { return false }
            return h.documentDate == nil && h.sentWith == nil && h.dateEvidence == nil && h.itemFields.isEmpty
        }
        func filed(_ p: OCRProcessor, _ f: URL) -> (date: String?, sentWith: String?, evidence: String?) {
            guard let tags = p.appliedGeneratedTags[f] else { return (nil, nil, nil) }
            return (EnclosureDates.ownDate(of: tags)?.display, tags.sentWith?.display,
                    p.enclosureDateReviews[f]?.decision?.headerEvidence(giving: tags))
        }
        // What `rememberCatalogueFields` files for the page in a catalogue run, from the same tags and decision.
        func record(_ p: OCRProcessor, _ f: URL) -> ProcessorCatalogueRecord.DocumentFields? {
            guard let tags = p.appliedGeneratedTags[f] else { return nil }
            return ProcessorCatalogueRecord.documentFields(tags: tags, type: nil, dateIsUserSet: false,
                                                          subjectsAreUserSet: false,
                                                          dating: p.enclosureDateReviews[f]?.decision,
                                                          itemFields: nil, entities: nil)
        }
        check("4 e2e: every page was tagged (so a nil below is an answer, not a missing page)",
              gFiles.allSatisfy { g.appliedGeneratedTags[$0] != nil })
        check("4 e2e: no page 2 carries a date, Sent with, evidence or item-field line",
              ["DOCA", "DOCB", "DOCC", "DOCD", "DOCE"].allSatisfy { noDateLines(gOut, $0) })
        let bRecord = record(g, gFiles[2]), eRecord = record(g, gFiles[1])
        check("4 e2e catalogue: B's date with the image evidence and its quote; E's inherited date and Sent with",
              bRecord?.documentDate?.value?.date == ArchiveDate.parse(wireValue: "1961-03-30")
              && bRecord?.documentDate?.evidence?.first?.source == "image"
              && bRecord?.documentDate?.evidence?.first?.quote == "March 30, 1961"
              && eRecord?.documentDate?.value?.date == ArchiveDate.parse(wireValue: "1947")
              && eRecord?.documentDate?.value?.uncertain == true
              && eRecord?.documentDate?.evidence?.first?.source == "inherited"
              && eRecord?.sentWith?.value?.date == ArchiveDate.parse(wireValue: "1947-03-03")
              && record(g, gFiles[4])?.documentDate == nil,
              "\(String(describing: bRecord?.documentDate?.evidence?.first)) \(String(describing: eRecord?.documentDate?.evidence?.first))")
        check("4 e2e A and D: no evidence (an explicit text year; no year)",
              filed(g, gFiles[0]).evidence == nil && filed(g, gFiles[4]).evidence == nil)
        check("4 e2e: explicit date, no date, image date and enclosure pair as filed",
              filed(g, gFiles[0]).date == "Mar 3, 1947" && filed(g, gFiles[0]).sentWith == nil
              && filed(g, gFiles[4]).date == nil
              && filed(g, gFiles[2]).date == "Mar 30, 1961"
              && filed(g, gFiles[1]).date == "1947" && filed(g, gFiles[1]).sentWith == "Mar 3, 1947",
              "\(gFiles.map { filed(g, $0) })")
        check("4 e2e B: the image class, its page, place and quote",
              filed(g, gFiles[2]).evidence == "image; page 1; dateline; \"March 30, 1961\"; gave 1961-03-30",
              "\(String(describing: filed(g, gFiles[2]).evidence))")
        let ch = header(gOut, "DOCC")
        check("4 e2e C: the estimate's source, quote and measured interval; page 2's body and other lines as rendered",
              filed(g, gFiles[3]).evidence == "estimate; from gateway-DOCA.jpg; \"March 3, 1947\"; 90% interval 1946-1949; gave 1947, Date Uncertain"
              && ch?.body == texts[3] && ch?.header?.classification == "Document Start"
              && ch?.header?.originalFilename == "gateway-DOCC.jpg" && ch?.header?.provenance != nil,
              "\(String(describing: filed(g, gFiles[3]).evidence)) \(String(describing: ch))")
        let cPDF = gOut["DOCC"]!.deletingPathExtension().appendingPathExtension("pdf")
        let cTags = (try? MacOSTagger.readTags(from: cPDF)) ?? []
        check("4 e2e C: the file carries its Finder tags and its image page",
              cTags.contains("1947") && cTags.contains("Date Uncertain")
              && PDFDocument(url: cPDF)?.page(at: 0)?.string?.isEmpty != false, "\(cTags)")
        check("4 e2e E: the inherited class and the cover's file",
              filed(g, gFiles[1]).evidence == "inherited; from gateway-DOCA.jpg; gave 1947, Date Uncertain",
              "\(String(describing: filed(g, gFiles[1]).evidence))")
        check("4 e2e: no scratch sibling left behind",
              ((try? fm.contentsOfDirectory(atPath: cPDF.deletingLastPathComponent().path)) ?? []).allSatisfy { !$0.hasSuffix(".tmp") })
        let e = applied(g, gFiles[1]), ed = json(gOut["DOCE"])
        check("3 E: the enclosure takes its cover's year with Date Uncertain, and Sent With the cover's date",
              e.contains("1947") && e.contains("Date Uncertain") && e.contains("Sent With 1947-03-03"), "\(e)")
        check("3 E: the sidecar names the cover as the source", (ed["dating"] as? [String: Any])?["class"] as? String
              == "inherited" && (ed["dating"] as? [String: Any])?["source"] as? String == "gateway-DOCA.jpg"
              && ed["enclosure_of"] != nil)

        let reclassificationCalls = wire.lock.withLock { wire.tagging + wire.trace.count + wire.images.count }
        let enclosurePDF = gOut["DOCE"]!.deletingPathExtension().appendingPathExtension("pdf")
        g.updateClassification(at: 0, to: .boxLabel)
        let standalone = (try? MacOSTagger.readTags(from: enclosurePDF)) ?? []
        let standaloneJSON = json(gOut["DOCE"])
        check("3 reclassification: a cover made into a label removes inherited year and Sent With from disk",
              !standalone.contains("1947") && standalone.contains("Date Uncertain")
              && !standalone.contains("Sent With 1947-03-03") && standaloneJSON["date"] == nil
              && standaloneJSON["enclosure_of"] == nil && standaloneJSON["sent_with"] == nil
              && (standaloneJSON["dating"] as? [String: Any])?["class"] as? String == "none"
              && noDateLines(gOut, "DOCE") && filed(g, gFiles[1]).sentWith == nil && filed(g, gFiles[1]).date == nil,
              "\(standalone) \(standaloneJSON)")
        g.updateClassification(at: 0, to: .documentStart)
        let restored = (try? MacOSTagger.readTags(from: enclosurePDF)) ?? []
        let restoredJSON = json(gOut["DOCE"])
        check("3 reclassification: restoring the cover restores inheritance, with no model calls",
              restored.contains("1947") && restored.contains("Sent With 1947-03-03")
              && restoredJSON["date"] as? String == "1947" && restoredJSON["date_uncertain"] as? Bool == true
              && restoredJSON["sent_with"] as? String == "1947-03-03"
              && NSDictionary(dictionary: restoredJSON).isEqual(to: ed)
              && filed(g, gFiles[1]).evidence == "inherited; from gateway-DOCA.jpg; gave 1947, Date Uncertain"
              && filed(g, gFiles[1]).date == "1947" && filed(g, gFiles[1]).sentWith == "Mar 3, 1947" && noDateLines(gOut, "DOCE")
              && wire.lock.withLock { wire.tagging + wire.trace.count + wire.images.count } == reclassificationCalls,
              "\(restored) \(restoredJSON)")

        // W47.ct-folder-date: a folder's container file holds a folder run from just after A, dated 1965-1967 by the user,
        // then one from just after C whose date is a label read nobody confirmed. Read, never written. The PDFs are
        // tagged where they are (the pre-OCRed route, output = source), as the runs were set on their names.
        func withFolderRuns(_ dir: URL) -> (URL, Data?) {
            let runs = [ContainerRun(start: "DOCAz.pdf", level: .folder,
                                     fields: ContainerFieldSet([.date: ContainerValue("1965-1967", source: .user)])),
                        ContainerRun(start: "DOCCz.pdf", level: .folder,
                                     fields: ContainerFieldSet([.date: ContainerValue("Feb. 1970", source: .label,
                                                                                      reader: "vision+parser")]))]
            _ = try? ContainerFileStore.write(ContainerFile(runs: runs), directory: dir, expecting: nil)
            let url = ContainerFileStore.containerFileURL(in: dir)
            return (url, try? Data(contentsOf: url))
        }
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (fd, _, fdOut) = processor(gateway: gw, out: "folderdate")
        let fdDir = tmp.appendingPathComponent("folderdate", isDirectory: true)
        let fdPDFs = markers.map { fdDir.appendingPathComponent("\($0).pdf") }
        fd.jobs = fd.jobs.enumerated().map { i, job in
            var inPlace = OCRJob(sourceURL: fdPDFs[i])
            // C is an enclosure of B. Its rotated scan is wider than the other PDFs in the image request.
            inPlace.result = i == 3
                ? OCRResult(text: job.result?.text, classification: .documentStart, rotationDegrees: 90,
                            errorMessage: nil, errorCode: nil, enclosure: true)
                : job.result
            inPlace.classification = job.classification
            return inPlace
        }
        fd.outputURLMap = Dictionary(uniqueKeysWithValues: fdPDFs.map { ($0, $0) })
        fd.rebuildSegments(files: fdPDFs)
        let (containerURL, before) = withFolderRuns(fdDir)
        wire.lock.withLock { wire.imageReply[792] = receivedStamp }
        await fd.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: fdDir,
                                     enableSegmentJSON: true)
        wire.lock.withLock { wire.imageReply[792] = nil }
        let fdA = applied(fd, fdPDFs[0]), fdB = applied(fd, fdPDFs[2]), fdC = applied(fd, fdPDFs[3])
        let fdD = applied(fd, fdPDFs[4]), fdE = applied(fd, fdPDFs[1])
        let fdBTags = (try? MacOSTagger.readTags(from: fdPDFs[2])) ?? []
        check("3 folder, in place: B takes the confirmed folder's midpoint ahead of its estimate",
              before != nil && fdB.contains("1966") && fdB.contains("Date Uncertain")
              && !fdB.contains("1947") && fdBTags.contains("1966") && fdBTags.contains("Date Uncertain"),
              "\(fdB) \(fdBTags)")
        let fdCTags = (try? MacOSTagger.readTags(from: fdPDFs[3])) ?? []
        let fdCDating = json(fdOut["DOCC"])["dating"] as? [String: Any]
        check("3 folder, in place: C keeps its stamp ahead of its cover's folder date",
              fd.segments.count == 5 && fd.segments[3].enclosureOf == 2
              && ["1960", "5 May", "Day 2", "Date Uncertain"].allSatisfy { fdC.contains($0) && fdCTags.contains($0) }
              && !fdCTags.contains("1966") && fdCTags.contains("Sent With 1966")
              && fdCDating?["class"] as? String == "stamp",
              "\(fdC) \(fdCTags) \(wire.images)")
        check("3 folder, in place: A (before the run, its own text) and E (its cover, in the unconfirmed run) keep theirs",
              fdA.contains("1947") && !fdA.contains("Date Uncertain") && fdE.contains("1947") && fdE.contains("Date Uncertain")
              && !fdE.contains("1966"), "\(fdA) \(fdE)")
        check("3 folder, in place: D, in a folder run whose date nobody confirmed, takes no folder date",
              !fdD.contains("1970") && !fdD.contains("1966") && !fdD.contains("2 February"), "\(fdD)")
        check("3 folder: the container file is read, never written",
              before != nil && (try? Data(contentsOf: containerURL)) == before)

        // A new output written into a folder with runs takes no folder date: its name was never in them.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (fresh, freshFiles, _) = processor(gateway: gw, out: "freshfolder")
        _ = withFolderRuns(tmp.appendingPathComponent("freshfolder", isDirectory: true))
        await fresh.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                        enableSegmentJSON: true)
        let freshC = applied(fresh, freshFiles[3])
        check("3 folder: a new output in a folder with confirmed runs keeps its own route (C's estimate)",
              freshC.contains("1947") && !freshC.contains("1966"), "\(freshC)")

        // The switch on: the image pass on A too, for its stamp; A's text year stands.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (every, eFiles, eOut) = processor(gateway: gw, out: "every", imageEvery: true)
        await every.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                        enableSegmentJSON: true)
        let ea = applied(every, eFiles[0]), ead = json(eOut["DOCA"])["dating"] as? [String: Any] ?? [:]
        check("3 switch on: the image pass on every document", wire.images.count == 5, "\(wire.images)")
        check("3 switch on: A keeps its text year and gains its stamp as a second-role date",
              ea.contains("1947") && !ea.contains("Date Uncertain") && ead["class"] as? String == "text"
              && (ead["second_role_dates"] as? [[String: Any]])?.first?["quote"] as? String == "Rec'd MAR 9 1947")

        // A gateway that does not serve the measured model: the trace asked again on the gateway's own model, no image
        // pass, no interval, the route named as the gateway's own.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = []; wire.refuseMeasured = true }
        let (other, oFiles2, oOut2) = processor(gateway: gw, out: "othergw")
        await other.performTaggingPhase(provider: .gemini, model: route.model, apiKey: "", outputDirectory: tmp,
                                        enableSegmentJSON: true)
        wire.lock.withLock { wire.refuseMeasured = false }
        let oc = applied(other, oFiles2[3]), ocd = json(oOut2["DOCC"])["dating"] as? [String: Any] ?? [:]
        check("3 gateway without the measured model: dated on its own model, no image call, no interval",
              wire.trace.count == 5 && wire.images.isEmpty && oc.contains("1947") && oc.contains("Date Uncertain")
              && ocd["interval_90"] == nil && ocd["route"] as? String == "Gateway · Gateway"
              && ocd["image_pass"] as? String == DateRoute.imageNoRoute, "\(wire.trace) \(wire.images) \(oc) \(ocd)")
        let gcd = json(gOut["DOCC"])["dating"] as? [String: Any] ?? [:]
        check("3 the measured route is named in the sidecar", gcd["route"] as? String == "Gateway · gemini-3.7-flash")

        // A direct key: no measured image route, so step 2 is skipped and says so; the trace call takes the run's route.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (direct, dFiles, dOut) = processor(gateway: nil, out: "direct")
        await direct.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                         outputDirectory: tmp, enableSegmentJSON: true)
        check("3 direct key: dated once each, no image call", wire.trace.count == 5 && wire.images.isEmpty,
              "\(wire.trace) \(wire.images)")
        let db = applied(direct, dFiles[2]), dbd = json(dOut["DOCB"])["dating"] as? [String: Any] ?? [:]
        check("3 direct key: B falls to the neighbour estimate, Date Uncertain, no interval shown",
              db.contains("1947") && db.contains("Date Uncertain") && dbd["image_pass"] as? String == DateRoute.imageNoRoute
              && dbd["interval_90"] == nil && dbd["class"] as? String == "estimate", "\(db) \(dbd)")
        check("4 e2e direct key: the estimate's evidence has no interval (the route did not measure one)",
              filed(direct, dFiles[2]).evidence == "estimate; from direct-DOCA.jpg; \"March 3, 1947\"; gave 1947, Date Uncertain"
              && noDateLines(dOut, "DOCB"),
              "\(String(describing: filed(direct, dFiles[2]).evidence))")

        // Sidecars off: the route still dates the tags; no sidecar is written.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (off, oFiles, oOut) = processor(gateway: nil, out: "off")
        await off.performTaggingPhase(provider: .openrouter, model: route.model, apiKey: "test-key",
                                      outputDirectory: tmp, enableSegmentJSON: false)
        check("3 sidecars off: the tags still dated by the route, no sidecar", applied(off, oFiles[0]).contains("1947")
              && !fm.fileExists(atPath: oOut["DOCA"]!.path))

        // 5. The manual tagging sheet's auto-date: the route on each card (no tagging call, no date-only prompt).
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (sheet, sFiles, sOut) = processor(gateway: gw, out: "sheet")
        let sheetRun = Task {
            await sheet.performManualTaggingPhase(mode: .autoDate, provider: .gemini, model: route.model,
                                                  thinkingLevel: nil, apiKey: "", outputDirectory: tmp,
                                                  enableSegmentJSON: true)
        }
        var filled = false
        for _ in 0..<400 {
            if sheet.awaitingManualTagging, sheet.manualTagSegments.count == 5,
               sheet.manualTagSegments.allSatisfy({ !$0.dateLoading }) { filled = true; break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        check("5 sheet: every card dated by the route once, no tagging call",
              filled && wire.tagging == 0 && wire.trace.sorted() == markers.sorted(), "\(filled) \(wire.tagging) \(wire.trace)")
        check("5 sheet: the image pass on the cards whose text has no year (B C D E)",
              wire.images.map { $0.first ?? 0 }.sorted() == [120, 130, 140, 150], "\(wire.images)")
        let cards = sheet.manualTagSegments
        if cards.count == 5 {
            check("5 sheet A: its text year and its dated form's month and day, no flag",
                  cards[0].year == "1947" && cards[0].month == "3 March" && cards[0].day == "Day 3" && !cards[0].dateUncertain,
                  "\(cards[0].year) \(cards[0].month) \(cards[0].day)")
            check("5 sheet E: its cover's year only, with inherited evidence",
                  cards[1].year == "1947" && cards[1].month.isEmpty && cards[1].dateUncertain
                  && cards[1].standingDating?.evidenceClass == .inherited)
            // Revisiting a cover and changing its date changes the inherited suggestion on the next card.
            sheet.manualTagSegments[0].ownDate = ArchiveDate.parse(wireValue: "1951-02-07")
            sheet.advanceManualSegment()
            check("5 sheet E: uses the reviewed cover's year", sheet.manualTagSegments[1].year == "1951")
            var rejected = sheet.manualTagSegments[1]
            rejected.enclosureOfSegmentIndex = nil
            rejected.enclosureCoverName = nil
            rejected.refreshInheritedDate(from: nil)
            check("5 sheet E: rejecting the relation restores the standalone decision",
                  rejected.year.isEmpty && rejected.standingDating?.evidenceClass == DateRoute.EvidenceClass.none)
            sheet.manualTagSegments[0] = cards[0]
            check("5 sheet B: the page image's 1961, no flag", cards[2].year == "1961" && !cards[2].dateUncertain)
            check("5 sheet C: the neighbour's 1947, Date Uncertain, no month",
                  cards[3].year == "1947" && cards[3].month.isEmpty && cards[3].dateUncertain)
            check("5 sheet D: no year without evidence (the old prompt always wrote one), Date Uncertain",
                  cards[4].year.isEmpty && cards[4].dateUncertain)
        } else {
            check("5 sheet: five cards", false, "\(cards.count)")
        }
        // The user retypes C's year: the date is theirs, so it carries none of the route's evidence.
        if sheet.manualTagSegments.count == 5 { sheet.manualTagSegments[3].year = "1948" }
        sheet.finishManualTagging()
        await sheetRun.value
        let sa = json(sOut["DOCA"])["dating"] as? [String: Any] ?? [:]
        let sb = json(sOut["DOCB"])["dating"] as? [String: Any] ?? [:]
        check("5 sheet: the kept dates' sidecars carry the route's dating object (A text, B image, D none)",
              sa["class"] as? String == "text" && sb["class"] as? String == "image"
              && (json(sOut["DOCD"])["dating"] as? [String: Any])?["class"] as? String == "none", "\(sa) \(sb)")
        let se = json(sOut["DOCE"])
        let sheetEnclosure = applied(sheet, sFiles[1])
        check("5 sheet E: Finder tags and sidecar use the final cover and record the inherited year",
              sheetEnclosure.contains("1947") && sheetEnclosure.contains("Sent With 1947-03-03")
              && sheetEnclosure.contains("Date Uncertain")
              && (se["dating"] as? [String: Any])?["class"] as? String == "inherited"
              && filed(sheet, sFiles[1]).evidence?.hasPrefix("inherited;") == true
              && filed(sheet, sFiles[1]).date == "1947" && filed(sheet, sFiles[1]).sentWith == "Mar 3, 1947"
              && noDateLines(sOut, "DOCE"),
              "\(sheetEnclosure) \(se)")
        check("5 sheet B: the evidence names the image, and page 2 has no line for it",
              filed(sheet, sFiles[2]).evidence == "image; page 1; dateline; \"March 30, 1961\"; gave 1961-03-30"
              && noDateLines(sOut, "DOCB"),
              "\(String(describing: filed(sheet, sFiles[2]).evidence))")
        let sc = applied(sheet, sFiles[3])
        check("5 sheet C, retyped: the user's 1948, no dating object, no evidence line",
              sc.contains("1948") && !sc.contains("1947") && json(sOut["DOCC"])["dating"] == nil
              && filed(sheet, sFiles[3]).date == "1948" && noDateLines(sOut, "DOCC"), "\(sc)")

        // 5. The manual segment card's auto-date: the route on the card's pages and on confirmed earlier documents.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (card, cardFiles, _) = processor(gateway: gw, out: "card")
        card.manualSegAutoDate = true
        card.manualSegModel = route.model
        card.manualSegProvider = .gemini
        card.manualSegApiKey = ""
        card.manualSegImages = cardFiles.enumerated().map {
            ManualSegImage(fileIndex: $0, url: $1, rotationDegrees: 0, kind: .document)
        }
        await card.fetchManualSegDate(forIndices: [2])
        check("5 card B: the page image's 1961 through the route, no tagging call",
              card.manualSegDraftTags.year == "1961" && !card.manualSegDraftTags.dateUncertain
              && card.manualSegDraftTags.standingDating?.evidenceClass == .image
              && wire.tagging == 0 && wire.trace == ["DOCB"] && wire.images.count == 1, "\(wire.trace) \(wire.images)")
        card.manualSegDraftTags = SegmentTagData()
        card.manualSegCompleted = (0..<3).map { CompletedManualSegment(indices: [$0], tags: SegmentTagData()) }
        await card.fetchManualSegDate(forIndices: [3])
        check("5 card C: uses the checked quote from a confirmed earlier document",
              card.manualSegDraftTags.year == "1947" && card.manualSegDraftTags.month.isEmpty
              && card.manualSegDraftTags.dateUncertain && card.manualSegDraftTags.standingDating?.evidenceClass == .estimate)
        card.manualSegImages[3].startsTreeFolder = true
        card.manualSegDraftTags = SegmentTagData()
        await card.fetchManualSegDate(forIndices: [3])
        check("5 card C: a new folder stops the earlier documents from supplying a year",
              card.manualSegDraftTags.year.isEmpty && card.manualSegDraftTags.dateUncertain
              && card.manualSegDraftTags.standingDating?.evidenceClass == DateRoute.EvidenceClass.none)
        card.manualSegDraftTags.year = "1950"
        check("5 card: a typed date carries none of the route's evidence", card.manualSegDraftTags.standingDating == nil)

        // W47.ct-folder-date-live: the sheet and the card on files tagged in place, in the folder runs of part 3.
        wire.lock.withLock { wire.tagging = 0; wire.trace = []; wire.images = []; wire.models = [] }
        let (ms, _, _) = processor(gateway: gw, out: "sheetfolder")
        let msDir = tmp.appendingPathComponent("sheetfolder", isDirectory: true)
        let msPDFs = markers.map { msDir.appendingPathComponent("\($0).pdf") }
        ms.jobs = ms.jobs.enumerated().map { i, job in
            var inPlace = OCRJob(sourceURL: msPDFs[i])
            inPlace.result = i == 1
                ? OCRResult(text: "", classification: .documentStart, errorMessage: nil, errorCode: nil, enclosure: true)
                : job.result
            inPlace.classification = job.classification
            return inPlace
        }
        ms.outputURLMap = Dictionary(uniqueKeysWithValues: msPDFs.map { ($0, $0) })
        ms.rebuildSegments(files: msPDFs)
        let (msContainer, msBefore) = withFolderRuns(msDir)
        let msRun = Task {
            await ms.performManualTaggingPhase(mode: .autoDate, provider: .gemini, model: route.model,
                                               thinkingLevel: nil, apiKey: "", outputDirectory: msDir,
                                               enableSegmentJSON: true)
        }
        var msFilled = false
        for _ in 0..<400 {
            if ms.awaitingManualTagging, ms.manualTagSegments.count == 5,
               ms.manualTagSegments.allSatisfy({ !$0.dateLoading }) { msFilled = true; break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let msCards = ms.manualTagSegments
        if msFilled, msCards.count == 5 {
            check("5 sheet, in place: B and C, undated of their own, take the confirmed folder's 1966 with Date Uncertain",
                  msCards[2].year == "1966" && msCards[2].dateUncertain && msCards[3].year == "1966"
                  && msCards[3].dateUncertain && msCards[3].standingDating?.evidenceClass == .folder,
                  "\(msCards.map(\.year))")
            check("5 sheet, in place: A's text year stands; E takes its cover's despite empty OCR, and D has no date",
                  msCards[0].year == "1947" && msCards[1].year == "1947" && msCards[4].year.isEmpty, "\(msCards.map(\.year))")
        } else {
            check("5 sheet, in place: five cards dated", false, "\(msFilled) \(msCards.count)")
        }
        if msCards.count == 5 {
            ms.manualTagSegments[1].enclosureOfSegmentIndex = nil
            ms.manualTagSegments[1].enclosureCoverName = nil
            ms.manualTagSegments[1].refreshInheritedDate(from: nil)
            ms.manualTagSegments[1].sentWith = "1954"
        }
        ms.finishManualTagging()
        await msRun.value
        ms.updateClassification(at: 0, to: .boxLabel)
        ms.updateClassification(at: 0, to: .documentStart)
        let msE = (try? MacOSTagger.readTags(from: msPDFs[1])) ?? []
        check("5 sheet: reclassification respects the rejected relation and the operator's typed Sent With",
              msE.contains("Sent With 1954") && !msE.contains("1947") && !msE.contains("Sent With 1947-03-03"),
              "\(msE)")
        let msC = applied(ms, msPDFs[3])
        check("5 sheet, in place: C written as 1966 with Date Uncertain", msC.contains("1966") && msC.contains("Date Uncertain")
              && ((try? MacOSTagger.readTags(from: msPDFs[3])) ?? []).contains("1966"), "\(msC)")
        ms.manualSegAutoDate = true
        ms.manualSegModel = route.model
        ms.manualSegProvider = .gemini
        ms.manualSegApiKey = ""
        ms.manualSegImages = msPDFs.enumerated().map {
            ManualSegImage(fileIndex: $0, url: $1, rotationDegrees: 0, kind: .document)
        }
        ms.manualSegDraftTags = SegmentTagData()
        await ms.fetchManualSegDate(forIndices: [3])
        check("5 card, in place: C takes the confirmed folder's 1966 with Date Uncertain",
              ms.manualSegDraftTags.year == "1966" && ms.manualSegDraftTags.dateUncertain
              && ms.manualSegDraftTags.standingDating?.evidenceClass == .folder, "\(ms.manualSegDraftTags.year)")
        check("5 in place: the container file is read, never written",
              msBefore != nil && (try? Data(contentsOf: msContainer)) == msBefore)
    }

    // MARK: 6. Live Capture

    /// W49.proc-live-date-order-per-collection: a Live run record in a new `<output>/<collection>/` folder keeps the order
    /// the session dated with (day first set on the output root only), so the Reader's folder date reads `6/2/61` as Live
    /// Capture's tags did. A scratch settings store and folder, never the operator's.
    private static func liveRecordOrder(_ dayFirstValues: [String: ResolvedSetting]) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("APDateOrder-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let store = SettingsLayerStore(directory: tmp.appendingPathComponent("store", isDirectory: true))
        let root = tmp.appendingPathComponent("out", isDirectory: true)
        let key = SettingsKey.numericDatesDayFirst.rawValue
        func recorded(_ name: String, session: [String: ResolvedSetting]?) -> (snapshot: Bool?, reader: Bool, folder: Int?) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let snapshot = LiveCaptureProcessor.liveRunSnapshot(store: store, folder: folder, run: nil, session: session)
            store.record(snapshot, kind: "liveCapture", fileCount: 1, in: folder)
            let reader = CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: root)
            let date = ContainerFolderDate.$dayFirst.withValue(reader) {
                ContainerFolderDate.confirmed(at: "", in: [ContainerRun(
                    start: "", level: .folder, fields: ContainerFieldSet([.date: ContainerValue("6/2/61", source: .user)]))])
            }
            return (snapshot.values[key]?.value.bool, reader, date?.month)
        }
        let alone = store.snapshot(outputDirectory: root.appendingPathComponent("Alone", isDirectory: true), runID: UUID())
        let dayFirst = recorded("Day", session: dayFirstValues)
        check("2 numeric order: a Live record in a new collection keeps the session's day first; the Reader reads 6/2/61 as February",
              alone.values[key]?.value.bool == false && dayFirst == (true, true, 2), "\(dayFirst)")
        // W49.proc-live-redate-chosen-collection: a new folder does not inherit `.collection` provenance from the output root.
        let newFolderSnap = LiveCaptureProcessor.liveRunSnapshot(
            store: store, folder: root.appendingPathComponent("NewFromRoot", isDirectory: true),
            run: nil, session: [key: ResolvedSetting(value: .bool(true), layer: .collection)])
        check("2 numeric order: a new collection's Live record drops the root's .collection provenance while keeping day first",
              newFolderSnap.values[key]?.value.bool == true && newFolderSnap.values[key]?.layer == nil,
              "\(String(describing: newFolderSnap.values[key]))")
        // The general layer says day first, the session's root says month first (its own collection layer).
        let monthValues = [key: ResolvedSetting(value: .bool(false), layer: .collection)]
        let general = store.setGeneral(.numericDatesDayFirst, .bool(true), source: .setByUser(Date()))
        let monthFirst = recorded("Month", session: monthValues)
        check("2 numeric order: a month-first session's record stays month first over a day-first general layer; 6/2/61 is June",
              general && monthFirst == (false, false, 6), "\(monthFirst)")
        // A chosen collection that sets the order itself keeps its own value in the record.
        let own = root.appendingPathComponent("Own", isDirectory: true)
        try? fm.createDirectory(at: own, withIntermediateDirectories: true)
        store.updateCollection(in: own) { $0.collection.set(.numericDatesDayFirst, .bool(false), source: .setByUser(Date())) }
        let kept = recorded("Own", session: dayFirstValues)
        check("2 numeric order: a collection's own order stays in its Live record", kept == (false, false, 6), "\(kept)")
    }

    private static func liveCapture() async {
        let fm = FileManager.default
        guard !(ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"] ?? "").isEmpty else {
            check("6 Live Capture runs against a scratch backup root (never the operator's)", false)
            return
        }
        guard let route = OpenRouterRoute.catalog.first else { check("6 an OpenRouter route", false); return }
        let wire = Wire()
        install(wire)
        defer { NetworkSession.testTransport = nil; LiveCaptureProcessor._recoveryTestOCRStub = nil }
        guard NetworkSession.testTransportIsActive else {
            check("6 the injected transport is active", false, "stopping before any request")
            return
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("APDateLive-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // A, its year in the text · B, no year in the text, dated on the page image · C, no year, an estimate that cites
        // a neighbour Live never sends · D, a phone year · E, a phone year equal to the read one. Every tagging reply names a year; each page's width names it.
        let docs: [(gid: String, text: String, width: Int, phoneYear: Int?)] = [
            ("A", "DOCA Washington\nMarch 3, 1947\nDear Mr. Hale:", 110, nil), ("B", "DOCB MEMORANDUM\nTo: Files", 120, nil),
            ("C", "DOCC Note to the files", 130, nil), ("D", "DOCD Another note", 140, 1933),
            ("E", "DOCE A fifth note", 150, 1950)]
        let anyYear = #"{"year": "1950", "month": "05 May", "day": "Day 9", "date_uncertain": false, "format": "memo"}"#
        wire.taggingReply = Dictionary(uniqueKeysWithValues: markers.map { ($0, anyYear) })
        wire.traceReply = [
            "DOCA": #"{"year": 1947, "lo": 1947, "hi": 1947, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "March 3, 1947"}}"#,
            "DOCB": #"{"year": 1947, "lo": 1946, "hi": 1948, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "March 3, 1947"}}"#,
            "DOCC": #"{"year": 1947, "lo": 1946, "hi": 1949, "date_uncertain": true, "evidence": {"neighbour": "P1", "quote": "March 3, 1947"}}"#,
        ]
        wire.imageReply = [120: #"{"dates": [{"quote": "RECEIVED APR 4 1961", "page": 1, "where": "stamp", "kind": "stamped", "year": 1961}, {"quote": "March 30, 1961", "page": 1, "where": "dateline", "kind": "typed", "year": 1961, "month": 3}], "document_date": {"year": 1961, "month": 3, "quote": "March 30, 1961"}}"#]

        func settle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func json(_ u: URL?) -> [String: Any] {
            guard let u, let d = try? Data(contentsOf: u),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o
        }
        let gw = GatewayConfig(baseURL: "https://gateway.test/v1", modelID: "some-tagging-model", displayName: "Gateway")
        let cfg = SessionProcessingConfig(
            provider: .gemini, model: route.model, thinkingLevel: .low, apiKey: "",
            taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
            outputDirectory: tmp.appendingPathComponent("out", isDirectory: true),
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: true, tagVocabulary: [], gateway: gw,
            outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1)
        let staging = tmp.appendingPathComponent("APStaging-date", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let s = CaptureSession()
        s._recoveryTestBeginLive(config: cfg, stagingDir: staging)
        s.liveProcessor._entityTestSetSettings([:])
        // The staging itself is awaited, not a deadline: this batch is the process's first Apple Vision reading (the
        // text layer's), which can wait about 30 s for the Neural Engine to compile its model again.
        s.liveProcessor._testFinalizeTasks = []
        for (i, d) in docs.enumerated() {
            let page = tmp.appendingPathComponent("page-\(d.gid).jpg")
            writeJPEG(page, width: d.width)
            LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(text: d.text, classification: nil, errorMessage: nil,
                                                                  errorCode: nil)
            _ = s.ingest(jpeg: (try? Data(contentsOf: page)) ?? Data(), groupId: d.gid, seq: i + 1, type: .document,
                         quality: nil, year: d.phoneYear, month: nil, deviceName: "TestPhone")
        }
        LiveCaptureProcessor._recoveryTestOCRStub = nil
        for d in docs { s.liveProcessor.segmentResolved(groupId: d.gid) }
        await s.liveProcessor._testAwaitFinalizes()
        let all = s.liveProcessor.staged.count == docs.count
        check("6 Live: every document stages", all, "\(s.liveProcessor.staged.count)")
        func staged(_ gid: String) -> LiveCaptureProcessor.StagedSegment? { s.liveProcessor.staged.first { $0.groupId == gid } }
        func dating(_ gid: String) -> [String: Any]? { json(staged(gid)?.jsonURL)["dating"] as? [String: Any] }
        func tags(_ gid: String) -> [String] { staged(gid)?.pdfURLs.first.flatMap { try? MacOSTagger.readTags(from: $0) } ?? [] }
        func catalogueDate(_ segment: LiveCaptureProcessor.StagedSegment?)
            -> (CatalogueRecord.DateValue, CatalogueRecord.Evidence<CatalogueRecord.DateValue>?)? {
            guard let data = segment?.catalogueRecords?.first, let record = try? CatalogueRecord(json: data),
                  let field = record.documents.first?.fields?.documentDate,
                  case .value(let date) = field.current else { return nil }
            return (date, field.evidence.first)
        }
        func readsCatalogueDate(_ segment: LiveCaptureProcessor.StagedSegment?, _ value: String,
                                source: String, quote: String, observed: String? = nil, uncertain: Bool = false) -> Bool {
            guard let (date, evidence) = catalogueDate(segment) else { return false }
            return date.date == ArchiveDate.parse(wireValue: value) && date.uncertain == uncertain
                && evidence?.source == source && evidence?.quote == quote
                && evidence?.observedValue?.date == ArchiveDate.parse(wireValue: observed ?? value)
        }
        func evidence(_ gid: String) -> String? {
            guard let pdf = staged(gid)?.pdfURLs.first, let doc = PDFDocument(url: pdf), let page = doc.page(at: 1) else { return nil }
            return PDFHeaderParser.parse(page).header?.dateEvidence
        }

        check("6 Live: tagged five times, dated three (not D or E, whose phone years win)",
              wire.tagging == 5 && wire.trace.sorted() == ["DOCA", "DOCB", "DOCC"], "\(wire.tagging) \(wire.trace)")
        check("6 Live: the image pass on B and C only, as the measured model",
              wire.images.map { $0.first ?? 0 }.sorted() == [120, 130] && wire.models.contains(DateRoute.gatewayModel),
              "\(wire.images)")
        let a = tags("A")
        check("6 Live A: its text year, no Date Uncertain; the sidecar's dating object says text",
              a.contains("1947") && !a.contains("1950") && !a.contains("Date Uncertain") && dating("A")?["class"] as? String == "text",
              "\(a)")
        let b = tags("B")
        check("6 Live B: the page image's 1961 and month, not the tagging call's 1950; its stamp a second-role date",
              b.contains("1961") && b.contains("3 March") && !b.contains("1950") && !b.contains("Date Uncertain")
              && (dating("B")?["second_role_dates"] as? [[String: Any]])?.first?["quote"] as? String == "RECEIVED APR 4 1961",
              "\(b)")
        check("6 Live B: the staged record holds the exact image date and its quoted evidence",
              readsCatalogueDate(staged("B"), "1961-03-30", source: "image", quote: "March 30, 1961")
                && evidence("B") == nil)
        let c = tags("C")
        check("6 Live C: an estimate with no neighbour sent writes no year (not the tagging call's 1950), Date Uncertain",
              !c.contains("1947") && !c.contains("1950") && c.contains("Date Uncertain")
              && dating("C")?["class"] as? String == "none" && evidence("C") == nil, "\(c)")
        let d = tags("D")
        check("6 Live D: the phone's 1933, no dating object", d.contains("1933") && !d.contains("1950")
              && dating("D") == nil && json(staged("D")?.jsonURL)["subjects"] != nil, "\(d)")
        // W49.proc-fix-s040 (S-040, run /tmp/ap-e2e-ui-r5: Q2 + 1962 on a page read 1974-12-03 was filed `1962, Day 3`):
        // a typed year other than the read one takes the read day and month with it, on the tags and in the sidecar.
        let dJSON = json(staged("D")?.jsonURL)
        check("6 Live D: the phone's year drops the day and month read from the tagging call's 1950-05-09",
              !d.contains("Day 9") && !d.contains("5 May") && dJSON["date"] as? String == "1933",
              "\(d) \(String(describing: dJSON["date"]))")
        let e = tags("E")
        check("6 Live E: a phone year equal to the read one keeps the read day and month",
              e.contains("1950") && e.contains("5 May") && e.contains("Day 9") && dating("E") == nil
              && json(staged("E")?.jsonURL)["date"] as? String == "1950-05-09",
              "\(e) \(String(describing: json(staged("E")?.jsonURL)["date"]))")

        // W47.item-fields-build: the item-field call on Live documents too (the gateway is the measured route).
        func fields(_ gid: String) -> [String: Any]? { json(staged(gid)?.jsonURL)["item_fields"] as? [String: Any] }
        check("6 Live: an item-field call per document, its object in each sidecar",
              wire.lock.withLock { wire.itemFields } == 5
              && ["A", "B", "C", "D", "E"].allSatisfy { fields($0)?["status"] as? String == "read" }
              && fields("A")?["route"] as? String == "Gateway · " + ItemFieldExtractor.gatewayModel,
              "\(wire.itemFields) \(String(describing: fields("A")))")

        // The manifest retains the decision so rotation can keep its trace and refresh just the image pass.
        let kept = s.liveProcessor._datingTestRetained("B")
        let reloaded = CaptureSession()
        reloaded.liveProcessor._recoveryTestLoadManifest(stagingDir: staging, config: cfg)
        check("6 Live: the staging manifest round-trips the decision", kept?.evidenceClass == .image
              && reloaded.liveProcessor._datingTestRetained("B") == kept
              && reloaded.liveProcessor._datingTestRetained("D") == nil)
        let before = (dating("B") ?? [:]) as NSDictionary
        let fieldsBefore = (fields("C") ?? [:]) as NSDictionary
        wire.lock.withLock {
            wire.imageReply[120] = "{}"
            wire.imageReply[60] = #"{"dates":[{"quote":"April 10, 1962","page":1,"where":"dateline","kind":"typed","year":1962,"month":4}],"document_date":{"year":1962,"month":4,"quote":"April 10, 1962"}}"#
        }
        let corrections = [("A", 90), ("B", 180), ("C", 90)]
        s.liveProcessor.rotationReviewPages = corrections.enumerated().compactMap { index, correction in
            let (gid, rotation) = correction
            guard let src = s.photos.first(where: { $0.groupId == gid })?.url else { return nil }
            return LiveCaptureProcessor.RotationReviewPage(groupId: gid, pageIndex: 0, order: index + 1,
                                                            sourceURL: src, rotationDegrees: rotation)
        }
        s.liveProcessor.applyRotationReviewAndFinalize()
        let done = await settle { !s.liveProcessor.isFinalizing }
        check("6 Live: only B and C repeat the image pass on rotation; tagging, trace and item fields are reused",
              done && wire.lock.withLock {
                  wire.images.compactMap(\.first).sorted() == [60, 120, 120, 130]
                      && wire.trace.count == 3 && wire.itemFields == 5 && wire.tagging == 5
              }, "\(wire.images)")
        check("6 Live: B keeps its date when the refreshed image reply cannot be read",
              ((dating("B") ?? [:]) as NSDictionary) == before
              && readsCatalogueDate(staged("B"), "1961-03-30", source: "image", quote: "March 30, 1961"))
        let corrected = tags("C")
        check("6 Live: the corrected image dates C in the Finder tags, optional export and catalogue record",
              corrected.contains("1962") && corrected.contains("Day 10") && !corrected.contains("Date Uncertain")
              && dating("C")?["class"] as? String == "image"
              && json(staged("C")?.jsonURL)["date"] as? String == "1962-04-10"
              && readsCatalogueDate(staged("C"), "1962-04-10", source: "image", quote: "April 10, 1962")
              && !fieldsBefore.allKeys.isEmpty && ((fields("C") ?? [:]) as NSDictionary) == fieldsBefore,
              "\(corrected) \(String(describing: dating("C")))")
        let refreshed = CaptureSession()
        refreshed.liveProcessor._recoveryTestLoadManifest(stagingDir: staging, config: cfg)
        check("6 Live: the refreshed decision survives manifest reload",
              refreshed.liveProcessor._datingTestRetained("C")?.year == 1962)

        // W47.ct-folder-date-live: a folder whose card is saved before its documents · G, undated of its own · H, its
        // date in the text · a second folder whose card is saved only after K, undated, was tagged · a box (its card
        // dated by the user too) and L, undated, after it. Through the real ingest, the marker card's Save and Finish.
        let staging2 = tmp.appendingPathComponent("APStaging-folder", isDirectory: true)
        try? fm.createDirectory(at: staging2, withIntermediateDirectories: true)
        let f = CaptureSession()
        f._recoveryTestBeginLive(config: cfg, stagingDir: staging2)
        f.liveProcessor._entityTestSetSettings([:])
        f.liveProcessor._testFinalizeTasks = []
        func fStaged(_ gid: String) -> LiveCaptureProcessor.StagedSegment? { f.liveProcessor.staged.first { $0.groupId == gid } }
        func fTags(_ gid: String) -> [String] { fStaged(gid)?.pdfURLs.first.flatMap { try? MacOSTagger.readTags(from: $0) } ?? [] }
        func fDating(_ gid: String) -> [String: Any]? { json(fStaged(gid)?.jsonURL)["dating"] as? [String: Any] }
        var seq = 0
        func capture(_ gid: String, _ type: CaptureGroupType, _ text: String,
                     month: Int? = nil, stamped: Bool = false) async -> Bool {
            seq += 1
            let page = tmp.appendingPathComponent("folder-\(gid).jpg")
            let width = 300 + seq
            if stamped { wire.lock.withLock { wire.imageReply[width] = receivedStamp } }
            writeJPEG(page, width: width)
            LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(text: text, classification: nil, errorMessage: nil,
                                                                  errorCode: nil)
            _ = f.ingest(jpeg: (try? Data(contentsOf: page)) ?? Data(), groupId: gid, seq: seq, type: type,
                         quality: nil, year: nil, month: month, deviceName: "TestPhone")
            if type == .document { f.liveProcessor.segmentResolved(groupId: gid) }
            await f.liveProcessor._testAwaitFinalizes()
            let done = fStaged(gid) != nil
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            return done
        }
        func save(_ gid: String, _ date: String) -> Bool {
            f.applyContainerFields(groupId: gid, fields: ContainerFieldSet([.date: ContainerValue(date, source: .user)]))
        }
        var captured = await capture("F1", .folder, "FOLDER 3")
        captured = save("F1", "1965-1967") && captured
        captured = await capture("S", .document, "DOCC Note to the files", stamped: true) && captured
        for (gid, type, text) in [("G", CaptureGroupType.document, "DOCC Note to the files"),
                                  ("H", .document, "DOCA Washington\nMarch 3, 1947\nDear Mr. Hale:"),
                                  ("F2", .folder, "FOLDER 4"), ("K", .document, "DOCC Note to the files"),
                                  ("X", .box, "BOX 7"), ("L", .document, "DOCC Note to the files")] {
            captured = await capture(gid, type, text) && captured
            if gid == "G" { captured = await capture("M", .document, "DOCC Note to the files", month: 4) && captured }
        }
        check("6 Live folder: every marker and document stages", captured, "\(f.liveProcessor.staged.map(\.groupId))")
        func hasStampDate(_ gid: String) -> Bool {
            let tags = fTags(gid)
            return tags.contains("1960") && tags.contains("5 May") && tags.contains("Day 2")
                && tags.contains("Date Uncertain") && !tags.contains("1966")
                && fDating(gid)?["class"] as? String == "stamp"
                && readsCatalogueDate(fStaged(gid), "1960-05-02", source: "stamp", quote: "RECEIVED MAY 2 1960",
                                      uncertain: true)
        }
        check("6 Live folder S: the stamped date wins when the folder's card is already saved", hasStampDate("S"))
        let g = fTags("G")
        check("6 Live folder G: the undated document takes the saved folder's uncertain midpoint",
              g.contains("1966") && g.contains("Date Uncertain") && fDating("G")?["class"] as? String == "folder"
              && fDating("G")?["folder_date"] as? String == "1965-1967"
              && readsCatalogueDate(fStaged("G"), "1966", source: "folder", quote: "1965-1967", uncertain: true), "\(g)")
        let m = fTags("M")
        check("6 Live folder M: the catalogue date keeps the phone month and the folder evidence gives its year",
              m.contains("1966") && m.contains("4 April") && m.contains("Date Uncertain")
              && readsCatalogueDate(fStaged("M"), "1966-04", source: "folder", quote: "1965-1967",
                                    observed: "1966", uncertain: true), "\(m)")
        let h = fTags("H")
        check("6 Live folder H: its own text year wins", h.contains("1947") && !h.contains("1966")
              && !h.contains("Date Uncertain"), "\(h)")
        check("6 Live folder K: tagged before its folder's card was saved, no folder date yet",
              !fTags("K").contains("1970") && fDating("K")?["class"] as? String == "none", "\(fTags("K"))")
        let finishCalls = wire.lock.withLock { wire.trace.count + wire.images.count + wire.itemFields + wire.tagging }
        let saved = save("F2", "Feb. 1970") && save("X", "1980")
        guard let source = f.photos.first(where: { $0.groupId == "G" })?.url else {
            check("6 Live folder G: source for rotation review", false)
            return
        }
        wire.lock.withLock { wire.imageReply[60] = receivedStamp }
        f.liveProcessor.rotationReviewPages = [
            .init(groupId: "G", pageIndex: 0, order: 1, sourceURL: source, rotationDegrees: 90),
        ]
        f.liveProcessor.applyRotationReviewAndFinalize()
        let finished = await settle { !f.liveProcessor.isFinalizing && fTags("K").contains("1970") }
        let k = fTags("K")
        check("6 Live folder K: Finish re-dates it from the card saved later: 1970, its month, no Date Uncertain",
              saved && finished && k.contains("1970") && k.contains("2 February") && !k.contains("Date Uncertain")
              && fDating("K")?["class"] as? String == "folder"
              && readsCatalogueDate(fStaged("K"), "1970-02", source: "folder", quote: "Feb. 1970")
              && f.liveProcessor._datingTestRetained("K")?.evidenceClass == .folder, "\(k)")
        let l = fTags("L")
        check("6 Live folder L: after a box, no folder date, and a box's date dates nothing",
              !l.contains("1970") && !l.contains("1980") && l.contains("Date Uncertain")
              && fDating("L")?["class"] as? String == "none", "\(l)")
        check("6 Live folder G: the stamp read after rotation replaces the folder date in the staged output",
              hasStampDate("G"), "\(fTags("G")) \(String(describing: fDating("G")))")
        check("6 Live folder: H and S keep their dates at Finish, with one call for the corrected image",
              fTags("H") == h && hasStampDate("S")
              && wire.lock.withLock {
                  wire.images.last == [60]
                      && wire.trace.count + wire.images.count + wire.itemFields + wire.tagging == finishCalls + 1
              })

        // W49.proc-live-redate-chosen-collection: filing a month-first Live session into an existing collection whose
        // own settings document sets day-first re-dates both folder-dated (`6/2/61`) and order-dependent text-dated
        // (`6/2/61`) documents locally before the move, with zero extra API calls; mid-session config adoption keeps
        // the session's locked date order.
        let chosenStore = SettingsLayerStore(directory: tmp.appendingPathComponent("chosen-store", isDirectory: true))
        let chosenRoot = tmp.appendingPathComponent("chosen-out", isDirectory: true)
        let chosenExisting = chosenRoot.appendingPathComponent("British Files", isDirectory: true)
        let staging3 = tmp.appendingPathComponent("APStaging-chosen", isDirectory: true)
        try? fm.createDirectory(at: chosenExisting, withIntermediateDirectories: true)
        try? fm.createDirectory(at: staging3, withIntermediateDirectories: true)
        chosenStore.updateCollection(in: chosenExisting) {
            $0.collection.set(.numericDatesDayFirst, .bool(true), source: .setByUser(Date()))
        }
        var chosenCfg = cfg
        chosenCfg.outputDirectory = chosenRoot
        let chosenSession = CaptureSession()
        chosenSession._recoveryTestBeginLive(config: chosenCfg, stagingDir: staging3)
        chosenSession.liveProcessor._entityTestSetSettings([SettingsKey.numericDatesDayFirst.rawValue: ResolvedSetting(value: .bool(false), layer: .general)])
        chosenSession.liveProcessor._testFinalizeTasks = []
        // Mid-session adoptSettingsSnapshot preserves the session's locked month-first order.
        chosenSession.liveProcessor.adoptSettingsSnapshot(chosenCfg)
        check("6 Live chosen-collection: mid-session settings reload keeps locked session date order",
              chosenSession.liveProcessor.effectiveDayFirst == false)

        wire.lock.withLock {
            wire.traceReply["DOCN"] = #"{"year": 1961, "lo": 1961, "hi": 1961, "date_uncertain": false, "evidence": {"neighbour": "self", "quote": "6/2/61"}}"#
            wire.taggingReply["DOCN"] = anyYear
        }
        func cCapture(_ gid: String, _ type: CaptureGroupType, _ text: String) async -> Bool {
            seq += 1
            let page = tmp.appendingPathComponent("chosen-\(gid).jpg")
            writeJPEG(page, width: 400 + seq)
            LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(text: text, classification: nil, errorMessage: nil, errorCode: nil)
            _ = chosenSession.ingest(jpeg: (try? Data(contentsOf: page)) ?? Data(), groupId: gid, seq: seq, type: type,
                                     quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            if type == .document { chosenSession.liveProcessor.segmentResolved(groupId: gid) }
            await chosenSession.liveProcessor._testAwaitFinalizes()
            let ok = chosenSession.liveProcessor.staged.contains { $0.groupId == gid }
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            return ok
        }
        let cF = await cCapture("CF1", .folder, "FOLDER 6/2/61")
        let cSaved = chosenSession.applyContainerFields(groupId: "CF1", fields: ContainerFieldSet([.date: ContainerValue("6/2/61", source: .user)]))
        let cDocFolder = await cCapture("CD1", .document, "DOCC Undated note in folder")
        let cDocText = await cCapture("CD2", .document, "DOCN London\n6/2/61\nDear Sir:")
        let preChosenCD1 = chosenSession.liveProcessor._datingTestRetained("CD1")
        let preChosenCD2 = chosenSession.liveProcessor._datingTestRetained("CD2")
        check("6 Live chosen-collection: month-first session initially dates 6/2/61 as June (folder 1961-06 and text 1961-06-02)",
              cF && cSaved && cDocFolder && cDocText
                && preChosenCD1?.year == 1961 && preChosenCD1?.month == 6 && preChosenCD1?.day == nil
                && preChosenCD2?.year == 1961 && preChosenCD2?.month == 6 && preChosenCD2?.day == 2,
              "cd1=\(String(describing: preChosenCD1?.month))/\(String(describing: preChosenCD1?.day)) cd2=\(String(describing: preChosenCD2?.month))/\(String(describing: preChosenCD2?.day))")

        let callsBeforeFinalize = wire.lock.withLock { wire.trace.count + wire.images.count + wire.itemFields + wire.tagging }
        let savedTestOut = ProcessInfo.processInfo.environment["LIVECAPTURE_TESTOUT"]
        setenv("LIVECAPTURE_TESTOUT", chosenRoot.path, 1)
        defer {
            if let savedTestOut { setenv("LIVECAPTURE_TESTOUT", savedTestOut, 1) } else { unsetenv("LIVECAPTURE_TESTOUT") }
        }
        let draft = LiveCaptureProcessor.CollectionDraft(
            id: "__unfiled__", finalName: "British Files", existingFolders: [chosenExisting],
            suggestedFolders: [chosenExisting], chosenExisting: chosenExisting, segmentCount: 3, photoCount: 3)
        chosenSession.liveProcessor.finalize([draft], settingsStore: chosenStore)
        let filedOK = await settle { !chosenSession.liveProcessor.isFinalizing && chosenSession.liveProcessor.staged.isEmpty }
        let callsAfterFinalize = wire.lock.withLock { wire.trace.count + wire.images.count + wire.itemFields + wire.tagging }
        let filedCompanions = ((try? fm.contentsOfDirectory(at: chosenExisting, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".archivesuite.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let filedDates = filedCompanions.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url), let rec = try? CatalogueRecord(json: data),
                  case .value(let dv)? = rec.documents.first?.fields?.documentDate?.current else { return nil }
            return dv.date.wireValue
        }
        check("6 Live chosen-collection: Finish re-dates folder (1961-02) and text (1961-02-06) before filing, with 0 API calls",
              filedOK && callsAfterFinalize == callsBeforeFinalize && filedDates == ["1961-02", "1961-02-06"],
              "filedOK=\(filedOK) calls=\(callsAfterFinalize - callsBeforeFinalize) dates=\(filedDates)")

        let newSubfolder = chosenRoot.appendingPathComponent("New Subfolder", isDirectory: true)
        try? fm.createDirectory(at: newSubfolder, withIntermediateDirectories: true)
        let rootCollectionSession: [String: ResolvedSetting] = [
            SettingsKey.numericDatesDayFirst.rawValue: ResolvedSetting(value: .bool(true), layer: .collection)
        ]
        let newFolderSnap = LiveCaptureProcessor.liveRunSnapshot(
            store: chosenStore, folder: newSubfolder, run: nil, session: rootCollectionSession)
        check("6 Live chosen-collection: new subfolder inherits root's day-first value without '.collection' provenance",
              newFolderSnap.values[SettingsKey.numericDatesDayFirst.rawValue]?.value.bool == true
                && newFolderSnap.values[SettingsKey.numericDatesDayFirst.rawValue]?.layer == nil,
              "\(String(describing: newFolderSnap.values[SettingsKey.numericDatesDayFirst.rawValue]))")
    }
}
#endif
