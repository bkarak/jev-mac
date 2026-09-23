import Foundation

/// Ready-made question sets for common decisions.
public enum Presets {
    public static let all: [(name: String, summary: String, json: String)] = [
        ("triage", "Support ticket routing: department, urgency, refund request", """
        {
          "department": {
            "type": "choice",
            "instructions": "Which team should handle this support message?",
            "criteria": {
              "billing": "charges, invoices, refunds, payment methods",
              "technical": "bugs, errors, outages, how-to questions about the product",
              "sales": "pricing, upgrades, new purchases, quotes",
              "account": "login, password, profile, account closure"
            }
          },
          "urgency": {
            "type": "score",
            "instructions": "How urgent is this message?",
            "levels": {
              "1": "no time pressure, informational",
              "2": "should be handled this week",
              "3": "blocking the customer today",
              "4": "outage, security or legal risk, needs immediate action"
            }
          },
          "wants_refund": {
            "type": "noul",
            "instructions": "The customer is asking for money back."
          }
        }
        """),
        ("email", "Inbox handling: intent, reply needed, priority, spam", """
        {
          "intent": {
            "type": "choice",
            "instructions": "What is the main intent of this email?",
            "criteria": {
              "request": "asks the recipient to do something",
              "question": "asks for information",
              "update": "shares status or news, no action needed",
              "scheduling": "proposes or changes a meeting time",
              "marketing": "promotional or newsletter content"
            }
          },
          "needs_reply": {
            "type": "noul",
            "instructions": "The sender expects a reply from the recipient."
          },
          "priority": {
            "type": "score",
            "instructions": "How important is it for the recipient to read this soon?",
            "levels": ["can be ignored", "read when convenient", "read today", "read now"]
          },
          "spam": {
            "type": "noul",
            "instructions": "This email is unsolicited bulk mail, phishing or a scam."
          }
        }
        """),
        ("moderation", "User-generated content review", """
        {
          "category": {
            "type": "choice",
            "instructions": "Which category best describes this content?",
            "criteria": {
              "ok": "acceptable content",
              "spam": "advertising, scams, repeated junk",
              "harassment": "insults or attacks aimed at a person or group",
              "self_harm": "mentions of hurting oneself",
              "adult": "sexual content"
            }
          },
          "severity": {
            "type": "score",
            "instructions": "How severe is any policy problem in this content?",
            "levels": ["none", "mild", "serious", "severe"]
          },
          "remove": {
            "type": "noul",
            "instructions": "This content should be removed from a general-audience community."
          }
        }
        """),
        ("sentiment", "Polarity, intensity and sarcasm of a text", """
        {
          "polarity": {
            "type": "choice",
            "instructions": "What is the overall sentiment of the text?",
            "criteria": ["positive", "neutral", "negative", "mixed"]
          },
          "intensity": {
            "type": "score",
            "instructions": "How strongly is the sentiment expressed?",
            "levels": ["flat", "mild", "clear", "strong", "extreme"]
          },
          "sarcastic": {
            "type": "noul",
            "instructions": "The text is sarcastic or ironic."
          }
        }
        """),
    ]

    public static func json(named name: String) -> String? {
        all.first { $0.name == name }?.json
    }

    public static func questions(named name: String) throws -> [Question] {
        guard let text = json(named: name) else {
            throw QuestionError("unknown preset '\(name)' (available: \(all.map(\.name).joined(separator: ", ")))")
        }
        return try QuestionSet.parse(text: text)
    }
}
