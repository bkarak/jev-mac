import Foundation
import NaturalLanguage

/// Detects the dominant language of a state so the engine can warn when the
/// on-device model does not support it.
public enum LanguageDetector {
    public static func detect(_ text: String) -> (code: String, confidence: Double)? {
        let r = NLLanguageRecognizer()
        r.processString(String(text.prefix(2_000)))
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        let confidence = r.languageHypotheses(withMaximum: 1)[lang] ?? 0
        return (lang.rawValue, confidence)
    }
}
