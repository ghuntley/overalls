import Foundation
import Combine
import MilaFFIShim

/// Lifecycle states for a bounded native terminal attachment.
public enum MilaTerminalState: Equatable, Sendable {
    case detached
    case attaching
    case attached
    case reconnecting
    case failed
}

public enum MilaTerminalError: Error, Equatable, Sendable {
    case invalidRequest
    case permissionDenied
    case unavailable
    case outputLimitExceeded
}

/// Host transport supplied by the native application. Terminal bytes stay in this host-owned
/// transport and are never copied into Rust FFI calls.
public protocol MilaTerminalTransport: Sendable {
    func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws
    /// Wait for the next bounded PTY output chunk. `nil` means the remote stream ended.
    /// The default keeps existing host transports source compatible while they are being
    /// upgraded to a real PTY reader.
    func receiveOutput() async throws -> Data?
    func sendInput(_ input: Data) async throws
    func resize(columns: UInt16, rows: UInt16) async throws
    func close() async
}

public extension MilaTerminalTransport {
    func receiveOutput() async throws -> Data? { nil }
}

/// An authenticated host PTY transport. The actual socket/PTY remains owned by the
/// native host, while the Rust session fences every operation to a live authenticated
/// deployment session. Bytes never cross this authorization wrapper.
public final class MilaAuthenticatedTerminalTransport: MilaTerminalTransport, @unchecked Sendable {
    private let authorized: @Sendable () -> Bool
    private let transport: any MilaTerminalTransport

    public init(session: any MilaPtySession, transport: any MilaTerminalTransport) {
        self.authorized = { session.isAuthenticated }
        self.transport = transport
    }

    /// Production transport backed by the authenticated Rust PTY registry,
    /// attaching to the caller's named terminal session on `machine`.
    public convenience init(session: any MilaPtySession, machine: UUID) {
        self.init(session: session, transport: MilaLiveSessionTerminalTransport(session: session, machine: machine))
    }

    /// Internal seam for native host tests; production callers must provide a live session.
    init(authorized: @escaping @Sendable () -> Bool, transport: any MilaTerminalTransport) {
        self.authorized = authorized
        self.transport = transport
    }

    public func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws {
        guard authorized() else { throw MilaTerminalError.unavailable }
        guard mila_terminal_attach_validate(from, columns, rows, readWrite ? 1 : 0).rawValue == 0 else {
            throw MilaTerminalError.invalidRequest
        }
        try await transport.attach(from: from, columns: columns, rows: rows, readWrite: readWrite)
    }

    public func sendInput(_ input: Data) async throws {
        guard authorized() else { throw MilaTerminalError.unavailable }
        guard mila_terminal_input_validate(input.count, 1).rawValue == 0 else {
            throw MilaTerminalError.invalidRequest
        }
        try await transport.sendInput(input)
    }

    public func resize(columns: UInt16, rows: UInt16) async throws {
        guard authorized() else { throw MilaTerminalError.unavailable }
        guard mila_terminal_resize_validate(columns, rows, 1).rawValue == 0 else {
            throw MilaTerminalError.invalidRequest
        }
        try await transport.resize(columns: columns, rows: rows)
    }

    public func receiveOutput() async throws -> Data? {
        guard authorized() else { await transport.close(); return nil }
        return try await transport.receiveOutput()
    }

    public func close() async { await transport.close() }
}

/// @cc [owner:ghuntley,label:security] mila-apple-pty-generation
/// Native Apple adapter for the Rust authenticated PTY ABI. It owns only the
/// opaque terminal handle and binds it to a PTY generation: attach kills any
/// previous handle and starts a new generation, and output polled for a handle
/// that is no longer current is discarded. When the parent session stops being
/// authenticated the handle is killed and the stream ends.
public final class MilaLiveSessionTerminalTransport: MilaTerminalTransport, @unchecked Sendable {
    /// Back-off between empty polls (no data, window adjust, or a closed channel).
    static let idlePoll: Duration = .milliseconds(25)
    private let session: any MilaPtySession
    private let machine: UUID
    private let idle: Duration
    private let lock = NSLock()
    private var terminal: UInt64 = 0
    private var generation: UInt64 = 0

    /// Keep locking in a synchronous helper; Swift 6 rejects direct
    /// `NSLock.lock/unlock` calls from an async context.
    private func withTerminalLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public init(session: any MilaPtySession, machine: UUID) { self.session = session; self.machine = machine; self.idle = Self.idlePoll }
    init(session: any MilaPtySession, machine: UUID, idle: Duration) { self.session = session; self.machine = machine; self.idle = idle }

    /// The PTY generation bound to the current handle; zero while detached.
    var currentGeneration: UInt64 { withTerminalLock { terminal == 0 ? 0 : generation } }

    public func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws {
        // `from` is the UI resume cursor, not the opaque PTY handle.  A fresh
        // attachment legitimately starts at zero; authorization comes from the
        // authenticated session and the requested read/write mode.
        guard readWrite else { throw MilaTerminalError.permissionDenied }
        guard session.isAuthenticated else { throw MilaTerminalError.unavailable }
        let handle: UInt64
        do { handle = try session.terminalAttach(machine: machine, columns: UInt32(columns), rows: UInt32(rows)) }
        catch { throw MilaTerminalError.unavailable }
        let previous = withTerminalLock { let old = terminal; terminal = handle; generation &+= 1; return old }
        if previous != 0 { session.terminalKill(previous) }
    }

