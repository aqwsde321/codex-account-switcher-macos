import Foundation

enum StrictJSONDocumentValidator {
    static func validate(_ data: Data, maximumBytes: Int = 1_048_576) throws {
        var parser = try StrictJSONParser(data: data, maximumBytes: maximumBytes)
        try parser.parseDocument()
    }
}

private struct StrictJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data, maximumBytes: Int) throws {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              !data.starts(with: [0xEF, 0xBB, 0xBF]),
              String(data: data, encoding: .utf8) != nil else {
            throw StrictJSONError.invalid
        }
        bytes = Array(data)
    }

    mutating func parseDocument() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw StrictJSONError.invalid
        }
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= 64, let byte = peek() else {
            throw StrictJSONError.invalid
        }
        switch byte {
        case 0x7B:
            try parseObject(depth: depth + 1)
        case 0x5B:
            try parseArray(depth: depth + 1)
        case 0x22:
            try parseStringValue()
        case 0x74:
            try consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39:
            try parseNumber()
        default:
            throw StrictJSONError.invalid
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try consume(0x7B)
        skipWhitespace()
        if peek() == 0x7D {
            index += 1
            return
        }

        var keys = Set<String>()
        while true {
            let key = try parseKey()
            guard keys.insert(key).inserted else {
                throw StrictJSONError.invalid
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()

            if peek() == 0x2C {
                index += 1
                skipWhitespace()
                guard peek() != 0x7D else {
                    throw StrictJSONError.invalid
                }
                continue
            }
            try consume(0x7D)
            return
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try consume(0x5B)
        skipWhitespace()
        if peek() == 0x5D {
            index += 1
            return
        }

        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if peek() == 0x2C {
                index += 1
                skipWhitespace()
                guard peek() != 0x5D else {
                    throw StrictJSONError.invalid
                }
                continue
            }
            try consume(0x5D)
            return
        }
    }

    private mutating func parseKey() throws -> String {
        try consume(0x22)
        let start = index
        while let byte = peek(), byte != 0x22 {
            guard byte >= 0x20, byte != 0x5C else {
                throw StrictJSONError.invalid
            }
            index += 1
        }
        guard peek() == 0x22,
              let key = String(bytes: bytes[start..<index], encoding: .utf8) else {
            throw StrictJSONError.invalid
        }
        index += 1
        return key
    }

    private mutating func parseStringValue() throws {
        try consume(0x22)
        while let byte = peek() {
            switch byte {
            case 0x22:
                index += 1
                return
            case 0x00..<0x20:
                throw StrictJSONError.invalid
            case 0x5C:
                index += 1
                try parseEscape()
            default:
                index += 1
            }
        }
        throw StrictJSONError.invalid
    }

    private mutating func parseEscape() throws {
        guard let byte = peek() else {
            throw StrictJSONError.invalid
        }
        index += 1
        if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte) {
            return
        }
        guard byte == 0x75 else {
            throw StrictJSONError.invalid
        }
        for _ in 0..<4 {
            guard let hex = peek(), isHexDigit(hex) else {
                throw StrictJSONError.invalid
            }
            index += 1
        }
    }

    private mutating func parseNumber() throws {
        if peek() == 0x2D {
            index += 1
        }
        guard let first = peek() else {
            throw StrictJSONError.invalid
        }
        if first == 0x30 {
            index += 1
            if let next = peek(), (0x30...0x39).contains(next) {
                throw StrictJSONError.invalid
            }
        } else {
            guard (0x31...0x39).contains(first) else {
                throw StrictJSONError.invalid
            }
            index += 1
            consumeDigits()
        }

        if peek() == 0x2E {
            index += 1
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw StrictJSONError.invalid
            }
            consumeDigits()
        }
        if peek() == 0x65 || peek() == 0x45 {
            index += 1
            if peek() == 0x2B || peek() == 0x2D {
                index += 1
            }
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw StrictJSONError.invalid
            }
            consumeDigits()
        }
    }

    private mutating func consumeDigits() {
        while let byte = peek(), (0x30...0x39).contains(byte) {
            index += 1
        }
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            throw StrictJSONError.invalid
        }
        index += literal.count
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard peek() == byte else {
            throw StrictJSONError.invalid
        }
        index += 1
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}

private enum StrictJSONError: Error {
    case invalid
}
