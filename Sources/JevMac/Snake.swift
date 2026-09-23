import Foundation

public struct Point: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    func moved(_ d: Direction) -> Point { Point(x + d.dx, y + d.dy) }
}

public enum Direction: String, CaseIterable, Sendable {
    case UP, DOWN, LEFT, RIGHT
    var dx: Int { self == .LEFT ? -1 : self == .RIGHT ? 1 : 0 }
    var dy: Int { self == .UP ? -1 : self == .DOWN ? 1 : 0 }
    var opposite: Direction {
        switch self { case .UP: .DOWN; case .DOWN: .UP; case .LEFT: .RIGHT; case .RIGHT: .LEFT }
    }
}

/// Deterministic PRNG so runs are reproducible per seed.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Facts about one candidate move, computed by the engine and handed to the model.
public struct MoveFeatures: Sendable {
    public let direction: Direction
    /// The move does not hit a wall or the body.
    public let legal: Bool
    public let eatsFood: Bool
    /// Empty cells reachable from the new head position.
    public let freeSpace: Int
    /// Manhattan distance from the new head to the food.
    public let foodDistance: Int
    /// The food is reachable from the new head through empty cells.
    public let foodReachable: Bool
}

public struct SnakeGame: Sendable {
    public let width: Int
    public let height: Int
    public private(set) var body: [Point]      // head first
    public private(set) var heading: Direction = .RIGHT
    public private(set) var food: Point
    public private(set) var alive = true
    public private(set) var moves = 0
    var rng: SplitMix64

    public var head: Point { body[0] }
    public var length: Int { body.count }
    public var score: Int { body.count - 3 }

    public init(width: Int = 20, height: Int = 14, seed: UInt64 = 1) {
        self.width = width
        self.height = height
        rng = SplitMix64(seed: seed)
        let cy = height / 2
        body = [Point(4, cy), Point(3, cy), Point(2, cy)]
        food = Point(0, 0)
        food = spawnFood()
    }

    /// Restores a position (head first), e.g. to replay or test it.
    public init(width: Int, height: Int, body: [Point], heading: Direction, food: Point, seed: UInt64 = 1) {
        precondition(!body.isEmpty, "a snake needs at least a head")
        self.width = width
        self.height = height
        self.body = body
        self.heading = heading
        self.food = food
        rng = SplitMix64(seed: seed)
    }

    func inBounds(_ p: Point) -> Bool { p.x >= 0 && p.y >= 0 && p.x < width && p.y < height }

    mutating func spawnFood() -> Point {
        let occupied = Set(body)
        let free = (0..<height).flatMap { y in (0..<width).map { Point($0, y) } }.filter { !occupied.contains($0) }
        return free.randomElement(using: &rng) ?? head
    }

    /// Body cells that block a move (the tail moves away unless the snake eats).
    func blocked(eating: Bool) -> Set<Point> {
        Set(eating ? body : Array(body.dropLast()))
    }

    public func features(_ d: Direction) -> MoveFeatures {
        let next = head.moved(d)
        let eats = next == food
        let legal = inBounds(next) && !blocked(eating: eats).contains(next) && !(length > 1 && d == heading.opposite)
        guard legal else {
            return MoveFeatures(direction: d, legal: false, eatsFood: false, freeSpace: 0,
                                foodDistance: abs(next.x - food.x) + abs(next.y - food.y), foodReachable: false)
        }
        // Simulate the body after the move, then flood-fill from the new head.
        var newBody = [next] + body
        if !eats { newBody.removeLast() }
        let walls = Set(newBody.dropFirst())
        var seen: Set<Point> = [next]
        var queue = [next]
        var foodSeen = eats
        while let p = queue.popLast() {
            for dir in Direction.allCases {
                let q = p.moved(dir)
                guard inBounds(q), !walls.contains(q), !seen.contains(q) else { continue }
                seen.insert(q)
                if q == food { foodSeen = true }
                queue.append(q)
            }
        }
        return MoveFeatures(direction: d, legal: true, eatsFood: eats, freeSpace: seen.count - 1,
                            foodDistance: abs(next.x - food.x) + abs(next.y - food.y), foodReachable: foodSeen)
    }

    public var allFeatures: [MoveFeatures] { Direction.allCases.map(features) }

