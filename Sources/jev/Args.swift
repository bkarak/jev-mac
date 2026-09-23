import Foundation
import JevCore

struct UsageError: JevError {
    let description: String
    init(_ d: String) { description = d }
}

/// Tiny `--option value` / `--option=value` / `--switch` parser. Unknown
/// options are errors: a typo must not silently swallow the next argument.
struct Args {
    var positional: [String] = []
    private var values: [String: String] = [:]
    private var switches: Set<String> = []

    /// Options every engine command accepts.
    static let engineOptions: Set<String> = ["model", "head", "samples", "sampling-temperature", "seed", "batch-size"]
    static let engineSwitches: Set<String> = ["no-cache", "prewarm", "fused"]

    init(_ argv: ArraySlice<String>, switches known: Set<String>, options: Set<String>) throws {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a == "--" {
                while let rest = it.next() { positional.append(rest) }
                break
            }
            guard a.hasPrefix("--"), a.count > 2 else { positional.append(a); continue }
            let body = String(a.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                let name = String(body[..<eq])
                if known.contains(name) { throw UsageError("--\(name) does not take a value") }
                guard options.contains(name) else { throw UsageError(Args.unknown(name, known.union(options))) }
                values[name] = String(body[body.index(after: eq)...])
                continue
            }
            if known.contains(body) { switches.insert(body); continue }
            guard options.contains(body) else { throw UsageError(Args.unknown(body, known.union(options))) }
            guard let v = it.next(), !v.hasPrefix("--") else { throw UsageError("--\(body) needs a value") }
            values[body] = v
        }
    }

    static func unknown(_ name: String, _ valid: Set<String>) -> String {
        "unknown option --\(name) (valid: \(valid.sorted().map { "--" + $0 }.joined(separator: " ")))"
    }

    func flag(_ n: String) -> Bool { switches.contains(n) }
    func string(_ n: String) -> String? { values[n] }

    func int(_ n: String, _ d: Int) throws -> Int {
        guard let s = values[n] else { return d }
        guard let v = Int(s) else { throw UsageError("--\(n) expects an integer, got '\(s)'") }
        return v
    }

    func double(_ n: String, _ d: Double) throws -> Double {
        guard let s = values[n] else { return d }
        guard let v = Double(s) else { throw UsageError("--\(n) expects a number, got '\(s)'") }
        return v
    }

    /// Shared engine options: --model, --head, --samples, --sampling-temperature, --seed, --no-cache, --batch-size.
    func agentConfig() throws -> AgentConfig {
        var c = AgentConfig()
        if let m = string("model") {
            guard let r = ModelRoute(rawValue: m) else {
                throw UsageError("--model must be one of \(ModelRoute.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            c.route = r
        }
        if let h = string("head") {
            guard let v = DecisionHead(rawValue: h) else { throw UsageError("--head must be distribution or vote") }
            c.head = v
        }
        c.samples = try int("samples", c.samples)
        c.samplingTemperature = try double("sampling-temperature", c.samplingTemperature)
        if let s = string("seed") {
            guard let v = UInt64(s) else { throw UsageError("--seed expects a non-negative integer") }
            c.seed = v
        }
        c.useCache = !flag("no-cache")
        c.prewarm = flag("prewarm")
        c.fused = flag("fused")
        if c.fused, c.head == .vote { throw UsageError("--fused works with --head distribution only") }
        c.batchSize = try int("batch-size", c.batchSize)
        guard c.samples >= 1, c.batchSize >= 1 else { throw UsageError("--samples and --batch-size must be ≥ 1") }
        return c
    }
}

func readFileOrStdin(_ path: String) throws -> String {
    if path == "-" {
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        throw UsageError("cannot read \(path): \((error as NSError).localizedDescription)")
    }
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
