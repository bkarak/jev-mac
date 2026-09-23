import Foundation
import FoundationModels

/// How a question's probability distribution is read out of the model.
///
/// Apple's foundation models do not expose token log-probabilities, so the
/// engine replaces laya's classifier heads with constrained generation:
///
/// * `distribution` — one guided call whose schema asks for the single best
///   option first, then an integer weight (0–100) for every option. One round
///   trip, full distribution. (Weights alone showed strong position bias.)
/// * `vote` — `samples` guided calls with random sampling, each constrained
///   to exactly one option key; the empirical frequencies (with add-½
///   smoothing) form the distribution. Slower, better calibrated.
public enum DecisionHead: String, Sendable, CaseIterable {
    case distribution
    case vote
}

/// A compiled prefix: session instructions + generation schema + the
/// property ↔ option mapping. Covers one question, or a whole question set
/// when fused.
public struct PreparedQuestion: Sendable {
    public let questions: [Question]
    public let head: DecisionHead
    public let fused: Bool
    public let instructions: String
    public let schema: GenerationSchema
    /// Schema property name for each option of each question (distribution head only).
    let propertyNames: [[String]]

    public var question: Question { questions[0] }
}

enum Heads {
    /// The keys the model sees. A noul question is asked as yes/no — its
    /// options stay "true"/"false" everywhere else. Asked with bare
    /// true/false, refund requests came back 17/20; as yes/no, 20/20.
    static func schemaKeys(for q: Question) -> [String] {
        q.type == .noul && q.options.map(\.key) == ["true", "false"] ? ["yes", "no"] : q.options.map(\.key)
    }

    static func prepare(_ q: Question, head: DecisionHead) throws -> PreparedQuestion {
        let instructions = PromptBuilder.buildPrefix(q, head: head)
        switch head {
        case .distribution:
            let (root, names) = decisionSchema(q, name: "Decision")
            return PreparedQuestion(questions: [q], head: head, fused: false, instructions: instructions,
                                    schema: try GenerationSchema(root: root, dependencies: []), propertyNames: [names])
        case .vote:
            let choice = DynamicGenerationSchema(name: "OptionKey", anyOf: schemaKeys(for: q))
            let root = DynamicGenerationSchema(name: "Decision", properties: [
                .init(name: "answer", description: "The chosen option", schema: choice),
            ])
            return PreparedQuestion(questions: [q], head: head, fused: false, instructions: instructions,
                                    schema: try GenerationSchema(root: root, dependencies: []), propertyNames: [])
        }
    }

    /// One schema with a decision object per question, answered in a single call.
    static func prepareFused(_ qs: [Question]) throws -> PreparedQuestion {
        var props: [DynamicGenerationSchema.Property] = []
        var names: [[String]] = []
        for (i, q) in qs.enumerated() {
            let (schema, n) = decisionSchema(q, name: "Decision\(i)")
            props.append(.init(name: q.name, description: q.instructions, schema: schema))
            names.append(n)
        }
        let root = DynamicGenerationSchema(name: "Answers", properties: props)
        return PreparedQuestion(questions: qs, head: .distribution, fused: true,
                                instructions: PromptBuilder.buildFusedPrefix(qs),
                                schema: try GenerationSchema(root: root, dependencies: []), propertyNames: names)
    }

    /// The model commits to one option first (an enum: the form it answers
    /// most reliably), then writes weights. Asked for weights alone, it piled
    /// the mass onto an early option regardless of content: German, Spanish
    /// and Italian text all came back "french", the second slot.
    static func decisionSchema(_ q: Question, name: String) -> (DynamicGenerationSchema, [String]) {
        let (weights, names) = weightsSchema(q, name: name + "Weights")
        let answer = DynamicGenerationSchema(name: name + "Answer", anyOf: schemaKeys(for: q))
        return (DynamicGenerationSchema(name: name, description: "Best option, then a weight per option", properties: [
            .init(name: "answer", description: "The single best option", schema: answer),
            .init(name: "weights", description: "Weight 0-100 per option", schema: weights),
        ]), names)
    }

    static func weightsSchema(_ q: Question, name: String) -> (DynamicGenerationSchema, [String]) {
        let names = propertyNames(for: q)
        let props = zip(schemaKeys(for: q), names).map { option, name in
            DynamicGenerationSchema.Property(
                name: name,
                description: "Weight 0-100 for \(q.type == .score ? "level " : "")\(option)",
                schema: DynamicGenerationSchema(type: Int.self, guides: [.range(0...100)])
            )
        }
        return (DynamicGenerationSchema(name: name, description: "Weight per option", properties: props), names)
    }

