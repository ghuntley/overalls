import Foundation
import MilaFFIShim

/// Operations exposed by the generated Rust FFI binding.
public enum MilaFFIOperation: String, Codable, Sendable {
    case bootstrap
    case refresh
}

/// Navigation targets accepted from external activation. Credentials and commands are excluded.
public enum MilaRoute: Hashable, Sendable {
    case machines
    case machine(id: UUID)
    case threads
    case thread(id: UUID)
    case settings
}

public enum MilaRouteParser {
    public static func parse(_ value: String) -> MilaRoute? {
        let bytes = value.utf8
        guard !value.isEmpty, bytes.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              let url = URL(string: value), url.scheme == "overalls",
              url.user == nil, url.port == nil, url.fragment == nil, url.query == nil,
              !value.contains("%") else { return nil }
        guard let host = url.host, !host.isEmpty, host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7f }) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let page = parts.first else { return nil }
        let tail = Array(parts.dropFirst())
        switch page.lowercased() {
        case "machines":
            guard let id = tail.first else { return tail.isEmpty ? .machines : nil }
            guard tail.count == 1, let uuid = UUID(uuidString: id) else { return nil }
            return .machine(id: uuid)
        case "threads":
            guard let id = tail.first else { return tail.isEmpty ? .threads : nil }
            guard tail.count == 1, let uuid = UUID(uuidString: id) else { return nil }
            return .thread(id: uuid)
        case "settings":
            return tail.isEmpty ? .settings : nil
        default:
            return nil
        }
    }
}

/// A request crossing the native/Rust boundary.
public struct MilaFFIRequest: Codable, Equatable, Sendable {
    public let operation: MilaFFIOperation
    public let payload: Data

    public init(operation: MilaFFIOperation, payload: Data = Data()) {
        self.operation = operation
        self.payload = payload
    }
}

/// A response crossing the native/Rust boundary.
public struct MilaFFIResponse: Codable, Equatable, Sendable {
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }
}

public struct MilaSnapshotMachine: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let desiredState: String
    public let observedState: String?
    public let pinned: Bool
    public let owner: String?
    public let read: Bool
    public let write: Bool
    public let manage: Bool
    /// Rust policy bits are present for live authenticated listings.
    public let actionBits: UInt16?

    enum CodingKeys: String, CodingKey { case id, name, desiredState = "desired_state", observedState = "observed_state", pinned, owner, read, write, manage, actionBits = "action_bits" }
}

public enum MilaMachineAction: UInt16, CaseIterable, Sendable {
    case start, stop, pause, resume, pin, unpin, delete

    public var title: String {
        switch self {
        case .start: MilaStrings.text(.actionStart); case .stop: MilaStrings.text(.actionStop)
        case .pause: MilaStrings.text(.actionPause); case .resume: MilaStrings.text(.actionResume)
        case .pin: MilaStrings.text(.actionPin); case .unpin: MilaStrings.text(.actionUnpin)
        case .delete: MilaStrings.text(.actionDelete)
        }
    }

    /// @cc [owner:ghuntley,label:security;protocol] mila-apple-session-lifecycle-actions
    /// Only the lifecycle verbs the Rust session dispatches (`start`, `stop`,
    /// `pause`, `resume`, `rm`) may be submitted; pin and unpin are projected by
    /// Rust policy but have no authenticated session command and MUST be refused
    /// before the bridge rather than reported as submitted.
    public var isSessionLifecycle: Bool { self != .pin && self != .unpin }

    var token: String {
        switch self { case .start: "start"; case .stop: "stop"; case .pause: "pause"; case .resume: "resume"; case .pin: "pin"; case .unpin: "unpin"; case .delete: "rm" }
    }
}

public struct MilaMachineActions: Equatable, Sendable {
    public let values: [MilaMachineAction]
    /// Lifecycle actions the authenticated session can dispatch, in Rust policy order.
    public var lifecycle: [MilaMachineAction] { values.filter(\.isSessionLifecycle) }
    fileprivate init(bits: UInt16) { values = MilaMachineAction.allCases.filter { bits & (1 << $0.rawValue) != 0 } }
}

