import Foundation
import FoundationModels

/// A fixed request replayed by the latency protocol.
public struct Workload: Sendable {
    public let name: String
    public let state: String
    public let questions: [Question]
}

/// Workloads shaped after Open-Jev's published latency study
/// (github.com/Zefan-Cai/Open-Jev, docs/inference-latency.md): two demo
/// requests plus a matrix of state sizes (128/512/1,024 tokens) × candidate
/// counts (2/8/32). The original texts are not public, so these reproduce the
/// shape, not the exact inputs.
public enum Workloads {
    public static let customerService = Workload(
        name: "customer service · 8 boolean",
        state: """
        Hi, this is Maria Keller (order #58213). I ordered a standing desk three weeks ago and it arrived \
        with a cracked frame and a missing screw set. I've emailed twice with no answer and I'm honestly fed up. \
        I want a full refund, not a replacement, and if this isn't sorted by Friday I'll cancel my business \
        account with you. Please call me back at 555-0142 — I'd rather speak to a real person.
        """,
        questions: try! QuestionSet.parse(text: #"""
        {"wants_refund":{"type":"noul","instructions":"The customer asks for their money back."},
         "wants_replacement":{"type":"noul","instructions":"The customer asks for a replacement product."},
         "item_damaged":{"type":"noul","instructions":"The item arrived damaged or incomplete."},
         "repeat_contact":{"type":"noul","instructions":"The customer has contacted support about this before."},
         "churn_risk":{"type":"noul","instructions":"The customer threatens to leave or cancel their account."},
         "wants_callback":{"type":"noul","instructions":"The customer asks to be phoned or to speak to a person."},
         "positive_tone":{"type":"noul","instructions":"The customer's tone is positive."},
         "has_order_number":{"type":"noul","instructions":"The message includes an order number."}}
        """#))

    public static let drone = Workload(
        name: "drone · 3 typed",
        state: """
        Drone D-7 telemetry: altitude 118 m, battery 23%, distance to home 2.4 km, wind 31 km/h gusting to \
        45 km/h from the west, 14 GPS satellites, payload attached. The return flight needs about 18% battery \
        in calm air.
        """,
        questions: try! QuestionSet.parse(text: #"""
        {"action":{"type":"choice","instructions":"What should the drone do next?",
           "criteria":{"continue_mission":"keep flying the planned route","return_home":"fly back to the home point now",
                       "land_now":"land immediately where it is","hover":"hold position and wait"}},
         "risk":{"type":"score","instructions":"How risky is the current flight situation?",
           "levels":["negligible","low","moderate","high","critical"]},
         "strong_wind":{"type":"noul","instructions":"The wind is stronger than 25 km/h."}}
        """#))

    static let products = [
        "running shoes", "laptop sleeve", "coffee grinder", "yoga mat", "desk lamp", "wireless earbuds",
        "hiking backpack", "electric kettle", "phone charger", "winter jacket", "board game", "office chair",
        "water bottle", "bike helmet", "camping tent", "kitchen knife set", "smart watch", "baby stroller",
        "garden hose", "travel pillow", "gaming mouse", "sunglasses", "air purifier", "standing desk",
        "rain boots", "guitar strings", "printer ink", "dog bed", "bath towels", "wall clock",
        "vacuum cleaner", "tennis racket",
    ]
    static let cities = ["Athens", "Lisbon", "Oslo", "Porto", "Lyon", "Gdansk", "Turin", "Ghent", "Bergen", "Malmo", "Split", "Cork"]

    /// A state of `tokens` tokens (±1 line, measured with the model's own
    /// tokenizer) and one choice question over `candidates` product categories.
    public static func synthetic(tokens: Int, candidates: Int, model: SystemLanguageModel = .default) async throws -> Workload {
        precondition((2...products.count).contains(candidates))
        let options = Array(products.prefix(candidates))
        let target = options[(tokens + candidates) % candidates]
        let request = "Customer request: I need help choosing a new \(target) for my next trip."
        var lines: [String] = []
        var i = 0
        while try await model.tokenCount(for: (lines + [request]).joined(separator: "\n")) < tokens {
            lines.append("Note \(i + 1): order #\(10_000 + i * 37) for a \(products[(i * 7) % products.count]) "
                         + "was shipped to \(cities[i % cities.count]) on day \(i % 28 + 1) and signed for at the door.")
            i += 1
        }
        let criteria = options.map { "\"\($0.replacingOccurrences(of: " ", with: "_"))\":\"\($0)\"" }.joined(separator: ",")
        let question = try QuestionSet.parse(text: """
        {"category":{"type":"choice","instructions":"Which product category is the customer request about?","criteria":{\(criteria)}}}
        """)
        return Workload(name: "\(tokens) state tokens · \(candidates) candidates",
                        state: (lines + [request]).joined(separator: "\n"), questions: question)
    }

    /// The 11-workload matrix: both demo requests, then state size × candidate count.
    public static func matrix(model: SystemLanguageModel = .default) async throws -> [Workload] {
        var all = [customerService, drone]
        for tokens in [128, 512, 1_024] {
            for candidates in [2, 8, 32] { all.append(try await synthetic(tokens: tokens, candidates: candidates, model: model)) }
        }
        return all
    }
}

public struct LatencyStats: Sendable {
    public let samplesMs: [Double]
    public let usage: Usage
    public let runs: Int

    /// Linear interpolation between order statistics (numpy's default).
    public static func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let rank = q * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    public var p50: Double { Self.percentile(samplesMs, 0.5) }
    public var p95: Double { Self.percentile(samplesMs, 0.95) }
    public var callsPerRequest: Double { Double(usage.calls) / Double(max(1, runs)) }
    public var inputTokensPerRequest: Double { Double(usage.inputTokens) / Double(max(1, runs)) }
    public var outputTokensPerRequest: Double { Double(usage.outputTokens) / Double(max(1, runs)) }
}

/// Open-Jev's timing protocol: warm up, then time each request end to end,
/// one at a time, with no reuse of results between requests.
public enum LatencyProtocol {
    public static func measure(_ w: Workload, agent: Agent, warmups: Int = 3, runs: Int = 20) async throws -> LatencyStats {
        for _ in 0..<warmups { _ = try await agent.predict(w.state, w.questions) }
        var samples: [Double] = []
        var usage = Usage()
        for _ in 0..<runs {
            let start = ContinuousClock.now
            let p = try await agent.predict(w.state, w.questions)
            let d = start.duration(to: .now)
            samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
            usage.add(p.usage)
        }
        return LatencyStats(samplesMs: samples, usage: usage, runs: runs)
    }
}

/// The FizzBuzz control: integers 1–100, three typed questions each, 300
/// decisions with exact ground truth. Reconstructed from Open-Jev's
/// one-line description of its suite.
public enum FizzBuzzSuite {
    public static let questions = try! QuestionSet.parse(text: #"""
    {"div3":{"type":"noul","instructions":"n is divisible by 3."},
     "div5":{"type":"noul","instructions":"n is divisible by 5."},
     "say":{"type":"choice","instructions":"What does FizzBuzz print for n?",
       "criteria":{"number":"n itself, when n is divisible by neither 3 nor 5","Fizz":"n is divisible by 3 but not by 5",
                   "Buzz":"n is divisible by 5 but not by 3","FizzBuzz":"n is divisible by both 3 and 5"}}}
    """#)

    public static func state(_ n: Int) -> JSON { .object([("n", .number(Double(n)))]) }

    /// The correct decision for each question, keyed by question name.
    public static func truth(_ n: Int) -> [String: String] {
        let three = n % 3 == 0, five = n % 5 == 0
        return ["div3": three ? "true" : "false", "div5": five ? "true" : "false",
                "say": three && five ? "FizzBuzz" : three ? "Fizz" : five ? "Buzz" : "number"]
    }

    public struct Result: Sendable {
        public var correct: [String: Int] = [:]
        public var total = 0
        public var misses: [String] = []
        public var errors = 0
    }

    public static func run(agent: Agent, numbers: ClosedRange<Int> = 1...100,
                           progress: (@Sendable (Int) -> Void)? = nil) async -> Result {
        var r = Result()
        for n in numbers {
            progress?(n)
            let expected = truth(n)
            r.total += 1
            do {
                let p = try await agent.predict(state: state(n), questions)
                for a in p.answers {
                    if a.decision == expected[a.question.name] {
                        r.correct[a.question.name, default: 0] += 1
                    } else {
                        r.misses.append("n=\(n) \(a.question.name): expected \(expected[a.question.name]!), got \(a.decision)")
                    }
                }
            } catch {
                r.errors += 1
                r.misses.append("n=\(n): \(Agent.explain(error))")
            }
        }
        return r
    }
}
