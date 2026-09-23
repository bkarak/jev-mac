import Testing
@testable import JevMac

@Suite("Hardware detection")
struct HardwareTests {
    @Test func thisMacIsDescribed() {
        let h = Hardware.current()
        #expect(h.chip != "unknown chip" && h.model != "unknown Mac")
        #expect(h.cpuCores >= 1 && h.memoryBytes >= 1_073_741_824)
        if let p = h.performanceCores, let e = h.efficiencyCores { #expect(p + e == h.cpuCores) }
        #expect(h.machine.hasPrefix(h.chip) && h.machine.hasSuffix("GB memory"))
        #expect(h.conditions.hasPrefix("macOS ") && h.conditions.contains("thermal "))
        #expect(h.drift.contains("thermal "))
        #expect(h.warnings.allSatisfy { !$0.isEmpty })
    }

    static let memoryCases: [(UInt64, String)] = [
        (68_719_476_736, "64 GB"), (25_769_803_776, "24 GB"), (1_610_612_736, "1.5 GB"), (536_870_912, "512 MB"),
    ]

    @Test("memory reads in GB", arguments: memoryCases)
    func memory(bytes: UInt64, text: String) {
        #expect(Hardware.formatMemory(bytes) == text)
    }
}
