import Foundation
import MilaFFIShim

public enum MilaSessionError: Error, Equatable, Sendable {
    case invalidInput
    case transport(Int32)
    case outputTooSmall
    case staleHandle
    case unavailable
}

/// Device-key custody used only while `mila_session_connect` runs. Production
/// uses `MilaDeviceSigner` (Secure Enclave); the protocol exists so the package
/// tests can drive a disposable fixture deployment without production fallback.
public protocol MilaSessionSigner: AnyObject {
    var openSSHPublicKey: String { get }
    /// Returns the 64-byte big-endian r||s P-256 signature of SHA-256(message).
    func sign(message: Data) throws -> Data
}

extension MilaDeviceSigner: MilaSessionSigner {}

/// @cc [owner:ghuntley,label:security;protocol] mila-apple-session-client
/// The authenticated operations the Apple adapter dispatches. `MilaLiveSession`
/// is the production implementation over the Rust `mila_session_*` ABI; every
/// mutation crosses as closed vocabulary plus canonical UUID and request IDs,
/// and Rust revalidates them before any network call.
public protocol MilaSessionClient: AnyObject, Sendable {
    var isAuthenticated: Bool { get }
    func refresh() throws -> Data
    func readMore() throws -> Data
    func whoami() throws -> Data
    func sshKeys() throws -> Data
    func revokeSSHKey(id: UUID, requestID: UUID) throws
    func machineAction(machine: UUID, action: String, requestID: UUID) throws
    func machineResize(machine: UUID, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) throws
    func machineCreate(name: String, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) throws
    func shareMutation(machine: UUID, email: String, role: String?, add: Bool, requestID: UUID) throws
    func threadAction(thread: UUID?, command: String, secondary: String?, input: String?, requestID: UUID?) throws -> Data
    func webShow(machine: UUID) throws -> Data
    func webSet(machine: UUID, port: UInt16, publicAccess: Bool, revision: UInt64, requestID: UUID) throws
    func close()
}

/// The PTY half of an authenticated session. Handles are opaque Rust registry
/// identifiers owned by the session that opened them.
public protocol MilaPtySession: AnyObject, Sendable {
    var isAuthenticated: Bool { get }
    func terminalAttach(columns: UInt32, rows: UInt32) throws -> UInt64
    func terminalPoll(_ terminal: UInt64) throws -> Data
    func terminalInput(_ terminal: UInt64, data: Data) throws
    func terminalResize(_ terminal: UInt64, columns: UInt32, rows: UInt32) throws
    func terminalKill(_ terminal: UInt64)
}

/// Canonical Porsche request identity: `porsche-` plus 32 lowercase hex digits.
func milaRequestID(_ id: UUID) -> String {
    "porsche-" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
}

/// A typed owner for a Rust live session. The handle is closed exactly once.
public final class MilaLiveSession: MilaSessionClient, MilaPtySession, @unchecked Sendable {
    /// Output bounds that mirror the Rust session's own limits. Exec-backed reads
    /// are fetched with one call into a buffer of this size: the Rust functions
    /// run the remote command on every call, so a size probe would execute it twice
    /// and a PTY probe would consume and discard a chunk.
    static let whoamiLimit = 64 * 1024
    static let commandLimit = 256 * 1024
    static let ptyChunkLimit = 1 << 20
    private var handle: UInt64
    private let lock = NSLock()
    private var ptyBuffer = [UInt8]()

    public convenience init(trust: Data, host: String, port: UInt16, timeoutMilliseconds: UInt32 = 15_000, signer: MilaDeviceSigner) throws {
        try self.init(trust: trust, host: host, port: port, timeoutMilliseconds: timeoutMilliseconds, sessionSigner: signer)
    }