/// Presentation records can only be constructed after Rust validation and policy projection.
public struct MilaMachinePresentation: Identifiable, Equatable, Sendable {
    public var id: UUID { machine.id }
    public let machine: MilaSnapshotMachine
    public let actions: MilaMachineActions
    fileprivate init(machine: MilaSnapshotMachine, actions: MilaMachineActions) {
        self.machine = machine
        self.actions = actions
    }
}

public struct MilaValidatedSnapshot: Equatable, Sendable {
    public let machines: [MilaMachinePresentation]
    public let metadata: MilaSnapshotMetadata
    fileprivate init(machines: [MilaMachinePresentation], metadata: MilaSnapshotMetadata) {
        self.machines = machines
        self.metadata = metadata
    }
}

public struct MilaSnapshotMetadata: Equatable, Sendable {

    public let machineCount: UInt32
    public let savedAt: UInt64
    public let hasMore: Bool

    public init(machineCount: UInt32, savedAt: UInt64, hasMore: Bool = false) {
        self.machineCount = machineCount
        self.savedAt = savedAt
        self.hasMore = hasMore
    }
}

public enum MilaFFIError: Error, Equatable, Sendable {
    case unavailable
    case invalidRoute
    case outputTooSmall
    case incompatibleABI
    case actionNotAllowed
}

public enum MilaPushProvider: UInt8, Sendable {
    case apple = 0
    case firebase = 1
}

public enum MilaPushEnvironment: UInt8, Sendable {
    case sandbox = 0
    case production = 1
}

public enum MilaThreadCommandKind: Int32, CaseIterable, Sendable {
    case unknown = 0, list, show, turns, prompt, answer, planApprove, planRevise, mode, read
}
public enum MilaMachineCommandKind: Int32, Sendable { case unknown = 0, list, show, new, resize, start, stop, pause, resume, delete, shareAdd, shareRemove, webShow, webSet }

/// @cc [owner:ghuntley,label:security;protocol] mila-apple-thread-actions
/// Closed set of authenticated thread operations, matching the Rust session's
/// vocabulary exactly: `thread ls`, `show`/`turns` (thread), `prompt` (thread +
/// stdin), `answer` (thread + question id + stdin), `plan approve` (thread +
/// plan id) and `plan revise` (thread + plan id + stdin). Reads carry no request
/// ID; mutations MUST carry a fresh one. Text crosses only as bounded stdin.
public enum MilaThreadAction: Sendable, Equatable {
    case list
    case show(thread: UUID)
    case turns(thread: UUID)
    case prompt(thread: UUID, text: String)
    case answer(thread: UUID, question: UUID, text: String)
    case planApprove(thread: UUID, plan: UUID)
    case planRevise(thread: UUID, plan: UUID, text: String)

    public static let maximumTextBytes = 64 * 1024

