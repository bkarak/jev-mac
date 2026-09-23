import Foundation
@testable import JevCore

/// Labeled states with one unambiguous answer each. Score labels are ranges
/// where neighbouring rubric levels are both defensible.
enum LiveCases {
    static let all: [LiveCase] = triage + email + moderation + sentiment + language + reading + numeric

    // MARK: Builders

    static func preset(_ name: String, _ question: String) -> Question {
        try! Presets.questions(named: name).first { $0.name == question }!
    }

    static func custom(_ json: String) -> Question { try! QuestionSet.parse(text: json)[0] }

    static func group(_ category: String, _ q: Question, _ items: [(String, Expectation)]) -> [LiveCase] {
        items.enumerated().map { i, item in
            LiveCase(id: "\(category)#\(i < 9 ? "0" : "")\(i + 1)", category: category, question: q,
                     state: .string(item.0), expect: item.1)
        }
    }

    static func keyed(_ category: String, _ q: Question, _ byKey: [(String, [String])]) -> [LiveCase] {
        group(category, q, byKey.flatMap { key, texts in texts.map { ($0, Expectation.key(key)) } })
    }

    static func truths(_ category: String, _ q: Question, yes: [String], no: [String]) -> [LiveCase] {
        group(category, q, yes.map { ($0, .truth(true)) } + no.map { ($0, .truth(false)) })
    }

    // MARK: triage (80)

    static let department = keyed("triage.department", preset("triage", "department"), [
        ("billing", [
            "I was charged twice for my March invoice. Please refund one of the payments.",
            "My credit card was billed $49 but my plan costs $29. Why the difference?",
            "Can you send me a copy of last month's invoice for my accountant?",
            "The payment failed and now my subscription shows as past due. How do I update my card?",
            "I cancelled last week but I was still charged this month.",
            "Please change the billing address on my invoices to our new office.",
            "Why is there a VAT charge on my receipt? We are tax exempt.",
            "I'd like a refund for the annual plan I bought by mistake yesterday.",
            "My bank shows a pending charge from you that I don't recognise.",
            "The invoice total doesn't match the amount you quoted; please correct the invoice.",
        ]),
        ("technical", [
            "The app crashes every time I open the settings page on my iPhone.",
            "I'm getting a 500 Internal Server Error when calling the /orders API endpoint.",
            "Sync has stopped working since the last update; my files don't upload anymore.",
            "The dashboard takes over a minute to load and sometimes times out.",
            "How do I export my data to CSV? I can't find the option anywhere.",
            "Push notifications stopped arriving on Android after I updated the app.",
            "The search feature returns no results even for items I know exist.",
            "Your webhook keeps sending duplicate events to our server.",
            "The page shows a blank white screen in Safari but works in Chrome.",
            "After the update, the printer integration throws error code E-1042.",
        ]),
        ("sales", [
            "We're a team of 50 — can you send a quote for the Enterprise plan?",
            "What's the price difference between the Pro and Business plans?",
            "I'd like to upgrade from the Basic plan to Pro. What would that cost?",
            "Do you offer discounts for non-profit organisations buying 20 licenses?",
            "We're evaluating your product for our company. Can we schedule a demo with sales?",
            "Is there volume pricing if we buy more than 100 seats?",
            "I want to buy an additional 10 user licenses for my team.",
            "Can you tell me what's included in the Premium tier before I purchase it?",
            "We need a formal quote with pricing for our procurement department.",
            "Are there any promotions for new customers who sign up this month?",
        ]),
        ("account", [
            "I forgot my password and the reset link isn't arriving.",
            "Please delete my account and all my personal data.",
            "How do I change the email address associated with my profile?",
            "My account got locked after too many login attempts.",
            "I want to change my username; it still shows my old company name.",
            "Someone else logged into my account from another country. Please secure it.",
            "I'd like to close my account at the end of this month.",
            "I can't log in — it says my email is not registered, but I've used it for years.",
            "Please update the name on my profile; I recently got married.",
            "How do I transfer ownership of my account to a colleague?",
        ]),
    ])

