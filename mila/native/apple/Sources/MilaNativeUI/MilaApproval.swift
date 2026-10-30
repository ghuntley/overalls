import Foundation
import Combine

/// The bounded result of the authenticated `whoami --json` approval envelope.
public struct MilaApprovalInfo: Equatable, Sendable {
    public let url: URL
    public let fingerprint: String
    public init(url: URL, fingerprint: String) { self.url = url; self.fingerprint = fingerprint }
}

public enum MilaApprovalResult: Equatable, Sendable {
    case approved
    case pending(MilaApprovalInfo)
    /// The deployment answered with a terminal refusal (`unauthorized`, `forbidden`).
    case refused
    /// The deployment answered `temporarily_unavailable`; the same session may retry.
    case unavailable
}

/// @cc [owner:ghuntley,label:security;protocol] mila-apple-whoami-envelope
/// Decodes the Porsche/Marshall `whoami --json` wire: `succeeded` (approved),
/// `approval_required` with `fingerprint` and `approval_url`, or `error` with a
/// reason. The approval URL MUST be credential- and fragment-free HTTPS on the
/// selected deployment host; any other shape is a protocol failure.
public enum MilaApprovalDecoder {
    public static func decode(_ data: Data, expectedHost: String? = nil) throws -> MilaApprovalResult {
        guard data.count <= 64 * 1024 else { throw MilaFFIError.outputTooSmall }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let value = object as? [String: Any], value["version"] as? Int == 1,
              let status = value["status"] as? String else { throw MilaFFIError.incompatibleABI }
        switch status {
        case "succeeded":
            guard value["result"] is [String: Any] else { throw MilaFFIError.incompatibleABI }
            return .approved
        case "approval_required":
            guard let rawURL = value["approval_url"] as? String, rawURL.utf8.count <= 2048,
                  let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil, url.fragment == nil, let host = url.host, !host.isEmpty,
                  let fingerprint = value["fingerprint"] as? String, validFingerprint(fingerprint),
                  expectedHost.map({ host.caseInsensitiveCompare($0) == .orderedSame }) ?? true
            else { throw MilaFFIError.incompatibleABI }
            return .pending(MilaApprovalInfo(url: url, fingerprint: fingerprint))
        case "error":
            switch value["error"] as? String {
            case "unauthorized", "forbidden": return .refused
            case "temporarily_unavailable": return .unavailable
            default: throw MilaFFIError.incompatibleABI
            }
        default: throw MilaFFIError.incompatibleABI
        }
    }

    /// OpenSSH fingerprints such as `SHA256:<base64>`: bounded, printable, no whitespace.
    static func validFingerprint(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 &&
            !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.properties.generalCategory == .control || !$0.isASCII }
    }
}

/// Approval polling deliberately reuses the authenticated adapter/session.
@MainActor public final class MilaApprovalController: ObservableObject {
    @Published public private(set) var result: MilaApprovalResult?
    @Published public private(set) var error = false
    public init() {}
    public func inspect(_ adapter: any MilaFFIAdapter, expectedHost: String) async {
        do { result = try MilaApprovalDecoder.decode(await adapter.checkApproval(), expectedHost: expectedHost); error = false }
        catch { self.error = true }
    }
}

public enum MilaSignInFailure: Equatable, Sendable {
    /// The SSH/trust connection could not be established.
    case unreachable
    case refused
    case protocolError
}

public enum MilaSignInPhase: Equatable, Sendable {
    case signedOut
    case connecting(UUID)
    case awaitingApproval(UUID, MilaApprovalInfo)
    case signedIn(UUID, generation: UInt64)
    case expired(UUID)
    case failed(UUID, MilaSignInFailure)
}