    /// Readable, unique identifiers derived from option keys.
    static func propertyNames(for q: Question) -> [String] {
        var used = Set<String>()
        return schemaKeys(for: q).map { key in
            let base = q.type == .score ? "level_" + key : key
            var s = String(base.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            if s.isEmpty || s.first!.isNumber { s = "o_" + s }
            var candidate = s
            var n = 2
            while used.contains(candidate) { candidate = "\(s)_\(n)"; n += 1 }
            used.insert(candidate)
            return candidate
        }
    }

    static func weights(from content: GeneratedContent, _ names: [String]) -> [Double] {
        names.map { Double((try? content.value(Int.self, forProperty: $0)) ?? 0) }
    }

    /// The distribution a decision object stands for (see `reconcile`).
    static func distribution(from content: GeneratedContent, _ q: Question, _ names: [String]) -> [Double] {
        let key = try? content.value(String.self, forProperty: "answer")
        let answer = key.flatMap { schemaKeys(for: q).firstIndex(of: $0) }
        let raw = (try? content.value(GeneratedContent.self, forProperty: "weights")).map { weights(from: $0, names) }
        return reconcile(raw ?? Array(repeating: 0, count: names.count), answer: answer)
    }

    /// Per-question distributions from a fused response, in question order.
    static func fusedDistributions(from content: GeneratedContent, _ p: PreparedQuestion) -> [[Double]] {
        zip(p.questions, p.propertyNames).map { q, names in
            guard let sub = try? content.value(GeneratedContent.self, forProperty: q.name) else {
                return Calibration.normalize(Array(repeating: 0, count: names.count))
            }
            return distribution(from: sub, q, names)
        }
    }

    /// Normalized weights in which the stated answer holds the largest share:
    /// if the weights disagree, the answer swaps shares with the top option
    /// (and wins exact ties). Without usable weights the answer counts as one
    /// vote; without an answer the weights stand alone.
    static func reconcile(_ w: [Double], answer: Int?) -> [Double] {
        guard let a = answer, w.indices.contains(a) else { return Calibration.normalize(w) }
        guard w.contains(where: { $0.isFinite && $0 > 0 }) else {
            return Calibration.fromVotes(w.indices.map { $0 == a ? 1 : 0 })
        }
        var p = Calibration.normalize(w)
        let top = p.indices.max { p[$0] < p[$1] }!
        if p[a] < p[top] { p.swapAt(a, top) }
        let tied = p.indices.filter { $0 != a && p[$0] == p[a] }
        if !tied.isEmpty {
            let shift = p[a] * 0.001
            for t in tied { p[t] -= shift }
            p[a] += shift * Double(tied.count)
        }
        return p
    }

    static func vote(from content: GeneratedContent, _ p: PreparedQuestion) -> Int? {
        guard let key = try? content.value(String.self, forProperty: "answer") else { return nil }
        return schemaKeys(for: p.question).firstIndex(of: key)
    }
}

// MARK: - Calibration and read-out

public enum Calibration {
    /// Normalizes non-negative weights; all-zero becomes uniform.
    public static func normalize(_ w: [Double]) -> [Double] {
        let clipped = w.map { max(0, $0.isFinite ? $0 : 0) }
        let total = clipped.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1 / Double(w.count), count: w.count) }
        return clipped.map { $0 / total }
    }

    /// Temperature scaling on probabilities: p_i^(1/T), renormalized.
    /// T > 1 flattens, T < 1 sharpens. A small floor keeps zero weights from
    /// being unrecoverable under flattening.
    ///
    /// Computed in log space: raising small probabilities to a large power
    /// underflows to zero, which used to turn extreme sharpening into a
    /// uniform distribution.
    public static func applyTemperature(_ p: [Double], _ t: Double) -> [Double] {
        guard t != 1, !p.isEmpty else { return p }
        let floor = 1e-4
        let logits = p.map { log(max($0, floor)) / t }
        let top = logits.max()!
        return normalize(logits.map { exp($0 - top) })
    }

    /// Frequencies with add-½ (Jeffreys) smoothing.
    public static func fromVotes(_ counts: [Int]) -> [Double] {
        normalize(counts.map { Double($0) + 0.5 })
    }

    /// 1 − normalized entropy: 1 for a one-hot distribution, 0 for uniform.
    public static func confidence(_ p: [Double]) -> Double {
        guard p.count > 1 else { return 1 }
        let h = p.reduce(0) { $1 > 0 ? $0 - $1 * log($1) : $0 }
        return max(0, 1 - h / log(Double(p.count)))
    }
}

/// The typed answer for one question.
public struct Answer: Sendable {
    public let question: Question
    public let probabilities: [Double]
    public let head: DecisionHead
    /// True when the distribution head was refused and the vote head answered instead.
    public let fallback: Bool
    public let samples: Int
    public let latencyMs: Double
    public let cached: Bool
    /// Answered as part of a single fused call for the whole question set.
    public let fused: Bool

    public var bestIndex: Int { probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0 }
    public var decision: String { question.options[bestIndex].key }
    public var confidence: Double { Calibration.confidence(probabilities) }

    public func probability(of key: String) -> Double {
        question.options.firstIndex { $0.key == key }.map { probabilities[$0] } ?? 0
    }

    /// Σ level · p for score questions.
    public var expectedScore: Double? {
        guard question.type == .score else { return nil }
        return zip(question.options, probabilities).reduce(0) { $0 + ($1.0.level ?? 0) * $1.1 }
    }

    public var json: JSON {
        let r = { (x: Double) in (x * 10_000).rounded() / 10_000 }
        let probs = JSON.object(zip(question.options, probabilities).map { ($0.key, .number(r($1))) })
        var out: [(String, JSON)] = [("type", .string(question.type.rawValue))]
        switch question.type {
        case .choice:
            out += [("decision", .string(decision)), ("probabilities", probs)]
        case .score:
            out += [("decision", .number(question.options[bestIndex].level ?? 0)),
                    ("expected", .number(r(expectedScore ?? 0))), ("probabilities", probs)]
        case .noul:
            let pTrue = probability(of: "true")
            out += [("decision", .bool(pTrue >= 0.5)), ("probability", .number(r(pTrue)))]
        }
        out += [("confidence", .number(r(confidence))),
                ("head", .string(fused ? "fused" : head.rawValue + (fallback ? " (fallback)" : ""))),
                ("samples", .number(Double(samples))),
                ("latency_ms", .number((latencyMs * 10).rounded() / 10)),
                ("prefix_cached", .bool(cached))]
        return .object(out)
    }
}
