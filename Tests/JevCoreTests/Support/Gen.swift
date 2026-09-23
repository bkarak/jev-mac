import Foundation
@testable import JevCore

/// Seeded generator: every property-test case is reproducible from its seed.
struct Gen {
    var rng: SplitMix64

    init(_ seed: Int) { rng = SplitMix64(seed: 0xA5A5_0000 &+ UInt64(seed)) }

    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
    mutating func double(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &rng) }
    mutating func chance(_ p: Double) -> Bool { double(0...1) < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }
    mutating func shuffled<T>(_ xs: [T]) -> [T] { xs.shuffled(using: &rng) }

    /// Pieces chosen to stress escaping: quotes, backslashes, control
    /// characters, non-ASCII, emoji, line separators and JSON punctuation.
    static let pieces: [String] = [
        "a", "b", "z", "Q", "0", "7", " ", "_", "-", ".", "é", "ß", "Ω", "中", "😀", "👩‍💻",
        "\"", "\\", "/", "\n", "\t", "\r", "\u{01}", "\u{1F}", "\u{7F}", "\u{2028}",
        "{", "}", "[", "]", ":", ",",
    ]

    mutating func text(max: Int = 12) -> String {
        (0..<int(0...max)).map { _ in pick(Gen.pieces) }.joined()
    }

    /// Integers, fractions, tiny and huge magnitudes.
    mutating func number() -> Double {
        switch int(0...5) {
        case 0: return Double(int(-1000...1000))
        case 1: return double(-1...1)
        case 2: return double(-1e6...1e6)
        case 3: return double(-1...1) * 1e-9
        case 4: return Double(int(-999_999_999_999_999...999_999_999_999_999))
        default: return double(-1...1) * 1e22
        }
    }

    mutating func json(depth: Int = 3, uniqueKeys: Bool = false) -> JSON {
        switch int(0...(depth == 0 ? 3 : 5)) {
        case 0: return .null
        case 1: return .bool(chance(0.5))
        case 2: return .number(number())
        case 3: return .string(text())
        case 4: return .array((0..<int(0...4)).map { _ in json(depth: depth - 1, uniqueKeys: uniqueKeys) })
        default:
            var pairs: [(String, JSON)] = []
            for _ in 0..<int(0...4) {
                let k = text(max: 6)
                if uniqueKeys, pairs.contains(where: { $0.0 == k }) { continue }
                pairs.append((k, json(depth: depth - 1, uniqueKeys: uniqueKeys)))
            }
            return .object(pairs)
        }
    }

    /// A top-level container (what JSONSerialization accepts without fragments).
    mutating func container(uniqueKeys: Bool) -> JSON {
        chance(0.5)
            ? .object((0..<int(1...5)).reduce(into: [(String, JSON)]()) { acc, _ in
                let k = "k" + text(max: 5)
                if !acc.contains(where: { $0.0 == k }) { acc.append((k, json(depth: 2, uniqueKeys: uniqueKeys))) }
            })
            : .array((0..<int(1...5)).map { _ in json(depth: 2, uniqueKeys: uniqueKeys) })
    }

    /// A probability vector with some exact zeros.
    mutating func distribution(_ n: Int) -> [Double] {
        Calibration.normalize((0..<n).map { _ in chance(0.15) ? 0 : double(0.001...1) })
    }

    mutating func uniqueKeys(_ n: Int) -> [String] {
        var keys: [String] = []
        while keys.count < n {
            let k = pick(["k", "Opt", "é", "中", "x y", "a-b", "9", "_"]) + text(max: 4)
            if !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !keys.contains(k) { keys.append(k) }
        }
        return keys
    }

    /// A random valid question spec and the question the engine must build from it.
    mutating func question(name: String) -> (spec: JSON, expected: Question) {
        let type = pick(QuestionType.allCases)
        let instructions = "Q " + text(max: 20)
        var spec: [(String, JSON)] = [("type", .string(type.rawValue)), ("instructions", .string(instructions))]
        var temperature = 1.0
        if chance(0.3) {
            temperature = (double(0.1...5) * 100).rounded() / 100
            spec.append(("temperature", .number(temperature)))
        }
        var options: [Option] = []
        switch type {
        case .choice:
            let keys = uniqueKeys(int(2...6))
            if chance(0.5) {
                spec.append(("criteria", .array(keys.map { .string($0) })))
                options = keys.map { Option(key: $0) }
            } else {
                let values = keys.map { _ in chance(0.7) ? JSON.string(text()) : json(depth: 1) }
                spec.append(("criteria", .object(Array(zip(keys, values)))))
                options = zip(keys, values).map { Option(key: $0, criterion: PromptBuilder.renderCriterion($1)) }
            }
        case .score:
            let n = int(2...6)
            if chance(0.5) {
                let values = (0..<n).map { _ in JSON.string(text()) }
                spec.append(("levels", .array(values)))
                options = values.enumerated().map {
                    Option(key: String($0 + 1), criterion: PromptBuilder.renderCriterion($1), level: Double($0 + 1))
                }
            } else {
                var levels = Set<Int>()
                while levels.count < n { levels.insert(int(-5...20)) }
                let keys = shuffled(Array(levels)).map { chance(0.2) ? "\($0).5" : String($0) }
                let values = keys.map { _ in JSON.string(text()) }
                spec.append(("levels", .object(Array(zip(keys, values)))))
                options = zip(keys, values).map {
                    Option(key: $0, criterion: PromptBuilder.renderCriterion($1), level: Double($0)!)
                }.sorted { $0.level! < $1.level! }
            }
        case .noul:
            let p = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            var t = "the STATE shows that: \(p)"
            var f = "the STATE does not show that: \(p)"
            if chance(0.5) {
                var crit: [(String, JSON)] = []
                if chance(0.5) { t = "T " + text(); crit.append(("true", .string(t))) }
                if chance(0.5) { f = "F " + text(); crit.append(("false", .string(f))) }
                spec.append(("criteria", .object(crit)))
            }
            options = [Option(key: "true", criterion: t), Option(key: "false", criterion: f)]
        }
        return (.object(spec), Question(name: name, type: type, instructions: instructions,
                                        options: options, temperature: temperature))
    }

    /// Random play that avoids immediate death when it can, to reach varied mid-game positions.
    mutating func snakePosition(width: Int = 10, height: Int = 8, steps: Int) -> SnakeGame {
        var game = SnakeGame(width: width, height: height, seed: UInt64(int(1...1_000_000)))
        for _ in 0..<steps {
            let legal = game.allFeatures.filter(\.legal).map(\.direction)
            guard let d = legal.isEmpty ? nil : pick(legal) else { break }
            game.step(d)
        }
        return game
    }
}

/// Builds a `\uXXXX` JSON escape at runtime (kept out of source literals on purpose).
func U(_ hex: String) -> String { "\\" + "u" + hex }

/// Numbers are compared with a relative tolerance where arithmetic is involved.
func close(_ a: Double, _ b: Double, tol: Double = 1e-9) -> Bool {
    abs(a - b) <= tol * max(1, abs(a), abs(b))
}