    static let urgency = group("triage.urgency", preset("triage", "urgency"), [
        ("Just wanted to say the new dashboard looks great. Keep it up!", .levels(1...2)),
        ("No rush, but at some point could you add a dark mode?", .levels(1...2)),
        ("FYI there's a small typo on your About page.", .levels(1...2)),
        ("Out of curiosity, which data centre region do you host in?", .levels(1...2)),
        ("Thanks for fixing my issue yesterday, everything works now.", .levels(1...2)),
        ("Please update the company name on our invoices before the end of the week.", .levels(2...3)),
        ("Our finance team needs last quarter's receipts by Friday.", .levels(2...3)),
        ("Two of our users can't open the reports page, but they can work around it for now.", .levels(2...3)),
        ("The export is slow, taking about ten minutes, but it eventually finishes.", .levels(2...3)),
        ("Can you add our new hire to the account sometime this week?", .levels(2...3)),
        ("I can't log in and I have a client presentation in two hours that depends on your tool.", .levels(3...4)),
        ("Our checkout page stopped accepting payments this morning; customers can't pay.", .levels(3...4)),
        ("The whole sales team is blocked because the CRM sync failed today.", .levels(3...4)),
        ("Our payroll export fails and salaries must be sent out today.", .levels(3...4)),
        ("I'm locked out of my account and need to submit a report due this afternoon.", .levels(3...4)),
        ("Your service is completely down for all our users right now. Production outage!", .levels(4...4)),
        ("Customer passwords are visible in plain text on your admin page. This is a security breach.", .levels(4...4)),
        ("Our lawyer says your data processing violates GDPR and this must be resolved immediately.", .levels(4...4)),
        ("All our servers are returning errors and no customer can access the site.", .levels(4...4)),
        ("Someone is accessing our account right now and deleting data!", .levels(4...4)),
    ])

    static let refund = truths("triage.wants_refund", preset("triage", "wants_refund"), yes: [
        "I was charged twice, please refund the duplicate payment.",
        "I'd like my money back for the annual plan, I don't use it.",
        "The product didn't work as advertised; I want a full refund.",
        "Please reverse the charge from yesterday, it was a mistake.",
        "Can I get reimbursed for the month the service was down?",
        "I want to return the device and get my payment back.",
        "Refund my last invoice please, I cancelled before the renewal date.",
        "Please credit the $30 overcharge back to my card.",
        "I demand my money back for this broken service.",
        "Is it possible to get a refund for the unused months of my subscription?",
    ], no: [
        "How do I change my password?",
        "Can you send me the invoice for March?",
        "The app crashes when I upload photos.",
        "I'd like to upgrade to the Pro plan.",
        "Thanks for the quick help yesterday!",
        "Please update my billing address.",
        "When will the new feature be released?",
        "I was charged correctly, I'm just confirming the payment went through.",
        "Can I add two more users to my account?",
        "The export button is greyed out, what am I doing wrong?",
    ])

    static let triage = department + urgency + refund

    // MARK: email (67)

    static let intent = keyed("email.intent", preset("email", "intent"), [
        ("request", [
            "Hi Anna, could you please send me the signed contract by Thursday? Thanks, Mark",
            "Please review the attached slides and add your comments before the board meeting.",
            "Could you approve my expense report in the finance portal today?",
            "Please forward me the latest version of the budget spreadsheet.",
            "I need you to update the website banner with the new logo before launch.",
        ]),
        ("question", [
            "Quick question: do you know which version of the API the mobile team is using?",
            "Is the office closed on Monday for the public holiday?",
            "What was the final headcount for the conference last year?",
            "Do you remember who the contact person at the supplier was?",
            "Which printer should we use for the colour brochures?",
        ]),
        ("update", [
            "FYI, the server migration finished successfully last night. No action needed.",
            "Just a heads-up: the Q3 report has been published on the intranet.",
            "The shipment left our warehouse this morning and should arrive Friday.",
            "Status update: the bug fix is deployed and customers are no longer affected.",
            "We hit our sales target for the month. Great job everyone!",
        ]),
        ("scheduling", [
            "Can we move our 1:1 from Tuesday 10:00 to Wednesday afternoon?",
            "Are you free for a 30-minute call on Friday at 2pm?",
            "I need to reschedule tomorrow's interview to next Monday at 9am.",
            "Let's set up a kickoff meeting next week — does Tuesday or Thursday morning work?",
            "The team sync moves one hour later, to 11:00, starting next week.",
        ]),
        ("marketing", [
            "Spring Sale! Get 40% off all plans this weekend only. Use code SPRING40.",
            "Our monthly newsletter: 5 productivity tips, new features, and customer stories.",
            "Don't miss our free webinar on cloud security. Register now to save your seat!",
            "Upgrade today and get 3 months free — a limited time offer for loyal customers.",
            "Introducing our new product line! Discover the collection in stores and online.",
        ]),
    ])

