import Foundation

/// The three typed-decision archetypes.
public enum QuestionType: String, Sendable, CaseIterable {
    /// Probability distribution over named options.
    case choice
    /// Probability distribution over ordered rubric levels, plus an expected score.
    case score
    /// P(true) for a proposition.
    case noul
}

/// One answer slot the model can pick: its key (what is reported back) and
/// the criterion text the model sees.
public struct Option: Sendable, Equatable, Hashable {
    public let key: String
    public let criterion: String?
    /// Numeric value, only set for `score` levels.
    public let level: Double?

    public init(key: String, criterion: String? = nil, level: Double? = nil) {
        self.key = key
        self.criterion = criterion
        self.level = level
    }
}

/// A validated, normalized question (the `_to_internal` form).
public struct Question: Sendable, Equatable, Hashable {
    public let name: String
    public let type: QuestionType
    public let instructions: String
    public let options: [Option]
    /// Per-question calibration temperature applied to the raw distribution.
    public let temperature: Double

    public init(name: String, type: QuestionType, instructions: String, options: [Option], temperature: Double = 1.0) {
        self.name = name
        self.type = type
        self.instructions = instructions
        self.options = options
        self.temperature = temperature
    }
}

public struct QuestionError: JevMacError {
    public let description: String
    init(_ d: String) { description = d }
}

public enum QuestionSet {
    /// Parses a question set: `{ "<name>": { "type": ..., "instructions": ..., "criteria"|"levels": ... } }`.
    public static func parse(_ json: JSON) throws -> [Question] {
        guard case let .object(pairs) = json, !pairs.isEmpty else {
            throw QuestionError("questions must be a non-empty JSON object keyed by question name")
        }
        var seen = Set<String>()
        return try pairs.map { name, spec in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuestionError("question names must not be empty")
            }
            guard seen.insert(name).inserted else { throw QuestionError("duplicate question name '\(name)'") }
            return try question(name: name, spec: spec)
        }
    }

    public static func parse(text: String) throws -> [Question] {
        try parse(JSON.parse(text))
    }

    static func question(name: String, spec: JSON) throws -> Question {
        guard case .object = spec else { throw QuestionError("question '\(name)' must be an object") }
        guard let rawType = spec["type"]?.stringValue, let type = QuestionType(rawValue: rawType) else {
            throw QuestionError("question '\(name)': type must be one of choice, score, noul")
        }
        guard let instructions = spec["instructions"]?.stringValue,
              !instructions.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw QuestionError("question '\(name)': instructions are required")
        }
        let temperature: Double
        switch spec["temperature"] {
        case nil: temperature = 1
        case let .number(n)?: temperature = n
        case let .string(t)? where Double(t) != nil: temperature = Double(t)!
        default: throw QuestionError("question '\(name)': temperature must be a number")
        }
        guard temperature.isFinite, temperature > 0 else {
            throw QuestionError("question '\(name)': temperature must be a finite number > 0")
        }

        let options: [Option]
        switch type {
        case .choice:
            options = try choiceOptions(name, spec["criteria"] ?? spec["options"])
            guard options.count >= 2 else { throw QuestionError("question '\(name)': choice needs at least 2 criteria") }
        case .score:
            options = try scoreLevels(name, spec["levels"] ?? spec["criteria"])
            guard options.count >= 2 else { throw QuestionError("question '\(name)': score needs at least 2 levels") }
        case .noul:
            options = try noulOptions(name, spec["criteria"], proposition: instructions)
        }
        guard options.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw QuestionError("question '\(name)': option keys must not be empty")
        }
        let keys = options.map(\.key)
        guard Set(keys).count == keys.count else { throw QuestionError("question '\(name)': duplicate option keys") }
        return Question(name: name, type: type, instructions: instructions, options: options, temperature: temperature)
    }

    static func choiceOptions(_ name: String, _ json: JSON?) throws -> [Option] {
        switch json {
        case let .array(items)?:
            return try items.map {
                guard let s = $0.stringValue else { throw QuestionError("question '\(name)': list criteria must be strings") }
                return Option(key: s)
            }
        case let .object(pairs)?:
            return pairs.map { Option(key: $0.0, criterion: PromptBuilder.renderCriterion($0.1)) }
        default:
            throw QuestionError("question '\(name)': choice requires 'criteria' as a list or object")
        }
    }

    static func scoreLevels(_ name: String, _ json: JSON?) throws -> [Option] {
        switch json {
        case let .array(items)?:
            return items.enumerated().map { i, v in
                Option(key: String(i + 1), criterion: PromptBuilder.renderCriterion(v), level: Double(i + 1))
            }
        case let .object(pairs)?:
            let levels = try pairs.map { k, v -> Option in
                guard let n = Double(k), n.isFinite else {
                    throw QuestionError("question '\(name)': level keys must be finite numbers, got '\(k)'")
                }
                return Option(key: k, criterion: PromptBuilder.renderCriterion(v), level: n)
            }.sorted { $0.level! < $1.level! }
            for (a, b) in zip(levels, levels.dropFirst()) where a.level == b.level {
                throw QuestionError("question '\(name)': levels '\(a.key)' and '\(b.key)' have the same value")
            }
            return levels
        default:
            throw QuestionError("question '\(name)': score requires 'levels' as a list or object")
        }
    }

    /// Defaults restate the proposition inside each option: a bare "the
    /// proposition is true" leaves the small model guessing which way round
    /// the question is.
    static func noulOptions(_ name: String, _ json: JSON?, proposition: String) throws -> [Option] {
        if let json, json != .null {
            guard case let .object(pairs) = json else {
                throw QuestionError("question '\(name)': noul criteria must be an object with 'true' and/or 'false'")
            }
            if let extra = pairs.first(where: { $0.0 != "true" && $0.0 != "false" }) {
                throw QuestionError("question '\(name)': unknown noul criterion '\(extra.0)' (use 'true' and 'false')")
            }
        }
        let p = proposition.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = json?["true"].map(PromptBuilder.renderCriterion) ?? "the STATE shows that: \(p)"
        let f = json?["false"].map(PromptBuilder.renderCriterion) ?? "the STATE does not show that: \(p)"
        return [Option(key: "true", criterion: t), Option(key: "false", criterion: f)]
    }
}
