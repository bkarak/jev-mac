import Foundation
import Testing
@testable import JevMac

@Suite("Model report")
struct ModelInfoTests {
    static let elapsedCases: [(String, Int?)] = [
        ("00:45", 45), ("05:02", 302), ("01:02:03", 3_723), ("08-15:04:54", 745_494), ("12", nil), ("x:10", nil),
    ]

    @Test("ps elapsed times parse to seconds", arguments: elapsedCases)
    func elapsed(text: String, seconds: Int?) {
        #expect(ModelInfo.parseElapsed(text) == seconds)
    }

    static let durationCases: [(Int, String)] = [(45, "45 s"), (252, "4 m 12 s"), (7_500, "2 h 5 m"), (745_494, "8 d 15 h")]

    @Test("durations read like 8 d 15 h", arguments: durationCases)
    func duration(seconds: Int, text: String) {
        #expect(ModelInfo.formatDuration(seconds) == text)
    }

    @Test func psOutputKeepsExecutableNamesEvenWithSpacesInPaths() {
        let text = """
          765  33792 08-15:39:36 /usr/libexec/modelmanagerd
         7333 830464 08-15:04:54 /System/Library/ExtensionKit/Extensions/TGOnDeviceInferenceProviderService.appex/Contents/MacOS/TGOnDeviceInferenceProviderService
         4242   1024    00:07 /Library/Application Support/Some Tool/helper
        garbage line
        """
        let procs = ModelInfo.parsePS(text)
        #expect(procs.map(\.name) == ["modelmanagerd", "TGOnDeviceInferenceProviderService", "helper"])
        #expect(procs[1] == ServiceProcess(pid: 7333, residentKB: 830_464, elapsedSeconds: 745_494,
                                           name: "TGOnDeviceInferenceProviderService"))
    }

    @Test func languagesGroupTheirRegions() {
        let langs = ["en-US", "en-GB", "fr-FR", "fr-CA", "ja-JP", "zh-Hans-CN"].map { Locale.Language(identifier: $0) }
        let s = ModelInfo.languageSummary(langs)
        #expect(s.languages == 4 && s.locales == 6)
        #expect(s.names == ["Chinese", "English (GB, US)", "French (CA, FR)", "Japanese"])
    }
}
