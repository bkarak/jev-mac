import Foundation
@testable import JevMac

/// Snake positions labeled from the engine's own move features: which moves
/// are safe, whether any legal move leaves room, whether food is reachable.
enum LiveSnake {
    static let questions = try! SnakeGame.questions(lean: false)

    /// 20 ordinary mid-game positions and 10 trapped ones (legal moves exist,
    /// but none leaves room for the body). A food-seeking random policy grows
    /// the snake so it eventually traps itself. Deterministic per seed.
    static let positions: [SnakeGame] = {
        var normal: [SnakeGame] = [], trapped: [SnakeGame] = []
        var seed = 0
        while (normal.count < 20 || trapped.count < 10) && seed < 5_000 {
            seed += 1
            var g = Gen(seed)
            var game = SnakeGame(width: 8, height: 8, seed: UInt64(seed))
            let sampleAt = 20 + seed % 60
            for step in 0..<400 {
                let legal = game.allFeatures.filter(\.legal)
                if legal.isEmpty { break }
                let safe = legal.filter { game.admissible($0) }
                if safe.isEmpty {
                    if trapped.count < 10 { trapped.append(game) }
                    break
                }
                if step == sampleAt, normal.count < 20 { normal.append(game) }
                let move = g.chance(0.7) ? legal.min { $0.foodDistance < $1.foodDistance }! : g.pick(legal)
                game.step(move.direction)
            }
        }
        return normal + trapped
    }()

    static let cases: [LiveCase] = positions.enumerated().flatMap { i, game -> [LiveCase] in
        let legal = game.allFeatures.filter(\.legal)
        let safe = legal.filter { game.admissible($0) }
        let acceptable = (safe.isEmpty ? legal : safe).map(\.direction.rawValue)
        let id = "snake#\(i < 9 ? "0" : "")\(i + 1)"
        return [
            LiveCase(id: id + ".next_move", category: "snake.next_move", question: questions[0],
                     state: game.stateJSON, expect: .anyOf(acceptable)),
            LiveCase(id: id + ".safe_move", category: "snake.safe_move", question: questions[1],
                     state: game.stateJSON, expect: .truth(!safe.isEmpty)),
            LiveCase(id: id + ".food", category: "snake.food_reachable", question: questions[2],
                     state: game.stateJSON, expect: .truth(legal.contains { $0.foodReachable })),
        ]
    }
}
