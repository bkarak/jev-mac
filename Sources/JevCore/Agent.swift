import Foundation
import FoundationModels

public struct AgentConfig: Sendable {
    public var route: ModelRoute = .auto
    public var head: DecisionHead = .distribution
    /// Number of sampled votes per question (vote head only).
    public var samples: Int = 5
    /// Sampling temperature for vote draws. Calibration temperature is per question.
    public var samplingTemperature: Double = 1.0
    public var seed: UInt64? = nil
    public var useCache: Bool = true
    /// Answer all questions in one guided call (distribution head only).
    public var fused: Bool = false
    /// Prewarm every newly created session (pooled sessions are warm anyway).
    public var prewarm: Bool = false
    public var cacheCapacity: Int = 64
    /// Maximum states processed concurrently by `predictBatch`.
    public var batchSize: Int = 4

    public init() {}
}

public struct Usage: Sendable {
    public var inputTokens = 0
    public var cachedTokens = 0
    public var outputTokens = 0
    public var calls = 0

    public init() {}

    mutating func add(_ u: LanguageModelSession.Usage) {
        inputTokens += u.input.totalTokenCount
        cachedTokens += u.input.cachedTokenCount
        outputTokens += u.output.totalTokenCount
        calls += 1
    }

    public mutating func add(_ o: Usage) {
        inputTokens += o.inputTokens
        cachedTokens += o.cachedTokens
        outputTokens += o.outputTokens
        calls += o.calls
    }
}

public struct Prediction: Sendable {
    public let answers: [Answer]
    public let route: ModelRoute
    public let language: String?
    public let languageSupported: Bool
    public let usage: Usage
    public let latencyMs: Double

    public subscript(name: String) -> Answer? { answers.first { $0.question.name == name } }

    public var json: JSON {
        var out: [(String, JSON)] = [
            ("answers", .object(answers.map { ($0.question.name, $0.json) })),
            ("model", .string(route.rawValue)),
        ]
        if let language {
            out.append(("language", .object([("code", .string(language)), ("supported", .bool(languageSupported))])))
        }
        out.append(("usage", .object([
            ("calls", .number(Double(usage.calls))),
            ("input_tokens", .number(Double(usage.inputTokens))),
            ("cached_input_tokens", .number(Double(usage.cachedTokens))),
            ("output_tokens", .number(Double(usage.outputTokens))),
        ])))
        out.append(("latency_ms", .number((latencyMs * 10).rounded() / 10)))
        return .object(out)
    }
}

/// Errors whose `description` is written for the user.
public protocol JevError: Error, CustomStringConvertible {}

public struct PredictionError: JevError {
    public let question: String
    public let underlying: Error
    public var description: String { "question '\(question)': \(Agent.explain(underlying))" }
}

/// Orchestrates a prediction: route → prefix (cached) → sequence → guided
/// generation → calibrated distribution, for every question concurrently.
public final class Agent: Sendable {
    public let config: AgentConfig
    public let router: Router
    let cache: PrefixCache

    public init(config: AgentConfig = AgentConfig(), router: Router = Router()) {
        self.config = config
        self.router = router
        // One idle session per request a prefix can see at once.
        let perPrefix = (config.head == .vote ? max(1, config.samples) : 1) * max(1, config.batchSize)
        cache = PrefixCache(router: router, capacity: config.cacheCapacity,
                            maxIdlePerEntry: max(4, perPrefix), prewarm: config.prewarm)
    }

    public var cacheStats: (hits: Int, misses: Int, entries: Int, reused: Int, created: Int) {
        get async { await (cache.hits, cache.misses, cache.count, cache.reuses, cache.created) }
    }

    /// Compiles every prefix and parks one prewarmed session for each, so the
    /// first real request finds its instructions already processed.
    public func warm(_ questions: [Question]) async throws {
        guard config.useCache else { return }
        let route = try router.resolve(config.route, estimatedTokens: 0)
        for q in questions {
            let (_, lease, _) = try await cache.checkout(q, head: config.head, route: route)
            if !lease.reused { lease.session.prewarm(promptPrefix: Prompt("STATE:\n")) }
            await cache.checkin(lease)
        }
    }

    public func predict(_ state: String, _ questions: [Question]) async throws -> Prediction {
        try await predict(state: .string(state), questions)
    }

