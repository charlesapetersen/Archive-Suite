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

    /// Read one level of a validated record. Values stay in their original wire form, including
    /// unknown numeric literals that Foundation cannot represent.
    struct Object {
        private let names: [String]
        private var values: [String: Data]

        init(_ data: Data) throws {
            var scanner = CatalogueJSON(bytes: Array(data))
            guard scanner.take(123) else { throw CatalogueRecord.Invalid.malformedJSON }
            var names: [String] = []
            var values: [String: Data] = [:]
            if !scanner.take(125) {
                repeat {
                    let key = try scanner.string()
                    let name = try scanner.decoder.decode(String.self, from: Data(scanner.bytes[key]))
                    guard scanner.take(58) else { throw CatalogueRecord.Invalid.malformedJSON }
                    names.append(name)
                    values[name] = try scanner.rawValue()
                } while scanner.take(44)
                guard scanner.take(125) else { throw CatalogueRecord.Invalid.malformedJSON }
            }
            self.names = names
            self.values = values
        }

        subscript(_ name: String) -> Data? {
            get { values[name] }
            set { values[name] = newValue }
        }

        var keys: Dictionary<String, Data>.Keys { values.keys }

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            var data = Data([123])
            for name in names + Set(values.keys).subtracting(names).sorted() {
                guard let value = values[name] else { continue }
                if data.count > 1 { data.append(44) }
                data.append(try encoder.encode(name))
                data.append(58)
                data.append(value)
            }
            data.append(125)
            return data
        }
    }

    static func entries(in data: Data) throws -> [Data] {
        var scanner = CatalogueJSON(bytes: Array(data))
        guard scanner.take(91) else { throw CatalogueRecord.Invalid.malformedJSON }
        if scanner.take(93) { return [] }
        var entries: [Data] = []
        repeat { entries.append(try scanner.rawValue()) } while scanner.take(44)
        guard scanner.take(93) else { throw CatalogueRecord.Invalid.malformedJSON }
        return entries
    }

    static func array(_ entries: [Data]) -> Data {
        var result = Data([91])
        for entry in entries {
            if result.count > 1 { result.append(44) }
            result.append(entry)
        }
        result.append(93)
        return result
    }

    private mutating func rawValue() throws -> Data {
        skipWhitespace()
        let start = index
        try value(depth: 0)
        return Data(bytes[start..<index])
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        let start = index
        skipWhitespace()
        guard peek == byte else {
            index = start
            return false
        }
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
