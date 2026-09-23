import Foundation

/// Builds the two halves of every model call:
///
/// * the **prefix** — question head (type + instructions) and rendered
///   options. It depends only on the question, so it becomes the session
///   instructions and is what `PrefixCache` reuses and prewarms.
/// * the **sequence** — the serialized state for one prediction.
public enum PromptBuilder {
    /// Upper bound on a rendered criterion, mirroring the per-option token cap.
    public static let maxCriterionCharacters = 280
    /// Upper bound on the serialized state so a single call stays inside the context window.
    public static let maxStateCharacters = 12_000

    /// Converts a state (free text or any JSON value) to the string the model reads.
    public static func serializeState(_ state: JSON) -> String {
        if case let .string(s) = state { return s }
        return state.serialized()
    }

    /// Formats a criterion value; structured values become compact JSON so a
    /// nested object never produces a malformed prompt.
    public static func renderCriterion(_ value: JSON) -> String {
        switch value {
        case let .string(s): return s
        case .null: return ""
        default: return value.serialized()
        }
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    /// One line per option: `key: criterion` for choice, `level N: criterion`
    /// for score, `yes` / `no` for noul.
    public static func renderOptions(_ q: Question) -> [String] {
        zip(q.options, Heads.schemaKeys(for: q)).map { o, key in
            let head = q.type == .score ? "level \(key)" : key
            guard let c = o.criterion, !c.isEmpty else { return head }
            return "\(head): \(clip(c, maxCriterionCharacters))"
        }
    }

    static let weightRule = "First give the single best option as the answer. Then, for every option, output an integer weight from 0 to 100 proportional to how likely it is the correct answer; the answer gets the largest weight. Weights should sum to 100. Put weight on more than one option only when the STATE is genuinely ambiguous."

    /// Question head (type + instructions), options and the type-specific rule.
    static func questionBlock(_ q: Question) -> [String] {
        var lines = [
            "QUESTION TYPE: \(q.type.rawValue)",
            (q.type == .noul ? "PROPOSITION: " : "QUESTION: ") + q.instructions,
            q.type == .score ? "RUBRIC LEVELS:" : "OPTIONS:",
        ]
        lines += renderOptions(q).map { "- " + $0 }
        switch q.type {
        case .choice: lines.append("Exactly one option is correct.")
        case .score: lines.append("Pick the rubric level that best describes the STATE; neighbouring levels may be partly plausible.")
        case .noul: lines.append("Answer yes if the PROPOSITION holds for the STATE, no if it does not.")
        }
        return lines
    }

    /// The question prefix used as session instructions.
    public static func buildPrefix(_ q: Question, head: DecisionHead) -> String {
        var lines = [
            "You are a decision engine, not a chat assistant.",
            "You read a STATE and answer one typed question about it. Base the answer only on the STATE.",
            "",
        ]
        lines += questionBlock(q)
        lines.append("")
        lines.append(head == .distribution ? weightRule : "Output the single best option.")
        return lines.joined(separator: "\n")
    }

    /// One prefix covering a whole question set, for the fused read-out
    /// (a single call answers every question — laya's one forward pass, many heads).
    public static func buildFusedPrefix(_ qs: [Question]) -> String {
        var lines = [
            "You are a decision engine, not a chat assistant.",
            "You read a STATE and answer several independent typed questions about it. Base every answer only on the STATE.",
        ]
        for q in qs {
            lines.append("")
            lines.append("## \(q.name)")
            lines += questionBlock(q)
        }
        lines.append("")
        lines.append("Answer every question separately. " + weightRule)
        return lines.joined(separator: "\n")
    }

    /// The per-prediction prompt.
    public static func buildSequence(state: String) -> String {
        "STATE:\n" + clip(state, maxStateCharacters)
    }
}