    public var isWellFormed: Bool {
        func safe(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                value.utf8.count <= Self.maximumTextBytes &&
                !value.unicodeScalars.contains { $0.value == 0 || ($0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t") }
        }
        switch self {
        case .list, .show, .turns, .planApprove: return true
        case .prompt(_, let text), .answer(_, _, let text), .planRevise(_, _, let text): return safe(text)
        }
    }

    public var isMutation: Bool {
        switch self { case .list, .show, .turns: false; default: true }
    }

    public var thread: UUID? {
        switch self {
        case .list: nil
        case .show(let id), .turns(let id), .prompt(let id, _), .answer(let id, _, _), .planApprove(let id, _), .planRevise(let id, _, _): id
        }
    }

    public var command: String {
        switch self {
        case .list: "thread ls"
        case .show: "thread show"
        case .turns: "thread turns"
        case .prompt: "thread prompt"
        case .answer: "thread answer"
        case .planApprove: "thread plan approve"
        case .planRevise: "thread plan revise"
        }
    }

    /// Canonical lowercase question or plan identity.
    public var secondary: String? {
        switch self {
        case .answer(_, let question, _): question.uuidString.lowercased()
        case .planApprove(_, let plan), .planRevise(_, let plan, _): plan.uuidString.lowercased()
        default: nil
        }
    }

    public var input: String? {
        switch self {
        case .prompt(_, let text), .answer(_, _, let text), .planRevise(_, _, let text): text
        default: nil
        }
    }
}

public enum MilaWebCommand: Sendable, Equatable {
    case show(machineID: UUID)
    case set(machineID: UUID, url: String)
}

public enum MilaWebCommandError: Error, Equatable, Sendable { case invalidURL; case rejected }

private extension MilaWebCommand { var isSet: Bool { if case .set = self { return true }; return false } }

private enum MilaRustFFI {
    static func getVersion(_ version: UnsafeMutablePointer<MilaFfiAbiVersion>) -> Int32 {
        mila_ffi_get_version(version).rawValue
    }
    static func formatRoute(_ input: UnsafePointer<CChar>, _ output: MilaRouteOutput) -> Int32 {
        mila_route_format(input, output).rawValue
    }
    static func validateSnapshot(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ host: UnsafePointer<CChar>, _ port: UInt16, _ hasPort: UInt8, _ summary: UnsafeMutablePointer<MilaSnapshotSummary>) -> Int32 {
        mila_snapshot_validate(bytes, length, host, port, hasPort, summary).rawValue
    }
    static func machineActions(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ host: UnsafePointer<CChar>, _ port: UInt16, _ hasPort: UInt8, _ index: UInt32, _ actions: UnsafeMutablePointer<MilaMachineActions>) -> Int32 {
        var raw = MilaFFIShim.MilaMachineActions(bits: 0)
        let status = mila_snapshot_machine_actions(bytes, length, host, port, hasPort, index, &raw).rawValue
        actions.pointee = MilaMachineActions(bits: raw.bits)
        return status
    }
    static func command(_ action: UnsafePointer<CChar>, _ machine: UnsafePointer<CChar>, _ request: UnsafePointer<CChar>?, _ output: MilaRouteOutput) -> Int32 {
        mila_session_command_format(action, machine, request, output).rawValue
    }
    static func threadKind(_ line: UnsafePointer<CChar>, _ out: UnsafeMutablePointer<MilaThreadCommandKind>) -> Int32 {
        var raw = MilaFFIShim.MilaThreadCommandKind(rawValue: 0)
        let status = mila_thread_command_kind(line, &raw).rawValue
        out.pointee = MilaThreadCommandKind(rawValue: Int32(raw.rawValue)) ?? .unknown
        return status
    }
    static func machineKind(_ line: UnsafePointer<CChar>, _ out: UnsafeMutablePointer<MilaMachineCommandKind>) -> Int32 {
        var raw = MilaFFIShim.MilaMachineCommandKind(rawValue: 0)
        let status = mila_machine_command_kind(line, &raw).rawValue
        out.pointee = MilaMachineCommandKind(rawValue: Int32(raw.rawValue)) ?? .unknown
        return status
    }
    static func pushRegistration(_ provider: UInt8, _ environment: UInt8, _ token: UnsafePointer<CChar>, _ app: UnsafePointer<CChar>, _ deployment: UnsafePointer<CChar>, _ endpoint: UnsafePointer<CChar>) -> Int32 {
        mila_push_registration_validate(provider, environment, token, app, deployment, endpoint).rawValue
    }
}

/// Adapter for the stable C ABI exported by `mila-ffi`.
/// The host must link the Rust library; no Rust-owned memory is retained by this value.
public struct LinkedMilaFFIAdapter: MilaFFIAdapter, Sendable {
    private let liveSession: (any MilaSessionClient)?
    private let ptySession: (any MilaPtySession)?

    public init() { liveSession = nil; ptySession = nil }

    /// Creates an adapter backed by an authenticated Rust session. Trust is pinned deployment data.
    public init(trust: Data, host: String, port: UInt16, signer: MilaDeviceSigner) throws {
        let session = try MilaLiveSession(trust: trust, host: host, port: port, signer: signer)
        liveSession = session; ptySession = session
    }

    /// Wraps an existing authenticated session (production `MilaLiveSession`, or a
    /// recording client in package tests). The adapter's validation and mapping
    /// run unchanged above it.
    public init(session: any MilaSessionClient, pty: (any MilaPtySession)? = nil) {
        liveSession = session
        ptySession = pty ?? (session as? any MilaPtySession)
    }

    /// Returns the authenticated PTY transport for native terminal presentation.
    /// Unsigned adapters deliberately return nil so a terminal cannot open.
    public func terminalTransport() -> (any MilaTerminalTransport)? {
        guard let ptySession else { return nil }
        return MilaAuthenticatedTerminalTransport(session: ptySession)
    }

    /// Closes the authenticated Rust session. Later calls fail as stale.
    public func close() { liveSession?.close() }

    public func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        // Keep the generic request surface useful without allowing arbitrary command
        // bytes to cross into the native client. Both supported operations are
        // fulfilled by the authenticated Rust session; these operations have no
        // caller supplied data, so a non-empty payload is rejected.
        guard let liveSession else { throw MilaFFIError.unavailable }
        switch request.operation {
        case .bootstrap, .refresh:
            guard request.payload.isEmpty else { throw MilaFFIError.invalidRoute }
            return MilaFFIResponse(payload: try liveSession.refresh())
        }
    }

    public func canonicalRoute(_ value: String) throws -> String {
        var output = [UInt8](repeating: 0, count: 2048)
        var written = 0
        let status = output.withUnsafeMutableBufferPointer { buffer in
            value.withCString { input in
                withUnsafeMutablePointer(to: &written) { writtenPointer in
                    let out = MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: writtenPointer)
                    return MilaRustFFI.formatRoute(input, out)
                }
            }
        }
        switch status {
        case 0: return String(decoding: output.prefix(written), as: UTF8.self)
        case -2: throw MilaFFIError.invalidRoute
        case -3: throw MilaFFIError.outputTooSmall
        default: throw MilaFFIError.unavailable
        }
    }

