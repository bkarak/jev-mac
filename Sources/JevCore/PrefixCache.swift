import Foundation
import FoundationModels

/// LRU cache of compiled question prefixes, each with a pool of sessions.
///
/// laya caches the encoder's hidden states for the question prefix. Apple's
/// model keeps that state inside a `LanguageModelSession`, so each entry keeps
/// the compiled prefix (instructions + generation schema) and a pool of idle
/// sessions. A session serves one request at a time. After a successful
/// request its transcript is reset to the instructions and it goes back into
/// the pool, so the next request finds the instruction prefix already
/// processed (reported as cached input tokens). A session whose request failed
/// is dropped rather than reused.
public actor PrefixCache {
    struct Key: Hashable, Sendable {
        let route: ModelRoute
        let head: DecisionHead
        let fused: Bool
        let questions: [Question]
    }

    /// A session lent out for exactly one request.
    public struct Lease: Sendable {
        let key: Key
        public let session: LanguageModelSession
        /// The instructions-only transcript the session is reset to on return.
        let base: Transcript
        /// The session served an earlier request, so its prefix is already processed.
        public let reused: Bool
    }

    final class Entry {
        let prepared: PreparedQuestion
        var idle: [(session: LanguageModelSession, base: Transcript)] = []
        init(_ p: PreparedQuestion) { prepared = p }
    }

    public let capacity: Int
    /// Idle sessions kept per prefix; enough for the concurrency one prefix
    /// sees (vote samples × batch size), beyond which returns are dropped.
    public let maxIdlePerEntry: Int
    /// Prewarm each newly created session with the start of the prompt.
    public let prewarm: Bool
    public private(set) var hits = 0
    public private(set) var misses = 0
    public private(set) var reuses = 0
    public private(set) var created = 0

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []   // least recently used first
    private let router: Router

    public init(router: Router, capacity: Int = 64, maxIdlePerEntry: Int = 16, prewarm: Bool = false) {
        self.router = router
        self.capacity = max(1, capacity)
        self.maxIdlePerEntry = max(0, maxIdlePerEntry)
        self.prewarm = prewarm
    }

    /// Compiled prefix and a session for one question.
    func checkout(_ q: Question, head: DecisionHead, route: ModelRoute) throws -> (PreparedQuestion, Lease, hit: Bool) {
        try checkout(Key(route: route, head: head, fused: false, questions: [q])) { try Heads.prepare(q, head: head) }
    }

    /// Compiled fused prefix and a session for a whole question set.
    func checkoutFused(_ qs: [Question], route: ModelRoute) throws -> (PreparedQuestion, Lease, hit: Bool) {
        try checkout(Key(route: route, head: .distribution, fused: true, questions: qs)) { try Heads.prepareFused(qs) }
    }

    private func checkout(_ key: Key, build: () throws -> PreparedQuestion) throws -> (PreparedQuestion, Lease, hit: Bool) {
        let entry: Entry
        let hit: Bool
        if let e = entries[key] {
            entry = e
            hit = true
            hits += 1
            order.removeAll { $0 == key }
            order.append(key)
        } else {
            entry = Entry(try build())
            hit = false
            misses += 1
            entries[key] = entry
            order.append(key)
            if order.count > capacity { entries[order.removeFirst()] = nil }
        }
        if let idle = entry.idle.popLast() {
            reuses += 1
            return (entry.prepared, Lease(key: key, session: idle.session, base: idle.base, reused: true), hit)
        }
        let session = router.session(for: key.route, instructions: entry.prepared.instructions)
        if prewarm { session.prewarm(promptPrefix: Prompt("STATE:\n")) }
        created += 1
        return (entry.prepared, Lease(key: key, session: session, base: session.transcript, reused: false), hit)
    }

    /// Takes a session back after a successful request: its transcript returns
    /// to the instructions and it waits for the next request with that prefix.
    /// Sessions of evicted prefixes, or beyond the pool limit, are dropped.
    func checkin(_ lease: Lease) {
        guard let entry = entries[lease.key], entry.idle.count < maxIdlePerEntry, !lease.session.isResponding else { return }
        if lease.session.transcript != lease.base { lease.session.transcript = lease.base }
        entry.idle.append((lease.session, lease.base))
    }

    public var count: Int { entries.count }
    public var idleSessions: Int { entries.values.reduce(0) { $0 + $1.idle.count } }
}
