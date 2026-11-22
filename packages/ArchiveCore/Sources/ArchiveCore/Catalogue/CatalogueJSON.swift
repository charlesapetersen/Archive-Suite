import Foundation

/// Foundation's typed decoder ignores duplicate object keys. Check the wire structure before
/// decoding so two parsers cannot choose different owners or field values from the same bytes.
struct CatalogueJSON {
    private let bytes: [UInt8]
    private var index = 0
    private var remainingValues = 500_000
    private let decoder = JSONDecoder()

    static func check(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw CatalogueRecord.Invalid.inputLimit }
        guard String(data: data, encoding: .utf8) != nil else { throw CatalogueRecord.Invalid.malformedJSON }
        var scanner = Self(bytes: Array(data))
        try scanner.value(depth: 0)
        scanner.skipWhitespace()
        guard scanner.peek == nil else { throw CatalogueRecord.Invalid.malformedJSON }
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        skipWhitespace()
        guard peek == byte else { return false }
        index += 1
        return true
    }

    private mutating func string() throws -> Range<Int> {
        guard take(34) else { throw CatalogueRecord.Invalid.malformedJSON }
        let start = index - 1
        while let byte = peek {
            index += 1
            if byte == 34 { return start..<index }
            if byte == 92, peek != nil { index += 1 }
        }
        throw CatalogueRecord.Invalid.malformedJSON
    }

    private mutating func value(depth: Int) throws {
        guard depth < 64, remainingValues > 0 else { throw CatalogueRecord.Invalid.inputLimit }
        remainingValues -= 1
        skipWhitespace()
        switch peek {
        case 123: // object
            index += 1
            if take(125) { return }
            var names: Set<String> = []
            repeat {
                let range = try string()
                let name = try decoder.decode(String.self, from: Data(bytes[range]))
                guard names.insert(name).inserted, take(58) else { throw CatalogueRecord.Invalid.malformedJSON }
                try value(depth: depth + 1)
            } while take(44)
            guard take(125) else { throw CatalogueRecord.Invalid.malformedJSON }
        case 91: // array
            index += 1
            if take(93) { return }
            repeat { try value(depth: depth + 1) } while take(44)
            guard take(93) else { throw CatalogueRecord.Invalid.malformedJSON }
        case 34:
            // Validate escapes even in unknown extension strings that the typed decoder may skip.
            let range = try string()
            _ = try decoder.decode(String.self, from: Data(bytes[range]))
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        default: try number()
        }
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard peek == byte else { throw CatalogueRecord.Invalid.malformedJSON }
            index += 1
        }
    }

    private mutating func digits() throws {
        let start = index
        while let byte = peek, (48...57).contains(byte) { index += 1 }
        guard start < index else { throw CatalogueRecord.Invalid.malformedJSON }
    }

    // Validate the spelling without converting unknown numbers to a machine numeric type.
    private mutating func number() throws {
        if peek == 45 { index += 1 }
        if peek == 48 { index += 1 } else { try digits() }
        if peek == 46 {
            index += 1
            try digits()
        }
        if peek == 69 || peek == 101 {
            index += 1
            if peek == 43 || peek == 45 { index += 1 }
            try digits()
        }
    }
}
