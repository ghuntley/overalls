import Foundation

public enum MilaWatchRead: Equatable, Sendable {
    case hint, idle, closed, authorityLost, transportLost

    static func decode(_ data: Data) throws -> Self {
        struct Notice: Decodable { let version: UInt8; let event: String }
        guard data.count <= 8192 else { throw MilaSessionError.invalidInput }
        let notice = try JSONDecoder().decode(Notice.self, from: data)
        guard notice.version == 1 else { throw MilaSessionError.invalidInput }
        switch notice.event {
        case "heartbeat", "unknown": return .idle
        case "watching", "resync", "machine", "terminal_session", "thread", "session": return .hint
        default: throw MilaSessionError.invalidInput
        }
    }
}

struct MilaWatchFilters: Equatable, Sendable {
    let machines: [UUID]
    let threads: [UUID]
    /// @cc [owner:ghuntley,label:protocol;recovery] apple-watch-displayed-identities
    /// Grouping MUST retain up to 500 distinct machine IDs and 256 distinct
    /// thread IDs after deduplication, with at most 64 filters per subscription.
    static func groups(machines: [UUID], threads: [UUID]) -> [Self] {
        let machines = Array(Array(Set(machines)).sorted { $0.uuidString < $1.uuidString }.prefix(500))
        let threads = Array(Array(Set(threads)).sorted { $0.uuidString < $1.uuidString }.prefix(256))
        var groups: [Self] = []
        for start in stride(from: 0, to: machines.count, by: 64) { groups.append(Self(machines: Array(machines[start..<min(start + 64, machines.count)]), threads: [])) }
        for start in stride(from: 0, to: threads.count, by: 64) { groups.append(Self(machines: [], threads: Array(threads[start..<min(start + 64, threads.count)]))) }
        return groups.isEmpty ? [Self(machines: [], threads: [])] : groups
    }
}

/// @cc [owner:ghuntley,label:security;recovery] mila-apple-watch-generation
/// Watch notices are invalidation hints only. Each approved generation owns
/// bounded read-only subscriptions; a hint performs ordinary authenticated
/// reads, reconnect replaces only the subscription, and authority loss signs out.
/// A rebind cancels old subscriptions and late notices cannot publish or mutate.
/// Transient capability contention is retried without discarding the subscription.
@MainActor public final class MilaWatchController {
    private var adapter: (any MilaFFIAdapter)?
    private var generation: UInt64 = 0
    private var filters: [MilaWatchFilters] = []
    private var tasks: [Task<Void, Never>] = []
    public var onHint: (@MainActor () async -> Void)?
    public var onAuthorityLost: (@MainActor () -> Void)?

    public init() {}
    public func bind(_ adapter: (any MilaFFIAdapter)?) {
        generation &+= 1
        tasks.forEach { $0.cancel() }; tasks = []
        self.adapter = adapter
        filters = []
        if adapter != nil { update(machines: [], threads: []) }
    }

    public func update(machines: [UUID], threads: [UUID]) {
        guard let adapter else { return }
        let fresh = MilaWatchFilters.groups(machines: machines, threads: threads)
        guard fresh != filters else { return }
        generation &+= 1
        let requested = generation
        tasks.forEach { $0.cancel() }; tasks = []
        filters = fresh
        tasks = fresh.map { filter in Task { [weak self] in
            var handle: UInt64 = 0
            defer { if handle != 0 { adapter.watchClose(handle) } }
            do {
                while !Task.isCancelled, self?.generation == requested {
                    do { handle = try await adapter.watchOpen(machines: filter.machines, threads: filter.threads); break }
                    catch { try await Task.sleep(for: .seconds(3)) }
                }
                guard handle != 0 else { return }
                while !Task.isCancelled {
                    let read: MilaWatchRead
                    do {
                        read = try await adapter.watchRead(handle)
                    } catch let error as MilaSessionError where error == .transport(-13) {
                        // The Rust capability registry uses Busy for a transient
                        // child-lock collision (for example while a reconnect or
                        // close is fencing the same subscription). It is not a
                        // transport failure and must not terminate this watcher.
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    guard self?.generation == requested, !Task.isCancelled else { return }
                    switch read {
                    case .hint: await self?.onHint?()
                    case .idle: break
                    case .authorityLost: self?.onAuthorityLost?(); return
                    case .closed, .transportLost:
                        try await Task.sleep(for: .seconds(1))
                        while !Task.isCancelled {
                            do { handle = try await adapter.watchReconnect(handle); break }
                            catch { try await Task.sleep(for: .seconds(3)) }
                        }
                    }
                }
            } catch { /* No mutation or fabricated state is published after a watch refusal. */ }
        } }
    }
}
