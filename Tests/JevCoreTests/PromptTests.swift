import FoundationModels
import Testing
@testable import JevCore

@Suite("Prompts and schemas")
struct PromptTests {
    static let prefixSeeds = 0..<12

    @Test("prefixes carry every part of the question, in order", arguments: prefixSeeds)
    func prefixes(seed: Int) throws {
        var g = Gen(seed)
        let count = g.int(1...4)
        var qs: [Question] = []
        for i in 0..<count { qs.append(g.question(name: "q\(i)").expected) }
        for q in qs {
            for head in DecisionHead.allCases {
                let prefix = PromptBuilder.buildPrefix(q, head: head)
                #expect(prefix.contains("QUESTION TYPE: \(q.type.rawValue)"))
                #expect(Self.containsInOrder(prefix, [(q.type == .noul ? "PROPOSITION: " : "QUESTION: ") + q.instructions]))
                #expect(Self.containsInOrder(prefix, PromptBuilder.renderOptions(q).map { "- " + $0 }))
                #expect(prefix.contains(head == .distribution ? "integer weight from 0 to 100" : "Output the single best option."))
            }
        }
        let fused = PromptBuilder.buildFusedPrefix(qs)
        #expect(Self.containsInOrder(fused, qs.map { "## \($0.name)" }))
        for q in qs { #expect(Self.containsInOrder(fused, PromptBuilder.renderOptions(q).map { "- " + $0 })) }
    }

    /// Literal (code-unit) search: generated text may end in "\r", which
    /// merges with the prompt's next "\n" into one Character and would defeat
    /// a Character-level search even though the bytes are all there.
    static func containsInOrder(_ text: String, _ parts: [String]) -> Bool {
        var cursor = text.startIndex
        for part in parts {
            guard let r = text.range(of: part, options: .literal, range: cursor..<text.endIndex) else { return false }
            cursor = r.upperBound
        }
        return true
    }

    @Test func optionRendering() throws {
        let qs = try QuestionSet.parse(text: #"""
        {"c":{"type":"choice","instructions":"x","criteria":{"a":"first","b":""}},
         "s":{"type":"score","instructions":"y","levels":["low","high"]},
         "n":{"type":"noul","instructions":"Is late."}}
        """#)
        #expect(PromptBuilder.renderOptions(qs[0]) == ["a: first", "b"])
        #expect(PromptBuilder.renderOptions(qs[1]) == ["level 1: low", "level 2: high"])
        #expect(PromptBuilder.renderOptions(qs[2]) == [
            "yes: the STATE shows that: Is late.", "no: the STATE does not show that: Is late.",
        ])
    }

    static let clipCases: [(Int, Int)] = [(0, 10), (9, 10), (10, 10), (11, 10), (500, 280), (281, 280), (280, 280), (13_000, 12_000)]

    @Test("clip never exceeds its limit", arguments: clipCases)
    func clip(length: Int, limit: Int) {
        let s = String(repeating: "é", count: length)
        let c = PromptBuilder.clip(s, limit)
        #expect(c.count == min(length, limit))
        if length <= limit {
            #expect(c == s)
        } else {
            #expect(c.hasSuffix("…") && s.hasPrefix(c.dropLast()))
        }
    }

    static let stateCases: [(JSON, String)] = [
        (.string("plain text"), "plain text"),
        (.string(""), ""),
        (.object([("b", .number(1)), ("a", .array([.bool(true), .null]))]), #"{"b":1,"a":[true,null]}"#),
        (.array([.string("x")]), #"["x"]"#),
        (.number(2.5), "2.5"),
        (.number(0.00001), "1e-05"),
    ]

    @Test("states serialize as text or compact JSON", arguments: stateCases)
    func serializeState(state: JSON, expected: String) {
        #expect(PromptBuilder.serializeState(state) == expected)
    }

    @Test func sequencesAreLabelledAndClipped() {
        #expect(PromptBuilder.buildSequence(state: "hi") == "STATE:\nhi")
        let long = PromptBuilder.buildSequence(state: String(repeating: "x", count: 20_000))
        #expect(long.count == "STATE:\n".count + PromptBuilder.maxStateCharacters)
        #expect(long.hasSuffix("…"))
    }

    static let criterionCases: [(JSON, String)] = [
        (.string("text"), "text"),
        (.null, ""),
        (.object([("sla", .string("4h"))]), #"{"sla":"4h"}"#),
        (.number(3), "3"),
    ]

    @Test("criteria render as text", arguments: criterionCases)
    func renderCriterion(value: JSON, expected: String) {
        #expect(PromptBuilder.renderCriterion(value) == expected)
    }

    static let nameSeeds = 0..<12

    @Test("schema property names are unique identifiers", arguments: nameSeeds)
    func propertyNames(seed: Int) {
        var g = Gen(seed)
        let keys = Array(Set(g.uniqueKeys(g.int(2...10)) + ["a b", "a_b", "a-b", "9", "_", "é", "😀"])).sorted()
        let q = Question(name: "q", type: .choice, instructions: "x", options: keys.map { Option(key: $0) })
        let names = Heads.propertyNames(for: q)
        #expect(names.count == keys.count)
        #expect(Set(names).count == names.count)
        for n in names {
            #expect(!n.isEmpty && !n.first!.isNumber)
            #expect(n.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }, "\(n)")
        }
    }

    @Test func propertyNameExamples() throws {
        let q = Question(name: "q", type: .choice, instructions: "x", options: ["a b", "a-b", "9"].map { Option(key: $0) })
        #expect(Heads.propertyNames(for: q) == ["a_b", "a_b_2", "o_9"])
        let s = try QuestionSet.parse(text: #"{"u":{"type":"score","instructions":"x","levels":["a","b"]}}"#)[0]
        #expect(Heads.propertyNames(for: s) == ["level_1", "level_2"])
    }

    static let schemaSeeds = 0..<12

    @Test("schemas compile for arbitrary questions", arguments: schemaSeeds)
    func schemas(seed: Int) throws {
        var g = Gen(seed)
        let count = g.int(1...4)
        var qs: [Question] = []
        for i in 0..<count { qs.append(g.question(name: "q\(i)").expected) }
        for q in qs {
            let d = try Heads.prepare(q, head: .distribution)
            #expect(d.propertyNames.count == 1 && d.propertyNames[0].count == q.options.count)
            #expect(d.instructions == PromptBuilder.buildPrefix(q, head: .distribution))
            let v = try Heads.prepare(q, head: .vote)
            #expect(v.propertyNames.isEmpty && v.questions == [q] && !v.fused)
        }
        let f = try Heads.prepareFused(qs)
        #expect(f.fused && f.questions == qs && f.propertyNames.count == qs.count)
        #expect(f.instructions == PromptBuilder.buildFusedPrefix(qs))
    }

    @Test func fusedSchemasAcceptUnusualQuestionNames() throws {
        let qs = try QuestionSet.parse(text: #"""
        {"τμήμα":{"type":"noul","instructions":"x"},"has space":{"type":"noul","instructions":"y"},"a.b":{"type":"noul","instructions":"z"}}
        """#)
        #expect(try Heads.prepareFused(qs).questions.count == 3)
    }
}
