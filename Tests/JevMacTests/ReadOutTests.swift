import FoundationModels
import Testing
@testable import JevMac

/// The read-out layer, driven with model-shaped output built from JSON, so
/// no model call is needed.
@Suite("Model output read-out")
struct ReadOutTests {
    static let department = try! QuestionSet.parse(
        text: #"{"d":{"type":"choice","instructions":"x","criteria":["billing","tech","sales"]}}"#)[0]

    static let weightCases: [(String, [Double])] = [
        (#"{"billing":80,"tech":15,"sales":5}"#, [80, 15, 5]),
        (#"{"billing":80,"tech":15}"#, [80, 15, 0]),
        (#"{"billing":1,"tech":1,"sales":1,"other":97}"#, [1, 1, 1]),
        (#"{"billing":150,"tech":0,"sales":0}"#, [150, 0, 0]),
        (#"{"billing":-5,"tech":10,"sales":0}"#, [-5, 10, 0]),
        (#"{"billing":"x","tech":10,"sales":0}"#, [0, 10, 0]),
        (#"{}"#, [0, 0, 0]),
        (#"{"sales":3,"billing":1,"tech":2}"#, [1, 2, 3]),
    ]

    @Test("weights are read per option; missing or malformed ones count as 0", arguments: weightCases)
    func weights(json: String, expected: [Double]) throws {
        let p = try Heads.prepare(Self.department, head: .distribution)
        #expect(Heads.weights(from: try GeneratedContent(json: json), p.propertyNames[0]) == expected)
    }

    static let fused = try! QuestionSet.parse(text: #"""
    {"d":{"type":"choice","instructions":"x","criteria":["billing","tech"]},"r":{"type":"noul","instructions":"y"}}
    """#)

    static let fusedCases: [(String, [[Double]])] = [
        (#"{"d":{"answer":"billing","weights":{"billing":70,"tech":30}},"r":{"answer":"yes","weights":{"yes":90,"no":10}}}"#,
         [[0.7, 0.3], [0.9, 0.1]]),
        (#"{"d":{"answer":"billing","weights":{"billing":70,"tech":30}}}"#, [[0.7, 0.3], [0.5, 0.5]]),
        (#"{"r":{"answer":"no","weights":{"no":100,"yes":0}},"d":{"weights":{"tech":1,"billing":3}}}"#, [[0.75, 0.25], [0, 1]]),
        (#"{"d":"oops","r":{"answer":"yes","weights":{"yes":1,"no":1}}}"#, [[0.5, 0.5], [0.5005, 0.4995]]),
    ]

    @Test("fused output is split back into per-question distributions", arguments: fusedCases)
    func fusedDistributions(json: String, expected: [[Double]]) throws {
        let p = try Heads.prepareFused(Self.fused)
        let got = Heads.fusedDistributions(from: try GeneratedContent(json: json), p)
        #expect(got.count == expected.count)
        for (g, e) in zip(got, expected) { #expect(g.count == e.count && zip(g, e).allSatisfy { close($0, $1) }, "\(got)") }
    }

    /// The distribution head asks for the answer first; weights that
    /// contradict it are reconciled so the stated answer always leads.
    static let decisionCases: [(String, [Double])] = [
        (#"{"answer":"billing","weights":{"billing":80,"tech":15,"sales":5}}"#, [0.8, 0.15, 0.05]),
        (#"{"answer":"tech","weights":{"billing":80,"tech":15,"sales":5}}"#, [0.15, 0.8, 0.05]),
        (#"{"answer":"tech","weights":{"billing":50,"tech":50,"sales":0}}"#, [0.4995, 0.5005, 0]),
        (#"{"answer":"sales"}"#, [0.2, 0.2, 0.6]),
        (#"{"answer":"billing","weights":{"billing":0,"tech":0,"sales":0}}"#, [0.6, 0.2, 0.2]),
        (#"{"weights":{"billing":1,"tech":3,"sales":0}}"#, [0.25, 0.75, 0]),
        (#"{"answer":"refunds","weights":{"billing":1,"tech":3,"sales":0}}"#, [0.25, 0.75, 0]),
    ]

    @Test("decision objects read out as distributions led by the answer", arguments: decisionCases)
    func decisions(json: String, expected: [Double]) throws {
        let p = try Heads.prepare(Self.department, head: .distribution)
        let got = Heads.distribution(from: try GeneratedContent(json: json), Self.department, p.propertyNames[0])
        #expect(zip(got, expected).allSatisfy { close($0, $1) }, "\(got)")
    }

    static let reconcileSeeds = 0..<5

    @Test("reconciled distributions always lead with the stated answer", arguments: reconcileSeeds)
    func reconcile(seed: Int) {
        var g = Gen(seed)
        for _ in 0..<50 {
            let n = g.int(2...8)
            let w = (0..<n).map { _ in Double(g.chance(0.3) ? 0 : g.int(0...100)) }
            let a = g.int(0...(n - 1))
            let p = Heads.reconcile(w, answer: a)
            #expect(close(p.reduce(0, +), 1) && p.allSatisfy { $0 >= 0 })
            #expect(p.indices.max { p[$0] < p[$1] } == a, "weights \(w), answer \(a) → \(p)")
            let plain = Calibration.normalize(w)
            if w.contains(where: { $0 > 0 }), plain.filter({ $0 >= plain[a] }).count == 1 {
                #expect(p == plain, "weights that already agree are left alone")
            }
        }
    }

    static let voteCases: [(String, Int?)] = [
        (#"{"answer":"billing"}"#, 0),
        (#"{"answer":"sales"}"#, 2),
        (#"{"answer":"Billing"}"#, nil),
        (#"{"answer":"refunds"}"#, nil),
        (#"{"choice":"billing"}"#, nil),
        (#"{"answer":3}"#, nil),
        (#"{}"#, nil),
    ]

    @Test("votes map to an option index or to nothing", arguments: voteCases)
    func votes(json: String, expected: Int?) throws {
        let p = try Heads.prepare(Self.department, head: .vote)
        #expect(Heads.vote(from: try GeneratedContent(json: json), p) == expected)
    }
}
