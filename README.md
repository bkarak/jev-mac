# jev-mac

> **Experimental.** This is a fun and research project that explores how far
> Apple's on-device foundation models can go as a typed-decision engine. It is
> not production software: answers can be confidently wrong, and some inputs are
> refused outright. See *Known limits* before relying on it.

A command-line typed-decision engine built on the architecture of
[laya-mlx](https://deepwiki.com/mizorewww/laya-mlx), running only on Apple's
foundation models (the `FoundationModels` framework). It uses no third-party
weights, no MLX and no Python.

You pass in a **state** (free text or JSON) and a set of **typed questions**.
jev-mac returns a probability distribution for every question, not free text:

| type     | returns                                                        |
|----------|----------------------------------------------------------------|
| `choice` | probabilities over named options                                |
| `score`  | probabilities over ordered rubric levels, plus `expected` score |
| `noul`   | `probability` = P(true) for a proposition                       |

Requirements: macOS 27, Apple silicon, Apple Intelligence turned on, Xcode 27 toolchain.

## Quick start

```bash
make release
```

```bash
make models
```

```bash
make run ARGS='predict --preset triage --summary "I was billed twice this month. Please refund the duplicate charge."'
```

```
department [choice] → billing  confidence=1.00
    billing    ████████████████████████  1.000
    technical  ························  0.000
    ...
urgency [score] → level 1  expected=1.00  confidence=1.00
wants_refund [noul] → true  P(true)=1.000
```

Read the output as a decision with a rough confidence, not as calibrated
probabilities. The on-device model often puts all the weight on its answer,
including when that answer is wrong; see *Tests*.

## Building with make

Running `make` on its own lists every target and variable. The targets:

| target | what it does |
|---|---|
| `make build` | debug build |
| `make release` | optimized build (`.build/release/jev-mac`) |
| `make test` or `make check` | deterministic tests: 577 cases, no model calls, under a second once built |
| `make test-live` | live tests against the on-device model: 423 cases, about 8 minutes |
| `make test-all` | all 1,000 test cases |
| `make models` | describe the Apple foundation models on this Mac and time them |
| `make snake` | play the snake demo in the terminal |
| `make run ARGS='…'` | run jev-mac with any arguments |
| `make bench` | triage preset latency, 10 warm runs |
| `make bench-latency` | latency matrix, Open-Jev protocol (about 8 minutes) |
| `make bench-fizzbuzz` | FizzBuzz control, 300 decisions (about 4 minutes) |
| `make install` / `make uninstall` | copy jev-mac into `PREFIX/bin`, or remove it |
| `make clean` | remove build products |

The variables:

| variable | meaning | default |
|---|---|---|
| `ARGS` | arguments for `run` and `snake` | none |
| `PREFIX` | install prefix; the binary goes to `PREFIX/bin` | `/usr/local` |
| `TEST_BUILD` | where the tests are built, outside iCloud Drive (its extended attributes break code-signing of the test bundle) | `/tmp/jev-mac-build` |
| `SWIFT` | the swift driver | `swift` |

Some examples:

```bash
make install PREFIX=~/.local
```

```bash
make snake ARGS='--lean --fps 2'
```

```bash
make snake ARGS='--headless --moves 50'
```

`make models` describes each Apple model on this Mac:

- variant and context window;
- capabilities (guided generation, tool calling, vision, reasoning);
- supported languages, and whether your locale is one of them;
- guardrail options and adapter support;
- the system processes that host the model, with their memory and uptime;
- Private Cloud Compute's context window and quota.

It then times the on-device model (first request, time to first token,
tokens/s and one jev-mac decision) and tries one small Private Cloud Compute
request. `jev-mac check` alone skips the timing and makes no model requests.

## Architecture mapping

| laya-mlx                                   | jev-mac (Apple foundation models)                                                                                     |
|--------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| `Agent` (load checkpoint, predict)         | `Agent`: routes, builds prompts, runs every question concurrently, calibrates ([Agent.swift](Sources/JevMac/Agent.swift)) |
| `_to_internal` question validation         | `QuestionSet.parse` → `Question` / `Option` ([Question.swift](Sources/JevMac/Question.swift))                      |
| `build_prefix` / `build_sequence`, `render_options`, `serialize_state`, `render_criterion` | `PromptBuilder` with the same functions; the prefix becomes the session instructions ([PromptBuilder.swift](Sources/JevMac/PromptBuilder.swift)) |
| Bidirectional encoder + decision heads     | Guided generation with a `DynamicGenerationSchema` built per question ([DecisionHeads.swift](Sources/JevMac/DecisionHeads.swift)) |
| Temperature calibration                    | Per-question `"temperature"`, applied as pᵢ^(1/T) and renormalized                                                 |
| `confidence_from_probs`                    | 1 − normalized entropy                                                                                            |
| `PrefixCache` (LRU of encoded prefixes)    | `PrefixCache`: an LRU of compiled prefix + schema, each with a pool of sessions reset to their instructions after every request, so the model can serve the prefix from its cache ([PrefixCache.swift](Sources/JevMac/PrefixCache.swift)) |
| Router over checkpoints                    | `Router` over Apple models: `on-device`, `tagging` (content-tagging adapter), `pcc` (Private Cloud Compute), `auto` |
| Language detection                         | `NLLanguageRecognizer` plus `SystemLanguageModel.supportsLocale`                                                   |
| Presets (triage, email, moderation)        | `triage`, `email`, `moderation`, `sentiment`                                                                        |
| `collate_items` / `batch_size`             | `--batch FILE` (JSONL), processed `--batch-size` states at a time                                                  |
| `laya-snake` demo + benchmark              | `jev-mac snake` (TUI with a safety shield) and `jev-mac snake --headless`, plus `jev-mac bench`                                  |
| `convert` (PyTorch → MLX)                  | Not needed. The model ships with macOS.                                                                             |

### Where it has to differ

Apple's models do not expose logits or token log-probabilities, and a
single forward pass is not available. jev-mac reads distributions out through
constrained generation instead, using one of two heads:

- **`distribution`** (default). One greedy call per question. The schema
  asks for the single best option first (an enum), then an integer weight from
  0 to 100 for every option. If the weights disagree with the stated answer,
  the answer takes the largest share. Per-question temperature scaling is then applied.
  Answer-first is not a stylistic choice. When the model was asked for weights
  alone, it piled the mass onto an early option regardless of content: German,
  Spanish and Italian text all came back `french`, the second slot, and
  reversing the option order moved the answers with the slot. The live test
  suite found this.
- **`vote`**. `--samples N` sampled calls per question, each constrained to a
  single option key. The empirical frequencies, with add-½ smoothing, become
  the distribution. This head is slower, but its distribution comes from
  actual sampling rather than from numbers the model writes.

If the on-device model refuses the `distribution` form of a question (this
does happen on some inputs), jev-mac falls back to `vote` for that question
automatically. The answer then reports `"head": "vote (fallback)"`.

### Measured on this Mac (AFM 3 Core Advanced, on-device, triage preset)

| mode                                   | warm median / prediction (3 questions) | notes                                      |
|----------------------------------------|----------------------------------------|--------------------------------------------|
| default (pooled sessions, cache)       | ~2.43 s                                | best accuracy; 7–16% of input from cache   |
| `--no-cache` (fresh session per call)  | ~2.45 s                                | no prefix reuse                            |
| `--prewarm`                            | ~2.43 s                                | prewarming new sessions changes little     |
| `--fused` (one call for all questions) | ~2.66 s                                | whole prompt from cache, but longer output and worse answers |

Asking for the answer before the weights costs about 29% in latency (1.87 s
before it). It buys 9 points of accuracy on choice questions and 14 on score
questions; see *Tests*.

The model is not reloaded between calls. It stays resident in the system's
inference service: during our runs that process kept one PID for 8+ days,
used 1.0–1.7 GB of memory, and logged no load or unload events.

jev-mac keeps a pool of sessions per question. A session serves one request, is
reset to its instructions, and waits for the next request with the same
question, so the model can serve the instruction prefix from its cache. A
session whose request failed is dropped. `--no-cache` goes back to a fresh
session per call. The gain is small, for two measured reasons:

- **Processing the prompt isn't the bottleneck.** Every request spends about
  410 ms before its first token, the same with 0 or 220 cached tokens and with
  239 or 437 input tokens. Generating the ~41-token answer and weights takes
  about 450 ms (roughly 90 tokens/s).
- **The service keeps only the most recently used session's context.**
  Alternating two sessions gave 0 cached tokens on every call; using one
  session twice in a row gave 220 on the second. A prediction's questions run
  interleaved, so they evict each other.

| per prediction, warm | fresh sessions (`--no-cache`) | pooled sessions (default) |
|---|---|---|
| triage, 3 questions | 2443–2446 ms · 0% of input cached | 2406–2429 ms · 7–16% cached |
| one question | 935 ms · 0% cached | 907 ms · 100% cached |

Latency therefore grows with the number of questions (the fixed per-request
overhead) and with the number of options (the weights written out). Leaving
the schema out of the prompt cuts the input to 239 tokens but makes the model
write more (59 output tokens), so it is slower overall. After the service has
been idle for a while, the first request pays about 0.4 s extra to warm up.
`jev-mac bench` excludes that with warmups; a one-shot `jev-mac predict` does not.

## Commands

```
jev-mac check [--measure]            describe the Apple models; --measure also times them
jev-mac presets [NAME]               list presets / print one as JSON
jev-mac predict [STATE…] (--preset NAME | --questions FILE) [options]
jev-mac bench   [STATE…] [--preset NAME | --questions FILE] [--runs N] [options]
jev-mac bench   --suite latency [--warmups 3 --runs 20]   11-workload latency matrix
jev-mac bench   --suite fizzbuzz                          300 typed decisions, exact labels
jev-mac snake   [--fps N] [--max-speed] [--unassisted] [--lean] [--headless --moves N]
```

The state comes from the arguments, from `--state-file FILE|-`, or from stdin
when it is piped. `--batch FILE|-` reads one state per line (plain text or
JSON) and prints one JSON result per line, in input order.

Engine options: `--model on-device|tagging|pcc|auto`, `--head distribution|vote`,
`--samples N`, `--sampling-temperature T`, `--seed N`, `--fused`, `--prewarm`
(prewarm each new session), `--no-cache` (no prefix cache or session reuse),
`--batch-size N`. Output options: `--pretty`, `--summary`.

## Question file format

```json
{
  "topic":  { "type": "choice", "instructions": "What is this review about?",
              "criteria": { "battery": "battery life", "display": "screen quality" } },
  "rating": { "type": "score", "instructions": "Implied star rating?",
              "levels": ["1 star", "2 stars", "3 stars", "4 stars", "5 stars"],
              "temperature": 1.5 },
  "would_recommend": { "type": "noul",
              "instructions": "The reviewer would recommend the product." }
}
```

- `criteria` can be a list (the option keys) or an object mapping each key to
  a criterion. Criterion values can be structured JSON.
- `levels` can be a list (scored 1…n) or an object with numeric keys.
- `noul` takes optional `criteria: {"true": …, "false": …}`. The defaults
  restate the proposition, which the small model needs.
- `temperature` (default 1) is the calibration temperature. Values above 1
  flatten the distribution.

See [Examples/questions.json](Examples/questions.json) and
[Examples/reviews.jsonl](Examples/reviews.jsonl):

```bash
.build/release/jev-mac predict --questions Examples/questions.json --batch Examples/reviews.jsonl
```

## Output

```json
{
  "answers": {
    "department":   { "type": "choice", "decision": "billing", "probabilities": { … }, "confidence": 0.86, … },
    "urgency":      { "type": "score", "decision": 1, "expected": 1.28, "probabilities": { … }, … },
    "wants_refund": { "type": "noul", "decision": true, "probability": 0.95, … }
  },
  "model": "on-device",
  "language": { "code": "en", "supported": true },
  "usage": { "calls": 3, "input_tokens": 1236, "cached_input_tokens": 0, "output_tokens": 87 },
  "latency_ms": 2367.2
}
```

Probabilities are rounded to four decimals, as in laya.

## Snake demo

`jev-mac snake` (or `make snake`) plays snake in the terminal. At every step
the engine works out the facts for each move (is it legal, does it leave room
for the body, does it eat the food or get closer to it, is the food still
reachable) and describes them to the model in plain words:

```
Snake on a 16×12 board, length 4, heading RIGHT. Head at (5,4), food at (9,4), 4 steps away.
Moves:
- UP: safe, moves away from the food (5 steps)
- DOWN: safe, moves away from the food (5 steps)
- LEFT: not possible (the snake's own body)
- RIGHT: safe, gets closer to the food (3 steps)
The food can be reached after moving UP, DOWN, RIGHT.
```

The model answers three questions: `next_move` (choice), `safe_move` (noul;
the DEAD-END RISK bar shows 1 − P) and `food_reachable` (noul). The safety
shield executes the highest-probability move that is legal and leaves room
for the body. `--unassisted` turns the shield off, and `--lean` asks only
`next_move` (about 2.5× faster).

The words matter. The first version gave the model raw numbers per move
(`food_distance_after: 6`, `free_space_after: 188`, …). The model can't
compare numbers across moves, so it fell back on the first option, UP, and
circled a corner without ever reaching the food. Over the same 200-move game
(16×12 board, seed 7, `--lean`):

| player | food eaten | moved closer when that was safe | deaths |
|---|---|---|---|
| random safe move (`--policy random`) | 1 | 55% | 0 |
| model, raw numbers (first version) | 0 in 40 moves | 42% | 0 |
| greedy rule (`--policy greedy`) | 17 | 100% | 0 |
| model, plain verdicts | **18** | **100%** (194/194) | 0 |

`--policy random|greedy` runs these baselines without the model; `--trace`
prints every decision of a headless run. The live test suite checks that
`next_move` heads for the food whenever that is safe, not merely that it is
safe (a check the first version would have failed).

Controls: space to pause, ↑/↓ to change speed, r to reset, q to quit. The
terminal needs to be about 90×22 with true color. With all three questions a
move takes about 2.4 s; with `--lean`, about 1 s.

## Known limits

- **Private Cloud Compute.** It reports itself as available, but requests from
  an unsigned CLI binary are rejected (`ModelManagerError 1046`). It probably
  needs a signed app with the Foundation Models entitlement. `--model auto`
  uses PCC only when a call would not fit the on-device context window.
- **Language support.** jev-mac flags languages the on-device model doesn't
  support (for example Greek) with `"supported": false` and a warning, and
  answers for those states are unreliable.
- **Answer quality.** It is limited by the ~3B on-device model. Use
  `--head vote --samples 7` when calibration matters more than latency.

## Tests

There are 1,000 test cases in two layers (`make test-all` runs both). iCloud
Drive adds extended attributes that break code-signing the test bundle, so the
Makefile builds the tests in `/tmp/jev-mac-build`, outside the synced folder.

**Deterministic (577 cases, under a second, no model calls):**

```bash
make test
```

These cover the JSON parser (strict RFC 8259, malformed surrogates, nesting
limit, interoperability with `JSONSerialization`), question validation,
calibration math, prompt and schema building, the read-out layer (driven with
model-shaped `GeneratedContent`), the prefix cache (checked against a
reference LRU), every routing combination, language detection, the snake rules
(checked against an independent oracle), the safety shield, and the real `jev-mac`
binary's exit codes and messages. Random inputs come from fixed seeds, so every
failure is reproducible.

**Live (423 cases, about 8 minutes, on-device model):**

```bash
make test-live
```

- **306 labeled states** across every preset, plus language identification,
  reading comprehension and numbers in JSON states.
- **90 snake positions**, labeled from the engine's own move features.
- **27 end-to-end checks:** vote arithmetic, fused calls, batch order,
  determinism, calibration on the live distribution, cache hits, language
  flagging, and the CLI.

Every live prediction must satisfy the engine's guarantees: probabilities in
[0, 1] that sum to 1, the decision equal to the argmax, the expected score
within the rubric, and JSON output that agrees with the typed answer. A failure
is labeled `INVALID OUTPUT` (a broken guarantee), `ENGINE ERROR` (the call
failed) or `MODEL MISS` (valid output, wrong answer). When the suite finishes it
prints accuracy per category and per question type, the Brier score for `noul`,
and latency. It saves the full list of misses to `$TMPDIR/jev-mac-live-report.txt`.

### Latest live results (final engine)

| | answer-free weights (initial) | + answer first | + yes/no framing for noul, reworded snake question |
|---|---|---|---|
| labeled accuracy | 80.6% | 86.1% | **90.9%** (360/396) |
| choice / score / noul | 83.3% / 78.0% / 78.5% | 92.5% / 92.0% / 77.9% | 92.5% / 92.0% / 89.0% |
| noul Brier score | 0.202 | 0.208 | 0.099 |
| invalid outputs | 0 | 0 | 0 |
| guardrail-blocked calls | 3 | 7 | 7 |
| median latency per question | 732 ms | 937 ms | 939 ms |

All 27 end-to-end checks pass in every run. Switching to pooled sessions changed
no answer (the same 36 misses) and lowered the median to 916 ms per question.
A dedicated check confirms that a reused session gets its prefix from cache
while its input token count matches a fresh session's, so nothing from the
previous request leaks in. Known weaknesses in the final run:

- **Scams are under-flagged.** 6 of 8 scam or phishing emails get P(spam) = 0.
- **Guardrails block moderation inputs.** Apple's safety guardrails block 5 of the 20
  moderation-category inputs (harassment, self-harm, adult). That is exactly the content
  the preset exists to classify.
- **Wrong answers are often confident.** Many misses come back at P = 1.00.

These cases also guided the two prompt fixes, so the last column is somewhat
optimistic. The FizzBuzz benchmark below is independent of them.

## Benchmarks

`jev-mac bench --suite latency` and `jev-mac bench --suite fizzbuzz` reproduce the
shape of two suites from [Open-Jev's benchmarks](https://zefan-cai.github.io/open-jev/benchmarks/).
The exact workload texts, JevBench tasks, JF100 and the remaining control
suites are not public, so only these two can be reproduced. They are
reconstructions of the same shape, not the same inputs.

**Latency** (3 warmups, 20 timed requests, concurrency 1, prefix cache off as in
Open-Jev's protocol; P50 / P95 ms):

| workload | jev-mac on-device (this Mac) | Open-Jev 2B (H100) | Jev 1.13.0 (hosted) | GPT-5.6 Luna | GPT-6 Astra |
|---|---|---|---|---|---|
| customer service, 8 boolean questions | 5506 / 5696 | 85 / 134 | 295 / 330 | 918 / 1443 | 1938 / 2376 |
| 1,024 state tokens, 32 candidates | 6681 / 6770 | 1016 / 1370 | 301 / 361 | 690 / 788 | 1388 / 1741 |

The full matrix (`jev-mac bench --suite latency`) shows that the candidate count
drives latency, not the state size. Weights are written out one per option,
so 32 candidates means about 290 output tokens and around 6 s whatever the
state size. With 2 candidates, going from 128 to 1,024 state tokens costs only
0.8 s → 1.4 s. The customer-service workload is 8 separate model calls.

**FizzBuzz** (integers 1–100, 3 typed questions each):

| | jev-mac on-device | Jev 1.13.0 | GPT-5.6 Luna | GPT-6 Astra |
|---|---|---|---|---|
| correct | 172/300 (57.3%) | 299/300 | 300/300 | 300/300 |

Per question: divisible-by-3 75/100, divisible-by-5 57/100, FizzBuzz output
40/100. Two of the three are below the majority-class baseline (67%, 80% and
53% respectively). The on-device model cannot do this arithmetic reliably.

The other systems' numbers are Open-Jev's published figures (read
2026-09-23). They were measured on different hardware and inputs, so treat the
comparison as an order of magnitude, not a matched speed-up.

## License

MIT; see [LICENSE](LICENSE).