    /// Legal and leaves at least as much room as the snake is long.
    public func admissible(_ f: MoveFeatures) -> Bool { f.legal && f.freeSpace >= length }

    @discardableResult
    public mutating func step(_ d: Direction) -> (ate: Bool, died: Bool) {
        guard alive else { return (false, true) }
        let f = features(d)
        moves += 1
        guard f.legal else { alive = false; return (false, true) }
        heading = d
        body.insert(head.moved(d), at: 0)
        if f.eatsFood {
            food = spawnFood()
            return (true, false)
        }
        body.removeLast()
        return (false, false)
    }

    /// The state the model reads: the board in one line, then one line per
    /// move with plain verdicts. The on-device model cannot compare numbers
    /// across moves reliably (given raw distances it favoured the first move,
    /// UP, and circled a corner), so the engine states the comparisons in words:
    /// "safe", "gets closer to the food". The model still makes the choice.
    public var stateText: String {
        let distance = abs(head.x - food.x) + abs(head.y - food.y)
        var lines = [
            "Snake on a \(width)×\(height) board, length \(length), heading \(heading.rawValue). "
                + "Head at (\(head.x),\(head.y)), food at (\(food.x),\(food.y)), \(distance) steps away.",
            "Moves:",
        ]
        for f in allFeatures {
            let verdict: String
            if !f.legal {
                verdict = "not possible (" + (inBounds(head.moved(f.direction)) ? "the snake's own body" : "a wall") + ")"
            } else {
                let safety = admissible(f) ? "safe" : "risky: leaves too little room for the body"
                let food = f.eatsFood ? "eats the food"
                    : f.foodDistance < distance ? "gets closer to the food (\(f.foodDistance) steps)"
                    : "moves away from the food (\(f.foodDistance) steps)"
                verdict = safety + ", " + food
            }
            lines.append("- \(f.direction.rawValue): \(verdict)")
        }
        let reachable = allFeatures.filter { $0.legal && $0.foodReachable }.map(\.direction.rawValue)
        lines.append(reachable.isEmpty ? "The food cannot be reached from here."
                                       : "The food can be reached after moving \(reachable.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    /// The moves a good player would pick: a safe move that eats the food, else
    /// a safe move that gets closer, else any safe move, else any legal move.
    public var goodMoves: [Direction] {
        let distance = abs(head.x - food.x) + abs(head.y - food.y)
        let feats = allFeatures
        let safe = feats.filter { admissible($0) }
        for tier in [safe.filter(\.eatsFood), safe.filter { $0.foodDistance < distance }, safe, feats.filter(\.legal)]
            where !tier.isEmpty { return tier.map(\.direction) }
        return []
    }

    public static let questionsJSON = """
    {
      "next_move": {
        "type": "choice",
        "instructions": "Pick the snake's next move. Choose only a move marked safe. Among the safe moves, prefer one that eats the food, then one that gets closer to the food.",
        "criteria": {
          "UP": "move the head one cell up",
          "DOWN": "move the head one cell down",
          "LEFT": "move the head one cell left",
          "RIGHT": "move the head one cell right"
        }
      },
      "safe_move": {
        "type": "noul",
        "instructions": "At least one move is marked safe."
      },
      "food_reachable": {
        "type": "noul",
        "instructions": "The food can still be reached."
      }
    }
    """

    public static func questions(lean: Bool) throws -> [Question] {
        let all = try QuestionSet.parse(text: questionsJSON)
        return lean ? all.filter { $0.name == "next_move" } : all
    }
}

/// Picks the executed move from the model's distribution.
public enum SafetyShield {
    /// Returns the move and whether the shield overrode the model's top choice.
    public static func choose(_ game: SnakeGame, probabilities: [Direction: Double], assisted: Bool) -> (Direction, intervened: Bool) {
        let ranked = Direction.allCases.sorted { probabilities[$0, default: 0] > probabilities[$1, default: 0] }
        let top = ranked[0]
        guard assisted else { return (top, false) }
        let feats = Dictionary(uniqueKeysWithValues: game.allFeatures.map { ($0.direction, $0) })
        if let pick = ranked.first(where: { game.admissible(feats[$0]!) }) ?? ranked.first(where: { feats[$0]!.legal }) {
            return (pick, pick != top)
        }
        return (top, false)
    }
}
