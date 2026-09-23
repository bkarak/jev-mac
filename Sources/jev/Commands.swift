import Foundation
import JevCore

enum Commands {
    static let predictSwitches = Args.engineSwitches.union(["pretty", "summary"])
    static let predictOptions = Args.engineOptions.union(["questions", "preset", "state-file", "batch"])
    static let benchSwitches = Args.engineSwitches
    static let benchOptions = Args.engineOptions.union(["questions", "preset", "runs", "suite", "warmups"])

    // MARK: check

    static func check() {
        let r = Router()
        print("Apple foundation models")
        print("  on-device (general)   \(r.onDeviceAvailability())")
        print("  on-device (tagging)   \(r.taggingAvailability())")
        print("  private cloud compute \(r.pccAvailability())")
        if r.onDeviceAvailability() == "available" {
            print("  on-device variant     \(r.onDeviceVariant)")
            print("  on-device context     \(r.onDeviceContextSize) tokens")
        }
    }

    // MARK: presets

    static func presets(_ args: Args) throws {
        if let name = args.positional.first {
            guard let json = Presets.json(named: name) else { throw UsageError("unknown preset '\(name)'") }
            print(json)
            return
        }
        for p in Presets.all {
            print("\(p.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.summary)")
        }
        print("\nShow one with: jev presets <name>")
    }

    static func loadQuestions(_ args: Args) throws -> [Question] {
        if args.string("questions") != nil, args.string("preset") != nil {
            throw UsageError("give either --questions or --preset, not both")
        }
        if let path = args.string("questions") {
            return try QuestionSet.parse(text: readFileOrStdin(path))
        }
        if let name = args.string("preset") { return try Presets.questions(named: name) }
        throw UsageError("give --questions FILE or --preset NAME (see: jev presets)")
    }

    /// A state line: JSON if it parses, otherwise the raw text.
    static func stateValue(_ text: String) -> JSON {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first == "{" || first == "[" || first == "\"", let j = try? JSON.parse(t) { return j }
        return .string(t)
    }

    // MARK: predict

