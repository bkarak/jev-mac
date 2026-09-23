import Foundation
import Testing
@testable import JevMac

/// Runs the real `jev-mac` binary. None of these reach the model: every case
/// either needs no model or fails validation first.
@Suite("CLI", .enabled(if: CLI.binary != nil, "needs the jev-mac binary next to the test bundle"))
struct CLITests {
    struct Case: Sendable, CustomTestStringConvertible {
        let args: [String]
        var stdin = ""
        let status: Int32
        var stdout: String? = nil
        var stderr: String? = nil
        var testDescription: String { (["jev-mac"] + args).joined(separator: " ") + (stdin.isEmpty ? "" : " < stdin") }
    }

    static let cases: [Case] = [
        Case(args: [], status: 0, stdout: "USAGE"),
        Case(args: ["help"], status: 0, stdout: "ENGINE OPTIONS"),
        Case(args: ["--help"], status: 0, stdout: "USAGE"),
        Case(args: ["-h"], status: 0, stdout: "USAGE"),
        Case(args: ["bogus"], status: 2, stderr: "unknown command"),
        Case(args: ["presets"], status: 0, stdout: "triage"),
        Case(args: ["presets", "nosuch"], status: 2, stderr: "unknown preset"),
        Case(args: ["presets", "--pretty"], status: 2, stderr: "unknown option --pretty"),
        Case(args: ["check", "--bogus"], status: 2, stderr: "unknown option --bogus"),
        Case(args: ["predict"], status: 2, stderr: "--questions FILE or --preset NAME"),
        Case(args: ["predict", "--preset", "nosuch", "x"], status: 2, stderr: "unknown preset"),
        Case(args: ["predict", "--preset", "triage", "--questions", "q.json", "x"], status: 2, stderr: "not both"),
        Case(args: ["predict", "--preset", "triage", "--model", "bogus", "x"], status: 2, stderr: "--model must be one of"),
        Case(args: ["predict", "--preset=triage", "--model=bogus", "x"], status: 2, stderr: "--model must be one of"),
        Case(args: ["predict", "--preset", "triage", "--head", "bogus", "x"], status: 2, stderr: "--head must be"),
        Case(args: ["predict", "--preset", "triage", "--samples", "0", "x"], status: 2, stderr: "must be ≥ 1"),
        Case(args: ["predict", "--preset", "triage", "--samples", "abc", "x"], status: 2, stderr: "expects an integer"),
        Case(args: ["predict", "--preset", "triage", "--seed", "-1", "x"], status: 2, stderr: "non-negative integer"),
        Case(args: ["predict", "--preset", "triage", "--batch-size", "0", "x"], status: 2, stderr: "must be ≥ 1"),
        Case(args: ["predict", "--preset", "triage", "--sampling-temperature", "hot", "x"], status: 2, stderr: "expects a number"),
        Case(args: ["predict", "--preset", "triage", "--fused", "--head", "vote", "x"], status: 2, stderr: "--fused works with"),
        Case(args: ["predict", "--prety", "--preset", "triage", "x"], status: 2, stderr: "unknown option --prety"),
        Case(args: ["predict", "--preset"], status: 2, stderr: "--preset needs a value"),
        Case(args: ["predict", "--questions", "--pretty"], status: 2, stderr: "--questions needs a value"),
        Case(args: ["predict", "--pretty=yes", "--preset", "triage", "x"], status: 2, stderr: "does not take a value"),
        Case(args: ["predict", "--preset", "triage"], status: 2, stderr: "the state is empty"),
        Case(args: ["predict", "--preset", "triage"], stdin: "   \n", status: 2, stderr: "the state is empty"),
        Case(args: ["predict", "--preset", "triage", "--batch", "-"], stdin: "\n  \n", status: 0, stdout: ""),
        Case(args: ["predict", "--questions", "/nonexistent/q.json", "x"], status: 2, stderr: "cannot read"),
        Case(args: ["predict", "--preset", "triage", "--state-file", "/nonexistent/s.txt"], status: 2, stderr: "cannot read"),
        Case(args: ["bench", "--runs", "0"], status: 2, stderr: "--runs must be ≥ 1"),
        Case(args: ["bench", "--summary"], status: 2, stderr: "unknown option --summary"),
        Case(args: ["bench", "--suite", "bogus"], status: 2, stderr: "--suite must be"),
        Case(args: ["bench", "--suite", "latency", "--runs", "0"], status: 2, stderr: "--runs ≥ 1"),
        Case(args: ["snake", "--width", "3"], status: 2, stderr: "--width 6…40"),
        Case(args: ["snake", "--height", "99"], status: 2, stderr: "--height 6…30"),
        Case(args: ["snake", "--fps", "abc"], status: 2, stderr: "expects a number"),
        Case(args: ["snake", "--fps", "0"], status: 2, stderr: "--fps must be > 0"),
        Case(args: ["snake", "--headless", "--moves", "0"], status: 2, stderr: "--moves must be ≥ 1"),
    ]

    @Test("exit codes and messages", arguments: cases)
    func run(_ c: Case) throws {
        let r = try CLI.run(c.args, stdin: c.stdin)
        #expect(r.status == c.status, "stderr: \(r.stderr)")
        if let out = c.stdout {
            if out.isEmpty { #expect(r.stdout.isEmpty) } else { #expect(r.stdout.contains(out), "stdout: \(r.stdout.prefix(200))") }
        }
        if let err = c.stderr { #expect(r.stderr.contains(err), "stderr: \(r.stderr)") }
        if c.status == 2 { #expect(r.stderr.hasPrefix("jev-mac: "), "errors are prefixed for scripts") }
    }

    @Test("presets print the exact question set the engine uses", arguments: Presets.all.map(\.name))
    func presetJSON(_ name: String) throws {
        let r = try CLI.run(["presets", name])
        #expect(r.status == 0)
        #expect(try QuestionSet.parse(text: r.stdout) == Presets.questions(named: name))
    }

    @Test func checkDescribesEveryModel() throws {
        let r = try CLI.run(["check"])
        #expect(r.status == 0)
        for text in ["On-device · SystemLanguageModel", "Private Cloud Compute · PrivateCloudComputeLanguageModel",
                     "context", "capabilities", "languages", "quota", "jev-mac check --measure"] {
            #expect(r.stdout.contains(text), "missing \(text)")
        }
    }

    static let badFiles: [(String, String)] = [
        (#"{"q":{"type":"noul",}}"#, "JSON parse error"),
        (#"{"q":{"type":"maybe","instructions":"x"}}"#, "type must be one of"),
    ]

    @Test("broken question files are usage errors", arguments: badFiles)
    func badQuestionFile(contents: String, message: String) throws {
        let path = try tempFile(contents)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = try CLI.run(["predict", "--questions", path, "x"])
        #expect(r.status == 2)
        #expect(r.stderr.contains(message), "stderr: \(r.stderr)")
    }
}
