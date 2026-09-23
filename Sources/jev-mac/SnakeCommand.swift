import Foundation
import JevMac
import Synchronization

/// Terminal snake driven by typed decisions from Apple's foundation models.
enum SnakeCommand {
    static let switches = Args.engineSwitches.union(["max-speed", "unassisted", "headless", "lean", "trace"])
    static let options = Args.engineOptions.union(["fps", "width", "height", "moves", "policy"])

    /// Who picks the moves: the model, or a baseline to compare it with.
    enum Policy: String {
        case model, random, greedy
    }

    struct Decision {
        var probabilities: [Direction: Double]
        var deadEndRisk: Double?
        var foodReachable: Double?
        var move: Direction
        var intervened: Bool
        var latencyMs: Double
    }

    struct Stats {
        var moves = 0, deaths = 0, interventions = 0, food = 0, best = 0
        /// Moves where a safe move closer to the food existed, and how many took one.
        var closerAvailable = 0, closerTaken = 0
        var latencies: [Double] = []
        let started = ContinuousClock.now

        var elapsedSeconds: Double {
            let d = started.duration(to: .now)
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        var medianMs: Double {
            guard !latencies.isEmpty else { return 0 }
            return latencies.sorted()[latencies.count / 2]
        }
    }

    /// A baseline decision: a random safe move, or the safe move that gets closest to the food.
    static func baseline(_ policy: Policy, _ game: SnakeGame, _ rng: inout SplitMix64) -> Decision {
        let feats = game.allFeatures
        let safe = feats.filter { game.admissible($0) }
        let pool = safe.isEmpty ? feats.filter(\.legal) : safe
        let pick: MoveFeatures? = policy == .random
            ? pool.randomElement(using: &rng)
            : pool.min { ($0.eatsFood ? -1 : $0.foodDistance) < ($1.eatsFood ? -1 : $1.foodDistance) }
        let move = pick?.direction ?? .UP
        return Decision(probabilities: [move: 1], deadEndRisk: nil, foodReachable: nil,
                        move: move, intervened: false, latencyMs: 0)
    }

    /// Records whether the move closed in on the food when a safe way to do so existed.
    static func track(_ stats: inout Stats, _ game: SnakeGame, _ move: Direction) {
        let now = abs(game.head.x - game.food.x) + abs(game.head.y - game.food.y)
        let feats = game.allFeatures
        guard feats.contains(where: { game.admissible($0) && $0.foodDistance < now }) else { return }
        stats.closerAvailable += 1
        if game.features(move).foodDistance < now { stats.closerTaken += 1 }
    }

    static func decide(_ agent: Agent, _ questions: [Question], _ game: SnakeGame, assisted: Bool) async throws -> Decision {
        let p = try await agent.predict(state: .string(game.stateText), questions)
        guard let move = p["next_move"] else { throw UsageError("model returned no next_move") }
        var probs: [Direction: Double] = [:]
        for d in Direction.allCases { probs[d] = move.probability(of: d.rawValue) }
        let (dir, intervened) = SafetyShield.choose(game, probabilities: probs, assisted: assisted)
        return Decision(probabilities: probs,
                        deadEndRisk: p["safe_move"].map { 1 - $0.probability(of: "true") },
                        foodReachable: p["food_reachable"]?.probability(of: "true"),
                        move: dir, intervened: intervened, latencyMs: p.latencyMs)
    }

