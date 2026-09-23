import Foundation
import FoundationModels

/// What one Apple foundation model reports about itself.
public struct ModelSummary: Sendable {
    public let status: String
    public let available: Bool
    public let variant: String?
    public let contextTokens: Int?
    public let capabilities: [(name: String, available: Bool)]
    public let languages: [Locale.Language]
}

/// A system process that hosts or guards the models.
public struct ServiceProcess: Sendable, Equatable {
    public let pid: Int
    public let residentKB: Int
    public let elapsedSeconds: Int
    public let name: String
}

/// Timings from a few small requests to the on-device model.
public struct OnDeviceTiming: Sendable {
    public let firstRequestMs: Double
    public let timeToFirstTokenMs: Double
    public let outputTokens: Int
    public let tokensPerSecond: Double
    public let decisionMs: Double
}

/// Introspection behind `jev-mac check`: what the models on this Mac report about
/// themselves, which system processes host them, and (on request) how fast
/// they answer.
public enum ModelInfo {
    public static let variants = [SystemLanguageModel.Variant.core3.displayName,
                                  SystemLanguageModel.Variant.coreAdvanced3.displayName]

    static func capabilities(_ c: LanguageModelCapabilities) -> [(name: String, available: Bool)] {
        [("guided generation", LanguageModelCapabilities.Capability.guidedGeneration), ("tool calling", .toolCalling),
         ("vision", .vision), ("reasoning", .reasoning)].map { ($0.0, c.contains($0.1)) }
    }

    static func summary(_ m: SystemLanguageModel) -> ModelSummary {
        ModelSummary(status: Router.describe(m.availability), available: m.isAvailable, variant: m.variant.displayName,
                     contextTokens: m.contextSize, capabilities: capabilities(m.capabilities),
                     languages: Array(m.supportedLanguages))
    }

    public static func onDevice(_ router: Router) -> ModelSummary { summary(router.onDevice) }
    public static func tagging(_ router: Router) -> ModelSummary { summary(router.tagging) }

    public static func privateCloudCompute(_ router: Router) async -> ModelSummary {
        let pcc = router.pcc
        return ModelSummary(status: router.pccAvailability(), available: pcc.isAvailable, variant: nil,
                            contextTokens: try? await pcc.contextSize, capabilities: capabilities(pcc.capabilities),
                            languages: Array((try? await pcc.supportedLanguages) ?? []))
    }

    public static func localeSupported(_ router: Router, _ locale: Locale = .current) -> Bool {
        router.onDevice.supportsLocale(locale)
    }

    public static func quota(_ router: Router) -> String {
        let q = router.pcc.quotaUsage
        var text: String
        switch q.status {
        case let .belowLimit(b): text = b.isApproachingLimit ? "approaching the limit" : "below the limit"
        case .limitReached: text = "limit reached"
        @unknown default: text = "unknown"
        }
        if let reset = q.resetDate { text += ", resets \(reset.formatted(date: .abbreviated, time: .shortened))" }
        return text
    }

    // MARK: Languages

    /// Languages grouped with their regions, e.g. "English (AU, GB, IN, US)",
    /// sorted by English name, plus how many languages and locales there are.
    public static func languageSummary(_ languages: [Locale.Language]) -> (languages: Int, locales: Int, names: [String]) {
        let english = Locale(identifier: "en")
        var regions: [String: Set<String>] = [:]
        for l in languages {
            guard let code = l.languageCode?.identifier else { continue }
            regions[code, default: []].formUnion(l.region.map { [$0.identifier] } ?? [])
        }
        let names = regions.map { code, rs -> String in
            let name = english.localizedString(forLanguageCode: code) ?? code
            return rs.count > 1 ? "\(name) (\(rs.sorted().joined(separator: ", ")))" : name
        }.sorted()
        return (regions.count, languages.count, names)
    }

    // MARK: Host processes

    /// The processes behind the models (`ps` reads their memory; our own
    /// process is not allowed to).
    public static func hostProcesses() -> [ServiceProcess] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,rss=,etime=,comm="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parsePS(String(decoding: data, as: UTF8.self))
            .filter { $0.name.hasSuffix("InferenceProviderService") || $0.name.hasSuffix("InferenceProvider")
                || $0.name.hasPrefix("PCC") || $0.name == "modelmanagerd" }
    }

    /// Parses `ps -o pid=,rss=,etime=,comm=` output; `comm` keeps only the executable name.
    public static func parsePS(_ text: String) -> [ServiceProcess] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int(f[0]), let rss = Int(f[1]), let elapsed = parseElapsed(String(f[2])) else { return nil }
            let name = String(f[3]).split(separator: "/").last.map(String.init) ?? String(f[3])
            return ServiceProcess(pid: pid, residentKB: rss, elapsedSeconds: elapsed, name: name)
        }
    }

    /// Seconds in a `ps` elapsed time: `[[dd-]hh:]mm:ss`.
    public static func parseElapsed(_ s: String) -> Int? {
        var days = 0
        var clock = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            guard let d = Int(s[..<dash]) else { return nil }
            days = d
            clock = s[s.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let v = parts.map { $0! }
        let (h, m, sec) = v.count == 3 ? (v[0], v[1], v[2]) : (0, v[0], v[1])
        return ((days * 24 + h) * 60 + m) * 60 + sec
    }

    /// "8 d 15 h", "2 h 5 m", "4 m 12 s", "45 s".
    public static func formatDuration(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3_600, m = seconds % 3_600 / 60, s = seconds % 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) m" }
        if m > 0 { return "\(m) m \(s) s" }
        return "\(s) s"
    }

    // MARK: Measurements (these make model requests)

    public static func measureOnDevice(_ router: Router) async throws -> OnDeviceTiming {
        func ms(_ start: ContinuousClock.Instant) -> Double {
            let d = start.duration(to: .now)
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        // 1. A tiny request: includes any warm-up after the service has been idle.
        var start = ContinuousClock.now
        _ = try await LanguageModelSession(model: router.onDevice)
            .respond(to: "Reply with the single word: ready.", options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 8))
        let first = ms(start)

        // 2. Streamed free text: time to first token, then generation speed.
        start = .now
        var ttft = -1.0
        let stream = LanguageModelSession(model: router.onDevice)
            .streamResponse(to: "Describe a harbour at dawn in about 80 words.",
                            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160))
        for try await _ in stream where ttft < 0 { ttft = ms(start) }
        let response = try await stream.collect()
        let total = ms(start)
        let tokens = response.usage.output.totalTokenCount

        // 3. One jev-mac decision: the triage department question through the engine.
        let question = try Presets.questions(named: "triage").first { $0.name == "department" }!
        start = .now
        _ = try await Agent(router: router).predict("I was charged twice this month. Please refund one payment.", [question])
        return OnDeviceTiming(firstRequestMs: first, timeToFirstTokenMs: ttft, outputTokens: tokens,
                              tokensPerSecond: Double(tokens) / max(0.001, (total - ttft) / 1000), decisionMs: ms(start))
    }

    /// Sends one tiny request to Private Cloud Compute to see whether this
    /// build may use it.
    public static func probePrivateCloudCompute(_ router: Router) async -> (ok: Bool, detail: String) {
        guard router.pcc.isAvailable else { return (false, router.pccAvailability()) }
        let start = ContinuousClock.now
        do {
            _ = try await LanguageModelSession(model: router.pcc)
                .respond(to: "Reply with the single word: ready.", options: GenerationOptions(maximumResponseTokens: 8))
            let d = start.duration(to: .now)
            return (true, String(format: "answered in %.1f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18))
        } catch {
            return (false, Agent.explain(error))
        }
    }
}