    /// Validates and summarizes an offline snapshot in Rust. Snapshot bytes are borrowed for the
    /// duration of the call and no machine records cross the native boundary.
    public func validateSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> MilaSnapshotMetadata {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var summary = MilaSnapshotSummary(machine_count: 0, saved_at: 0)
        let status = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return host.withCString { hostPointer in
                withUnsafeMutablePointer(to: &summary) { summaryPointer in
                    MilaRustFFI.validateSnapshot(base, data.count, hostPointer, port ?? 0, port == nil ? 0 : 1, summaryPointer)
                }
            }
        }
        switch status {
        case 0: return MilaSnapshotMetadata(machineCount: summary.machine_count, savedAt: summary.saved_at)
        case -4: throw MilaFFIError.invalidRoute
        default: throw MilaFFIError.unavailable
        }
    }

    public func machineActions(_ data: Data, host: String, port: UInt16? = nil, index: UInt32) throws -> MilaMachineActions {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var raw = MilaMachineActions(bits: 0)
        let status = data.withUnsafeBytes { bytes -> Int32 in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return host.withCString { hostPointer in
                withUnsafeMutablePointer(to: &raw) { MilaRustFFI.machineActions(base, data.count, hostPointer, port ?? 0, port == nil ? 0 : 1, index, $0) }
            }
        }
        guard status == 0 else { throw MilaFFIError.unavailable }
        return raw
    }

    public func formatMachineAction(_ action: MilaMachineAction, machineID: UUID, requestID: UUID? = nil) throws -> String {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var output = [UInt8](repeating: 0, count: 512); var written = 0
        let status = output.withUnsafeMutableBufferPointer { buffer in
            action.token.withCString { actionPtr in machineID.uuidString.lowercased().withCString { machinePtr in
                if let requestID { return ("porsche-" + requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")).withCString { req in withUnsafeMutablePointer(to: &written) { MilaRustFFI.command(actionPtr, machinePtr, req, MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: $0)) } } }
                return withUnsafeMutablePointer(to: &written) { MilaRustFFI.command(actionPtr, machinePtr, nil, MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: $0)) }
            }}
        }
        guard status == 0 else { throw status == -3 ? MilaFFIError.outputTooSmall : MilaFFIError.unavailable }
        return String(decoding: output.prefix(written), as: UTF8.self)
    }

    public func classifyThreadCommand(_ line: String) throws -> MilaThreadCommandKind {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var kind = MilaThreadCommandKind.unknown
        let status = line.withCString { MilaRustFFI.threadKind($0, &kind) }
        guard status == 0 else { throw MilaFFIError.unavailable }
        return kind
    }
    public func classifyWebCommand(_ command: MilaWebCommand) throws -> MilaMachineCommandKind {
        let line: String
        switch command {
        case .show(let machineID): line = "web show \(machineID.uuidString.lowercased())"
        case .set(let machineID, let url):
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.user == nil, parsed.password == nil, parsed.fragment == nil else { throw MilaWebCommandError.invalidURL }
            line = "web set \(machineID.uuidString.lowercased()) \(url)"
        }
        let kind = try classifyMachineCommand(line)
        guard kind == (command.isSet ? .webSet : .webShow) else { throw MilaWebCommandError.rejected }
        return kind
    }

    public func classifyMachineCommand(_ line: String) throws -> MilaMachineCommandKind {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        var kind = MilaMachineCommandKind.unknown
        let status = line.withCString { MilaRustFFI.machineKind($0, &kind) }
        guard status == 0 else { throw MilaFFIError.unavailable }
        return kind
    }

    /// Validates push metadata in Rust without exposing or retaining the device token.
    /// The token is borrowed for the call and is never retained by the native layer.
    public func validatePushRegistration(provider: MilaPushProvider, environment: MilaPushEnvironment, token: String, appID: String, deployment: String, endpoint: String) throws {
        try validatePushRegistration(provider: provider.rawValue, environment: environment.rawValue, token: token, appID: appID, deployment: deployment, endpoint: endpoint)
    }

    /// Compatibility entry point for callers decoding persisted provider values.
    public func validatePushRegistration(provider: UInt8, environment: UInt8, token: String, appID: String, deployment: String, endpoint: String) throws {
        guard abiCompatible() else { throw MilaFFIError.incompatibleABI }
        let status = token.withCString { tokenPtr in appID.withCString { appPtr in deployment.withCString { deploymentPtr in endpoint.withCString { endpointPtr in MilaRustFFI.pushRegistration(provider, environment, tokenPtr, appPtr, deploymentPtr, endpointPtr) } } } }
        guard status == 0 else { throw MilaFFIError.unavailable }
    }

    public func decodeSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> [MilaSnapshotMachine] {
        _ = try validateSnapshot(data, host: host, port: port)
        let decoder = JSONDecoder()
        let object = try decoder.decode(MilaSnapshotEnvelope.self, from: data)
        return object.machines
    }

    /// @cc [owner:ghuntley,label:security] mila-apple-rust-policy
    /// Every displayed machine action MUST come from Rust for the same validated snapshot index.
    public func projectSnapshot(_ data: Data, host: String, port: UInt16? = nil) throws -> MilaValidatedSnapshot {
        let metadata = try validateSnapshot(data, host: host, port: port)
        let machines = try decodeSnapshot(data, host: host, port: port)
        let projected = try machines.enumerated().map { index, machine in
            try validateMachineDisplay(machine)
            return MilaMachinePresentation(machine: machine, actions: try machineActions(data, host: host, port: port, index: UInt32(index)))
        }
        return MilaValidatedSnapshot(machines: projected, metadata: metadata)
    }

    public func listSSHKeys() async throws -> [MilaSSHKey] {
        guard let liveSession else { throw MilaFFIError.unavailable }
        let data: Data
        do { data = try liveSession.sshKeys() } catch { throw MilaFFIError.unavailable }
        return try Self.decodeSSHKeys(data)
    }

    public func revokeSSHKey(_ key: MilaSSHKey, requestID: UUID) async throws {
        guard requestID != UUID.zero, let liveSession else { throw MilaFFIError.unavailable }
        try liveSession.revokeSSHKey(id: key.id, requestID: requestID)
    }

    public func refreshSnapshot() async throws -> MilaValidatedSnapshot {
        guard let liveSession else { throw MilaFFIError.unavailable }
        let data: Data
        do { data = try liveSession.refresh() } catch { throw MilaFFIError.unavailable }
        return try Self.projectListing(data)
    }

    /// Fetches the next bounded page; Rust returns the accumulated listing.
    public func loadMoreSnapshot() async throws -> MilaValidatedSnapshot {
        guard let liveSession else { throw MilaFFIError.unavailable }
        let data: Data
        do { data = try liveSession.readMore() } catch { throw MilaFFIError.unavailable }
        return try Self.projectListing(data)
    }

    public func checkApproval() async throws -> Data {
        guard let liveSession else { throw MilaFFIError.unavailable }
        do { return try liveSession.whoami() }
        catch { throw MilaFFIError.unavailable }
    }

    /// Projects the Rust live listing (`{"machines":[...],"has_more":bool}` with
    /// per-row `action_bits`) into presentation records.
    static func projectListing(_ data: Data) throws -> MilaValidatedSnapshot {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(MilaSnapshotEnvelope.self, from: data)
        guard envelope.machines.count <= 256 else { throw MilaFFIError.outputTooSmall }
        let metadata = MilaSnapshotMetadata(machineCount: UInt32(envelope.machines.count), savedAt: 0, hasMore: envelope.hasMore)
        let machines = try envelope.machines.enumerated().map { index, machine in
            _ = index
            try validateMachineDisplay(machine)
            // A live row without Rust policy bits presents no actions.
            return MilaMachinePresentation(machine: machine, actions: MilaMachineActions(bits: machine.actionBits ?? 0))
        }
        return MilaValidatedSnapshot(machines: machines, metadata: metadata)
    }

    static func decodeSSHKeys(_ data: Data) throws -> [MilaSSHKey] {
        guard data.count <= MilaLiveSession.commandLimit else { throw MilaFFIError.outputTooSmall }
        let decoded = try MilaPorscheEnvelope<MilaSSHKeyEnvelope>.decode(data)
        guard decoded.keys.count <= 256 else { throw MilaFFIError.outputTooSmall }
        return try decoded.keys.map { try $0.presentation() }
    }

    private func validateMachineDisplay(_ machine: MilaSnapshotMachine) throws { try Self.validateMachineDisplay(machine) }

    private static func validateMachineDisplay(_ machine: MilaSnapshotMachine) throws {
        guard machine.name.utf8.count <= 128,
              !machine.name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw MilaFFIError.outputTooSmall
        }
    }

    /// @cc [owner:ghuntley,label:security] mila-apple-no-fabricated-submission
    /// Formatting MUST NOT be reported as submission; absent an authenticated session, actions fail unavailable.
    public func submit(_ action: MilaMachineAction, machine: MilaMachinePresentation, requestID: UUID) async throws {
        guard requestID != UUID.zero else { throw MilaFFIError.unavailable }
        guard machine.actions.values.contains(action), action.isSessionLifecycle else { throw MilaFFIError.actionNotAllowed }
        _ = try formatMachineAction(action, machineID: machine.id, requestID: requestID)
        guard let liveSession else { throw MilaFFIError.unavailable }
        do {
            try liveSession.machineAction(machine: machine.id, action: action.token, requestID: requestID)
        } catch { throw MilaFFIError.unavailable }
    }

    public func resize(machine: MilaMachinePresentation, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) async throws {
        guard requestID != UUID.zero, machine.machine.write, (1...256).contains(cpu), (256...4_194_304).contains(memory), (1...16_777_216).contains(disk), let liveSession else { throw MilaFFIError.unavailable }
        do { try liveSession.machineResize(machine: machine.id, cpu: cpu, memory: memory, disk: disk, requestID: requestID) }
        catch { throw MilaFFIError.unavailable }
    }

    public func createMachine(name: String, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) async throws {
        guard requestID != UUID.zero, let liveSession, !name.isEmpty, name.utf8.count <= 128, cpu > 0, memory > 0, disk > 0 else { throw MilaFFIError.unavailable }
        do { try liveSession.machineCreate(name: name, cpu: cpu, memory: memory, disk: disk, requestID: requestID) }
        catch { throw MilaFFIError.unavailable }
    }

    public func submitShare(_ principal: MilaSharePrincipal, role: MilaShareRole?, machine: MilaMachinePresentation, remove: Bool, requestID: UUID) async throws {
        guard requestID != UUID.zero, machine.machine.write else { throw MilaMachineSharingError.unavailable }
        guard let liveSession else { throw MilaMachineSharingError.unavailable }
        do { try liveSession.shareMutation(machine: machine.id, email: principal.value, role: remove ? nil : role?.rawValue, add: !remove, requestID: requestID) }
        catch { throw MilaMachineSharingError.unavailable }
    }

    public func webEndpointProjection(machine: UUID) async throws -> MilaWebEndpointProjection {
        guard let liveSession else { throw MilaFFIError.unavailable }
        do {
            return try MilaPorscheEnvelope<MilaWebEndpointProjection>.decode(try liveSession.webShow(machine: machine))
        } catch { throw MilaFFIError.unavailable }
    }

    public func webEndpoint(machine: UUID) async throws -> MilaWebEndpoint {
        let projection = try await webEndpointProjection(machine: machine)
        return try projection.endpoint(for: machine)
    }

    public func threadAction(thread: UUID?, command: String, secondary: String? = nil, input: String? = nil, requestID: UUID? = nil) async throws -> Data {
        guard let liveSession else { throw MilaFFIError.unavailable }
        do { return try liveSession.threadAction(thread: thread, command: command, secondary: secondary, input: input, requestID: requestID) }
        catch { throw MilaFFIError.unavailable }
    }

    private func abiCompatible() -> Bool {
        var version = MilaFfiAbiVersion(major: 0, minor: 0)
        return MilaRustFFI.getVersion(&version) == 0 && version.major == 1
    }
}

