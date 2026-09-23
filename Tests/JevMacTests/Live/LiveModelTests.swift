import Foundation
import Testing
@testable import JevMac

/// End-to-end checks against Apple's on-device model. A failing labeled case
/// is reported as MODEL MISS (wrong answer), INVALID OUTPUT (the engine broke
/// a guarantee) or ENGINE ERROR (the call failed); the suite prints an
/// accuracy report when it finishes.
@Suite("Live · on-device model", .enabled(if: Live.enabled, "set JEV_MAC_LIVE=1 to run against the model"),
       .serialized, .timeLimit(.minutes(3)), .liveReport)
struct LiveModelTests {
    // MARK: Labeled decisions (306) and snake positions (90)

    @Test("labeled decision", arguments: LiveCases.all)
    func labeled(_ c: LiveCase) async {
        await Live.check(c)
    }

    @Test("snake position", arguments: LiveSnake.cases)
    func snake(_ c: LiveCase) async {
        await Live.check(c)
    }

    // MARK: Engine behaviour on the real model (27)

    static let presetStates: [(String, String, String, Expectation)] = [
        ("triage", "I was charged twice for my March invoice. Please refund one of the payments.", "department", .key("billing")),
        ("email", "Congratulations!!! You have WON a $1000 gift card. Click here to claim now!", "spam", .truth(true)),
        ("moderation", "Does anyone know a good hiking trail near Lake Tahoe for beginners?", "category", .key("ok")),
        ("sentiment", "Absolutely love this phone, the camera is amazing!", "polarity", .key("positive")),
    ]

    @Test("a whole preset answers every question validly", arguments: presetStates)
    func wholePreset(preset: String, state: String, question: String, expect: Expectation) async throws {
        let qs = try Presets.questions(named: preset)
        let p = try await Live.agent.predict(state, qs)
        #expect(Validity.violations(p, for: qs).isEmpty, "\(Validity.violations(p, for: qs))")
        #expect(p.usage.calls >= qs.count)
        let a = try #require(p[question])
        #expect(expect.judge(a).correct, "MODEL MISS: expected \(expect), got \(Live.describe(a))")
    }

    static let voteAgent: Agent = {
        var c = AgentConfig()
        c.head = .vote
        c.samples = 3
        c.seed = 42
        return Agent(config: c)
    }()

    static let voteCases = LiveCases.department.enumerated().filter { $0.offset % 8 == 0 }.map(\.element)

    @Test("the vote head returns smoothed vote frequencies", arguments: voteCases)
    func voteHead(_ c: LiveCase) async throws {
        let p = try await Self.voteAgent.predict(state: c.state, [c.question])
        #expect(Validity.violations(p, for: [c.question]).isEmpty)
        let a = p.answers[0]
        #expect(a.head == .vote && a.samples == 3 && p.usage.calls == 3)
        let k = Double(a.probabilities.count)
        let counts = a.probabilities.map { $0 * (3 + 0.5 * k) - 0.5 }
        #expect(counts.allSatisfy { abs($0 - $0.rounded()) < 1e-9 && $0 > -1e-9 }, "not vote-shaped: \(a.probabilities)")
        #expect(counts.reduce(0, +) <= 3 + 1e-9)
        #expect(c.expect.judge(a).correct, "MODEL MISS: expected \(c.expect), got \(Live.describe(a))")
    }

    static let fusedAgent: Agent = {
        var c = AgentConfig()
        c.fused = true
        return Agent(config: c)
    }()

    static let fusedStates = [
        "The app crashes every time I open the settings page on my iPhone.",
        "We're a team of 50 — can you send a quote for the Enterprise plan?",
        "Please delete my account and all my personal data.",
    ]

    @Test("the fused head answers everything in one call, or falls back cleanly", arguments: fusedStates)
    func fusedHead(_ state: String) async throws {
        let qs = try Presets.questions(named: "triage")
        let p = try await Self.fusedAgent.predict(state, qs)
        #expect(Validity.violations(p, for: qs).isEmpty, "\(Validity.violations(p, for: qs))")
        let fused = p.answers.map(\.fused)
        #expect((fused.allSatisfy { $0 } && p.usage.calls == 1) || fused.allSatisfy { !$0 })
    }

    @Test func batchKeepsInputOrder() async throws {
        let q = LiveCases.preset("triage", "department")
        let states: [JSON] = [0, 10, 20, 30, 1, 11].map { LiveCases.department[$0].state }
        let results = await Live.agent.predictBatch(states, [q])
        #expect(results.count == states.count)
        for (s, r) in zip(states, results) {
            let batch = try r.get()
            let single = try await Live.agent.predict(state: s, [q])
            #expect(batch.answers[0].probabilities == single.answers[0].probabilities, "result out of order for \(s)")
        }
    }

    static let determinismStates = [
        "The dashboard takes over a minute to load and sometimes times out.",
        "How do I change the email address associated with my profile?",
        "Is there volume pricing if we buy more than 100 seats?",
        "My bank shows a pending charge from you that I don't recognise.",
    ]

