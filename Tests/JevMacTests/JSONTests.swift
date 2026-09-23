import Foundation
import Testing
@testable import JevMac

@Suite("JSON")
struct JSONTests {
    // MARK: Invalid input is rejected, never guessed at and never a crash

    static let invalidCases: [String] = [
        "", " ", "{", "}", "[", "]", "[1,]", "[,1]", "{\"a\":}", "{\"a\" 1}", "{a:1}", "{'a':1}",
        "{\"a\":1,}", "[1 2]", "01", "-01", "+1", ".5", "5.", "1e", "1e+", "-", "--1", "0x10", "NaN",
        "Infinity", "-Infinity", "tru", "nul", "falsey", "\"abc", "\"\\x\"", "\"" + U("12") + "\"",
        "\"" + U("12G4") + "\"", "\"a\tb\"", "\"line\nbreak\"", "[1] [2]", "{\"a\":1}}", "1e999",
        "\"\\", "[\"a\",]",
    ]

    @Test("rejects invalid JSON", arguments: invalidCases)
    func rejectsInvalid(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSON.parse(text) }
    }

    // MARK: Valid edge cases parse to exactly the right value

    static let validCases: [(String, JSON)] = [
        (" 1 ", .number(1)),
        ("-0", .number(0)),
        ("0", .number(0)),
        ("1E5", .number(100_000)),
        ("1e-5", .number(1e-5)),
        ("-12.5e+2", .number(-1250)),
        ("0.0001", .number(0.0001)),
        ("[]", .array([])),
        ("{}", .object([])),
        ("\"\\/\"", .string("/")),
        ("\"\\b\\f\\n\\r\\t\"", .string("\u{8}\u{C}\n\r\t")),
        ("\"" + U("00e9") + "\"", .string("é")),
        ("\"" + U("D83D") + U("DE00") + "\"", .string("😀")),
        ("[true,false,null]", .array([.bool(true), .bool(false), .null])),
        ("\"日本語\"", .string("日本語")),
        ("{\"a\":{\"b\":[1,{\"c\":null}]}}",
         .object([("a", .object([("b", .array([.number(1), .object([("c", .null)])]))]))])),
        ("{\"a\":1,\"a\":2}", .object([("a", .number(1)), ("a", .number(2))])),
        (" \t\n\r[ 1 , 2 ]\n", .array([.number(1), .number(2)])),
    ]

    @Test("parses valid edge cases", arguments: validCases)
    func parsesValid(_ text: String, _ expected: JSON) throws {
        #expect(try JSON.parse(text) == expected)
    }

    // MARK: Surrogate escapes (a malformed pair used to trap on integer underflow)

    static let surrogateCases: [(String, String)] = [
        (U("D83D"), "\u{FFFD}"),
        (U("DE00"), "\u{FFFD}"),
        (U("D83D") + U("0041"), "\u{FFFD}A"),
        (U("D83D") + "A", "\u{FFFD}A"),
        (U("D83D") + U("D83D") + U("DE00"), "\u{FFFD}😀"),
        (U("DE00") + U("D83D"), "\u{FFFD}\u{FFFD}"),
        (U("D83D") + "\\n", "\u{FFFD}\n"),
    ]

    @Test("handles malformed surrogates without trapping", arguments: surrogateCases)
    func surrogates(_ body: String, _ expected: String) throws {
        #expect(try JSON.parse("\"" + body + "\"") == .string(expected))
    }

    // MARK: Numbers serialize exactly (0.00001 used to reach the model as 0)

    static let numberCases: [Double] = [
        0, -0.0, 1, -1, 42, 999_999_999_999_999, 1e15, 1e16, 0.5, 0.1, 1.0 / 3, 3.14159265358979,
        1e-5, 1e-7, 1e-300, 5e-324, 1.7976931348623157e308, -2.5e-10, 123_456.789, 2.0e21,
    ]

    @Test("numbers round-trip exactly", arguments: numberCases)
    func numbersRoundTrip(_ x: Double) throws {
        let text = JSON.number(x).serialized()
        #expect(try JSON.parse(text) == .number(x), "\(x) serialized as \(text)")
        if x == x.rounded(), abs(x) < 1e15 {
            #expect(!text.contains(".") && !text.contains("e"), "integers print without a fraction: \(text)")
        }
    }

    @Test func nonFiniteNumbersSerializeAsNull() {
        #expect(JSON.number(.nan).serialized() == "null")
        #expect(JSON.number(.infinity).serialized() == "null")
        #expect(JSON.number(-.infinity).serialized() == "null")
    }

    // MARK: String escaping

    static let escapeCases: [(String, String)] = [
        ("\"", #""\"""#),
        ("\\", #""\\""#),
        ("\n", #""\n""#),
        ("\t", #""\t""#),
        ("\r", #""\r""#),
        ("\u{01}", "\"" + U("0001") + "\""),
        ("\u{1F}", "\"" + U("001f") + "\""),
        ("é", "\"é\""),
        ("😀", "\"😀\""),
        ("/", "\"/\""),
        ("\u{7F}", "\"\u{7F}\""),
        ("\u{2028}", "\"\u{2028}\""),
    ]

    @Test("escapes strings minimally and reversibly", arguments: escapeCases)
    func escapes(_ raw: String, _ encoded: String) throws {
        #expect(JSON.string(raw).serialized() == encoded)
        #expect(try JSON.parse(encoded) == .string(raw))
    }

    // MARK: Nesting depth (unbounded recursion used to overflow the stack)

    @Test func nestingAtTheLimitParses() throws {
        let text = String(repeating: "[", count: JSON.maxDepth) + String(repeating: "]", count: JSON.maxDepth)
        #expect(try JSON.parse(text) != .null)
    }

    @Test func nestingBeyondTheLimitIsRejected() {
        #expect(throws: JSONParseError.self) { try JSON.parse(String(repeating: "[", count: 100_000)) }
        #expect(throws: JSONParseError.self) {
            try JSON.parse(String(repeating: "{\"a\":", count: JSON.maxDepth + 1) + "1" + String(repeating: "}", count: JSON.maxDepth + 1))
        }
    }

    // MARK: Accessors and formatting

    @Test func accessors() throws {
        let j = try JSON.parse(#"{"s":"x","n":2.5,"t":"3"}"#)
        #expect(j["s"]?.stringValue == "x")
        #expect(j["n"]?.doubleValue == 2.5)
        #expect(j["t"]?.doubleValue == 3)
        #expect(j["missing"] == nil)
        #expect(JSON.array([])["x"] == nil)
        #expect(JSON.number(1).stringValue == nil)
    }

    @Test func keyOrderIsPreserved() throws {
        let text = #"{"z":1,"a":2,"m":3}"#
        guard case let .object(pairs) = try JSON.parse(text) else { Issue.record("not an object"); return }
        #expect(pairs.map(\.0) == ["z", "a", "m"])
        #expect(try JSON.parse(text).serialized() == text)
    }

    @Test func prettyOutputIsIndentedAndReparses() throws {
        let v = JSON.object([("a", .array([.number(1), .object([("b", .null)])])), ("c", .object([]))])
        let pretty = v.serialized(pretty: true)
        #expect(pretty == "{\n  \"a\": [\n    1,\n    {\n      \"b\": null\n    }\n  ],\n  \"c\": {}\n}")
        #expect(try JSON.parse(pretty) == v)
    }

    // MARK: Properties over random documents

    static let roundTripSeeds = 0..<18

    @Test("random documents round-trip", arguments: roundTripSeeds)
    func randomRoundTrip(seed: Int) throws {
        var g = Gen(seed)
        let v = g.json(depth: 4)
        #expect(try JSON.parse(v.serialized()) == v)
        #expect(try JSON.parse(v.serialized(pretty: true)) == v)
    }

    static let foundationSeeds = 0..<10

    /// Our output must be valid JSON to Foundation, and we must read Foundation's output.
    @Test("interoperates with JSONSerialization", arguments: foundationSeeds)
    func agreesWithFoundation(seed: Int) throws {
        var g = Gen(seed)
        let v = g.container(uniqueKeys: true)
        let object = try JSONSerialization.jsonObject(with: Data(v.serialized().utf8), options: [.fragmentsAllowed])
        #expect(Self.same(Self.fromFoundation(object), v))
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        #expect(Self.same(try JSON.parse(data: data), v))
    }

    static func fromFoundation(_ o: Any) -> JSON {
        switch o {
        case is NSNull: return .null
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(fromFoundation))
        case let d as [String: Any]: return .object(d.map { ($0.key, fromFoundation($0.value)) })
        default: return .string("<\(type(of: o))>")
        }
    }

    /// Structural equality that ignores object key order and tolerates the
    /// last-digit differences of a decimal round trip.
    static func same(_ a: JSON, _ b: JSON) -> Bool {
        switch (a, b) {
        case let (.number(x), .number(y)): return close(x, y, tol: 1e-12)
        case let (.array(x), .array(y)): return x.count == y.count && zip(x, y).allSatisfy(same)
        case let (.object(x), .object(y)):
            let xs = x.sorted { $0.0 < $1.0 }, ys = y.sorted { $0.0 < $1.0 }
            return xs.count == ys.count && zip(xs, ys).allSatisfy { $0.0 == $1.0 && same($0.1, $1.1) }
        default: return a == b
        }
    }
}
