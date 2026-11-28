import Foundation
import Testing
@testable import ArchiveCore

@Suite("AdvancedSearchRules — shared FTS5 query builder and date range parsing")
struct AdvancedSearchRulesTests {
    @Test("DateRoleChoice maps to the expected DateRole list")
    func dateRoleChoices() {
        #expect(DateRoleChoice.either.roles == [.own, .sentWith])
        #expect(DateRoleChoice.own.roles == [.own])
        #expect(DateRoleChoice.sentWith.roles == [.sentWith])
    }

    @Test("words splits whitespace, strips outer quotes, and drops punctuation-only tokens")
    func wordsExtraction() {
        #expect(AdvancedSearchText.words("  \"harbour\" \u{201c}report\u{201d} - & 1958 ") == ["harbour", "report", "1958"])
        #expect(AdvancedSearchText.words("--- & * !!") == [])
        #expect(AdvancedSearchText.words("   ") == [])
        #expect(AdvancedSearchText.words("arch*").first == "arch*")
    }

    @Test("ftsExpression safely quotes terms, handles prefix wildcards, operators, and columns")
    func ftsExpressions() {
        #expect(AdvancedSearchText.ftsExpression(op: .allWords, text: "   --- ", column: nil) == nil)
        #expect(AdvancedSearchText.ftsExpression(op: .allWords, text: "harbour", column: nil) == "\"harbour\"")
        #expect(AdvancedSearchText.ftsExpression(op: .allWords, text: "harbour report", column: nil)
                == "(\"harbour\" \"report\")")
        #expect(AdvancedSearchText.ftsExpression(op: .allWords, text: "harb* report", column: "body")
                == "body : (\"harb\"* \"report\")")
        #expect(AdvancedSearchText.ftsExpression(op: .phrase, text: "dear dean*", column: nil)
                == "\"dear dean\"")
        #expect(AdvancedSearchText.ftsExpression(op: .phrase, text: "dear dean", column: "title")
                == "title : (\"dear dean\")")
        #expect(AdvancedSearchText.ftsExpression(op: .anyWords, text: "alpha beta", column: nil)
                == "(\"alpha\" OR \"beta\")")
        #expect(AdvancedSearchText.ftsExpression(op: .noWords, text: "NOT OR NEAR", column: "ocr")
                == "ocr : (\"NOT\" OR \"OR\" OR \"NEAR\")")
        #expect(AdvancedSearchText.ftsExpression(op: .allWords, text: "o\"brien", column: nil)
                == "\"o\"\"brien\"")
    }

    @Test("dateKeys parses year, month, day, decade, and single-digit month/day")
    func dateKeysParsing() {
        let year = AdvancedSearchText.dateKeys("1981")
        #expect(year?.lower == 19810000 && year?.upper == 19811231)

        let month = AdvancedSearchText.dateKeys("1981-6")
        #expect(month?.lower == 19810600 && month?.upper == 19810631)

        let day = AdvancedSearchText.dateKeys(" 1981-6-3 ")
        #expect(day?.lower == 19810603 && day?.upper == 19810603)

        let decade = AdvancedSearchText.dateKeys("1950s")
        #expect(decade?.lower == 19500000 && decade?.upper == 19591231)

        #expect(AdvancedSearchText.dateKeys("") == nil)
        #expect(AdvancedSearchText.dateKeys("not a date") == nil)
        #expect(AdvancedSearchText.dateKeys("1981-02-30") == nil)
        #expect(AdvancedSearchText.dateKeys("1955s") == nil)
    }

    @Test("dateBounds constructs inclusive lower/upper bounds for after, before, and between")
    func dateBoundsConstruction() {
        #expect(AdvancedSearchText.dateBounds(op: .after, from: "1960", to: "")
                == DateRangeFilter(lower: 19600000, upper: nil))
        #expect(AdvancedSearchText.dateBounds(op: .before, from: "1960-03", to: "")
                == DateRangeFilter(lower: nil, upper: 19600331))
        #expect(AdvancedSearchText.dateBounds(op: .between, from: "1950", to: "1955-06")
                == DateRangeFilter(lower: 19500000, upper: 19550631))
        #expect(AdvancedSearchText.dateBounds(op: .between, from: "1950", to: "   ")
                == DateRangeFilter(lower: 19500000, upper: nil))
        #expect(AdvancedSearchText.dateBounds(op: .between, from: "", to: "1955")
                == DateRangeFilter(lower: nil, upper: 19551231))
        #expect(AdvancedSearchText.dateBounds(op: .between, from: "1950", to: "bad") == nil)
        #expect(AdvancedSearchText.dateBounds(op: .between, from: "", to: "") == nil)
        #expect(AdvancedSearchText.dateBounds(op: .contains, from: "1950", to: "") == nil)
    }

    @Test("dateMatches evaluates undated and bounded rules across own and sentWith roles")
    func dateMatching() {
        let ownOnly: [DateRole: Int] = [.own: 19580312]
        let sentOnly: [DateRole: Int] = [.sentWith: 19580401]
        let empty: [DateRole: Int] = [:]

        #expect(AdvancedSearchText.dateMatches(op: .undated, bounds: nil, role: .either, keys: empty) == true)
        #expect(AdvancedSearchText.dateMatches(op: .undated, bounds: nil, role: .either, keys: ownOnly) == false)
        #expect(AdvancedSearchText.dateMatches(op: .undated, bounds: nil, role: .sentWith, keys: ownOnly) == true)
        #expect(AdvancedSearchText.dateMatches(op: .undated, bounds: nil, role: .own, keys: sentOnly) == true)

        let bounds = AdvancedSearchText.dateBounds(op: .between, from: "1958-03", to: "1958-03")
        #expect(AdvancedSearchText.dateMatches(op: .between, bounds: bounds, role: .either, keys: ownOnly) == true)
        #expect(AdvancedSearchText.dateMatches(op: .between, bounds: bounds, role: .sentWith, keys: ownOnly) == false)
        #expect(AdvancedSearchText.dateMatches(op: .between, bounds: bounds, role: .either, keys: sentOnly) == false)
        #expect(AdvancedSearchText.dateMatches(op: .between, bounds: nil, role: .either, keys: ownOnly) == nil)
    }
}