    static func run(_ args: Args) async throws {
        var config = try args.agentConfig()
        if args.string("model") == nil { config.route = .onDevice }
        let agent = Agent(config: config)
        let questions = try SnakeGame.questions(lean: args.flag("lean"))
        // Validate every option before touching the model or the terminal.
        let width = try args.int("width", 16)
        let height = try args.int("height", 12)
        guard (6...40).contains(width), (6...30).contains(height) else { throw UsageError("--width 6…40, --height 6…30") }
        var seed = config.seed ?? 7
        let moves = try args.int("moves", 200)
        guard moves >= 1 else { throw UsageError("--moves must be ≥ 1") }
        let fps = try args.double("fps", 4)
        guard fps.isFinite, fps > 0 else { throw UsageError("--fps must be > 0") }
        let assisted = !args.flag("unassisted")

        try await agent.warm(questions)

        guard let policy = Policy(rawValue: args.string("policy") ?? "model") else {
            throw UsageError("--policy must be model, random or greedy")
        }
        if args.flag("headless") {
            try await headless(agent, questions, width: width, height: height, seed: seed,
                               moves: moves, assisted: assisted, policy: policy, trace: args.flag("trace"))
            return
        }

        let controls = ControlBox(Controls(fps: fps, maxSpeed: args.flag("max-speed")))
        let term = Terminal()
        term.enter()
        defer { term.leave() }
        startKeyReader(controls)

        var game = SnakeGame(width: width, height: height, seed: seed)
        var stats = Stats()
        var last: Decision?
        var status = "warming up…"

        while true {
            let c = controls.state.withLock { c -> Controls in let copy = c; c.reset = false; return copy }
            if c.quit { break }
            if c.reset {
                seed &+= 1
                game = SnakeGame(width: width, height: height, seed: seed)
                last = nil
            }
            if c.paused {
                term.draw(frame(game, last, stats, c, status: "paused", assisted: assisted))
                try await Task.sleep(for: .milliseconds(60))
                continue
            }

            let tick = ContinuousClock.now
            do {
                let d = try await decide(agent, questions, game, assisted: assisted)
                last = d
                stats.latencies.append(d.latencyMs)
                if d.intervened { stats.interventions += 1 }
                track(&stats, game, d.move)
                let r = game.step(d.move)
                stats.moves += 1
                if r.ate { stats.food += 1 }
                stats.best = max(stats.best, game.score)
                status = r.died ? "crashed — restarting" : "running"
                if r.died {
                    stats.deaths += 1
                    term.draw(frame(game, last, stats, c, status: status, assisted: assisted))
                    try await Task.sleep(for: .milliseconds(700))
                    seed &+= 1
                    game = SnakeGame(width: width, height: height, seed: seed)
                }
            } catch {
                status = "error: " + Agent.explain(error)
            }
            term.draw(frame(game, last, stats, c, status: status, assisted: assisted))

            if !c.maxSpeed {
                let budget = Duration.milliseconds(Int(1000 / max(0.25, c.fps)))
                let spent = tick.duration(to: .now)
                if spent < budget { try await Task.sleep(for: budget - spent) }
            }
        }
        term.leave()
        print(summary(stats))
        print("machine     " + Hardware.current().machine)
    }

    static func headless(_ agent: Agent, _ questions: [Question], width: Int, height: Int, seed: UInt64, moves: Int,
                         assisted: Bool, policy: Policy = .model, trace: Bool = false) async throws {
        if policy == .model { Commands.printEnvironment(agent.router) } else { print("machine     " + Hardware.current().machine) }
        print("policy      \(policy.rawValue)\(policy == .model ? (questions.count == 1 ? " · next_move only" : " · \(questions.count) questions") : "")\n")
        var game = SnakeGame(width: width, height: height, seed: seed)
        var stats = Stats()
        var s = seed
        var rng = SplitMix64(seed: seed)
        for i in 1...max(1, moves) {
            let d = policy == .model ? try await decide(agent, questions, game, assisted: assisted)
                                     : baseline(policy, game, &rng)
            stats.latencies.append(d.latencyMs)
            if d.intervened { stats.interventions += 1 }
            track(&stats, game, d.move)
            if trace {
                let dist = abs(game.head.x - game.food.x) + abs(game.head.y - game.food.y)
                let probs = Direction.allCases.map { "\($0.rawValue) \(String(format: "%.2f", d.probabilities[$0] ?? 0))" }
                let next = game.features(d.move).foodDistance
                printErr("\(i): head (\(game.head.x),\(game.head.y)) food (\(game.food.x),\(game.food.y)) distance \(dist) · "
                         + probs.joined(separator: " ") + " → \(d.move.rawValue)\(d.intervened ? " (shield)" : "") · distance \(next)")
            }
            let r = game.step(d.move)
            stats.moves += 1
            if r.ate { stats.food += 1 }
            stats.best = max(stats.best, game.score)
            if r.died {
                stats.deaths += 1
                s &+= 1
                game = SnakeGame(width: width, height: height, seed: s)
            }
            if !trace { FileHandle.standardError.write(Data("\rmove \(i)/\(moves)".utf8)) }
        }
        printErr("")
        print(summary(stats))
        Commands.printEndConditions()
    }

    static func summary(_ s: Stats) -> String {
        String(format: "%d moves · %.2f moves/s · median decision %.0f ms · food %d · best score %d · deaths %d · shield interventions %d",
               s.moves, Double(s.moves) / max(0.001, s.elapsedSeconds), s.medianMs, s.food, s.best, s.deaths, s.interventions)
            + String(format: " · closed in on the food in %d of %d moves where that was safe (%.0f%%)",
                     s.closerTaken, s.closerAvailable, 100 * Double(s.closerTaken) / Double(max(1, s.closerAvailable)))
    }

