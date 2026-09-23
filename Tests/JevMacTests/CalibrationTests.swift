import Foundation
import Testing
@testable import JevMac

@Suite("Calibration")
struct CalibrationTests {
    static let normalizeSeeds = 0..<7

    @Test("normalize yields a distribution proportional to usable weights", arguments: normalizeSeeds)
    func normalize(seed: Int) {
        var g = Gen(seed)
        let raw = (0..<g.int(1...10)).map { _ -> Double in
            switch g.int(0...6) {
            case 0: return 0
            case 1: return -g.double(0...5)
            case 2: return .nan
            case 3: return .infinity
            default: return g.double(0...100)
            }
        }
        let p = Calibration.normalize(raw)
        #expect(p.count == raw.count)
        #expect(close(p.reduce(0, +), 1))
        #expect(p.allSatisfy { $0 >= 0 && $0 <= 1 })
        let usable = raw.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = usable.reduce(0, +)
        if total > 0 {
            for (x, y) in zip(usable, p) { #expect(close(y, x / total)) }
        } else {
            #expect(p.allSatisfy { close($0, 1 / Double(raw.count)) }, "no usable weight means uniform")
        }
    }

    @Test func normalizeExamples() {
        #expect(Calibration.normalize([30, 10]) == [0.75, 0.25])
        #expect(Calibration.normalize([0, 0, 0, 0]) == [0.25, 0.25, 0.25, 0.25])
        #expect(Calibration.normalize([]) == [])
        #expect(Calibration.normalize([7]) == [1])
        #expect(Calibration.applyTemperature([0.7, 0.3], 1) == [0.7, 0.3], "T = 1 is the identity")
    }

    static let temperatureCases: [(Int, Double)] = (0..<8).map { ($0, [0.001, 0.05, 0.3, 0.7, 1.5, 3, 20, 1000][$0 % 8]) }

    @Test("temperature reshapes without reordering", arguments: temperatureCases)
    func temperature(seed: Int, t: Double) {
        var g = Gen(seed)
        var p = g.distribution(g.int(2...8))
        while p.filter({ $0 == p.max()! }).count > 1 { p = g.distribution(p.count) }
        let q = Calibration.applyTemperature(p, t)
        #expect(close(q.reduce(0, +), 1))
        #expect(argmax(q) == argmax(p), "the top option never changes")
        for i in p.indices { for j in p.indices where p[i] > p[j] { #expect(q[i] >= q[j] - 1e-12) } }
        if t < 1 {
            #expect(q.max()! >= p.max()! - 1e-3, "T < 1 sharpens")
        } else {
            #expect(q.max()! <= p.max()! + 1e-9, "T > 1 flattens")
        }
    }

    /// Raising probabilities to the power 1/T underflowed for tiny T and
    /// returned a uniform distribution instead of a one-hot one.
    static let extremeCases: [([Double], Double, Int)] = [
        ([0.4, 0.35, 0.25], 0.001, 0),
        ([0.2, 0.5, 0.3], 0.0001, 1),
        ([0.1, 0.2, 0.3, 0.4], 0.002, 3),
    ]

    @Test("extreme sharpening converges to one-hot", arguments: extremeCases)
    func extremeSharpening(p: [Double], t: Double, top: Int) {
        let q = Calibration.applyTemperature(p, t)
        #expect(q[top] > 0.999, "got \(q)")
    }

    static let voteSeeds = 0..<10

    @Test("votes become add-½ smoothed frequencies", arguments: voteSeeds)
    func votes(seed: Int) {
        var g = Gen(seed)
        let counts = (0..<g.int(2...6)).map { _ in g.int(0...7) }
        let p = Calibration.fromVotes(counts)
        let n = Double(counts.reduce(0, +)), k = Double(counts.count)
        for (c, x) in zip(counts, p) { #expect(close(x, (Double(c) + 0.5) / (n + 0.5 * k))) }
        #expect(p.allSatisfy { $0 > 0 }, "no option is ever certain to be wrong")
        #expect(close(p.reduce(0, +), 1))
    }

    @Test("confidence is 1 for one-hot and 0 for uniform", arguments: 2...9)
    func confidenceBounds(n: Int) {
        var oneHot = [Double](repeating: 0, count: n)
        oneHot[n / 2] = 1
        #expect(close(Calibration.confidence(oneHot), 1))
        #expect(abs(Calibration.confidence([Double](repeating: 1 / Double(n), count: n))) < 1e-9)
    }

    static let confidenceSeeds = 0..<10

    @Test("confidence ignores order and drops when mixed with uniform", arguments: confidenceSeeds)
    func confidence(seed: Int) {
        var g = Gen(seed)
        let p = g.distribution(g.int(2...8))
        let c = Calibration.confidence(p)
        #expect(c >= 0 && c <= 1)
        #expect(close(Calibration.confidence(g.shuffled(p)), c))
        let u = 1 / Double(p.count)
        #expect(Calibration.confidence(p.map { 0.5 * $0 + 0.5 * u }) <= c + 1e-12)
    }

    func argmax(_ p: [Double]) -> Int { p.indices.max { p[$0] < p[$1] }! }
}
