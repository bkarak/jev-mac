import Testing
@testable import JevCore

@Suite("Routing")
struct RouterTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let route: ModelRoute
        let onDevice, tagging, pcc, oversized: Bool
        var testDescription: String {
            "\(route.rawValue) on-device=\(onDevice) tagging=\(tagging) pcc=\(pcc) oversized=\(oversized)"
        }
    }

    /// Every route × every availability combination × input that fits or not.
    static let cases: [Case] = ModelRoute.allCases.flatMap { r in
        [false, true].flatMap { o in [false, true].flatMap { t in [false, true].flatMap { p in
            [false, true].map { big in Case(route: r, onDevice: o, tagging: t, pcc: p, oversized: big) }
        } } }
    }

    @Test("routing rules hold for every combination", arguments: cases)
    func rules(_ c: Case) {
        let r = Router.choose(c.route, onDevice: c.onDevice, tagging: c.tagging, pcc: c.pcc,
                              contextSize: 4096, estimatedTokens: c.oversized ? 10_000 : 500)
        switch c.route {
        case .onDevice, .tagging, .pcc:
            let available: [ModelRoute: Bool] = [.onDevice: c.onDevice, .tagging: c.tagging, .pcc: c.pcc]
            #expect(r == (available[c.route]! ? c.route : nil), "an explicit route is served by that model or not at all")
        case .auto:
            #expect(r != .tagging, "auto never picks the specialised adapter")
            #expect((r == nil) == (!c.onDevice && !c.pcc), "auto fails only when no general model exists")
            if c.onDevice && !c.oversized { #expect(r == .onDevice, "prefer on-device when the input fits") }
            if c.oversized && c.pcc { #expect(r == .pcc, "overflow goes to the server model") }
            if c.oversized && !c.pcc && c.onDevice { #expect(r == .onDevice, "with nothing larger, on-device reports it") }
            if !c.onDevice && c.pcc { #expect(r == .pcc) }
        }
    }

    @Test func autoSwitchesAtEightyFivePercentOfTheContext() {
        let limit = Int(4096 * 0.85)
        #expect(Router.choose(.auto, onDevice: true, tagging: true, pcc: true, contextSize: 4096, estimatedTokens: limit - 1) == .onDevice)
        #expect(Router.choose(.auto, onDevice: true, tagging: true, pcc: true, contextSize: 4096, estimatedTokens: limit) == .pcc)
    }

    static let estimateCases: [(String, Int)] = [("", 1), ("abcd", 2), (String(repeating: "x", count: 400), 101), ("é", 1)]

    @Test("token estimates grow with UTF-8 size", arguments: estimateCases)
    func estimates(text: String, expected: Int) {
        #expect(Router.estimateTokens(text) == expected)
    }
}