/// @cc [owner:ghuntley,label:protocol] mila-apple-porsche-envelope
/// Porsche `--json` reads arrive as `{"version":1,"status":"succeeded","result":T}`.
/// Decoders MUST accept that envelope (and the bare `T` some Rust projections
/// emit) and MUST refuse any other status rather than presenting partial data.
struct MilaPorscheEnvelope<Value: Decodable>: Decodable {
    let value: Value
    private enum Keys: String, CodingKey { case version, status, result }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.status) {
            guard try container.decode(Int.self, forKey: .version) == 1,
                  try container.decode(String.self, forKey: .status) == "succeeded" else {
                throw MilaFFIError.unavailable
            }
            value = try container.decode(Value.self, forKey: .result)
        } else {
            value = try Value(from: decoder)
        }
    }
    static func decode(_ data: Data) throws -> Value { try JSONDecoder().decode(Self.self, from: data).value }
}

/**
 * @cc [owner:ghuntley,label:security] mila-apple-ffi-typed-boundary
 * The Apple UI MUST exchange typed requests and validated snapshot projections with the Rust
 * adapter; raw pointers, credentials, and terminal bytes MUST NOT appear in this interface.
 */
private struct MilaSSHKeyEnvelope: Codable {
    let keys: [MilaSSHKeyWire]
}
private struct MilaSSHKeyWire: Codable {
    let id: UUID; let label: String?; let algorithm: String; let fingerprint: String
    func presentation() throws -> MilaSSHKey {
        guard algorithm.utf8.count <= 64,
              let key = MilaSSHKey.validated(id: id, fingerprint: fingerprint, algorithm: algorithm, label: label) else { throw MilaFFIError.invalidRoute }
        return key
    }
}

