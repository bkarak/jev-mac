import Foundation
import JevCore

let help = """
jev — typed-decision engine on Apple foundation models

Answers structured questions about a state with calibrated probabilities
instead of free text. Three question types:
  choice  probabilities over named options
  score   probabilities over ordered rubric levels + expected score
  noul    P(true) for a proposition

USAGE
  jev check                                  model availability
  jev presets [NAME]                         list presets / print one as JSON
  jev predict [STATE…] (--preset NAME | --questions FILE) [options]
  jev bench [STATE…] [--preset NAME | --questions FILE] [--runs N] [options]
  jev bench --suite latency [--warmups 3 --runs 20]   11-workload latency matrix
  jev bench --suite fizzbuzz                          300 typed decisions with exact labels
  jev snake [--fps N] [--max-speed] [--unassisted] [--lean] [--headless --moves N]

PREDICT INPUT
  STATE…                  state text on the command line (JSON objects allowed)
  --state-file FILE|-     read the state from a file or stdin
  --batch FILE|-          JSONL / one state per line; prints one JSON result per line
  (stdin is used when no state is given and input is piped)

ENGINE OPTIONS
  --model on-device|tagging|pcc|auto   Apple model route (default auto)
  --head distribution|vote             read-out head (default distribution)
  --samples N                          votes per question for --head vote (default 5)
  --sampling-temperature T             sampling temperature for votes (default 1.0)
  --seed N                             sampling seed for reproducible votes
  --batch-size N                       concurrent states in --batch (default 4)
  --fused                              answer all questions in one call (fewer tokens, less accurate)
  --prewarm                            prewarm each newly created session
  --no-cache                           no prefix cache or session reuse: a fresh session per call

OUTPUT
  --pretty                pretty-printed JSON
  --summary               human-readable bars instead of JSON

SNAKE
  --fps N   --max-speed   --unassisted (disable safety shield)   --lean (next_move only)
  --width W --height H    --seed N     --headless --moves N (benchmark, no UI)
"""

@main
struct Main {
    static func main() async {
        let argv = CommandLine.arguments.dropFirst()
        guard let command = argv.first else { print(help); return }
        let rest = argv.dropFirst()
        do {
            switch command {
            case "check":
                Commands.check()
            case "presets":
                try Commands.presets(Args(rest, switches: [], options: []))
            case "predict":
                try await Commands.predict(Args(rest, switches: Commands.predictSwitches, options: Commands.predictOptions))
            case "bench":
                try await Commands.bench(Args(rest, switches: Commands.benchSwitches, options: Commands.benchOptions))
            case "snake":
                try await SnakeCommand.run(Args(rest, switches: SnakeCommand.switches, options: SnakeCommand.options))
            case "help", "--help", "-h":
                print(help)
            default:
                throw UsageError("unknown command '\(command)'. Run: jev help")
            }
        } catch {
            printErr("jev: " + Agent.explain(error))
            exit(error is UsageError || error is QuestionError || error is JSONParseError ? 2 : 1)
        }
    }
}
