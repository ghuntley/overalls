import Foundation
import XCTest
@testable import MilaNativeUI

/// Rust live-listing bytes (`mila_session_listing`) for package tests.
enum MilaListingFixture {
    static let running = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let stopped = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let paused = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    /// Bits follow `mila_runtime::MachineAction` order: start, stop, pause, resume, pin, unpin, delete.
    static func row(_ id: UUID, name: String, state: String, bits: UInt16, write: Bool = true) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","name":"\#(name)","desired_state":"\#(state)","observed_state":"\#(state)","pinned":false,"owner":"owner@example.test","read":true,"write":\#(write),"manage":true,"action_bits":\#(bits)}"#
    }

    static func listing(_ rows: [String], hasMore: Bool = false) -> Data {
        Data(#"{"machines":[\#(rows.joined(separator: ","))],"has_more":\#(hasMore)}"#.utf8)
    }

    /// running: stop|pause|pin|delete; stopped: start|pin|delete; paused: resume|pin|delete.
    static let firstPage = listing([
        row(running, name: "alpha", state: "running", bits: 0b1010110),
        row(stopped, name: "beta", state: "stopped", bits: 0b1010001),
    ], hasMore: true)
    static let allPages = listing([
        row(running, name: "alpha", state: "running", bits: 0b1010110),
        row(stopped, name: "beta", state: "stopped", bits: 0b1010001),
        row(paused, name: "gamma", state: "paused", bits: 0b1011000),
    ])

    static func snapshot(_ data: Data = firstPage) throws -> MilaValidatedSnapshot { try LinkedMilaFFIAdapter.projectListing(data) }
    static func machine(_ id: UUID = running) throws -> MilaMachinePresentation {
        try XCTUnwrap(try snapshot(allPages).machines.first { $0.id == id })
    }
}

/// A recording `MilaSessionClient`/`MilaPtySession` that stands in for the Rust
/// session below `LinkedMilaFFIAdapter`, so the adapter's real mapping runs.
final class RecordingSession: MilaSessionClient, MilaPtySession, @unchecked Sendable {
    enum Call: Equatable {
        case refresh, readMore, whoami, sshKeys, close
        case revoke(UUID, UUID)
        case action(UUID, String, UUID)
        case resize(UUID, UInt32, UInt64, UInt64)
        case create(String)
        case share(UUID, String, String?, Bool, UUID)
        case thread(UUID?, String, String?, String?, UUID?)
        case webShow(UUID)
        case webSet(UUID, UInt16, Bool, UInt64)
        case ptyAttach(UUID, UInt32, UInt32), ptyPoll(UInt64), ptyRead(UInt64, UInt32), ptyInput(UInt64, Data), ptyResize(UInt64, UInt32, UInt32), ptyKill(UInt64)
        case deviceRegister(MilaDevicePlatform, String, String?), deviceList, devicePreferences(UUID, Bool), deviceRemove(UUID)
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ call: Call) { lock.lock(); recorded.append(call); lock.unlock() }