    static let needsReply = truths("email.needs_reply", preset("email", "needs_reply"), yes: [
        "Can you confirm whether you'll attend the dinner on Saturday?",
        "Please let me know which option you prefer by tomorrow.",
        "Could you send me your availability for next week?",
        "What do you think of the draft? I'd like your feedback before I submit it.",
        "Are you able to cover my shift on Friday? Let me know.",
        "Please reply with your shirt size for the team event.",
        "Can we meet on Tuesday? Let me know if that works for you.",
        "Do you approve the budget increase? I need a yes or no today.",
    ], no: [
        "FYI: the office will be closed on Monday. No need to reply.",
        "Our weekly newsletter: this week's top stories in tech.",
        "Your order #4521 has shipped and will arrive on Thursday.",
        "This is an automated message. Please do not reply to this email.",
        "Thanks, that's all I needed. Have a great weekend!",
        "The server maintenance completed successfully at 02:00.",
        "Reminder: your subscription renews automatically on May 1.",
        "Congratulations to the team on the successful launch!",
    ])

    static let spam = truths("email.spam", preset("email", "spam"), yes: [
        "Congratulations!!! You have WON a $1000 gift card. Click here to claim now!",
        "Your account has been suspended. Verify your password at secure-login.example-verify.com immediately.",
        "Make $5000 a week working from home! No experience needed, reply now.",
        "Dear friend, I am a prince and need your help transferring $10 million. You will receive 30%.",
        "URGENT: Your package could not be delivered. Pay a $2 fee here to reschedule: bit.ly/xyz123",
        "Cheap meds online!!! No prescription needed, 90% off, order today.",
        "You've been selected for an exclusive crypto investment with guaranteed 300% returns.",
        "Final notice: your computer is infected. Call this number now to remove the viruses.",
    ], no: [
        "Hi Sam, attached are the meeting notes from today. Let me know if I missed anything.",
        "Your order #4521 from our store has shipped.",
        "Reminder: dentist appointment tomorrow at 10:00.",
        "Can we move our call to 3pm?",
        "Here is the quarterly report you asked for.",
        "Thanks for your payment. Your receipt is attached.",
        "Mum here — don't forget to bring the cake on Sunday!",
        "The team lunch is on Friday at the Italian place near the office.",
    ])

    static let priority = group("email.priority", preset("email", "priority"), [
        ("Weekly newsletter: the top 10 gadgets of the month.", .levels(1...2)),
        ("Promotional offer: 20% off shoes this weekend.", .levels(1...2)),
        ("FYI, the cafeteria menu for next week is attached.", .levels(1...2)),
        ("Please review the draft policy whenever you have a moment; there's no deadline.", .levels(2...3)),
        ("Can you send me the figures for the report that is due on Friday?", .levels(2...3)),
        ("The client meeting was moved to this afternoon at 3pm, please prepare the slides.", .levels(3...4)),
        ("The server is down and customers can't log in — I need you on the call NOW.", .levels(4...4)),
        ("Security alert: someone signed in to your account from an unknown device. If this wasn't you, act immediately.", .levels(4...4)),
        ("Reminder: submit your timesheet by the end of the day today.", .levels(3...4)),
        ("Your flight tomorrow morning has been cancelled; please rebook.", .levels(3...4)),
    ])

    static let email = intent + needsReply + spam + priority

    // MARK: moderation (30)