    @Test("greedy read-out is deterministic", arguments: determinismStates)
    func deterministic(_ state: String) async throws {
        var c = AgentConfig()
        c.useCache = false
        let agent = Agent(config: c)
        let qs = try Presets.questions(named: "triage")
        let a = try await agent.predict(state, qs), b = try await agent.predict(state, qs)
        guard !a.answers.contains(where: \.fallback), !b.answers.contains(where: \.fallback) else { return }
        #expect(a.answers.map(\.probabilities) == b.answers.map(\.probabilities))
    }

    static let temperatureStates = [
        "The camera is excellent, but the battery life is terrible.",
        "The package was delivered on Tuesday at 3pm.",
        "I'm really disappointed with the quality of this jacket.",
    ]

    @Test("calibration temperature is applied to the same raw distribution", arguments: temperatureStates)
    func temperature(_ state: String) async throws {
        func polarity(_ t: Double) throws -> Question {
            try QuestionSet.parse(text: #"{"polarity":{"type":"choice","instructions":"What is the overall sentiment of the text?","criteria":["positive","neutral","negative","mixed"],"temperature":"# + "\(t)}}")[0]
        }
        let p1 = try await Live.agent.predict(state, [polarity(1)]).answers[0]
        let p3 = try await Live.agent.predict(state, [polarity(3)]).answers[0]
        let p03 = try await Live.agent.predict(state, [polarity(0.3)]).answers[0]
        guard !p1.fallback, !p3.fallback, !p03.fallback else { return }
        #expect(zip(p3.probabilities, Calibration.applyTemperature(p1.probabilities, 3)).allSatisfy { close($0, $1) })
        #expect(zip(p03.probabilities, Calibration.applyTemperature(p1.probabilities, 0.3)).allSatisfy { close($0, $1) })
        #expect(p3.decision == p1.decision && p03.decision == p1.decision)
    }

    @Test func reusedSessionsServeThePrefixFromCacheWithoutLeaking() async throws {
        let agent = Agent()
        let q = LiveCases.preset("sentiment", "polarity")
        let first = try await agent.predict("I liked the movie.", [q])
        let second = try await agent.predict("The hotel was fine.", [q])
        #expect(!first.answers[0].cached && second.answers[0].cached)
        #expect(second.usage.cachedTokens > 0, "the instructions come from the model's cache")
        let stats = await agent.cacheStats
        #expect(stats.hits == 1 && stats.misses == 1 && stats.entries == 1 && stats.reused == 1 && stats.created == 1)
        var off = AgentConfig()
        off.useCache = false
        let fresh = try await Agent(config: off).predict("The hotel was fine.", [q])
        #expect(second.usage.inputTokens == fresh.usage.inputTokens, "no trace of the earlier request in the reused session")
    }

    static let languageStates: [(String, String, Bool)] = [
        ("Το κινητό ζεσταίνεται πολύ και κολλάει όταν παίζω παιχνίδια.", "el", false),
        ("The phone gets very hot and freezes when I play games.", "en", true),
        ("Le téléphone chauffe beaucoup et se bloque quand je joue.", "fr", true),
    ]

    @Test("languages are detected and unsupported ones flagged", arguments: languageStates)
    func language(text: String, code: String, supported: Bool) async throws {
        let q = LiveCases.preset("sentiment", "polarity")
        let p = try await Live.agent.predict(text, [q])
        #expect(p.language == code && p.languageSupported == supported)
        #expect(try JSON.parse(p.json.serialized())["language"]?["supported"] == .bool(supported))
        #expect(Validity.violations(p, for: [q]).isEmpty)
    }

    @Test(.enabled(if: CLI.binary != nil)) func cliPrintsTheDocumentedJSON() throws {
        let r = try CLI.run(["predict", "--preset", "triage", "I was charged twice. Please refund the duplicate payment."])
        #expect(r.status == 0, "\(r.stderr)")
        let j = try JSON.parse(r.stdout)
        guard case let .object(answers)? = j["answers"] else { Issue.record("no answers"); return }
        #expect(answers.map(\.0) == ["department", "urgency", "wants_refund"])
        for (_, a) in answers { for key in ["type", "decision", "confidence", "head", "latency_ms"] { #expect(a[key] != nil, "\(key)") } }
        #expect(j["model"]?.stringValue == "on-device")
        #expect((j["usage"]?["calls"]?.doubleValue ?? 0) >= 3)
    }

    @Test(.enabled(if: CLI.binary != nil)) func cliSummaryListsEveryQuestion() throws {
        let r = try CLI.run(["predict", "--preset", "sentiment", "--summary", "Absolutely love this phone!"])
        #expect(r.status == 0, "\(r.stderr)")
        for line in ["polarity [choice]", "intensity [score]", "sarcastic [noul]", "on-device · 3 calls"] {
            #expect(r.stdout.contains(line), "missing \(line)")
        }
    }

    @Test(.enabled(if: CLI.binary != nil)) func cliBatchStreamsOneResultPerLineInOrder() throws {
        let states = ["I forgot my password.", "Please refund my last invoice.", "The app crashes on start."]
        let r = try CLI.run(["predict", "--preset", "triage", "--batch", "-"], stdin: states.joined(separator: "\n"))
        #expect(r.status == 0, "\(r.stderr)")
        let lines = r.stdout.split(separator: "\n")
        #expect(lines.count == states.count)
        for line in lines { #expect((try? JSON.parse(String(line)))?["answers"] != nil) }
    }
}