    static func predict(_ args: Args) async throws {
        let questions = try loadQuestions(args)
        let agent = Agent(config: try args.agentConfig())

        if let batchPath = args.string("batch") {
            let states = try readFileOrStdin(batchPath)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(stateValue)
            var failures = 0
            for (i, r) in await agent.predictBatch(states, questions).enumerated() {
                switch r {
                case let .success(p): print(p.json.serialized())
                case let .failure(e):
                    failures += 1
                    print(JSON.object([("index", .number(Double(i))), ("error", .string(Agent.explain(e)))]).serialized())
                }
            }
            if failures > 0 { printErr("\(failures) of \(states.count) states failed") }
            return
        }

        let state: JSON
        if let path = args.string("state-file") {
            state = stateValue(try readFileOrStdin(path))
        } else if !args.positional.isEmpty {
            state = stateValue(args.positional.joined(separator: " "))
        } else if isatty(STDIN_FILENO) == 0 {
            state = stateValue(try readFileOrStdin("-"))
        } else {
            throw UsageError("no state given: pass text, --state-file FILE, or pipe it on stdin")
        }

        if case let .string(text) = state, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw UsageError("the state is empty")
        }
        let p = try await agent.predict(state: state, questions)
        if !p.languageSupported, let l = p.language {
            printErr("warning: detected language '\(l)' is not supported by the on-device model")
        }
        if args.flag("summary") {
            printSummary(p)
        } else {
            print(p.json.serialized(pretty: args.flag("pretty")))
        }
    }

    static func bar(_ p: Double, width: Int = 24) -> String {
        let n = Int((p * Double(width)).rounded())
        return String(repeating: "█", count: n) + String(repeating: "·", count: width - n)
    }

    static func printSummary(_ p: Prediction) {
        for a in p.answers {
            let q = a.question
            switch q.type {
            case .noul:
                let t = a.probability(of: "true")
                print("\(q.name) [noul] → \(t >= 0.5 ? "true" : "false")  P(true)=\(String(format: "%.3f", t))  \(bar(t))")
            case .choice, .score:
                var head = "\(q.name) [\(q.type.rawValue)] → \(q.type == .score ? "level " : "")\(a.decision)"
                if let e = a.expectedScore { head += "  expected=\(String(format: "%.2f", e))" }
                print(head + "  confidence=\(String(format: "%.2f", a.confidence))")
                let w = q.options.map(\.key.count).max() ?? 0
                for (o, pr) in zip(q.options, a.probabilities) {
                    print("    \(o.key.padding(toLength: w, withPad: " ", startingAt: 0))  \(bar(pr))  \(String(format: "%.3f", pr))")
                }
            }
        }
        print(String(format: "\n%@ · %d calls · %d in / %d cached / %d out tokens · %.0f ms",
                     p.route.rawValue, p.usage.calls, p.usage.inputTokens, p.usage.cachedTokens, p.usage.outputTokens, p.latencyMs))
    }

    // MARK: bench

    static let benchState = "Hi, I was charged twice for my subscription this month and my card is now overdrawn. Please refund the duplicate charge today."

    static func bench(_ args: Args) async throws {
        switch args.string("suite") {
        case nil, "preset": try await benchPreset(args)
        case "latency": try await benchLatency(args)
        case "fizzbuzz": try await benchFizzBuzz(args)
        case let s?: throw UsageError("--suite must be preset, latency or fizzbuzz, got '\(s)'")
        }
    }

    /// Open-Jev's latency protocol over the 11-workload matrix.
    static func benchLatency(_ args: Args) async throws {
        let warmups = try args.int("warmups", 3), runs = try args.int("runs", 20)
        guard warmups >= 0, runs >= 1 else { throw UsageError("--warmups must be ≥ 0 and --runs ≥ 1") }
        // Open-Jev times with the prefix cache off; identical repeated requests
        // would otherwise be served largely from a reused session's cache.
        var config = try args.agentConfig()
        config.useCache = false
        let agent = Agent(config: config)
        print("Latency protocol · \(warmups) warmups · \(runs) timed requests · concurrency 1 · prefix cache off · \(agent.router.onDeviceVariant)")
        let workloads = try await Workloads.matrix()
        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
        func lpad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        print(pad("workload", 34) + lpad("state tok", 10) + lpad("calls", 7) + lpad("in tok", 8) + lpad("out tok", 9)
              + lpad("P50 ms", 9) + lpad("P95 ms", 9))
        for w in workloads {
            let tokens = try await agent.router.tokenCount(w.state)
            let s = try await LatencyProtocol.measure(w, agent: agent, warmups: warmups, runs: runs)
            print(pad(w.name, 34) + lpad("\(tokens)", 10) + lpad(String(format: "%.0f", s.callsPerRequest), 7)
                  + lpad(String(format: "%.0f", s.inputTokensPerRequest), 8) + lpad(String(format: "%.0f", s.outputTokensPerRequest), 9)
                  + lpad(String(format: "%.1f", s.p50), 9) + lpad(String(format: "%.1f", s.p95), 9))
        }
    }

    /// The FizzBuzz control: 100 integers × 3 typed questions, exact ground truth.
    static func benchFizzBuzz(_ args: Args) async throws {
        let agent = Agent(config: try args.agentConfig())
        let r = await FizzBuzzSuite.run(agent: agent) { n in FileHandle.standardError.write(Data("\r  n = \(n)/100".utf8)) }
        printErr("")
        print("FizzBuzz control · integers 1–100 · 3 typed questions · \(r.total * FizzBuzzSuite.questions.count) decisions")
        for q in FizzBuzzSuite.questions {
            print("  \(q.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.correct[q.name, default: 0])/\(r.total)")
        }
        let ok = r.correct.values.reduce(0, +), all = r.total * FizzBuzzSuite.questions.count
        print(String(format: "  overall %d/%d (%.1f%%)", ok, all, 100 * Double(ok) / Double(all)))
        if r.errors > 0 { print("  errors \(r.errors)") }
        for m in r.misses.prefix(12) { print("  miss   \(m)") }
        if r.misses.count > 12 { print("  … \(r.misses.count - 12) more") }
    }

    static func benchPreset(_ args: Args) async throws {
        let questions = args.string("questions") != nil || args.string("preset") != nil
            ? try loadQuestions(args) : try Presets.questions(named: "triage")
        let runs = try args.int("runs", 10)
        guard runs >= 1 else { throw UsageError("--runs must be ≥ 1") }
        let state = args.positional.isEmpty ? benchState : args.positional.joined(separator: " ")
        let agent = Agent(config: try args.agentConfig())

        print("Benchmarking \(questions.count) questions × \(runs) runs (head=\(agent.config.head.rawValue), cache=\(agent.config.useCache ? "on" : "off"))")
        let cold = try await agent.predict(state, questions)
        print(String(format: "  cold   %.0f ms (%@)", cold.latencyMs, cold.route.rawValue))

        var lat: [Double] = []
        var usage = Usage()
        for i in 1...runs {
            let p = try await agent.predict(state, questions)
            lat.append(p.latencyMs)
            usage.add(p.usage)
            FileHandle.standardError.write(Data("\r  run \(i)/\(runs)".utf8))
        }
        printErr("")
        lat.sort()
        let pct = { (q: Double) in lat[min(lat.count - 1, Int((Double(lat.count - 1) * q).rounded()))] }
        let mean = lat.reduce(0, +) / Double(lat.count)
        print(String(format: "  warm   median %.0f ms · p90 %.0f ms · mean %.0f ms · min %.0f · max %.0f", pct(0.5), pct(0.9), mean, lat.first!, lat.last!))
        print(String(format: "  rate   %.2f predictions/s · %.2f questions/s", 1000 / mean, 1000 / mean * Double(questions.count)))
        print(String(format: "  tokens %.0f in (%.0f%% cached) · %.0f out per prediction",
                     Double(usage.inputTokens) / Double(runs),
                     usage.inputTokens > 0 ? 100 * Double(usage.cachedTokens) / Double(usage.inputTokens) : 0,
                     Double(usage.outputTokens) / Double(runs)))
        let stats = await agent.cacheStats
        print("  cache  \(stats.hits) hits · \(stats.misses) misses · \(stats.entries) prefixes · "
              + "\(stats.reused) sessions reused · \(stats.created) created")
    }
}