    static let category = keyed("moderation.category", preset("moderation", "category"), [
        ("ok", [
            "Here's my recipe for banana bread: mix three ripe bananas with flour, eggs and sugar.",
            "Does anyone know a good hiking trail near Lake Tahoe for beginners?",
            "Great game last night! The final goal was incredible.",
            "I just finished reading a fantastic book about the history of Rome.",
        ]),
        ("spam", [
            "BUY CHEAP FOLLOWERS NOW!!! 10,000 followers for $5, visit my profile link!!!",
            "Earn $500 a day from home, DM me for the secret method!!! Limited spots!!!",
            "Best replica watches, 90% off, free shipping, visit cheapwatches-example.biz now",
            "Click my link to win a free phone, only 3 left, hurry!!!",
        ]),
        ("harassment", [
            "You're a pathetic idiot and everyone in this forum hates you. Just leave.",
            "Nobody wants to hear from someone as stupid and ugly as you.",
            "People like you are worthless trash and shouldn't be allowed to post here.",
            "Shut up, loser. Your opinion is garbage, just like you.",
        ]),
        ("self_harm", [
            "Lately I've been thinking about hurting myself and I don't know who to talk to.",
            "I feel like I don't want to be alive anymore.",
            "I started hurting myself again when things get too hard.",
            "Sometimes I think everyone would be better off if I just disappeared for good.",
        ]),
        ("adult", [
            "Check out my 18+ only uncensored photos, adults only, link in bio.",
            "Looking for a hookup tonight, send me some spicy pics.",
            "This thread is for sharing explicit adult content only, NSFW.",
            "Subscribe to my adults-only page for exclusive nude content.",
        ]),
    ])

    static let remove = truths("moderation.remove", preset("moderation", "remove"), yes: [
        "You're a pathetic idiot and everyone here hates you.",
        "BUY CHEAP FOLLOWERS NOW, visit my link!!!",
        "Subscribe to my adults-only page for explicit nude content.",
        "People like you are worthless trash.",
        "Win a free phone!!! Click this link now, only 3 left!!!",
    ], no: [
        "Does anyone have tips for growing tomatoes on a balcony?",
        "I respectfully disagree with the author's conclusion about inflation.",
        "Happy birthday to my wonderful sister!",
        "Here's a photo of my cat sleeping on my keyboard.",
        "The meeting minutes from Tuesday are now posted in the group files.",
    ])

    static let moderation = category + remove

    // MARK: sentiment (44)

    static let polarity = keyed("sentiment.polarity", preset("sentiment", "polarity"), [
        ("positive", [
            "Absolutely love this phone, the camera is amazing!",
            "Best customer service I've ever experienced. Thank you!",
            "The hotel was spotless and the staff were incredibly friendly.",
            "What a fantastic concert, I'd go again in a heartbeat.",
            "This update made the app so much faster. Great job!",
            "Delicious food and a lovely atmosphere. Highly recommended.",
        ]),
        ("neutral", [
            "The package was delivered on Tuesday at 3pm.",
            "The meeting is scheduled for room 204.",
            "The product comes in blue, black and white.",
            "The store opens at 9am on weekdays.",
            "The report contains twelve pages and three charts.",
            "The train to Athens departs from platform 4.",
        ]),
        ("negative", [
            "Terrible experience. The food was cold and the waiter was rude.",
            "The app crashes constantly and support never answers. Awful.",
            "Worst purchase I've made this year, it broke after two days.",
            "I'm really disappointed with the quality of this jacket.",
            "The flight was delayed six hours and nobody told us anything. Horrible.",
            "This software is slow, buggy and overpriced.",
        ]),
        ("mixed", [
            "The camera is excellent, but the battery life is terrible.",
            "Great food, but the service was painfully slow.",
            "I love the design, although it's far too expensive.",
            "The hotel room was beautiful, but the street noise kept us awake all night.",
            "Fast delivery, but the item arrived damaged.",
            "The movie had stunning visuals but a boring, predictable plot.",
        ]),
    ])

    static let sarcastic = truths("sentiment.sarcastic", preset("sentiment", "sarcastic"), yes: [
        "Oh great, another Monday. Just what I needed.",
        "Wow, the train is late again. What a surprise.",
        "Fantastic, my phone died right before the important call. Perfect timing.",
        "Sure, because waiting on hold for two hours is my favourite hobby.",
        "Oh wonderful, it's raining on the one day I left my umbrella at home.",
    ], no: [
        "The train arrived on time and the ride was comfortable.",
        "I really enjoyed the concert last night.",
        "The meeting was moved to Thursday.",
        "Thank you for helping me move house, I really appreciate it.",
        "This recipe turned out exactly as described.",
    ])

