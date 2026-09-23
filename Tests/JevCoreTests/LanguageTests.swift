import Testing
@testable import JevCore

@Suite("Language detection")
struct LanguageTests {
    static let samples: [(String, String)] = [
        ("en", "The weather is lovely today and we are going for a long walk in the park."),
        ("fr", "Il fait très beau aujourd'hui et nous allons faire une longue promenade dans le parc."),
        ("de", "Das Wetter ist heute wunderschön und wir machen einen langen Spaziergang im Park."),
        ("es", "Hoy hace un tiempo precioso y vamos a dar un largo paseo por el parque."),
        ("it", "Oggi il tempo è bellissimo e faremo una lunga passeggiata nel parco."),
        ("pt", "O tempo está lindo hoje e vamos dar um longo passeio no parque."),
        ("nl", "Het weer is vandaag prachtig en we gaan een lange wandeling maken in het park."),
        ("el", "Ο καιρός είναι υπέροχος σήμερα και θα κάνουμε μια μεγάλη βόλτα στο πάρκο."),
        ("ru", "Сегодня прекрасная погода, и мы собираемся долго гулять в парке."),
        ("ja", "今日はとても良い天気なので、公園を長く散歩する予定です。"),
        ("zh-Hans", "今天天气很好，我们要去公园散步很长时间。"),
        ("ko", "오늘은 날씨가 아주 좋아서 공원에서 오래 산책할 거예요."),
        ("ar", "الطقس جميل اليوم وسنذهب في نزهة طويلة في الحديقة."),
        ("he", "מזג האוויר נפלא היום ואנחנו הולכים לטיול ארוך בפארק."),
        ("sv", "Vädret är underbart idag och vi ska ta en lång promenad i parken."),
        ("tr", "Bugün hava çok güzel ve parkta uzun bir yürüyüşe çıkacağız."),
    ]

    @Test("detects the language of a state", arguments: samples)
    func detects(code: String, text: String) throws {
        let d = try #require(LanguageDetector.detect(text))
        #expect(d.code == code)
        #expect(d.confidence > 0 && d.confidence <= 1)
    }

    @Test func emptyTextHasNoLanguage() {
        #expect(LanguageDetector.detect("") == nil)
        #expect(LanguageDetector.detect("   \n ") == nil)
    }
}
