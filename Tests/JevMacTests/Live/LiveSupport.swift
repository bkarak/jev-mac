import Foundation
import Testing
@testable import JevMac

/// Live tests call Apple's on-device model. They are opt-in:
///
///     JEV_MAC_LIVE=1 swift test --scratch-path /tmp/jev-mac-build --filter Live
enum Live {
    static let enabled = ProcessInfo.processInfo.environment["JEV_MAC_LIVE"] == "1"

    /// The engine exactly as `jev-mac predict` configures it by default.
    static let agent = Agent()

    /// Runs one labeled case: the output must be valid, and should be right.
    static func check(_ c: LiveCase) async {
        let p: Prediction
        do {
            p = try await agent.predict(state: c.state, [c.question])
        } catch {
            let text = Agent.explain(error)
            await LiveLedger.shared.add(LiveRow(c, error: text))
            Issue.record("ENGINE ERROR on \(c.id): \(text)")
            return
        }
        let invalid = Validity.violations(p, for: [c.question])
        #expect(invalid.isEmpty, "INVALID OUTPUT on \(c.id): \(invalid)")
        guard let a = p.answers.first else { return }
        let verdict = c.expect.judge(a)
        await LiveLedger.shared.add(LiveRow(c, answer: a, verdict: verdict, latencyMs: p.latencyMs, invalid: invalid.count))
        #expect(verdict.correct, "MODEL MISS on \(c.id): expected \(c.expect), got \(Live.describe(a)) · state: \(c.stateExcerpt)")
    }

    static func describe(_ a: Answer) -> String {
        let probs = zip(a.question.options, a.probabilities)
            .map { "\($0.key)=\(String(format: "%.2f", $1))" }.joined(separator: " ")
        return "\(a.decision) [\(probs)]\(a.fallback ? " (vote fallback)" : "")"
    }
}

/// What a labeled case accepts as a correct answer.
enum Expectation: Sendable, CustomStringConvertible {
    case key(String)
    case anyOf([String])
    case levels(ClosedRange<Double>)
    case truth(Bool)

    var description: String {
        switch self {
        case let .key(k): k
        case let .anyOf(ks): "one of \(ks.joined(separator: "/"))"
        case let .levels(r): r.lowerBound == r.upperBound ? "level \(Int(r.lowerBound))" : "level \(Int(r.lowerBound))–\(Int(r.upperBound))"
        case let .truth(t): t ? "true" : "false"
        }
    }

    /// Whether the decision is acceptable, and the probability mass the model
    /// put on acceptable answers.
    func judge(_ a: Answer) -> (correct: Bool, mass: Double) {
        switch self {
        case let .key(k):
            return (a.decision == k, a.probability(of: k))
        case let .anyOf(ks):
            return (ks.contains(a.decision), ks.reduce(0) { $0 + a.probability(of: $1) })
        case let .levels(r):
            let mass = zip(a.question.options, a.probabilities)
                .filter { r.contains($0.0.level ?? .nan) }.reduce(0) { $0 + $1.1 }
            return (r.contains(a.question.options[a.bestIndex].level ?? .nan), mass)
        case let .truth(t):
            let p = a.probability(of: "true")
            return ((p >= 0.5) == t, t ? p : 1 - p)
        }
    }
}

struct LiveCase: Sendable, CustomTestStringConvertible {
    let id: String
    let category: String
    let question: Question
    let state: JSON
    let expect: Expectation

    var testDescription: String { id }

    var stateExcerpt: String {
        let s = PromptBuilder.serializeState(state)
        return s.count > 120 ? String(s.prefix(117)) + "…" : s
    }
}

/// Properties every prediction must have, whether or not the model is right.
enum Validity {
    static func violations(_ p: Prediction, for questions: [Question]) -> [String] {
        var v: [String] = []
        if p.answers.map(\.question) != questions { v.append("answers do not match the questions, in order") }
        for a in p.answers {
            let q = a.question, probs = a.probabilities
            if probs.count != q.options.count { v.append("\(q.name): \(probs.count) probabilities for \(q.options.count) options") }
            if !probs.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) { v.append("\(q.name): probability outside [0, 1]") }
            if abs(probs.reduce(0, +) - 1) > 1e-6 { v.append("\(q.name): probabilities sum to \(probs.reduce(0, +))") }
            if !(0...1).contains(a.confidence) { v.append("\(q.name): confidence \(a.confidence)") }
            if let e = a.expectedScore {
                let levels = q.options.compactMap(\.level)
                if e < levels.min()! - 1e-9 || e > levels.max()! + 1e-9 { v.append("\(q.name): expected score \(e) outside the levels") }
            }
            if !(a.latencyMs > 0) { v.append("\(q.name): latency not measured") }
            if a.head == .vote && a.samples < 1 { v.append("\(q.name): vote without samples") }
        }
        if p.usage.calls < 1 { v.append("no model call recorded") }
        if p.route == .auto { v.append("route was not resolved") }
        do {
            let j = try JSON.parse(p.json.serialized())
            for a in p.answers {
                guard let aj = j["answers"]?[a.question.name] else { v.append("\(a.question.name) missing from JSON"); continue }
                switch a.question.type {
                case .choice:
                    if aj["decision"]?.stringValue != a.decision { v.append("\(a.question.name): JSON decision differs") }
                case .score:
                    if aj["decision"]?.doubleValue != a.question.options[a.bestIndex].level { v.append("\(a.question.name): JSON level differs") }
                case .noul:
                    if aj["decision"] != .bool(a.probability(of: "true") >= 0.5) { v.append("\(a.question.name): JSON decision differs") }
                }
            }
        } catch {
            v.append("prediction JSON does not parse: \(error)")
        }
        return v
    }
}

