import Testing
@testable import JevMac

@Suite("Benchmark definitions")
struct BenchmarkTests {
    @Test func fizzBuzzLabelsAreExact() {
        let say = ["number", "number", "Fizz", "number", "Buzz", "Fizz", "number", "number",
                   "Fizz", "Buzz", "number", "Fizz", "number", "number", "FizzBuzz"]
        for n in 1...15 {
            let t = FizzBuzzSuite.truth(n)
            #expect(t["say"] == say[n - 1])
            #expect(t["div3"] == (n % 3 == 0 ? "true" : "false") && t["div5"] == (n % 5 == 0 ? "true" : "false"))
        }
        let counts = Dictionary(grouping: 1...100, by: { FizzBuzzSuite.truth($0)["say"]! }).mapValues(\.count)
        #expect(counts == ["FizzBuzz": 6, "Fizz": 27, "Buzz": 14, "number": 53])
        #expect(FizzBuzzSuite.questions.map(\.name) == ["div3", "div5", "say"])
    }

    @Test func percentilesMatchNumpy() {
        #expect(LatencyStats.percentile([4, 1, 3, 2], 0.5) == 2.5)
        #expect(close(LatencyStats.percentile([1, 2, 3, 4], 0.95), 3.85))
        #expect(LatencyStats.percentile([7], 0.95) == 7)
        #expect(close(LatencyStats.percentile((1...20).map(Double.init), 0.95), 19.05))
        #expect(LatencyStats.percentile([], 0.5).isNaN)
    }

    @Test func demoWorkloadsHaveThePublishedShape() {
        #expect(Workloads.customerService.questions.count == 8)
        #expect(Workloads.customerService.questions.allSatisfy { $0.type == .noul })
        #expect(Workloads.drone.questions.count == 3)
        #expect(Set(Workloads.drone.questions.map(\.type)) == Set(QuestionType.allCases))
    }
}