    var authenticated = true
    var isAuthenticated: Bool { lock.lock(); defer { lock.unlock() }; return authenticated }
    var listing = MilaListingFixture.firstPage
    var moreListing = MilaListingFixture.allPages
    var whoamiResponses: [Data] = []
    var sshKeyData = Data(#"{"version":1,"status":"succeeded","result":{"keys":[]}}"#.utf8)
    var threadResponses: [String: Data] = [:]
    var webData = Data()
    var failMutations = false
    var ptyOutput: [Data] = []
    var nextTerminal: UInt64 = 100

    func refresh() throws -> Data { record(.refresh); return listing }
    func readMore() throws -> Data { record(.readMore); return moreListing }
    func whoami() throws -> Data {
        record(.whoami)
        lock.lock(); defer { lock.unlock() }
        guard !whoamiResponses.isEmpty else { throw MilaSessionError.transport(-11) }
        return whoamiResponses.count == 1 ? whoamiResponses[0] : whoamiResponses.removeFirst()
    }
    func sshKeys() throws -> Data { record(.sshKeys); return sshKeyData }
    func revokeSSHKey(id: UUID, requestID: UUID) throws { record(.revoke(id, requestID)); if failMutations { throw MilaSessionError.invalidInput } }
    func machineAction(machine: UUID, action: String, requestID: UUID) throws { record(.action(machine, action, requestID)); if failMutations { throw MilaSessionError.invalidInput } }
    func machineResize(machine: UUID, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) throws { record(.resize(machine, cpu, memory, disk)) }
    func machineCreate(name: String, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) throws { record(.create(name)) }
    func shareMutation(machine: UUID, email: String, role: String?, add: Bool, requestID: UUID) throws {
        record(.share(machine, email, role, add, requestID)); if failMutations { throw MilaSessionError.invalidInput }
    }
    func threadAction(thread: UUID?, command: String, secondary: String?, input: String?, requestID: UUID?) throws -> Data {
        record(.thread(thread, command, secondary, input, requestID))
        if failMutations && requestID != nil { throw MilaSessionError.invalidInput }
        guard let data = threadResponses[command] else { throw MilaSessionError.transport(-11) }
        return data
    }
    /// Successive `web show` replies; the last one repeats. Empty means `webData`.
    var webShowReplies: [Data] = []
    /// Thrown by `web set` after it is recorded, with `refusal` as the session's last refusal.
    var webSetError: MilaSessionError?
    var refusal: String?
    func webShow(machine: UUID) throws -> Data {
        record(.webShow(machine))
        lock.lock(); defer { lock.unlock() }
        guard !webShowReplies.isEmpty else { return webData }
        return webShowReplies.count == 1 ? webShowReplies[0] : webShowReplies.removeFirst()
    }
    func webSet(machine: UUID, port: UInt16, publicAccess: Bool, revision: UInt64, requestID: UUID) throws {
        record(.webSet(machine, port, publicAccess, revision))
        if let webSetError { throw webSetError }
    }
    func lastRefusal() -> String? { refusal }
    /// Porsche's `device register` receipt (protocol/test/fixtures/porsche_device_results.json).
    var deviceReceipt = Data(#"{"version":1,"status":"succeeded","request_id":"porsche-0123456789abcdef0123456789abcdef","operation_id":null,"result":{"id":"5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b","platform":"macos","enabled":true,"state":"active"}}"#.utf8)
    var deviceListing = Data(#"{"version":1,"status":"succeeded","result":{"items":[],"limit":10,"push_enabled":true}}"#.utf8)
    func notificationDevices() throws -> Data { record(.deviceList); return deviceListing }
    func notificationDeviceRegister(platform: MilaDevicePlatform, susanReply: Data, encryptionPublicKey: String, label: String?, now: UInt64) throws -> Data {
        record(.deviceRegister(platform, encryptionPublicKey, label)); if failMutations { throw MilaSessionError.invalidInput }
        return deviceReceipt
    }
    func notificationDevicePreferences(id: UUID, enabled: Bool) throws { record(.devicePreferences(id, enabled)); if failMutations { throw MilaSessionError.invalidInput } }
    func notificationDeviceRemove(id: UUID) throws { record(.deviceRemove(id)); if failMutations { throw MilaSessionError.invalidInput } }
    func close() { record(.close); lock.lock(); authenticated = false; lock.unlock() }

    func terminalAttach(machine: UUID, columns: UInt32, rows: UInt32) throws -> UInt64 {
        record(.ptyAttach(machine, columns, rows))
        lock.lock(); defer { lock.unlock() }
        guard authenticated else { throw MilaSessionError.staleHandle }
        nextTerminal += 1
        return nextTerminal
    }
    func terminalPoll(_ terminal: UInt64) throws -> Data {
        record(.ptyPoll(terminal))
        lock.lock(); defer { lock.unlock() }
        return ptyOutput.isEmpty ? Data() : ptyOutput.removeFirst()
    }
    /// Scripted output as Rust's bounded read reports it: an empty chunk is an
    /// idle channel, and an exhausted script stays idle.
    func terminalRead(_ terminal: UInt64, waitMilliseconds: UInt32) throws -> MilaTerminalRead {
        record(.ptyRead(terminal, waitMilliseconds))
        lock.lock(); defer { lock.unlock() }
        guard !ptyOutput.isEmpty else { return .idle }
        let chunk = ptyOutput.removeFirst()
        return chunk.isEmpty ? .idle : .data(chunk)
    }
    func terminalInput(_ terminal: UInt64, data: Data) throws { record(.ptyInput(terminal, data)) }
    func terminalResize(_ terminal: UInt64, columns: UInt32, rows: UInt32) throws { record(.ptyResize(terminal, columns, rows)) }
    func terminalKill(_ terminal: UInt64) { record(.ptyKill(terminal)) }
}

/// An adapter over a recording session for controller-level tests.
func recordingAdapter(_ session: RecordingSession = RecordingSession()) -> (LinkedMilaFFIAdapter, RecordingSession) {
    (LinkedMilaFFIAdapter(session: session), session)
}

/// Isolated defaults and store for deployment/session tests.
struct MilaIsolatedDefaults {
    let suite = "mila.test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: MilaDeploymentStore
    init() { defaults = UserDefaults(suiteName: suite)!; store = MilaDeploymentStore(defaults: defaults) }
    func tearDown() { defaults.removePersistentDomain(forName: suite) }
}

enum MilaWhoami {
    static let approved = Data(#"{"version":1,"status":"succeeded","result":{"id":"44444444-4444-4444-8444-444444444444","email":"owner@example.test","guest_username":"owner","public_key":"ecdsa-sha2-nistp256 AAAA"}}"#.utf8)
    static func pending(host: String = "mila.example.test") -> Data {
        Data(#"{"version":1,"status":"approval_required","fingerprint":"SHA256:q3Zx+9fixture/AbC=","approval_url":"https://\#(host)/ssh/approve/abc","message":"Approve this key in your browser, then retry the command."}"#.utf8)
    }
    static let refused = Data(#"{"version":1,"status":"error","error":"unauthorized"}"#.utf8)
}

/// Polls a main-actor condition while letting spawned tasks run.
@MainActor func eventually(_ condition: () -> Bool, iterations: Int = 200) async -> Bool {
    for _ in 0..<iterations {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Asserts that a main-actor condition becomes true while spawned tasks run.
@MainActor func assertEventually(_ condition: () -> Bool, iterations: Int = 200,
                                 file: StaticString = #filePath, line: UInt = #line) async {
    let satisfied = await eventually(condition, iterations: iterations)
    XCTAssertTrue(satisfied, "condition not reached", file: file, line: line)
}