struct LiveRow: Sendable {
    let id: String
    let category: String
    let type: QuestionType
    let expected: String
    let got: String
    let correct: Bool
    let mass: Double?
    let brier: Double?
    let latencyMs: Double?
    let error: String?
    let invalid: Int
    let fallback: Bool

    init(_ c: LiveCase, error: String) {
        (id, category, type, expected) = (c.id, c.category, c.question.type, c.expect.description)
        (got, correct, mass, brier, latencyMs, self.error, invalid, fallback) = ("error", false, nil, nil, nil, error, 0, false)
    }

    init(_ c: LiveCase, answer a: Answer, verdict: (correct: Bool, mass: Double), latencyMs: Double, invalid: Int) {
        (id, category, type, expected) = (c.id, c.category, c.question.type, c.expect.description)
        got = Live.describe(a)
        correct = verdict.correct
        mass = verdict.mass
        if case let .truth(t) = c.expect {
            let d = a.probability(of: "true") - (t ? 1 : 0)
            brier = d * d
        } else {
            brier = nil
        }
        self.latencyMs = latencyMs
        error = nil
        self.invalid = invalid
        fallback = a.fallback
    }
}

actor LiveLedger {
    static let shared = LiveLedger()
    private(set) var rows: [LiveRow] = []

    func add(_ r: LiveRow) { rows.append(r) }

    func report() -> (summary: String, misses: String) {
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "–" : String(format: "%.1f%%", 100 * Double(n) / Double(d)) }
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }

        var order: [String] = []
        for r in rows where !order.contains(r.category) { order.append(r.category) }
        let hardware = Hardware.current()
        var out = ["", "── jev-mac live validity report " + String(repeating: "─", count: 44),
                   "machine     " + hardware.machine, "conditions  " + hardware.conditions, ""]
        out.append(pad("category", 24) + lpad("n", 5) + lpad("correct", 9) + lpad("accuracy", 10) + lpad("p(ok)", 8) + lpad("errors", 8))
        for cat in order {
            let rs = rows.filter { $0.category == cat }
            let ok = rs.filter(\.correct).count
            let masses = rs.compactMap(\.mass)
            let mass = masses.isEmpty ? "–" : String(format: "%.2f", masses.reduce(0, +) / Double(masses.count))
            out.append(pad(cat, 24) + lpad("\(rs.count)", 5) + lpad("\(ok)", 9) + lpad(pct(ok, rs.count), 10)
                       + lpad(mass, 8) + lpad("\(rs.filter { $0.error != nil }.count)", 8))
        }
        let byType = QuestionType.allCases.map { t -> String in
            let rs = rows.filter { $0.type == t }
            return "\(t.rawValue) \(pct(rs.filter(\.correct).count, rs.count)) (n=\(rs.count))"
        }
        let ok = rows.filter(\.correct).count
        let briers = rows.compactMap(\.brier)
        let lat = rows.compactMap(\.latencyMs).sorted()
        out.append("")
        out.append("by type      " + byType.joined(separator: " · "))
        out.append("overall      \(rows.count) cases · \(ok) correct (\(pct(ok, rows.count))) · "
                   + "\(rows.filter { $0.invalid > 0 }.count) invalid outputs · \(rows.filter { $0.error != nil }.count) engine errors · "
                   + "\(rows.filter(\.fallback).count) refusal fallbacks")
        if !briers.isEmpty {
            out.append(String(format: "noul Brier   %.3f  (0 = perfect, 0.25 = always saying 50%%)", briers.reduce(0, +) / Double(briers.count)))
        }
        if !lat.isEmpty {
            out.append(String(format: "latency      median %.0f ms · p90 %.0f ms", lat[lat.count / 2], lat[min(lat.count - 1, lat.count * 9 / 10)]))
        }
        let misses = rows.filter { !$0.correct }
            .map { "\($0.id)\texpected \($0.expected)\tgot \($0.error.map { "ERROR " + $0 } ?? $0.got)" }
            .joined(separator: "\n")
        return (out.joined(separator: "\n"), misses)
    }
}

/// Prints the report once the whole live suite has finished and saves it,
/// with every miss listed, next to the system temp directory.
struct LiveReport: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await function()
        guard await !LiveLedger.shared.rows.isEmpty else { return }
        let (summary, misses) = await LiveLedger.shared.report()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jev-mac-live-report.txt")
        try? (summary + "\n\nmisses\n" + misses + "\n").write(to: url, atomically: true, encoding: .utf8)
        print(summary + "\nfull report with every miss: \(url.path)\n")
    }
}

extension Trait where Self == LiveReport {
    static var liveReport: Self { LiveReport() }
}
