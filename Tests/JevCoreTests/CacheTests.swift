import FoundationModels
import Testing
@testable import JevCore

@Suite("Prefix cache")
struct CacheTests {
    static let router = Router()
    static let pool: [Question] = (0..<6).map {
        Question(name: "q\($0)", type: .noul, instructions: "P\($0)",
                 options: [Option(key: "true", criterion: "t"), Option(key: "false", criterion: "f")])
    }

    static let lruSeeds = 0..<5

    /// Replays a random access pattern against a reference LRU.
    @Test("behaves like an LRU", arguments: lruSeeds)
    func lru(seed: Int) async throws {
        var g = Gen(seed)
        let capacity = g.int(1...5)
        let cache = PrefixCache(router: Self.router, capacity: capacity)
        var reference: [Int] = []   // least recently used first
        var hits = 0, misses = 0
        for _ in 0..<40 {
            let k = g.int(0...5)
            let expected = reference.contains(k)
            let (prepared, _, hit) = try await cache.checkout(Self.pool[k], head: .distribution, route: .onDevice)
            #expect(hit == expected)
            #expect(prepared.question == Self.pool[k])
            if expected { hits += 1; reference.removeAll { $0 == k } } else { misses += 1 }
            reference.append(k)
            if reference.count > capacity { reference.removeFirst() }
        }
        #expect(await cache.hits == hits)
        #expect(await cache.misses == misses)
        #expect(await cache.count == reference.count)
    }

    @Test func keysSeparateHeadsRoutesAndFusion() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 10)
        let q = Self.pool[0]
        #expect(try await cache.checkout(q, head: .distribution, route: .onDevice).hit == false)
        #expect(try await cache.checkout(q, head: .distribution, route: .onDevice).hit == true)
        #expect(try await cache.checkout(q, head: .vote, route: .onDevice).hit == false)
        #expect(try await cache.checkout(q, head: .distribution, route: .tagging).hit == false)
        #expect(try await cache.checkoutFused([q], route: .onDevice).hit == false)
        #expect(try await cache.checkoutFused([q], route: .onDevice).hit == true)
        #expect(await cache.count == 4)
    }

    @Test func calibrationTemperatureIsPartOfTheKey() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 10)
        let a = Self.pool[1]
        let b = Question(name: a.name, type: a.type, instructions: a.instructions, options: a.options, temperature: 2)
        #expect(try await cache.checkout(a, head: .distribution, route: .onDevice).hit == false)
        #expect(try await cache.checkout(b, head: .distribution, route: .onDevice).hit == false)
        #expect(await cache.count == 2)
    }

    @Test func checkoutReturnsTheCompiledPrefix() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 0)
        #expect(await cache.capacity == 1, "capacity is clamped to at least one entry")
        let (prepared, _, _) = try await cache.checkout(Self.pool[2], head: .vote, route: .onDevice)
        #expect(prepared.instructions == PromptBuilder.buildPrefix(Self.pool[2], head: .vote))
        #expect(prepared.head == .vote)
    }

    // MARK: Session pool

    @Test func returnedSessionsAreReusedForTheSamePrefix() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 4)
        let (_, first, _) = try await cache.checkout(Self.pool[0], head: .distribution, route: .onDevice)
        #expect(!first.reused)
        await cache.checkin(first)
        let (_, second, _) = try await cache.checkout(Self.pool[0], head: .distribution, route: .onDevice)
        #expect(second.reused && second.session === first.session)
        #expect(await cache.idleSessions == 0, "a lent session is not in the pool")
        #expect(await cache.reuses == 1)
        #expect(await cache.created == 1)
    }

    @Test func concurrentRequestsGetTheirOwnSessions() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 4)
        let (_, a, _) = try await cache.checkout(Self.pool[1], head: .vote, route: .onDevice)
        let (_, b, _) = try await cache.checkout(Self.pool[1], head: .vote, route: .onDevice)
        #expect(a.session !== b.session, "a session never serves two requests at once")
        await cache.checkin(a)
        await cache.checkin(b)
        #expect(await cache.idleSessions == 2)
        let (_, c, _) = try await cache.checkout(Self.pool[2], head: .vote, route: .onDevice)
        #expect(!c.reused, "sessions are never shared across prefixes")
    }

    @Test func returnedSessionsAreResetToTheirInstructions() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 4)
        let (_, lease, _) = try await cache.checkout(Self.pool[3], head: .distribution, route: .onDevice)
        let base = lease.session.transcript
        #expect(base.count == 1, "a new session holds only its instructions")
        lease.session.transcript = Transcript(entries: [])   // stands in for a request's prompt and response
        await cache.checkin(lease)
        let (_, again, _) = try await cache.checkout(Self.pool[3], head: .distribution, route: .onDevice)
        #expect(again.reused && again.session.transcript == base)
    }

    @Test func thePoolIsBounded() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 4, maxIdlePerEntry: 1)
        let (_, a, _) = try await cache.checkout(Self.pool[4], head: .distribution, route: .onDevice)
        let (_, b, _) = try await cache.checkout(Self.pool[4], head: .distribution, route: .onDevice)
        await cache.checkin(a)
        await cache.checkin(b)
        #expect(await cache.idleSessions == 1)
    }

    @Test func evictedPrefixesDropTheirSessions() async throws {
        let cache = PrefixCache(router: Self.router, capacity: 1)
        let (_, old, _) = try await cache.checkout(Self.pool[0], head: .distribution, route: .onDevice)
        _ = try await cache.checkout(Self.pool[5], head: .distribution, route: .onDevice)   // evicts pool[0]
        await cache.checkin(old)
        #expect(await cache.idleSessions == 0)
        #expect(await cache.count == 1)
    }
}
