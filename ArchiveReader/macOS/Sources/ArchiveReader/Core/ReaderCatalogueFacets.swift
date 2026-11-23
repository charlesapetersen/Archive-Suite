import ArchiveCore
import Foundation

extension CatalogueRecord.Field {
    var readerValue: Value? {
        if case .value(let value) = current { return value }
        return nil
    }

    var readerIsCleared: Bool {
        if case .cleared = current { return true }
        return false
    }
}

enum ReaderCatalogueFacets {
    static func itemFields(_ document: CatalogueRecord.DocumentFields) -> [CheckableField: String] {
        let item: [(CheckableField, String?)] = [
            (.title, document.title?.readerValue), (.publication, document.publication?.readerValue),
            (.documentKind, document.documentKind?.readerValue),
            (.publicationDate, document.publicationDate?.readerValue?.date.wireValue),
            (.byline, document.byline?.readerValue?.joined(separator: " · ")),
            (.sender, document.senders?.readerValue?.joined(separator: " · ")),
            (.recipient, document.recipients?.readerValue?.joined(separator: " · ")),
            (.sendingPlace, document.sendingPlaces?.readerValue?.joined(separator: " · ")),
            (.recipientPlace, document.recipientPlaces?.readerValue?.joined(separator: " · "))
        ]
        return Dictionary(uniqueKeysWithValues: item.compactMap { field, value in value.map { (field, $0) } })
    }

    static func searchValues(_ document: CatalogueRecord.DocumentFields) -> [String] {
        let strings = [
            document.title?.readerValue, document.publication?.readerValue, document.documentKind?.readerValue,
            document.itemType?.readerValue, document.documentDate?.readerValue?.date.wireValue,
            document.sentWith?.readerValue?.date.wireValue, document.publicationDate?.readerValue?.date.wireValue
        ].compactMap { $0 }
        let lists = [
            document.byline?.readerValue, document.senders?.readerValue, document.recipients?.readerValue,
            document.sendingPlaces?.readerValue, document.recipientPlaces?.readerValue, document.subjects?.readerValue
        ]
        return strings + lists.compactMap { $0 }.flatMap { $0 }
    }

    static func document(_ facts: ItemFacts?) -> CatalogueRecord.DocumentFields? {
        (try? facts?.document.get())?.document.fields
    }

    static func hasAssessedDate(_ fields: CatalogueRecord.DocumentFields, roles: [DateRole]) -> Bool {
        roles.allSatisfy { role in role == .own ? fields.documentDate != nil : fields.sentWith != nil }
    }


    /// Produce the list's existing facet interface from typed values. Subjects never pass through
    /// the Finder token parser and the companion's quality or colour cannot imply an item type.
    static func tags(file: ItemFacts?, document: ItemFacts?) -> DocumentTags {
        let fileFields = (try? file?.file.get())?.pair.record.fileFields
        let documentFields = (try? document?.document.get())?.document.fields
        let own = documentFields?.documentDate?.readerValue
        let sentWith = documentFields?.sentWith?.readerValue
        let colour = FinderLabel.allCases.first {
            $0.tokenName.caseInsensitiveCompare(fileFields?.colour?.readerValue ?? "") == .orderedSame
        }
        let readState = ReadState.allCases.first {
            $0.rawValue.caseInsensitiveCompare(fileFields?.readState?.readerValue ?? "") == .orderedSame
        }
        let month = own?.date.month.map { DocumentTags.Month(number: $0, name: DocumentTags.monthNames[$0 - 1]) }
        let checks: [(CheckableField, Bool?)] = [
            (.date, documentFields?.documentDate?.isChecked), (.sentWith, documentFields?.sentWith?.isChecked),
            (.documentKind, documentFields?.documentKind?.isChecked), (.title, documentFields?.title?.isChecked),
            (.byline, documentFields?.byline?.isChecked), (.publication, documentFields?.publication?.isChecked),
            (.publicationDate, documentFields?.publicationDate?.isChecked),
            (.recipientPlace, documentFields?.recipientPlaces?.isChecked),
            (.sender, documentFields?.senders?.isChecked), (.recipient, documentFields?.recipients?.isChecked),
            (.sendingPlace, documentFields?.sendingPlaces?.isChecked)
        ]
        var raw: [String] = []
        if fileFields?.ocrPoor?.readerValue == true { raw.append(DocumentTags.poorOCRTag) }
        if fileFields?.ocrFailed?.readerValue == true { raw.append("OCR Failed") }
        return DocumentTags(
            raw: raw, labelNumber: colour?.rawValue,
            year: own?.date.precision == .decade ? nil : own?.date.year,
            month: month, day: own?.date.day, dateUncertain: own?.uncertain ?? false,
            decade: own?.date.precision == .decade ? own?.date.year : nil,
            quality: fileFields?.quality?.readerValue, readState: readState,
            itemType: ItemType.allCases.first {
                $0.rawValue.caseInsensitiveCompare(documentFields?.itemType?.readerValue ?? "") == .orderedSame
            },
            subjects: documentFields?.subjects?.readerValue ?? [],
            yearToken: nil, monthToken: nil, dayToken: nil, decadeToken: nil, qualityToken: nil,
            sentWith: sentWith?.date, sentWithUncertain: sentWith?.uncertain ?? false,
            checkedFields: Set(checks.compactMap { $0.1 == true ? $0.0 : nil })
        )
    }
}