    public func receiveOutput() async throws -> Data? {
        let (handle, bound) = withTerminalLock { (terminal, generation) }
        guard handle != 0 else { return nil }
        guard session.isAuthenticated else { await close(); return nil }
        let data: Data
        do { data = try session.terminalPoll(handle) } catch { throw MilaTerminalError.unavailable }
        // A reattach or close during the poll invalidates its chunk.
        guard withTerminalLock({ terminal == handle && generation == bound }) else { return nil }
        if data.isEmpty { try? await Task.sleep(for: idle) }
        return data
    }

    public func sendInput(_ input: Data) async throws {
        let handle = withTerminalLock { terminal }
        guard handle != 0, session.isAuthenticated else { throw MilaTerminalError.unavailable }
        do { try session.terminalInput(handle, data: input) } catch { throw MilaTerminalError.unavailable }
    }

    public func resize(columns: UInt16, rows: UInt16) async throws {
        let handle = withTerminalLock { terminal }
        guard handle != 0, session.isAuthenticated else { throw MilaTerminalError.unavailable }
        do { try session.terminalResize(handle, columns: UInt32(columns), rows: UInt32(rows)) }
        catch { throw MilaTerminalError.invalidRequest }
    }

    public func close() async {
        let handle = withTerminalLock { let old = terminal; terminal = 0; generation &+= 1; return old }
        if handle != 0 { session.terminalKill(handle) }
    }
}

public struct MilaNoopTerminalTransport: MilaTerminalTransport {
    public init() {}
    public func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws {}
    public func receiveOutput() async throws -> Data? { nil }
    public func sendInput(_ input: Data) async throws { _ = input }
    public func resize(columns: UInt16, rows: UInt16) async throws {}
    public func close() async {}
}

/// Main-actor terminal lifecycle model. Rust validates every operation before host transport use.
@MainActor
public final class MilaTerminalController: ObservableObject {
    public static let maximumRenderedOutput = 256 * 1024
    @Published public private(set) var state: MilaTerminalState = .detached
    @Published public private(set) var output = Data()
    @Published public private(set) var columns: UInt16 = 80
    @Published public private(set) var rows: UInt16 = 24
    private let transport: any MilaTerminalTransport
    private var lastAttach: (from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool)?
    private var receiveTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var submittedAttachIDs = Set<UUID>()

    public init(transport: any MilaTerminalTransport = MilaNoopTerminalTransport()) {
        self.transport = transport
    }

    public func attach(from: UInt64 = 0, columns: UInt16 = 80, rows: UInt16 = 24, readWrite: Bool = true, requestID: UUID = UUID()) async {
        guard submittedAttachIDs.insert(requestID).inserted else { state = .failed; return }
        guard validateAttach(from: from, columns: columns, rows: rows, readWrite: readWrite) else {
            state = .failed; return
        }
        generation &+= 1
        state = .attaching
        do {
            try await transport.attach(from: from, columns: columns, rows: rows, readWrite: readWrite)
            self.columns = columns; self.rows = rows
            lastAttach = (from, columns, rows, readWrite)
            state = .attached
            startReceiving()
        } catch { state = .failed }
    }

    public func reconnect() async {
        guard let request = lastAttach else { state = .failed; return }
        state = .reconnecting
        generation &+= 1
        receiveTask?.cancel()
        // A reconnect starts a fresh PTY stream; never display bytes from the ended generation.
        output.removeAll(keepingCapacity: true)
        await transport.close()
        do {
            try await transport.attach(from: request.from, columns: request.columns, rows: request.rows, readWrite: request.readWrite)
            state = .attached
            startReceiving()
        } catch { state = .failed }
    }

    public func sendInput(_ input: Data) async {
        guard state == .attached else { state = .failed; return }
        let permission: UInt8 = 1
        guard mila_terminal_input_validate(input.count, permission).rawValue == 0 else {
            state = .failed; return
        }
        do { try await transport.sendInput(input) } catch { state = .failed }
    }

    public func resize(columns: UInt16, rows: UInt16) async {
        // Keep the host-side bounds explicit; the Rust ABI applies the same
        // contract, while Swift's imported enum raw values are platform-sized.
        guard state == .attached, columns > 0, rows > 0, columns <= 512, rows <= 512 else {
            state = .failed
            return
        }
        do { try await transport.resize(columns: columns, rows: rows); self.columns = columns; self.rows = rows }
        catch { state = .failed }
    }

    public func appendOutput(_ bytes: Data) {
        guard state == .attached else { return }
        guard bytes.count <= Self.maximumRenderedOutput else { state = .failed; return }
        let available = Self.maximumRenderedOutput - output.count
        output.append(bytes.prefix(available))
    }

    public func close() async {
        receiveTask?.cancel(); receiveTask = nil
        generation &+= 1
        await transport.close(); state = .detached; lastAttach = nil; output.removeAll(keepingCapacity: true)
    }

    private func startReceiving() {
        receiveTask?.cancel()
        let transport = self.transport
        let generation = self.generation
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard let bytes = try await transport.receiveOutput() else { break }
                    guard !bytes.isEmpty else { continue }
                    await MainActor.run { [weak self] in
                        guard let self, self.state == .attached, self.generation == generation else { return }
                        self.appendOutput(bytes)
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self, self.state == .attached, self.generation == generation else { return }
                    // A clean PTY EOF is still a disconnected session. Keep the UI from
                    // accepting input against a transport that has already ended.
                    self.state = .failed
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.state == .attached, self.generation == generation else { return }
                    self.state = .failed
                }
            }
        }
    }

    private func validateAttach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) -> Bool {
        mila_terminal_attach_validate(from, columns, rows, readWrite ? 1 : 0).rawValue == 0
    }
}
