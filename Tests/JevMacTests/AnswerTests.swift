import Foundation
import FoundationModels
import Testing
@testable import JevMac

@Suite("Answers and predictions")
struct AnswerTests {
    static let answerSeeds = 0..<20

    @Test("answer JSON agrees with the typed answer", arguments: answerSeeds)
    func answerJSON(seed: Int) throws {
        var g = Gen(seed)
        let q = g.question(name: "q").expected
        let probs = g.distribution(q.options.count)
        let head = g.pick(DecisionHead.allCases)
        let a = Answer(question: q, probabilities: probs, head: head, fallback: g.chance(0.2), samples: g.int(1...9),
                       latencyMs: g.double(0...5000), cached: g.chance(0.5), fused: g.chance(0.3))
        let j = try JSON.parse(a.json.serialized())
        let r = { (x: Double) in (x * 10_000).rounded() / 10_000 }
        let best = probs.indices.max { probs[$0] < probs[$1] }!

        #expect(j["type"]?.stringValue == q.type.rawValue)
        switch q.type {
        case .choice, .score:
            guard case let .object(pairs)? = j["probabilities"] else { Issue.record("no probabilities"); return }
            #expect(pairs.map(\.0) == q.options.map(\.key), "options keep their order")
            #expect(pairs.map { $0.1.doubleValue! } == probs.map(r), "four-decimal rounding")
            if q.type == .choice {
                #expect(j["decision"]?.stringValue == q.options[best].key)
            } else {
                #expect(j["decision"]?.doubleValue == q.options[best].level)
                let levels = q.options.compactMap(\.level)
                let e = try #require(j["expected"]?.doubleValue)
                #expect(e >= levels.min()! - 1e-4 && e <= levels.max()! + 1e-4)
            }
        case .noul:
            let pTrue = probs[0]
            #expect(j["probability"]?.doubleValue == r(pTrue))
            #expect(j["decision"] == .bool(pTrue >= 0.5))
        }
        let c = try #require(j["confidence"]?.doubleValue)
        #expect(c >= 0 && c <= 1)
        #expect(j["head"]?.stringValue?.hasPrefix(a.fused ? "fused" : head.rawValue) == true)
    }

    @Test func expectedScoreIsTheProbabilityWeightedLevel() throws {
        let q = try QuestionSet.parse(text: #"{"u":{"type":"score","instructions":"x","levels":{"1":"a","9":"b","10":"c"}}}"#)[0]
        let a = Answer(question: q, probabilities: [0.2, 0.3, 0.5], head: .distribution, fallback: false,
                       samples: 1, latencyMs: 1, cached: false, fused: false)
        #expect(close(a.expectedScore!, 7.9))
        #expect(a.decision == "10")
    }

    @Test func noulDecisionAtExactlyHalfIsTrue() throws {
        let q = try QuestionSet.parse(text: #"{"r":{"type":"noul","instructions":"x"}}"#)[0]
        let a = Answer(question: q, probabilities: [0.5, 0.5], head: .distribution, fallback: false,
                       samples: 1, latencyMs: 1, cached: false, fused: false)
        #expect(a.json["decision"] == .bool(true))
    }

    @Test func tiesGoToTheFirstOption() throws {
        let q = try QuestionSet.parse(text: #"{"c":{"type":"choice","instructions":"x","criteria":["a","b","c"]}}"#)[0]
        let a = Answer(question: q, probabilities: [0.25, 0.375, 0.375], head: .vote, fallback: false,
                       samples: 3, latencyMs: 1, cached: false, fused: false)
        #expect(a.decision == "b")
    }

    static func sampleAnswers() throws -> [Answer] {
        try QuestionSet.parse(text: #"{"d":{"type":"choice","instructions":"x","criteria":["a","b"]},"r":{"type":"noul","instructions":"y"}}"#)
            .map { Answer(question: $0, probabilities: [0.8, 0.2], head: .distribution, fallback: false,
                          samples: 1, latencyMs: 5, cached: false, fused: false) }
    }

    @Test func predictionJSONHasEverySection() throws {
        var usage = Usage()
        usage.inputTokens = 100; usage.cachedTokens = 40; usage.outputTokens = 12; usage.calls = 2
        let p = Prediction(answers: try Self.sampleAnswers(), route: .onDevice, language: "en",
                           languageSupported: true, usage: usage, latencyMs: 12.34)
        let j = try JSON.parse(p.json.serialized())
        guard case let .object(answers)? = j["answers"] else { Issue.record("no answers"); return }
        #expect(answers.map(\.0) == ["d", "r"])
        #expect(j["model"]?.stringValue == "on-device")
        #expect(j["language"]?["code"]?.stringValue == "en")
        #expect(j["language"]?["supported"] == .bool(true))
        #expect(j["usage"]?["calls"]?.doubleValue == 2)
        #expect(j["usage"]?["input_tokens"]?.doubleValue == 100)
        #expect(j["usage"]?["cached_input_tokens"]?.doubleValue == 40)
        #expect(j["usage"]?["output_tokens"]?.doubleValue == 12)
        #expect(j["latency_ms"]?.doubleValue == 12.3)
    }

    @Test func predictionJSONOmitsAnUndetectedLanguage() throws {
        let p = Prediction(answers: try Self.sampleAnswers(), route: .pcc, language: nil,
                           languageSupported: true, usage: Usage(), latencyMs: 1)
        let j = try JSON.parse(p.json.serialized())
        #expect(j["language"] == nil)
        #expect(j["model"]?.stringValue == "pcc")
    }

    @Test func predictionsAreAddressableByQuestionName() throws {
        let p = Prediction(answers: try Self.sampleAnswers(), route: .onDevice, language: nil,
                           languageSupported: true, usage: Usage(), latencyMs: 1)
        #expect(p["r"]?.question.type == .noul)
        #expect(p["nope"] == nil)
    }

    @Test func usageAccumulatesAcrossCalls() {
        var u = Usage()
        u.add(LanguageModelSession.Usage(input: .init(totalTokenCount: 300, cachedTokenCount: 100),
                                         output: .init(totalTokenCount: 20, reasoningTokenCount: 0)))
        var other = Usage()
        other.inputTokens = 50; other.cachedTokens = 5; other.outputTokens = 7; other.calls = 3
        u.add(other)
        #expect(u.inputTokens == 350 && u.cachedTokens == 105 && u.outputTokens == 27 && u.calls == 4)
    }

    @Test func explainUsesTheEnginesOwnDescriptions() {
        #expect(Agent.explain(QuestionError("bad spec")) == "bad spec")
        #expect(Agent.explain(RouterError(description: "no model")) == "no model")
        let wrapped = PredictionError(question: "urgency", underlying: RouterError(description: "no model"))
        #expect(Agent.explain(wrapped) == "question 'urgency': no model")
    }

    @Test func explainUnwrapsModelManagerRejections() {
        let inner = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1046)
        let middle = NSError(domain: "FoundationModels.LanguageModelError", code: -1,
                             userInfo: [NSMultipleUnderlyingErrorsKey: [inner]])
        let outer = NSError(domain: "FoundationModels.LanguageModelError", code: -1,
                            userInfo: [NSMultipleUnderlyingErrorsKey: [middle]])
        let text = Agent.explain(outer)
        #expect(text.contains("1046") && text.contains("entitlement"), "\(text)")
    }

    @Test func explainFallsBackToTheLocalizedDescription() {
        let e = NSError(domain: "Elsewhere", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(Agent.explain(e) == "boom")
    }
}