/// @cc [owner:ghuntley,label:security] mila-apple-sign-in-lifecycle
/// Sign-in connects one authenticated Rust session, then polls `whoami` on that
/// same session (Porsche binds a pending approval to its SSH connection). Only
/// a `succeeded` envelope enters `signedIn`; approval expires after a bounded
/// lifetime. Every poll result is fenced to the session generation that issued
/// it, and refusal, expiry, protocol failure and sign-out close the session.
@MainActor public final class MilaSignInController: ObservableObject {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    @Published public private(set) var phase: MilaSignInPhase = .signedOut
    private let session: MilaDeploymentSessionController
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let pollInterval: Duration
    private let approvalLifetime: TimeInterval
    private let maxTransientRetries: Int
    private var task: Task<Void, Never>?

    public init(session: MilaDeploymentSessionController,
                pollInterval: Duration = .seconds(3),
                approvalLifetime: TimeInterval = 600,
                maxTransientRetries: Int = 5,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.session = session
        self.pollInterval = pollInterval
        self.approvalLifetime = approvalLifetime
        self.maxTransientRetries = maxTransientRetries
        self.now = now
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    /// The authenticated adapter, only while the approved generation is current.
    public var adapter: (any MilaFFIAdapter)? {
        guard case .signedIn(_, let generation) = phase, generation == session.generation else { return nil }
        return session.adapter()
    }

    public var isSignedIn: Bool { adapter != nil }

    /// The validated approval page for the pending generation, if any.
    public var approvalURL: URL? {
        if case .awaitingApproval(_, let info) = phase { return info.url }
        return nil
    }

    /// Starts a fresh generation and resolves it to signed-in, expired or failed.
    public func signIn(_ deployment: MilaDeployment) {
        task?.cancel()
        phase = .connecting(deployment.id)
        guard session.signIn(deployment), let adapter = session.adapter() else {
            phase = .failed(deployment.id, .unreachable)
            return
        }
        let generation = session.generation
        task = Task { [weak self] in await self?.poll(adapter, deployment: deployment, generation: generation) }
    }

    /// Restarts sign-in for the selected deployment with a new generation.
    public func reconnect() {
        guard let deployment = session.selectedDeployment else { return }
        signIn(deployment)
    }

    public func signOut() {
        task?.cancel(); task = nil
        session.signOut()
        phase = .signedOut
    }

    /// Waits for the current poll to settle; used by tests and the journey mode.
    public func settle() async { await task?.value }

    private func current(_ generation: UInt64) -> Bool { !Task.isCancelled && session.generation == generation }

    private func poll(_ adapter: any MilaFFIAdapter, deployment: MilaDeployment, generation: UInt64) async {
        var issuedAt: Date?
        var transient = 0
        while current(generation) {
            let result: MilaApprovalResult
            do {
                result = try MilaApprovalDecoder.decode(try await adapter.checkApproval(), expectedHost: deployment.host)
            } catch MilaFFIError.unavailable {
                // Transport failure on the bound session: approval cannot complete on it.
                guard current(generation) else { return }
                return end(deployment.id, .failed(deployment.id, .unreachable))
            } catch {
                guard current(generation) else { return }
                return end(deployment.id, .failed(deployment.id, .protocolError))
            }
            guard current(generation) else { return }
            switch result {
            case .approved:
                phase = .signedIn(deployment.id, generation: generation)
                return
            case .refused:
                return end(deployment.id, .failed(deployment.id, .refused))
            case .unavailable:
                transient += 1
                if transient > maxTransientRetries { return end(deployment.id, .failed(deployment.id, .unreachable)) }
            case .pending(let info):
                let started = issuedAt ?? now()
                issuedAt = started
                if now().timeIntervalSince(started) >= approvalLifetime { return end(deployment.id, .expired(deployment.id)) }
                phase = .awaitingApproval(deployment.id, info)
            }
            do { try await sleep(pollInterval) } catch { return }
        }
    }

    /// Terminal outcomes close the session so a stale approval cannot be reused.
    private func end(_ deployment: UUID, _ outcome: MilaSignInPhase) {
        session.signOut()
        phase = outcome
    }
}