    public func predict(state: JSON, _ questions: [Question]) async throws -> Prediction {
        let start = ContinuousClock.now
        let text = PromptBuilder.serializeState(state)
        let sequence = PromptBuilder.buildSequence(state: text)
        let lang = LanguageDetector.detect(text)
        let longestPrefix = questions.map { PromptBuilder.buildPrefix($0, head: config.head) }.max { $0.count < $1.count } ?? ""
        let route = try router.resolve(config.route, estimatedTokens: Router.estimateTokens(longestPrefix, sequence) + 64)

        var fusedResult: [(Int, Answer, Usage)]? = nil
        if config.fused, config.head == .distribution, questions.count > 1 {
            do {
                fusedResult = try await answerFused(questions, sequence: sequence, route: route)
            } catch LanguageModelError.refusal {
                fusedResult = nil  // fall through to per-question calls, which have their own fallback
            }
        }
        let results = if let fusedResult { fusedResult } else { try await withThrowingTaskGroup(of: (Int, Answer, Usage).self) { group in
            for (i, q) in questions.enumerated() {
                group.addTask {
                    do {
                        let (a, u) = try await self.answer(q, sequence: sequence, route: route)
                        return (i, a, u)
                    } catch {
                        throw PredictionError(question: q.name, underlying: error)
                    }
                }
            }
            var out: [(Int, Answer, Usage)] = []
            for try await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        } }

        var usage = Usage()
        for r in results { usage.add(r.2) }
        let elapsed = start.duration(to: .now)
        return Prediction(
            answers: results.map(\.1),
            route: route,
            language: lang?.code,
            languageSupported: lang.map { router.supportsLanguage($0.code) } ?? true,
            usage: usage,
            latencyMs: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        )
    }

    /// Runs many states through the same question set, `batchSize` at a time,
    /// preserving input order.
    public func predictBatch(_ states: [JSON], _ questions: [Question]) async -> [Result<Prediction, Error>] {
        var results = [Result<Prediction, Error>?](repeating: nil, count: states.count)
        let work: @Sendable (Int) async -> (Int, Result<Prediction, Error>) = { i in
            do { return (i, .success(try await self.predict(state: states[i], questions))) }
            catch { return (i, .failure(error)) }
        }
        await withTaskGroup(of: (Int, Result<Prediction, Error>).self) { group in
            var pending = states.indices.makeIterator()
            for _ in 0..<max(1, config.batchSize) {
                guard let i = pending.next() else { break }
                group.addTask { await work(i) }
            }
            for await (i, r) in group {
                results[i] = r
                if let j = pending.next() { group.addTask { await work(j) } }
            }
        }
        return results.map { $0! }
    }

    // MARK: - One question

    private enum Prefix {
        case single(Question, DecisionHead)
        case fused([Question])
    }

    /// Runs `body` with a session for `prefix`: a pooled one when the cache is
    /// on (returned to the pool only if `body` succeeds), a fresh one when it
    /// is off. `reused` tells whether the session already held the prefix.
    private func withSession<T>(_ prefix: Prefix, route: ModelRoute,
                                _ body: (PreparedQuestion, LanguageModelSession) async throws -> T) async throws -> (T, reused: Bool) {
        guard config.useCache else {
            let p: PreparedQuestion
            switch prefix {
            case let .single(q, head): p = try Heads.prepare(q, head: head)
            case let .fused(qs): p = try Heads.prepareFused(qs)
            }
            return (try await body(p, router.session(for: route, instructions: p.instructions)), false)
        }
        let p: PreparedQuestion, lease: PrefixCache.Lease
        switch prefix {
        case let .single(q, head): (p, lease, _) = try await cache.checkout(q, head: head, route: route)
        case let .fused(qs): (p, lease, _) = try await cache.checkoutFused(qs, route: route)
        }
        let result = try await body(p, lease.session)
        await cache.checkin(lease)
        return (result, lease.reused)
    }

    private func answer(_ q: Question, sequence: String, route: ModelRoute) async throws -> (Answer, Usage) {
        let start = ContinuousClock.now
        var usage = Usage()
        var head = config.head
        var fallback = false
        var raw: [Double]
        var cachedHit: Bool

        do {
            (raw, cachedHit) = try await readOut(q, head: head, sequence: sequence, route: route, usage: &usage)
        } catch LanguageModelError.refusal where head == .distribution {
            // The small model occasionally refuses the weight-per-option form
            // while answering the single-choice form of the same question.
            head = .vote
            fallback = true
            (raw, cachedHit) = try await readOut(q, head: head, sequence: sequence, route: route, usage: &usage)
        }

        let probs = Calibration.applyTemperature(raw, q.temperature)
        let elapsed = start.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return (Answer(question: q, probabilities: probs, head: head, fallback: fallback,
                       samples: head == .vote ? max(1, config.samples) : 1, latencyMs: ms, cached: cachedHit, fused: false), usage)
    }