    /// Connects with any signer. The signer is borrowed only for the duration of
    /// the call; Rust does not retain the callback context.
    public init(trust: Data, host: String, port: UInt16, timeoutMilliseconds: UInt32 = 15_000, sessionSigner signer: any MilaSessionSigner) throws {
        guard !trust.isEmpty, !host.isEmpty else { throw MilaSessionError.invalidInput }
        let box = MilaSignerBox(signer)
        var connected: UInt64 = 0
        let status: Int32 = trust.withUnsafeBytes { trustRaw in
            host.utf8CString.withUnsafeBufferPointer { hostBuffer in
                let key = Array(signer.openSSHPublicKey.utf8)
                return key.withUnsafeBufferPointer { keyBuffer in
                    mila_session_connect(trustRaw.bindMemory(to: UInt8.self).baseAddress, trust.count,
                                          hostBuffer.baseAddress, host.utf8.count,
                                          keyBuffer.baseAddress, key.count, port, timeoutMilliseconds,
                                          milaAppleSessionSigner, UInt(bitPattern: Unmanaged.passUnretained(box).toOpaque()), &connected)
                }
            }
        }
        withExtendedLifetime(box) {}
        guard status == 0 else { throw Self.error(status) }
        guard connected != 0 else { throw MilaSessionError.unavailable }
        self.handle = connected
    }

    /// Wraps an arbitrary handle without connecting. Package tests use it to
    /// exercise the linked Rust ABI's stale-handle refusal for every operation.
    init(unconnectedHandleForTesting handle: UInt64) { self.handle = handle }

    deinit { close() }

    /// Returns whether the authenticated Rust session is still live.
    /// This is used by host transports to fence terminal operations after sign-out or close.
    public var isAuthenticated: Bool {
        lock.lock(); defer { lock.unlock() }
        return handle != 0
    }

    public func refresh() throws -> Data {
        let current = try validHandle()
        let status = mila_session_read_machines(current, 0)
        guard status == 0 else { throw Self.error(status) }
        return try copyListing(current)
    }

    /// Fetches the bounded browser-approval identity envelope from the live session.
    /// The Rust boundary returns either an authenticated identity or an approval-required
    /// link; callers must decode and validate the envelope before presenting it.
    public func whoami() throws -> Data {
        let current = try validHandle()
        return try Self.readOnce(limit: Self.whoamiLimit) { mila_session_whoami(current, $0, $1, $2) }
    }

    public func sshKeys() throws -> Data {
        let current = try validHandle()
        return try Self.readOnce(limit: Self.commandLimit) { mila_session_ssh_keys(current, $0, $1, $2) }
    }

    public func revokeSSHKey(id: UUID, requestID: UUID) throws {
        let current = try validHandle()
        let key = Array(id.uuidString.lowercased().utf8)
        let request = Array(milaRequestID(requestID).utf8)
        let status = key.withUnsafeBufferPointer { k in request.withUnsafeBufferPointer { r in
            mila_session_ssh_key_revoke(current, k.baseAddress, k.count, r.baseAddress, r.count)
        }}
        guard status == 0 else { throw Self.error(status) }
    }

    public func machineAction(machine: UUID, action: String, requestID: UUID) throws {
        let current = try validHandle()
        let machineBytes = Array(machine.uuidString.lowercased().utf8)
        let actionBytes = Array(action.utf8)
        let requestBytes = Array(milaRequestID(requestID).utf8)
        let status = machineBytes.withUnsafeBufferPointer { m in actionBytes.withUnsafeBufferPointer { a in requestBytes.withUnsafeBufferPointer { r in
            mila_session_machine_action(current, m.baseAddress, m.count, a.baseAddress, a.count, r.baseAddress, r.count)
        } } }
        guard status == 0 else { throw Self.error(status) }
    }

    public func machineResize(machine: UUID, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) throws {
        let current = try validHandle()
        guard (1...256).contains(cpu), (256...4_194_304).contains(memory), (1...16_777_216).contains(disk) else { throw MilaSessionError.invalidInput }
        let machineBytes = Array(machine.uuidString.lowercased().utf8)
        let requestBytes = Array(milaRequestID(requestID).utf8)
        let status = machineBytes.withUnsafeBufferPointer { m in requestBytes.withUnsafeBufferPointer { r in
            mila_session_machine_resize(current, m.baseAddress, m.count, cpu, memory, disk, r.baseAddress, r.count)
        }}
        guard status == 0 else { throw Self.error(status) }
    }

    public func machineCreate(name: String, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) throws {
        let current = try validHandle()
        let nameBytes = Array(name.utf8)
        let requestBytes = Array(milaRequestID(requestID).utf8)
        let status = nameBytes.withUnsafeBufferPointer { n in requestBytes.withUnsafeBufferPointer { r in
            mila_session_machine_create(current, n.baseAddress, n.count, cpu, memory, disk, r.baseAddress, r.count)
        }}
        guard status == 0 else { throw Self.error(status) }
    }