    static let intensity = group("sentiment.intensity", preset("sentiment", "intensity"), [
        ("The package arrived.", .levels(1...2)),
        ("The food was okay, I guess.", .levels(1...2)),
        ("I liked the movie.", .levels(2...3)),
        ("I really enjoyed the trip, it was lovely.", .levels(3...4)),
        ("This is the BEST DAY OF MY LIFE!!! I'm absolutely ecstatic!!!", .levels(4...5)),
        ("I absolutely hate this, it's the worst thing ever, completely disgusting!!!", .levels(4...5)),
        ("The hotel was fine.", .levels(1...2)),
        ("I'm furious. This is an outrageous, unacceptable disaster!", .levels(4...5)),
        ("The service was good.", .levels(2...3)),
        ("The lecture was a bit boring.", .levels(2...3)),
    ])

    static let sentiment = polarity + sarcastic + intensity

    // MARK: language identification (15)

    static let language = keyed("language.id", custom(#"""
    {"language":{"type":"choice","instructions":"In which language is the STATE written?",
      "criteria":{"english":"English","french":"French","german":"German","spanish":"Spanish","italian":"Italian"}}}
    """#), [
        ("english", ["The weather is lovely today, let's go for a walk in the park.",
                     "Could you please send me the report by Friday?",
                     "My brother bought a new car last week."]),
        ("french", ["Il fait très beau aujourd'hui, allons nous promener au parc.",
                    "Pouvez-vous m'envoyer le rapport avant vendredi ?",
                    "Mon frère a acheté une nouvelle voiture la semaine dernière."]),
        ("german", ["Das Wetter ist heute wunderschön, lass uns im Park spazieren gehen.",
                    "Könnten Sie mir bitte den Bericht bis Freitag schicken?",
                    "Mein Bruder hat letzte Woche ein neues Auto gekauft."]),
        ("spanish", ["Hace un tiempo precioso hoy, vamos a pasear por el parque.",
                     "¿Podría enviarme el informe antes del viernes?",
                     "Mi hermano compró un coche nuevo la semana pasada."]),
        ("italian", ["Oggi il tempo è bellissimo, andiamo a fare una passeggiata al parco.",
                     "Potrebbe inviarmi il rapporto entro venerdì?",
                     "Mio fratello ha comprato una macchina nuova la settimana scorsa."]),
    ])

    // MARK: reading comprehension (30)

    static let meetingDay = group("reading.meeting_day", custom(#"""
    {"meeting_day":{"type":"choice","instructions":"On which weekday does the meeting take place now, after any change described in the STATE?",
      "criteria":["Monday","Tuesday","Wednesday","Thursday","Friday"]}}
    """#), [
        ("The meeting originally planned for Monday has been moved to Wednesday.", .key("Wednesday")),
        ("We'll meet on Friday instead of Tuesday as the room is booked.", .key("Friday")),
        ("Thursday's meeting is cancelled; we'll hold it on Monday next week instead.", .key("Monday")),
        ("Heads-up: the review stays on Tuesday, only the time changed to 3pm.", .key("Tuesday")),
        ("Due to the holiday, Wednesday's standup moves to Thursday.", .key("Thursday")),
    ])

    static let orderStatus = group("reading.order_status", custom(#"""
    {"order_status":{"type":"choice","instructions":"What is the current status of the order?",
      "criteria":{"processing":"being prepared, not shipped yet","shipped":"on its way to the customer",
                  "delivered":"has arrived at the customer","cancelled":"will not be fulfilled"}}}
    """#), [
        ("Your order has left our warehouse and is on its way.", .key("shipped")),
        ("The courier left the parcel at your front door this afternoon.", .key("delivered")),
        ("We're currently packing your items and will ship them tomorrow.", .key("processing")),
        ("As requested, your order has been cancelled and you will not be charged.", .key("cancelled")),
        ("Your parcel is with the courier and should arrive in 2 days.", .key("shipped")),
    ])

    /// Each fact is its own proposition, so each case carries its own question.
    static let facts: [LiveCase] = [
        ("Anna is older than Ben. Ben is older than Chris.", "Anna is older than Chris.", true),
        ("The store is open Monday to Friday, 9am to 5pm.", "The store is open on Sunday.", false),
        ("All tickets for Saturday's show are sold out.", "You can still buy a ticket for Saturday's show.", false),
        ("The package weighs 3 kg and the limit for standard shipping is 5 kg.", "The package qualifies for standard shipping.", true),
        ("Maria moved from Madrid to Lisbon in 2019 and still lives there.", "Maria currently lives in Lisbon.", true),
        ("The flight was cancelled due to the storm.", "The flight departed on time.", false),
        ("Tom has a meeting from 2pm to 4pm.", "Tom is free at 3pm.", false),
        ("The recipe needs 2 eggs and we have 6 eggs.", "We have enough eggs for the recipe.", true),
        ("The museum is free for children under 12. Lucy is 8.", "Lucy can enter the museum for free.", true),
        ("The contract expires on 31 March. Today is 15 April.", "The contract is still valid today.", false),
        ("The meeting room holds 8 people and 12 have registered.", "Everyone who registered fits in the meeting room.", false),
        ("Sara has lived in Berlin since 2015 and has never lived anywhere else.", "Sara has lived in Paris.", false),
        ("The shop accepts cash and credit cards but not cheques.", "You can pay by credit card at the shop.", true),
        ("The train leaves at 14:10 and the journey takes 50 minutes.", "The train arrives at 15:00.", true),
        ("Every employee must complete the safety course. Dan is an employee.", "Dan must complete the safety course.", true),
        ("The library closes at 6pm on Saturdays. It is Saturday, 7pm.", "The library is open now.", false),
        ("The warranty covers two years from purchase. Mia bought the laptop three years ago.", "Mia's laptop is still under warranty.", false),
        ("The parcel was signed for by the recipient at 10:42.", "The parcel was delivered.", true),
        ("Only members can use the pool. Leo is not a member.", "Leo can use the pool.", false),
        ("It rained all day, so the football match was postponed to Sunday.", "The football match took place as planned.", false),
    ].enumerated().map { i, fact in
        let q = Question(name: "fact", type: .noul, instructions: fact.1,
                         options: try! QuestionSet.noulOptions("fact", nil, proposition: fact.1))
        return LiveCase(id: "reading.facts#\(i < 9 ? "0" : "")\(i + 1)", category: "reading.facts",
                        question: q, state: .string(fact.0), expect: .truth(fact.2))
    }

    static let reading = meetingDay + orderStatus + facts

    // MARK: numbers in structured JSON states (40)

    static func numeric(_ category: String, _ q: Question, _ field: String, _ values: [Double],
                        extra: [(String, JSON)] = [], expect: (Double) -> Expectation) -> [LiveCase] {
        values.enumerated().map { i, v in
            LiveCase(id: "\(category)#\(i < 9 ? "0" : "")\(i + 1)", category: category, question: q,
                     state: .object(extra + [(field, .number(v))]), expect: expect(v))
        }
    }

    static let cpu = numeric("numeric.cpu", custom(#"{"cpu_high":{"type":"noul","instructions":"CPU usage (cpu_percent) is above 90 percent."}}"#),
                             "cpu_percent", [12, 35, 55, 72, 85, 89, 91, 93, 97, 99],
                             extra: [("host", .string("web-1")), ("memory_percent", .number(48))]) { .truth($0 > 90) }

    static let disk = numeric("numeric.disk", custom(#"{"disk_low":{"type":"noul","instructions":"Free disk space (disk_free_gb) is below 10 GB."}}"#),
                              "disk_free_gb", [2, 5, 8, 9.5, 11, 15, 40, 120, 0.5, 250],
                              extra: [("volume", .string("/data"))]) { .truth($0 < 10) }

    static let battery = numeric("numeric.battery", custom(#"""
    {"battery":{"type":"score","instructions":"Which band does battery_percent fall into?",
      "levels":["below 20%","20% to 49%","50% to 79%","80% or more"]}}
    """#), "battery_percent", [5, 15, 25, 40, 55, 70, 85, 95, 100, 48], extra: [("device", .string("phone"))]) { v in
        let level: Double = v < 20 ? 1 : v < 50 ? 2 : v < 80 ? 3 : 4
        return .levels(level...level)
    }

    static let temperature = numeric("numeric.temperature", custom(#"""
    {"weather":{"type":"choice","instructions":"Classify temperature_c.",
      "criteria":{"freezing":"below 0 °C","cold":"0 to 14 °C","mild":"15 to 24 °C","hot":"25 °C or more"}}}
    """#), "temperature_c", [-8, -1, 3, 10, 16, 21, 27, 35, 14, 25], extra: [("city", .string("Athens"))]) { v in
        .key(v < 0 ? "freezing" : v < 15 ? "cold" : v < 25 ? "mild" : "hot")
    }

    static let numeric = cpu + disk + battery + temperature
}