private struct MilaSnapshotEnvelope: Codable {
    let machines: [MilaSnapshotMachine]
    let hasMore: Bool
    enum CodingKeys: String, CodingKey { case machines, hasMore = "has_more" }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        machines = try values.decode([MilaSnapshotMachine].self, forKey: .machines)
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

public protocol MilaFFIAdapter: Sendable {
    func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse
    func refreshSnapshot() async throws -> MilaValidatedSnapshot
    func loadMoreSnapshot() async throws -> MilaValidatedSnapshot
    /// Ends the authenticated session owned by this adapter, if any.
    func close()
    func checkApproval() async throws -> Data
    func listSSHKeys() async throws -> [MilaSSHKey]
    func revokeSSHKey(_ key: MilaSSHKey, requestID: UUID) async throws
    func submit(_ action: MilaMachineAction, machine: MilaMachinePresentation, requestID: UUID) async throws
    func resize(machine: MilaMachinePresentation, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) async throws
    func createMachine(name: String, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) async throws
    func submitShare(_ principal: MilaSharePrincipal, role: MilaShareRole?, machine: MilaMachinePresentation, remove: Bool, requestID: UUID) async throws
    func webEndpointProjection(machine: UUID) async throws -> MilaWebEndpointProjection
    func webEndpoint(machine: UUID) async throws -> MilaWebEndpoint
    func threadAction(thread: UUID?, command: String, secondary: String?, input: String?, requestID: UUID?) async throws -> Data
    func classifyThreadCommand(_ line: String) throws -> MilaThreadCommandKind
    func classifyMachineCommand(_ line: String) throws -> MilaMachineCommandKind
    func classifyWebCommand(_ command: MilaWebCommand) throws -> MilaMachineCommandKind
    func validatePushRegistration(provider: UInt8, environment: UInt8, token: String, appID: String, deployment: String, endpoint: String) throws
}

public extension MilaFFIAdapter {
    func checkApproval() async throws -> Data { throw MilaFFIError.unavailable }
    func listSSHKeys() async throws -> [MilaSSHKey] { throw MilaFFIError.unavailable }
    func revokeSSHKey(_ key: MilaSSHKey, requestID: UUID) async throws { _ = key; _ = requestID; throw MilaFFIError.unavailable }
    func refreshSnapshot() async throws -> MilaValidatedSnapshot { throw MilaFFIError.unavailable }
    func loadMoreSnapshot() async throws -> MilaValidatedSnapshot { throw MilaFFIError.unavailable }
    func close() {}
    func submit(_ action: MilaMachineAction, machine: MilaMachinePresentation, requestID: UUID) async throws { throw MilaFFIError.unavailable }
    func resize(machine: MilaMachinePresentation, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) async throws { throw MilaFFIError.unavailable }
    func createMachine(name: String, cpu: UInt32, memory: UInt64, disk: UInt64, requestID: UUID) async throws { throw MilaFFIError.unavailable }
    func submitShare(_ principal: MilaSharePrincipal, role: MilaShareRole?, machine: MilaMachinePresentation, remove: Bool, requestID: UUID) async throws { _ = principal; _ = role; _ = machine; _ = remove; _ = requestID; throw MilaMachineSharingError.unavailable }
    func webEndpointProjection(machine: UUID) async throws -> MilaWebEndpointProjection { _ = machine; throw MilaFFIError.unavailable }
    func webEndpoint(machine: UUID) async throws -> MilaWebEndpoint { _ = machine; throw MilaFFIError.unavailable }
    func threadAction(thread: UUID?, command: String, secondary: String? = nil, input: String? = nil, requestID: UUID? = nil) async throws -> Data { _ = thread; _ = command; _ = secondary; _ = input; _ = requestID; throw MilaFFIError.unavailable }
    func classifyThreadCommand(_ line: String) throws -> MilaThreadCommandKind { _ = line; throw MilaFFIError.unavailable }
    func classifyMachineCommand(_ line: String) throws -> MilaMachineCommandKind { _ = line; throw MilaFFIError.unavailable }
    func classifyWebCommand(_ command: MilaWebCommand) throws -> MilaMachineCommandKind { _ = command; throw MilaFFIError.unavailable }
    func validatePushRegistration(provider: UInt8, environment: UInt8, token: String, appID: String, deployment: String, endpoint: String) throws { throw MilaFFIError.unavailable }
}

/// Explicit placeholder until generated UniFFI bindings are linked by the host application.
public struct UnavailableMilaFFIAdapter: MilaFFIAdapter, Sendable {
    public init() {}

    public func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse {
        _ = request
        throw MilaFFIError.unavailable
    }
}
