import Testing
@testable import JevCore

@Suite("Question schema")
struct QuestionTests {
    struct Valid: Sendable, CustomTestStringConvertible {
        let label: String
        let json: String
        let names: [String]
        let keys: [[String]]
        var levels: [[Double]]? = nil
        var criteria: [[String?]]? = nil
        var temperatures: [Double]? = nil
        var testDescription: String { label }
    }

    static let validCases: [Valid] = [
        Valid(label: "choice list", json: #"{"d":{"type":"choice","instructions":"Who?","criteria":["billing","tech"]}}"#,
              names: ["d"], keys: [["billing", "tech"]], criteria: [[nil, nil]]),
        Valid(label: "choice object keeps order",
              json: #"{"d":{"type":"choice","instructions":"Who?","criteria":{"z":"last","a":"first","m":"middle"}}}"#,
              names: ["d"], keys: [["z", "a", "m"]], criteria: [["last", "first", "middle"]]),
        Valid(label: "structured criteria become compact JSON",
              json: #"{"d":{"type":"choice","instructions":"x","criteria":{"a":{"sla":"4h","tier":2},"b":["x","y"]}}}"#,
              names: ["d"], keys: [["a", "b"]], criteria: [[#"{"sla":"4h","tier":2}"#, #"["x","y"]"#]]),
        Valid(label: "options alias", json: #"{"d":{"type":"choice","instructions":"x","options":["p","q","r"]}}"#,
              names: ["d"], keys: [["p", "q", "r"]]),
        Valid(label: "score list is one-based", json: #"{"u":{"type":"score","instructions":"x","levels":["low","mid","high"]}}"#,
              names: ["u"], keys: [["1", "2", "3"]], levels: [[1, 2, 3]], criteria: [["low", "mid", "high"]]),
        Valid(label: "score keys sort numerically", json: #"{"u":{"type":"score","instructions":"x","levels":{"10":"ten","9":"nine","1":"one"}}}"#,
              names: ["u"], keys: [["1", "9", "10"]], levels: [[1, 9, 10]]),
        Valid(label: "score decimal levels", json: #"{"u":{"type":"score","instructions":"x","levels":{"1.5":"b","0.5":"a"}}}"#,
              names: ["u"], keys: [["0.5", "1.5"]], levels: [[0.5, 1.5]]),
        Valid(label: "score negative levels", json: #"{"u":{"type":"score","instructions":"x","levels":{"1":"good","-1":"bad","0":"meh"}}}"#,
              names: ["u"], keys: [["-1", "0", "1"]], levels: [[-1, 0, 1]]),
        Valid(label: "noul defaults restate the proposition", json: #"{"r":{"type":"noul","instructions":"Wants a refund."}}"#,
              names: ["r"], keys: [["true", "false"]],
              criteria: [["the STATE shows that: Wants a refund.", "the STATE does not show that: Wants a refund."]]),
        Valid(label: "noul custom criteria", json: #"{"r":{"type":"noul","instructions":"x","criteria":{"true":"asked","false":"not asked"}}}"#,
              names: ["r"], keys: [["true", "false"]], criteria: [["asked", "not asked"]]),
        Valid(label: "noul partial criteria", json: #"{"r":{"type":"noul","instructions":"Is spam.","criteria":{"true":"spam"}}}"#,
              names: ["r"], keys: [["true", "false"]], criteria: [["spam", "the STATE does not show that: Is spam."]]),
        Valid(label: "noul null criteria means defaults", json: #"{"r":{"type":"noul","instructions":"x","criteria":null}}"#,
              names: ["r"], keys: [["true", "false"]]),
        Valid(label: "temperature number", json: #"{"q":{"type":"noul","instructions":"x","temperature":2}}"#,
              names: ["q"], keys: [["true", "false"]], temperatures: [2]),
        Valid(label: "temperature numeric string", json: #"{"q":{"type":"noul","instructions":"x","temperature":"0.5"}}"#,
              names: ["q"], keys: [["true", "false"]], temperatures: [0.5]),
        Valid(label: "question order is kept",
              json: #"{"b":{"type":"noul","instructions":"x"},"a":{"type":"noul","instructions":"y"},"c":{"type":"noul","instructions":"z"}}"#,
              names: ["b", "a", "c"], keys: [["true", "false"], ["true", "false"], ["true", "false"]], temperatures: [1, 1, 1]),
        Valid(label: "unicode names and keys",
              json: #"{"τμήμα":{"type":"choice","instructions":"Ποιο;","criteria":["λογιστήριο","τεχνικό"]}}"#,
              names: ["τμήμα"], keys: [["λογιστήριο", "τεχνικό"]]),
        Valid(label: "many options",
              json: #"{"l":{"type":"choice","instructions":"x","criteria":["a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z"]}}"#,
              names: ["l"], keys: [(97...122).map { String(UnicodeScalar(UInt8($0))) }]),
        Valid(label: "unknown fields are ignored", json: #"{"q":{"type":"noul","instructions":"x","notes":"ignored"}}"#,
              names: ["q"], keys: [["true", "false"]]),
    ]

    @Test("accepts valid specs", arguments: validCases)
    func acceptsValid(_ c: Valid) throws {
        let qs = try QuestionSet.parse(text: c.json)
        #expect(qs.map(\.name) == c.names)
        #expect(qs.map { $0.options.map(\.key) } == c.keys)
        if let levels = c.levels { #expect(qs.map { $0.options.compactMap(\.level) } == levels) }
        if let criteria = c.criteria { #expect(qs.map { $0.options.map(\.criterion) } == criteria) }
        if let t = c.temperatures { #expect(qs.map(\.temperature) == t) }
    }

    struct Invalid: Sendable, CustomTestStringConvertible {
        let label: String
        let json: String
        let message: String
        var testDescription: String { label }
    }

    static let invalidCases: [Invalid] = [
        Invalid(label: "top level array", json: "[]", message: "non-empty JSON object"),
        Invalid(label: "empty object", json: "{}", message: "non-empty JSON object"),
        Invalid(label: "question not an object", json: #"{"q":5}"#, message: "must be an object"),
        Invalid(label: "missing type", json: #"{"q":{"instructions":"x"}}"#, message: "type must be one of"),
        Invalid(label: "unknown type", json: #"{"q":{"type":"maybe","instructions":"x"}}"#, message: "type must be one of"),
        Invalid(label: "type not a string", json: #"{"q":{"type":5,"instructions":"x"}}"#, message: "type must be one of"),
        Invalid(label: "missing instructions", json: #"{"q":{"type":"noul"}}"#, message: "instructions are required"),
        Invalid(label: "blank instructions", json: #"{"q":{"type":"noul","instructions":"   "}}"#, message: "instructions are required"),
        Invalid(label: "instructions not a string", json: #"{"q":{"type":"noul","instructions":["x"]}}"#, message: "instructions are required"),
        Invalid(label: "choice without criteria", json: #"{"q":{"type":"choice","instructions":"x"}}"#, message: "requires 'criteria'"),
        Invalid(label: "choice criteria as text", json: #"{"q":{"type":"choice","instructions":"x","criteria":"a,b"}}"#, message: "requires 'criteria'"),
        Invalid(label: "choice with one option", json: #"{"q":{"type":"choice","instructions":"x","criteria":["a"]}}"#, message: "at least 2"),
        Invalid(label: "choice duplicate keys", json: #"{"q":{"type":"choice","instructions":"x","criteria":["a","a"]}}"#, message: "duplicate option keys"),
        Invalid(label: "choice non-string entry", json: #"{"q":{"type":"choice","instructions":"x","criteria":["a",1]}}"#, message: "must be strings"),
        Invalid(label: "choice empty key", json: #"{"q":{"type":"choice","instructions":"x","criteria":["a",""]}}"#, message: "must not be empty"),
        Invalid(label: "choice blank key", json: #"{"q":{"type":"choice","instructions":"x","criteria":{"a":"x","  ":"y"}}}"#, message: "must not be empty"),
        Invalid(label: "score without levels", json: #"{"q":{"type":"score","instructions":"x"}}"#, message: "requires 'levels'"),
        Invalid(label: "score single level", json: #"{"q":{"type":"score","instructions":"x","levels":["only"]}}"#, message: "at least 2 levels"),
        Invalid(label: "score non-numeric level", json: #"{"q":{"type":"score","instructions":"x","levels":{"high":"a","low":"b"}}}"#, message: "finite numbers"),
        Invalid(label: "score duplicate level values", json: #"{"q":{"type":"score","instructions":"x","levels":{"1":"a","1.0":"b"}}}"#, message: "same value"),
        Invalid(label: "score NaN level", json: #"{"q":{"type":"score","instructions":"x","levels":{"nan":"a","1":"b"}}}"#, message: "finite numbers"),
        Invalid(label: "score infinite level", json: #"{"q":{"type":"score","instructions":"x","levels":{"inf":"a","1":"b"}}}"#, message: "finite numbers"),
        Invalid(label: "noul criteria as a list", json: #"{"q":{"type":"noul","instructions":"x","criteria":["yes","no"]}}"#, message: "must be an object"),
        Invalid(label: "noul unknown criterion", json: #"{"q":{"type":"noul","instructions":"x","criteria":{"maybe":"?"}}}"#, message: "unknown noul criterion"),
        Invalid(label: "temperature zero", json: #"{"q":{"type":"noul","instructions":"x","temperature":0}}"#, message: "finite number > 0"),
        Invalid(label: "temperature negative", json: #"{"q":{"type":"noul","instructions":"x","temperature":-1}}"#, message: "finite number > 0"),
        Invalid(label: "temperature text", json: #"{"q":{"type":"noul","instructions":"x","temperature":"abc"}}"#, message: "must be a number"),
        Invalid(label: "temperature bool", json: #"{"q":{"type":"noul","instructions":"x","temperature":true}}"#, message: "must be a number"),
        Invalid(label: "temperature infinite", json: #"{"q":{"type":"noul","instructions":"x","temperature":"inf"}}"#, message: "finite number > 0"),
        Invalid(label: "empty question name", json: #"{"":{"type":"noul","instructions":"x"}}"#, message: "must not be empty"),
        Invalid(label: "duplicate question names",
                json: #"{"q":{"type":"noul","instructions":"x"},"q":{"type":"noul","instructions":"y"}}"#, message: "duplicate question name"),
    ]

    @Test("rejects invalid specs with a useful message", arguments: invalidCases)
    func rejectsInvalid(_ c: Invalid) {
        do {
            _ = try QuestionSet.parse(text: c.json)
            Issue.record("accepted an invalid spec")
        } catch let e as QuestionError {
            #expect(e.description.contains(c.message), "message was: \(e.description)")
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func malformedJSONIsAParseErrorNotASchemaError() {
        #expect(throws: JSONParseError.self) { try QuestionSet.parse(text: #"{"q":{"type":"noul",}}"#) }
    }

    static let randomSeeds = 0..<12

    @Test("random specs parse to the expected questions", arguments: randomSeeds)
    func randomSpecs(seed: Int) throws {
        var g = Gen(seed)
        let count = g.int(1...4)
        var generated: [(spec: JSON, expected: Question)] = []
        for i in 0..<count { generated.append(g.question(name: "q\(i)")) }
        let spec = JSON.object(generated.enumerated().map { ("q\($0.offset)", $0.element.spec) })
        #expect(try QuestionSet.parse(text: spec.serialized()) == generated.map(\.expected))
    }

    @Test("presets are valid question sets", arguments: Presets.all.map(\.name))
    func presetIsValid(_ name: String) throws {
        let qs = try Presets.questions(named: name)
        #expect(qs.count >= 3)
        #expect(Set(qs.map(\.type)) == Set(QuestionType.allCases), "each preset exercises all three types")
        #expect(Set(qs.map(\.name)).count == qs.count)
        #expect(try QuestionSet.parse(text: Presets.json(named: name)!) == qs)
    }

    @Test func unknownPresetsAreReported() {
        #expect(Set(Presets.all.map(\.name)).count == Presets.all.count)
        #expect(throws: QuestionError.self) { try Presets.questions(named: "nope") }
    }
}
