import Foundation
import Testing
@testable import ArchiveCore

/// Golden tests for GeneratedTags — the Processor's tag vocabulary and formatting.
/// These pin the emit order, title-casing, and date-token builders that must round-trip
/// with the Reader's parser (SPEC/tag-format.md §Finder tags).
struct GeneratedTagsTests {

    // MARK: - allTags emit order

    @Test func allTags_datedWithSubjects() {
        let tags = GeneratedTags(
            year: "1987",
            month: "03 March",
            day: "Day 15",
            subjectTags: ["democratic party", "elections"],
            colorTag: "Red"
        )
        #expect(tags.allTags == [
            "1987", "03 March", "Day 15",
            "Democratic Party", "Elections",
            "Red"
        ])
    }

    @Test func allTags_ocrFailed() {
        let tags = GeneratedTags(ocrFailed: true, colorTag: "Purple")
        #expect(tags.allTags == ["OCR Failed", "Purple"])
    }

    @Test func allTags_ocrFailedNoColor() {
        let tags = GeneratedTags(ocrFailed: true)
        #expect(tags.allTags == ["OCR Failed"])
    }

    @Test func allTags_boxLabel() {
        let tags = GeneratedTags(subjectTags: ["Box"], colorTag: "Red")
        #expect(tags.allTags == ["Box", "Red"])
    }

    @Test func allTags_folderLabel() {
        let tags = GeneratedTags(subjectTags: ["Folder"], colorTag: "Purple")
        #expect(tags.allTags == ["Folder", "Purple"])
    }

    @Test func allTags_dateUncertain() {
        let tags = GeneratedTags(year: "1990", dateUncertain: true, subjectTags: ["labor unions"])
        #expect(tags.allTags == ["1990", "Date Uncertain", "Labor Unions"])
    }

    @Test func allTags_yearOnly() {
        let tags = GeneratedTags(year: "2001")
        #expect(tags.allTags == ["2001"])
    }

    @Test func allTags_empty() {
        let tags = GeneratedTags()
        #expect(tags.allTags == [])
    }

    // MARK: - capitalizeFirstLetters

    @Test func capitalizeFirstLetters_basic() {
        #expect(GeneratedTags.capitalizeFirstLetters("democratic party") == "Democratic Party")
    }

    @Test func capitalizeFirstLetters_preservesInternalCaps() {
        #expect(GeneratedTags.capitalizeFirstLetters("mcDonald") == "McDonald")
    }

    @Test func capitalizeFirstLetters_singleWord() {
        #expect(GeneratedTags.capitalizeFirstLetters("taxes") == "Taxes")
    }

    @Test func capitalizeFirstLetters_alreadyCapped() {
        #expect(GeneratedTags.capitalizeFirstLetters("OCR Failed") == "OCR Failed")
    }

    @Test func capitalizeFirstLetters_empty() {
        #expect(GeneratedTags.capitalizeFirstLetters("") == "")
    }

    // MARK: - monthTag

    @Test func monthTag_allTwelve() {
        let expected = [
            "01 January", "02 February", "03 March", "04 April",
            "05 May", "06 June", "07 July", "08 August",
            "09 September", "10 October", "11 November", "12 December"
        ]
        for m in 1...12 {
            #expect(GeneratedTags.monthTag(m) == expected[m - 1])
        }
    }

    @Test func monthTag_outOfRange() {
        #expect(GeneratedTags.monthTag(0) == nil)
        #expect(GeneratedTags.monthTag(13) == nil)
        #expect(GeneratedTags.monthTag(-1) == nil)
    }

    // MARK: - monthNumber

    @Test func monthNumber_specFormat() {
        #expect(GeneratedTags.monthNumber(from: "03 March") == 3)
        #expect(GeneratedTags.monthNumber(from: "12 December") == 12)
    }

    @Test func monthNumber_bareNumber() {
        #expect(GeneratedTags.monthNumber(from: "7") == 7)
        #expect(GeneratedTags.monthNumber(from: "11") == 11)
    }

    @Test func monthNumber_bareName() {
        #expect(GeneratedTags.monthNumber(from: "March") == 3)
        #expect(GeneratedTags.monthNumber(from: "january") == 1)
    }

    @Test func monthNumber_outOfRange() {
        #expect(GeneratedTags.monthNumber(from: "13") == nil)
        #expect(GeneratedTags.monthNumber(from: "0") == nil)
        #expect(GeneratedTags.monthNumber(from: "foo") == nil)
    }

    // MARK: - dayNumber

    @Test func dayNumber_specFormat() {
        #expect(GeneratedTags.dayNumber(from: "Day 15") == 15)
        #expect(GeneratedTags.dayNumber(from: "Day 1") == 1)
        #expect(GeneratedTags.dayNumber(from: "Day 31") == 31)
    }

    @Test func dayNumber_bareNumber() {
        #expect(GeneratedTags.dayNumber(from: "15") == 15)
    }

    @Test func dayNumber_caseInsensitive() {
        #expect(GeneratedTags.dayNumber(from: "day 7") == 7)
    }

    @Test func dayNumber_outOfRange() {
        #expect(GeneratedTags.dayNumber(from: "Day 0") == nil)
        #expect(GeneratedTags.dayNumber(from: "Day 32") == nil)
        #expect(GeneratedTags.dayNumber(from: "none") == nil)
    }

    // MARK: - machineDate

    @Test func machineDate_full() {
        let tags = GeneratedTags(year: "1987", month: "03 March", day: "Day 15")
        #expect(tags.machineDate == "1987-03-15")
    }

    @Test func machineDate_yearMonth() {
        let tags = GeneratedTags(year: "1987", month: "03 March")
        #expect(tags.machineDate == "1987-03")
    }

    @Test func machineDate_yearOnly() {
        let tags = GeneratedTags(year: "1987")
        #expect(tags.machineDate == "1987")
    }

    @Test func machineDate_noYear() {
        let tags = GeneratedTags()
        #expect(tags.machineDate == nil)
    }

    // MARK: - stringField

    @Test func stringField_string() {
        #expect(GeneratedTags.stringField("hello" as Any) == "hello")
    }

    @Test func stringField_emptyString() {
        #expect(GeneratedTags.stringField("" as Any) == nil)
        #expect(GeneratedTags.stringField("   " as Any) == nil)
    }

    @Test func stringField_int() {
        #expect(GeneratedTags.stringField(1987 as Any) == "1987")
    }

    @Test func stringField_double() {
        #expect(GeneratedTags.stringField(1987.0 as Any) == "1987")
    }

    @Test func stringField_nil() {
        #expect(GeneratedTags.stringField(nil) == nil)
    }

    // MARK: - Codable round-trip

    @Test func codableRoundTrip() throws {
        let original = GeneratedTags(
            year: "1987", month: "03 March", day: "Day 15",
            dateUncertain: false, ocrFailed: false,
            subjectTags: ["Democratic Party", "Elections"],
            colorTag: "Red", format: "letter",
            authorName: "John", recipientName: "Jane"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeneratedTags.self, from: data)
        #expect(decoded.allTags == original.allTags)
        #expect(decoded.machineDate == original.machineDate)
        #expect(decoded.format == "letter")
        #expect(decoded.authorName == "John")
    }

    // MARK: - public init defaults

    @Test func defaultInit() {
        let tags = GeneratedTags()
        #expect(tags.year == nil)
        #expect(tags.month == nil)
        #expect(tags.day == nil)
        #expect(tags.dateUncertain == false)
        #expect(tags.ocrFailed == false)
        #expect(tags.subjectTags == [])
        #expect(tags.colorTag == nil)
        #expect(tags.format == nil)
        #expect(tags.authorName == nil)
        #expect(tags.recipientName == nil)
        #expect(tags.authorLocation == nil)
        #expect(tags.recipientLocation == nil)
        #expect(tags.publicationName == nil)
    }
}
