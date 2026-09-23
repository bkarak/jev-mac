import Foundation

/// A minimal JSON value that preserves object key order.
///
/// Question schemas list options in a meaningful order (choice options,
/// rubric levels), and `JSONSerialization` discards that order, so the
/// engine carries its own small parser and serializer.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Deepest array/object nesting the parser accepts.
    public static let maxDepth = 256

    public subscript(key: String) -> JSON? {
        if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(n): return n
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> JSON {
        var p = Parser(Array(text.utf8))
        p.skipWhitespace()
        let value = try p.value()
        p.skipWhitespace()
        guard p.atEnd else { throw p.error("trailing characters") }
        return value
    }

    public static func parse(data: Data) throws -> JSON {
        try parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: Serialization

    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let close = pretty ? String(repeating: "  ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        let sep = pretty ? ": " : ":"
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n): out += JSON.format(n)
        case let .string(s): out += JSON.quote(s)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, item) in items.enumerated() {
                out += pad
                item.write(into: &out, pretty: pretty, indent: indent + 1)
                out += (i < items.count - 1 ? "," : "") + nl
            }
            out += close + "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, (k, v)) in pairs.enumerated() {
                out += pad + JSON.quote(k) + sep
                v.write(into: &out, pretty: pretty, indent: indent + 1)
                out += (i < pairs.count - 1 ? "," : "") + nl
            }
            out += close + "}"
        }
    }

    /// Integers print without a fraction; everything else uses Swift's
    /// shortest representation that round-trips exactly. (Output rounding,
    /// such as four-decimal probabilities, happens before serialization.)
    static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return "\(n)"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

public struct JSONParseError: JevMacError {
    public let message: String
    public let offset: Int
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

/// A strict RFC 8259 parser. It rejects rather than guesses (leading zeros,
/// `+1`, `.5`, unknown escapes, raw control characters), never traps on
/// malformed surrogate escapes, and bounds nesting depth so hostile input
/// cannot overflow the stack.
private struct Parser {
    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { i >= bytes.count }
    var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    func error(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    static func isDigit(_ b: UInt8?) -> Bool { b.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }

    mutating func skipWhitespace() {
        while let b = peek, b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 { i += 1 }
    }

    mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard peek == b else { throw error("expected \(literal)") }
            i += 1
        }
    }

    mutating func value() throws -> JSON {
        guard let b = peek else { throw error("unexpected end of input") }
        switch b {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), 0x30...0x39: return try number()
        default: throw error("unexpected character")
        }
    }

    mutating func enter() throws {
        depth += 1
        guard depth <= JSON.maxDepth else { throw error("nesting deeper than \(JSON.maxDepth) levels") }
    }

    mutating func object() throws -> JSON {
        try enter()
        defer { depth -= 1 }
        i += 1
        var pairs: [(String, JSON)] = []
        skipWhitespace()
        if peek == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try string()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            pairs.append((key, try value()))
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "}"): i += 1; return .object(pairs)
            case nil: throw error("unterminated object")
            default: throw error("expected , or }")
            }
        }
    }

    mutating func array() throws -> JSON {
        try enter()
        defer { depth -= 1 }
        i += 1
        var items: [JSON] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try value())
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "]"): i += 1; return .array(items)
            case nil: throw error("unterminated array")
            default: throw error("expected , or ]")
            }
        }
    }

    mutating func string() throws -> String {
        i += 1
        var buf: [UInt8] = []
        while let b = peek {
            i += 1
            switch b {
            case UInt8(ascii: "\""): return String(decoding: buf, as: UTF8.self)
            case UInt8(ascii: "\\"): try escape(into: &buf)
            case 0x00..<0x20: i -= 1; throw error("unescaped control character in string")
            default: buf.append(b)
            }
        }
        throw error("unterminated string")
    }

    mutating func escape(into buf: inout [UInt8]) throws {
        guard let e = peek else { throw error("unterminated escape") }
        i += 1
        switch e {
        case UInt8(ascii: "\""): buf.append(0x22)
        case UInt8(ascii: "\\"): buf.append(0x5C)
        case UInt8(ascii: "/"): buf.append(0x2F)
        case UInt8(ascii: "b"): buf.append(0x08)
        case UInt8(ascii: "f"): buf.append(0x0C)
        case UInt8(ascii: "n"): buf.append(0x0A)
        case UInt8(ascii: "r"): buf.append(0x0D)
        case UInt8(ascii: "t"): buf.append(0x09)
        case UInt8(ascii: "u"):
            let unit = try hex4()
            var scalar = Unicode.Scalar(unit) ?? "\u{FFFD}"
            if (0xD800..<0xDC00).contains(unit) {
                // A high surrogate only counts when a low-surrogate escape follows;
                // anything else becomes U+FFFD and is parsed on its own.
                if peek == UInt8(ascii: "\\"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "u"),
                   let low = Parser.hexValue(bytes, at: i + 2), (0xDC00..<0xE000).contains(low) {
                    i += 6
                    scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}"
                } else {
                    scalar = "\u{FFFD}"
                }
            } else if (0xDC00..<0xE000).contains(unit) {
                scalar = "\u{FFFD}"
            }
            buf.append(contentsOf: Array(String(scalar).utf8))
        default:
            i -= 1
            throw error("invalid escape sequence")
        }
    }

    static func hexValue(_ bytes: [UInt8], at start: Int) -> UInt32? {
        guard start + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for b in bytes[start..<start + 4] {
            let d: UInt32
            switch b {
            case 0x30...0x39: d = UInt32(b - 0x30)
            case 0x41...0x46: d = UInt32(b - 0x41 + 10)
            case 0x61...0x66: d = UInt32(b - 0x61 + 10)
            default: return nil
            }
            v = v << 4 | d
        }
        return v
    }

    mutating func hex4() throws -> UInt32 {
        guard let v = Parser.hexValue(bytes, at: i) else { throw error("expected 4 hex digits after \\u") }
        i += 4
        return v
    }

    /// number = [ "-" ] ( "0" / digit1-9 *digit ) [ "." 1*digit ] [ ( "e" / "E" ) [ "+" / "-" ] 1*digit ]
    mutating func number() throws -> JSON {
        let start = i
        if peek == UInt8(ascii: "-") { i += 1 }
        guard Parser.isDigit(peek) else { throw error("invalid number") }
        if peek == UInt8(ascii: "0") {
            i += 1
            if Parser.isDigit(peek) { throw error("leading zeros are not allowed") }
        } else {
            while Parser.isDigit(peek) { i += 1 }
        }
        if peek == UInt8(ascii: ".") {
            i += 1
            guard Parser.isDigit(peek) else { throw error("expected digits after the decimal point") }
            while Parser.isDigit(peek) { i += 1 }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard Parser.isDigit(peek) else { throw error("expected exponent digits") }
            while Parser.isDigit(peek) { i += 1 }
        }
        guard let n = Double(String(decoding: bytes[start..<i], as: UTF8.self)), n.isFinite else {
            throw error("number out of range")
        }
        return .number(n)
    }
}