    /// One call answers every question; usage is attributed to the first answer.
    private func answerFused(_ qs: [Question], sequence: String, route: ModelRoute) async throws -> [(Int, Answer, Usage)] {
        let start = ContinuousClock.now
        let ((distributions, u), reused) = try await withSession(.fused(qs), route: route) { p, s in
            let r = try await s.respond(to: sequence, schema: p.schema, options: GenerationOptions(samplingMode: .greedy))
            return (Heads.fusedDistributions(from: r.content, p), r.usage)
        }
        var usage = Usage()
        usage.add(u)
        let elapsed = start.duration(to: .now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return zip(qs, distributions).enumerated().map { i, pair in
            let probs = Calibration.applyTemperature(pair.1, pair.0.temperature)
            let a = Answer(question: pair.0, probabilities: probs, head: .distribution, fallback: false,
                           samples: 1, latencyMs: ms, cached: reused, fused: true)
            return (i, a, i == 0 ? usage : Usage())
        }
    }

    /// Runs one head and returns the raw (uncalibrated) distribution.
    private func readOut(_ q: Question, head: DecisionHead, sequence: String, route: ModelRoute,
                         usage: inout Usage) async throws -> ([Double], Bool) {
        switch head {
        case .distribution:
            let ((distribution, u), reused) = try await withSession(.single(q, head), route: route) { p, s in
                let r = try await s.respond(to: sequence, schema: p.schema, options: GenerationOptions(samplingMode: .greedy))
                return (Heads.distribution(from: r.content, q, p.propertyNames[0]), r.usage)
            }
            usage.add(u)
            return (distribution, reused)

        case .vote:
            let n = max(1, config.samples)
            let draws = try await withThrowingTaskGroup(of: (Int?, LanguageModelSession.Usage, Bool).self) { group in
                for k in 0..<n {
                    group.addTask {
                        let seed = self.config.seed.map { $0 &+ UInt64(k) }
                        let opts = GenerationOptions(samplingMode: .random(probabilityThreshold: 0.95, seed: seed),
                                                     temperature: self.config.samplingTemperature)
                        let ((vote, u), reused) = try await self.withSession(.single(q, head), route: route) { p, s in
                            let r = try await s.respond(to: sequence, schema: p.schema, options: opts)
                            return (Heads.vote(from: r.content, p), r.usage)
                        }
                        return (vote, u, reused)
                    }
                }
                var out: [(Int?, LanguageModelSession.Usage, Bool)] = []
                for try await d in group { out.append(d) }
                return out
            }
            var counts = Array(repeating: 0, count: q.options.count)
            var hit = false
            for (idx, u, h) in draws {
                usage.add(u)
                hit = hit || h
                if let idx { counts[idx] += 1 }
            }
            return (Calibration.fromVotes(counts), hit)
        }
    }

    /// Human-readable text for framework errors.
    public static func explain(_ error: Error) -> String {
        if let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: return "state too large for the model context window (try --model pcc)"
            case .guardrailViolation: return "blocked by Apple's safety guardrails"
            case .unsupportedLanguageOrLocale: return "language not supported by the model"
            case .rateLimited: return "rate limited by the system"
            case .refusal: return "the model refused to answer"
            case .timeout: return "the model timed out"
            default: return e.localizedDescription
            }
        }
        if let e = error as? any JevError { return e.description }
        // Unclassified framework failures arrive as NSErrors wrapping the
        // model manager's code; surface the innermost one.
        var ns = error as NSError
        while let inner = (ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError])?.first
                ?? ns.userInfo[NSUnderlyingErrorKey] as? NSError { ns = inner }
        if ns.domain.contains("ModelManager") {
            return "the system model manager rejected the request (\(ns.domain) \(ns.code)); "
                + "Private Cloud Compute may require a signed app with the Foundation Models entitlement"
        }
        return error.localizedDescription
    }
}