    public func shareMutation(machine: UUID, email: String, role: String?, add: Bool, requestID: UUID) throws {
        let current = try validHandle()
        let machineBytes = Array(machine.uuidString.lowercased().utf8)
        let emailBytes = Array(email.utf8)
        let roleBytes = Array((role ?? "").utf8)
        let requestBytes = Array(milaRequestID(requestID).utf8)
        let status = machineBytes.withUnsafeBufferPointer { m in emailBytes.withUnsafeBufferPointer { e in roleBytes.withUnsafeBufferPointer { r in requestBytes.withUnsafeBufferPointer { q in
            mila_session_share_mutation(current, m.baseAddress, m.count, e.baseAddress, e.count, r.baseAddress, r.count, add ? 1 : 0, q.baseAddress, q.count)
        }}}}
        guard status == 0 else { throw Self.error(status) }
    }

    public func threadAction(thread: UUID?, command: String, secondary: String? = nil, input: String? = nil, requestID: UUID? = nil) throws -> Data {
        let current = try validHandle()
        let threadBytes = Array((thread?.uuidString.lowercased() ?? "").utf8)
        let commandBytes = Array(command.utf8)
        let secondaryBytes = Array((secondary ?? "").utf8)
        let inputBytes = Array((input ?? "").utf8)
        let requestBytes = Array((requestID.map(milaRequestID) ?? "").utf8)
        func call(_ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int, _ written: UnsafeMutablePointer<Int>) -> Int32 {
            threadBytes.withUnsafeBufferPointer { t in commandBytes.withUnsafeBufferPointer { c in secondaryBytes.withUnsafeBufferPointer { s in inputBytes.withUnsafeBufferPointer { i in requestBytes.withUnsafeBufferPointer { r in
                mila_session_thread_action(current, t.baseAddress, t.count, c.baseAddress, c.count, s.baseAddress, s.count, i.baseAddress, i.count, r.baseAddress, r.count, output, capacity, written)
            }}}}}
        }
        return try Self.readOnce(limit: Self.commandLimit) { call($0, $1, $2) }
    }

    /// Fetches the authenticated machine web projection. Rust performs the
    /// HTTPS request and bounds the returned JSON before it crosses the ABI.
    public func webShow(machine: UUID) throws -> Data {
        let current = try validHandle()
        let machineBytes = Array(machine.uuidString.lowercased().utf8)
        return try Self.readOnce(limit: Self.commandLimit) { output, capacity, written in
            machineBytes.withUnsafeBufferPointer { m in
                mila_session_web_show(current, m.baseAddress, m.count, output, capacity, written)
            }
        }
    }

    /// Mutates a machine web endpoint using the server-provided optimistic revision.
    public func webSet(machine: UUID, port: UInt16, publicAccess: Bool, revision: UInt64, requestID: UUID) throws {
        guard port > 0 else { throw MilaSessionError.invalidInput }
        let current = try validHandle()
        let machineBytes = Array(machine.uuidString.lowercased().utf8)
        let requestBytes = Array(milaRequestID(requestID).utf8)
        let status = machineBytes.withUnsafeBufferPointer { m in
            requestBytes.withUnsafeBufferPointer { r in
                mila_session_web_set(current, m.baseAddress, m.count, port, publicAccess ? 1 : 0, revision, r.baseAddress, r.count)
            }
        }
        guard status == 0 else { throw Self.error(status) }
    }

    public func readMore() throws -> Data {
        let current = try validHandle()
        let status = mila_session_read_machines(current, 1)
        guard status == 0 else { throw Self.error(status) }
        return try copyListing(current)
    }

    /// Opens an authenticated PTY owned by this session. The returned opaque
    /// handle is valid only until `terminalKill` or session close.
    public func terminalAttach(columns: UInt32 = 120, rows: UInt32 = 40) throws -> UInt64 {
        let current = try validHandle()
        guard (1...4096).contains(columns), (1...512).contains(rows) else { throw MilaSessionError.invalidInput }
        var terminal: UInt64 = 0
        let status = mila_session_terminal_attach(current, columns, rows, &terminal).rawValue
        guard status == 0, terminal != 0 else { throw Self.error(status) }
        return terminal
    }

