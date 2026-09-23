import Testing
@testable import JevCore

@Suite("Snake engine")
struct SnakeTests {
    /// An independent re-implementation of the move rules (grid + BFS rather
    /// than sets + DFS), used as an oracle for `features`.
    static func oracle(_ g: SnakeGame, _ d: Direction) -> (legal: Bool, eats: Bool, free: Int, reach: Bool) {
        let step: (Int, Int) = switch d { case .UP: (0, -1); case .DOWN: (0, 1); case .LEFT: (-1, 0); case .RIGHT: (1, 0) }
        let nx = g.head.x + step.0, ny = g.head.y + step.1
        let eats = nx == g.food.x && ny == g.food.y
        let after = eats ? g.body : Array(g.body.dropLast())
        let reverse = g.body.count > 1 && g.body[1] == Point(nx, ny)
        guard nx >= 0, ny >= 0, nx < g.width, ny < g.height, !reverse, !after.contains(Point(nx, ny)) else {
            return (false, false, 0, false)
        }
        var blocked = Array(repeating: Array(repeating: false, count: g.width), count: g.height)
        for p in after { blocked[p.y][p.x] = true }
        blocked[ny][nx] = true
        var queue = [(nx, ny)], index = 0, free = 0, reach = eats
        while index < queue.count {
            let (x, y) = queue[index]
            index += 1
            for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                let ax = x + dx, ay = y + dy
                guard ax >= 0, ay >= 0, ax < g.width, ay < g.height, !blocked[ay][ax] else { continue }
                blocked[ay][ax] = true
                free += 1
                if ax == g.food.x && ay == g.food.y { reach = true }
                queue.append((ax, ay))
            }
        }
        return (true, eats, free, reach)
    }

    static let playSeeds = 0..<12

    @Test("random play keeps every invariant", arguments: playSeeds)
    func randomPlay(seed: Int) {
        var g = Gen(seed)
        let (w, h) = (g.int(6...14), g.int(6...12))
        var game = SnakeGame(width: w, height: h, seed: UInt64(seed))
        var eaten = 0, restarts = 0
        var problems: [String] = []
        for step in 0..<250 {
            let body = game.body
            if Set(body).count != body.count { problems.append("\(step): body overlaps itself") }
            if !body.allSatisfy({ game.inBounds($0) }) { problems.append("\(step): body out of bounds") }
            for (a, b) in zip(body, body.dropFirst()) where abs(a.x - b.x) + abs(a.y - b.y) != 1 {
                problems.append("\(step): body not contiguous")
            }
            if body.contains(game.food) { problems.append("\(step): food on the body") }
            if game.length != 3 + eaten { problems.append("\(step): length \(game.length) after eating \(eaten)") }
            if body[1] != Point(game.head.x - game.heading.dx, game.head.y - game.heading.dy) {
                problems.append("\(step): heading disagrees with the body")
            }
            let legal = game.allFeatures.filter(\.legal).map(\.direction)
            let move = !legal.isEmpty && g.chance(0.95) ? g.pick(legal) : g.pick(Direction.allCases)
            let shouldDie = !legal.contains(move)
            let r = game.step(move)
            if r.died != shouldDie { problems.append("\(step): died=\(r.died) for a move with legal=\(!shouldDie)") }
            if r.ate { eaten += 1 }
            if r.died {
                if game.alive { problems.append("\(step): still alive after dying") }
                restarts += 1
                game = SnakeGame(width: w, height: h, seed: UInt64(seed * 1000 + restarts))
                eaten = 0
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(5))")
    }

    static let oracleSeeds = 0..<12

    @Test("move features match an independent oracle", arguments: oracleSeeds)
    func featuresMatchOracle(seed: Int) {
        var g = Gen(seed)
        var problems: [String] = []
        for _ in 0..<10 {
            let (w, h, steps) = (g.int(6...12), g.int(6...10), g.int(0...120))
            let game = g.snakePosition(width: w, height: h, steps: steps)
            for d in Direction.allCases {
                let f = game.features(d), o = Self.oracle(game, d)
                if f.legal != o.legal || (f.legal && (f.eatsFood != o.eats || f.freeSpace != o.free || f.foodReachable != o.reach)) {
                    problems.append("\(d) at \(game.head): engine \(f) oracle \(o)")
                }
                let next = Point(game.head.x + d.dx, game.head.y + d.dy)
                if f.foodDistance != abs(next.x - game.food.x) + abs(next.y - game.food.y) { problems.append("\(d): food distance") }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(3))")
    }

    // MARK: Hand-built positions

    @Test func hittingAWallKills() {
        var game = SnakeGame(width: 6, height: 6, body: [Point(5, 2), Point(4, 2), Point(3, 2)], heading: .RIGHT, food: Point(0, 0))
        #expect(!game.features(.RIGHT).legal)
        #expect(game.step(.RIGHT).died && !game.alive)
    }

    @Test func hittingTheBodyKills() {
        var game = SnakeGame(width: 6, height: 6,
                             body: [Point(2, 2), Point(2, 3), Point(3, 3), Point(3, 2), Point(3, 1)], heading: .UP, food: Point(0, 0))
        #expect(!game.features(.RIGHT).legal)
        #expect(game.step(.RIGHT).died)
    }

    @Test func chasingTheTailIsLegal() {
        var game = SnakeGame(width: 6, height: 6,
                             body: [Point(2, 2), Point(2, 3), Point(3, 3), Point(3, 2)], heading: .UP, food: Point(0, 0))
        #expect(game.features(.RIGHT).legal, "the tail moves out of the way")
        let r = game.step(.RIGHT)
        #expect(!r.died && game.head == Point(3, 2) && game.length == 4)
    }

    @Test func eatingGrowsTheSnakeAndMovesTheFood() {
        var game = SnakeGame(width: 6, height: 6, body: [Point(2, 2), Point(1, 2), Point(0, 2)], heading: .RIGHT, food: Point(3, 2))
        let r = game.step(.RIGHT)
        #expect(r.ate && !r.died && game.length == 4)
        #expect(!game.body.contains(game.food) && game.inBounds(game.food))
    }

    @Test func reversingIsIllegal() {
        let game = SnakeGame(width: 8, height: 8, seed: 3)
        #expect(!game.features(.LEFT).legal)
        #expect(game.features(.RIGHT).legal && game.features(.UP).legal && game.features(.DOWN).legal)
    }

    @Test func openBoardCountsEveryFreeCell() {
        let game = SnakeGame(width: 6, height: 6, body: [Point(2, 0), Point(1, 0), Point(0, 0)], heading: .RIGHT, food: Point(5, 5))
        let f = game.features(.RIGHT)
        #expect(f.legal && f.freeSpace == 33 && f.foodReachable && game.admissible(f))
    }

    /// Head sealed in a 12-cell strip by its own body: legal moves exist but
    /// none leaves room for a 12-long snake, and the food is out of reach.
    static let pocket = SnakeGame(width: 6, height: 6, body: [
        Point(1, 5), Point(2, 5), Point(2, 4), Point(2, 3), Point(2, 2), Point(2, 1),
        Point(2, 0), Point(3, 0), Point(4, 0), Point(5, 0), Point(5, 1), Point(5, 2),
    ], heading: .LEFT, food: Point(4, 4))

    @Test func sealedPocketIsADeadEnd() {
        let game = Self.pocket
        let legal = game.allFeatures.filter(\.legal)
        #expect(legal.map(\.direction) == [.UP, .LEFT])
        #expect(legal.allSatisfy { $0.freeSpace == 10 && !$0.foodReachable && !game.admissible($0) })
    }

    @Test func stateJSONMirrorsTheFeatures() throws {
        let game = Self.pocket
        let j = game.stateJSON
        #expect(j["head"]?.stringValue == "(1,5)" && j["heading"]?.stringValue == "LEFT" && j["length"]?.doubleValue == 12)
        for f in game.allFeatures {
            let m = try #require(j["moves"]?[f.direction.rawValue])
            #expect(m["legal"] == .bool(f.legal))
            #expect(m["eats_food"] == .bool(f.eatsFood))
            #expect(m["free_space_after"]?.doubleValue == Double(f.freeSpace))
            #expect(m["room_for_body"] == .bool(game.admissible(f)))
            #expect(m["food_distance_after"]?.doubleValue == Double(f.foodDistance))
            #expect(m["food_reachable_after"] == .bool(f.foodReachable))
        }
    }

    static let sizes: [(Int, Int)] = [(6, 6), (10, 8), (20, 14), (40, 30)]

    @Test("new games start in a valid position", arguments: sizes)
    func newGame(width: Int, height: Int) {
        let game = SnakeGame(width: width, height: height, seed: 11)
        #expect(game.head == Point(4, height / 2) && game.heading == .RIGHT && game.length == 3 && game.score == 0)
        #expect(game.inBounds(game.food) && !game.body.contains(game.food))
        #expect(game.alive && game.moves == 0)
    }

    @Test func seedsAreReproducible() {
        var a = SplitMix64(seed: 99), b = SplitMix64(seed: 99), c = SplitMix64(seed: 100)
        let xs = (0..<8).map { _ in a.next() }
        #expect(xs == (0..<8).map { _ in b.next() })
        #expect(xs != (0..<8).map { _ in c.next() })
        var g1 = SnakeGame(width: 10, height: 8, seed: 5), g2 = SnakeGame(width: 10, height: 8, seed: 5)
        for d in [Direction.RIGHT, .DOWN, .DOWN, .LEFT] { g1.step(d); g2.step(d) }
        #expect(g1.body == g2.body && g1.food == g2.food)
    }

    @Test func aDeadSnakeStaysDead() {
        var game = SnakeGame(width: 6, height: 6, body: [Point(5, 2), Point(4, 2), Point(3, 2)], heading: .RIGHT, food: Point(0, 0))
        game.step(.RIGHT)
        let body = game.body
        #expect(game.step(.UP).died && game.body == body)
    }

    static let shieldSeeds = 0..<12

    @Test("the shield executes the best safe move", arguments: shieldSeeds)
    func shield(seed: Int) {
        var g = Gen(seed)
        var problems: [String] = []
        for _ in 0..<10 {
            let (w, h, steps) = (g.int(6...10), g.int(6...10), g.int(0...150))
            let game = g.snakePosition(width: w, height: h, steps: steps)
            let weights = g.shuffled([0.4, 0.3, 0.2, 0.1])
            let probs = Dictionary(uniqueKeysWithValues: zip(Direction.allCases, weights))
            let ranked = Direction.allCases.sorted { probs[$0]! > probs[$1]! }
            let feats = Dictionary(uniqueKeysWithValues: game.allFeatures.map { ($0.direction, $0) })
            let expected = ranked.first { game.admissible(feats[$0]!) } ?? ranked.first { feats[$0]!.legal } ?? ranked[0]

            let (move, intervened) = SafetyShield.choose(game, probabilities: probs, assisted: true)
            if move != expected { problems.append("assisted picked \(move), expected \(expected)") }
            if intervened != (move != ranked[0]) { problems.append("intervention flag wrong") }

            let (raw, flagged) = SafetyShield.choose(game, probabilities: probs, assisted: false)
            if raw != ranked[0] || flagged { problems.append("unassisted must execute the top choice") }
        }
        #expect(problems.isEmpty, "\(problems.prefix(3))")
    }

    @Test func shieldInADeadEndTakesTheBestLegalMove() {
        let probs: [Direction: Double] = [.RIGHT: 0.6, .LEFT: 0.2, .UP: 0.1, .DOWN: 0.1]
        let (move, intervened) = SafetyShield.choose(Self.pocket, probabilities: probs, assisted: true)
        #expect(move == .LEFT && intervened)
    }

    @Test func snakeQuestionsParse() throws {
        #expect(try SnakeGame.questions(lean: false).map(\.name) == ["next_move", "safe_move", "food_reachable"])
        #expect(try SnakeGame.questions(lean: true).map(\.name) == ["next_move"])
    }
}