    // MARK: Rendering

    /// The model and the chip it runs on, for the panel title.
    static let panelTitle = "\(Router().onDeviceVariant) on \(Hardware.current().chip)"

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1B}[48;2;\(r);\(g);\(b)m" }
    static let reset = "\u{1B}[0m"

    static func frame(_ g: SnakeGame, _ d: Decision?, _ s: Stats, _ c: Controls, status: String, assisted: Bool) -> [String] {
        var lines: [String] = []
        let body = Dictionary(uniqueKeysWithValues: g.body.enumerated().map { ($1, $0) })
        lines.append("┌" + String(repeating: "──", count: g.width) + "┐")
        for y in 0..<g.height {
            var row = "│"
            for x in 0..<g.width {
                let p = Point(x, y)
                if let i = body[p] {
                    let shade = max(60, 200 - i * 8)
                    row += (i == 0 ? rgb(250, 220, 80) : rgb(40, shade, 90)) + "  " + reset
                } else if p == g.food {
                    row += rgb(220, 60, 70) + "  " + reset
                } else {
                    row += rgb(24, 26, 32) + "  " + reset
                }
            }
            lines.append(row + "│")
        }
        lines.append("└" + String(repeating: "──", count: g.width) + "┘")

        var panel = [
            "JEV-MAC SNAKE · " + panelTitle,
            "",
            "score \(g.score)   length \(g.length)   best \(s.best)",
            "",
            "NEXT MOVE",
        ]
        for dir in Direction.allCases {
            let p = d?.probabilities[dir] ?? 0
            let mark = d?.move == dir ? "▶" : " "
            panel.append("\(mark) \(dir.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)) \(Commands.bar(p, width: 20)) \(String(format: "%.2f", p))")
        }
        panel.append("")
        if let r = d?.deadEndRisk { panel.append("DEAD-END RISK   \(Commands.bar(r, width: 12)) \(String(format: "%.2f", r))") }
        if let r = d?.foodReachable { panel.append("FOOD REACHABLE  \(Commands.bar(r, width: 12)) \(String(format: "%.2f", r))") }
        panel += [
            "",
            String(format: "decision  %.0f ms   median %.0f ms", d?.latencyMs ?? 0, s.medianMs),
            String(format: "rate      %.2f moves/s", Double(s.moves) / max(0.001, s.elapsedSeconds)),
            "pacing    " + (c.maxSpeed ? "max speed" : String(format: "%.2f fps target", c.fps)),
            "shield    " + (assisted ? "on · \(s.interventions) interventions" : "off (unassisted)"),
            "deaths    \(s.deaths)   moves \(s.moves)",
            "",
            "status    \(status)",
            "",
            "space pause · ↑/↓ speed · r reset · q quit",
        ]

        let n = max(lines.count, panel.count)
        let boardWidth = g.width * 2 + 2
        return (0..<n).map { i in
            let left = i < lines.count ? lines[i] : String(repeating: " ", count: boardWidth)
            let right = i < panel.count ? panel[i] : ""
            return left + "   " + right
        }
    }
}

final class ControlBox: Sendable {
    let state: Mutex<Controls>
    init(_ c: Controls) { state = Mutex(c) }
}

struct Controls: Sendable {
    var fps: Double
    var maxSpeed: Bool
    var paused = false
    var reset = false
    var quit = false
}

func startKeyReader(_ controls: ControlBox) {
    let t = Thread {
        var buf = [UInt8](repeating: 0, count: 8)
        while true {
            let n = read(STDIN_FILENO, &buf, 8)
            if n <= 0 { continue }
            let bytes = Array(buf[0..<n])
            controls.state.withLock { c in
                switch bytes {
                case [0x20]: c.paused.toggle()
                case [UInt8(ascii: "q")], [UInt8(ascii: "Q")], [0x03]: c.quit = true
                case [UInt8(ascii: "r")], [UInt8(ascii: "R")]: c.reset = true
                case [0x1B, 0x5B, 0x41]: c.maxSpeed = false; c.fps = min(30, c.fps * 1.5)
                case [0x1B, 0x5B, 0x42]: c.maxSpeed = false; c.fps = max(0.25, c.fps / 1.5)
                default: break
                }
            }
        }
    }
    t.start()
}

/// Raw mode + alternate screen, restored on exit.
final class Terminal {
    private var original = termios()
    private var active = false

    func enter() {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
        active = true
    }

    func leave() {
        guard active else { return }
        active = false
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }

    func draw(_ lines: [String]) {
        write("\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n") + "\u{1B}[J")
    }

    private func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
}