    /// Polls one bounded PTY output chunk. Empty data means no data or EOF.
    /// One call with a full-size buffer: Rust reads the channel before checking
    /// capacity, so a size probe would drop the chunk it measured.
    public func terminalPoll(_ terminal: UInt64) throws -> Data {
        guard terminal != 0 else { throw MilaSessionError.invalidInput }
        lock.lock()
        if ptyBuffer.count != Self.ptyChunkLimit { ptyBuffer = [UInt8](repeating: 0, count: Self.ptyChunkLimit) }
        var buffer = ptyBuffer
        ptyBuffer = []
        lock.unlock()
        defer { lock.lock(); ptyBuffer = buffer; lock.unlock() }
        var written = 0
        let status = buffer.withUnsafeMutableBufferPointer { output in
            mila_session_terminal_poll(terminal, output.baseAddress, output.count, &written).rawValue
        }
        guard status == 0, written <= buffer.count else { throw Self.error(status) }
        return Data(buffer.prefix(written))
    }

    /// Writes bounded input bytes to an authenticated PTY.
    public func terminalInput(_ terminal: UInt64, data: Data) throws {
        guard terminal != 0, !data.isEmpty, data.count <= 1 << 20 else { throw MilaSessionError.invalidInput }
        let status = data.withUnsafeBytes { raw in
            mila_session_terminal_input(terminal, raw.bindMemory(to: UInt8.self).baseAddress, data.count).rawValue
        }
        guard status == 0 else { throw Self.error(status) }
    }

    /// Resizes an authenticated PTY using the same bounds as the Rust transport.
    public func terminalResize(_ terminal: UInt64, columns: UInt32, rows: UInt32) throws {
        guard terminal != 0, (1...4096).contains(columns), (1...512).contains(rows) else { throw MilaSessionError.invalidInput }
        let status = mila_session_terminal_resize(terminal, columns, rows).rawValue
        guard status == 0 else { throw Self.error(status) }
    }

    /// Closes a PTY and invalidates its opaque handle.
    public func terminalKill(_ terminal: UInt64) {
        guard terminal != 0 else { return }
        _ = mila_session_terminal_kill(terminal)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { return }
        _ = mila_session_close(handle)
        handle = 0
    }

    private func validHandle() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard handle != 0 else { throw MilaSessionError.staleHandle }
        return handle
    }

    private func copyListing(_ handle: UInt64) throws -> Data {
        var required = 0
        var status = mila_session_listing(handle, nil, 0, &required)
        guard status == 0 || status == -3, required > 0, required <= 1_048_576 else { throw Self.error(status) }
        var bytes = [UInt8](repeating: 0, count: required)
        status = mila_session_listing(handle, &bytes, bytes.count, &required)
        guard status == 0 else { throw Self.error(status) }
        return Data(bytes.prefix(required))
    }

    /// Calls a Rust output function exactly once with a caller-owned buffer.
    static func readOnce(limit: Int, _ call: (UnsafeMutablePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: limit)
        var written = 0
        let status = bytes.withUnsafeMutableBufferPointer { call($0.baseAddress, $0.count, &written) }
        guard status == 0, written > 0, written <= limit else {
            throw status == 0 ? MilaSessionError.unavailable : Self.error(status)
        }
        return Data(bytes.prefix(written))
    }

    static func error(_ status: Int32) -> MilaSessionError {
        switch status { case -3: return .outputTooSmall; case -10: return .staleHandle; case -11, -12, -13, -14: return .transport(status); case -4, -1: return .invalidInput; default: return .transport(status) }
    }
}

private func milaAppleSessionSigner(_ context: UInt, _ message: UnsafePointer<UInt8>?, _ length: Int, _ signature: UnsafeMutablePointer<UInt8>?) -> Int32 {
    guard context != 0, let message, let signature, length > 0, length <= 65_536,
          let opaque = UnsafeRawPointer(bitPattern: context) else { return -1 }
    do {
        let box = Unmanaged<MilaSignerBox>.fromOpaque(opaque).takeUnretainedValue()
        let raw = try box.signer.sign(message: Data(bytes: message, count: length))
        guard raw.count == 64 else { return -1 }
        raw.copyBytes(to: signature, count: 64)
        return 0
    } catch { return -1 }
}

/// Stable class reference handed to Rust as the callback context during connect.
private final class MilaSignerBox {
    let signer: any MilaSessionSigner
    init(_ signer: any MilaSessionSigner) { self.signer = signer }
}
