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

    /// The state the model reads: board facts plus per-move features.
    public var stateJSON: JSON {
        let moves = allFeatures.map { f -> (String, JSON) in
            (f.direction.rawValue, .object([
                ("legal", .bool(f.legal)),
                ("eats_food", .bool(f.eatsFood)),
                ("free_space_after", .number(Double(f.freeSpace))),
                ("room_for_body", .bool(admissible(f))),
                ("food_distance_after", .number(Double(f.foodDistance))),
                ("food_reachable_after", .bool(f.foodReachable)),
            ]))
        }
        return .object([
            ("board", .string("\(width)x\(height), x grows right, y grows down")),
            ("head", .string("(\(head.x),\(head.y))")),
            ("heading", .string(heading.rawValue)),
            ("food", .string("(\(food.x),\(food.y))")),
            ("length", .number(Double(length))),
            ("moves", .object(moves)),
        ])
    }

    public static let questionsJSON = """
    {
      "next_move": {
        "type": "choice",
        "instructions": "Pick the snake's next move. Never pick a move whose legal is false. Among legal moves prefer those with room_for_body true, then eats_food true, then the smallest food_distance_after.",
        "criteria": {
          "UP": "move the head one cell up (y-1)",
          "DOWN": "move the head one cell down (y+1)",
          "LEFT": "move the head one cell left (x-1)",
          "RIGHT": "move the head one cell right (x+1)"
        }
      },
      "safe_move": {
        "type": "noul",
        "instructions": "At least one legal move has room_for_body true."
      },
      "food_reachable": {
        "type": "noul",
        "instructions": "At least one legal move has food_reachable_after true."
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
