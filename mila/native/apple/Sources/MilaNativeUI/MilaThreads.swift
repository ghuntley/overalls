import Foundation
import Combine

/// One row of `thread ls --json` (`result.items[]`). Content stays server-side;
/// rows carry identity, title, state and unread count only.
public struct MilaThreadRow: Decodable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String?
    public let status: String
    public let unread: Int

    enum CodingKeys: String, CodingKey { case id, title, status, unread }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        status = try values.decode(String.self, forKey: .status)
        unread = try values.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        guard (title?.utf8.count ?? 0) <= 512, status.utf8.count <= 64, (0...1_000_000).contains(unread),
              !(title ?? "").unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !status.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw MilaFFIError.invalidRoute
        }
    }
}

struct MilaThreadPage: Decodable {
    let items: [MilaThreadRow]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" }
}

/// The controls of `thread show --json`: the open question and latest plan
/// identities needed to answer or decide, never their content.
public struct MilaThreadDetail: Decodable, Equatable, Sendable {
    public struct Reference: Decodable, Equatable, Sendable { public let id: UUID }
    public struct Plan: Decodable, Equatable, Sendable { public let id: UUID; public let implemented: Bool? }
    public let id: UUID
    public let title: String?
    public let status: String
    public let busy: Bool?
    public let pendingQuestion: Reference?
    public let latestPlan: Plan?
    enum CodingKeys: String, CodingKey {
        case id, title, status, busy
        case pendingQuestion = "pending_question"
        case latestPlan = "latest_plan"
    }
}

public enum MilaThreadsState: Equatable, Sendable { case signedOut, idle, loading, loaded, failed }

public enum MilaThreadMutationState: Equatable, Sendable {
    case idle
    case submitting(UUID)
    case applied(UUID)
    case failed(UUID?)
}

/// @cc [owner:ghuntley,label:security] mila-apple-thread-session-binding
/// Thread reads and mutations run only on the bound authenticated adapter.
/// Rebinding (sign-in, reconnect, sign-out) clears rows and detail and fences
/// late results; malformed actions and reused request IDs fail before the
/// bridge, and each mutation is submitted at most once.
@MainActor public final class MilaThreadsController: ObservableObject {
    public static let maximumRows = 256
    @Published public private(set) var state: MilaThreadsState = .signedOut
    @Published public private(set) var threads: [MilaThreadRow] = []
    @Published public private(set) var detail: MilaThreadDetail?
    @Published public private(set) var mutation: MilaThreadMutationState = .idle
    private var adapter: (any MilaFFIAdapter)?
    private var token: UInt64 = 0
    private var usedRequestIDs = Set<UUID>()

    public init() {}

    public func bind(_ adapter: (any MilaFFIAdapter)?) {
        token &+= 1
        self.adapter = adapter
        threads = []
        detail = nil
        mutation = .idle
        state = adapter == nil ? .signedOut : .idle
    }

    public func list() async {
        guard let adapter else { state = .signedOut; return }
        let requested = token
        state = .loading
        do {
            let data = try await adapter.threadAction(thread: nil, command: MilaThreadAction.list.command, secondary: nil, input: nil, requestID: nil)
            let page = try MilaPorscheEnvelope<MilaThreadPage>.decode(data)
            guard requested == token else { return }
            threads = Array(page.items.prefix(Self.maximumRows))
            state = .loaded
        } catch {
            guard requested == token else { return }
            state = .failed
        }
    }

    public func show(_ thread: UUID) async {
        guard let adapter else { return }
        let requested = token
        do {
            let data = try await adapter.threadAction(thread: thread, command: MilaThreadAction.show(thread: thread).command, secondary: nil, input: nil, requestID: nil)
            let value = try MilaPorscheEnvelope<MilaThreadDetail>.decode(data)
            guard requested == token else { return }
            detail = value.id == thread ? value : nil
            if value.id != thread { state = .failed }
        } catch {
            guard requested == token else { return }
            detail = nil
            state = .failed
        }
    }

    /// Submits one thread mutation and refreshes the thread's controls on success.
    public func perform(_ action: MilaThreadAction, requestID: UUID = UUID()) async {
        guard let adapter else { mutation = .failed(nil); return }
        if case .submitting = mutation { return }
        guard action.isMutation, action.isWellFormed, requestID != .zero,
              usedRequestIDs.insert(requestID).inserted else { mutation = .failed(requestID); return }
        let requested = token
        mutation = .submitting(requestID)
        do {
            _ = try await adapter.threadAction(thread: action.thread, command: action.command, secondary: action.secondary, input: action.input, requestID: requestID)
            guard requested == token else { return }
            mutation = .applied(requestID)
            if let thread = action.thread { await show(thread) }
        } catch {
            guard requested == token else { return }
            mutation = .failed(requestID)
        }
    }
}
