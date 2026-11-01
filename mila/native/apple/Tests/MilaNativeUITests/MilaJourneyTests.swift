import CryptoKit
import Foundation
import Security
import XCTest
@testable import MilaNativeUI

/// Trust reconciliation through the linked Rust ABI, with the shared transport fixture.
final class MilaTrustDocumentTests: XCTestCase {
    private func ca(_ index: Int) throws -> String {
        // Tests/MilaNativeUITests/<file> -> mila/native/apple -> mila
        let mila = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: mila.appendingPathComponent("rust/mila-transport/tests/fixtures/ssh_host_certificates.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let certificates = try XCTUnwrap(root["certificates"] as? [[String: Any]])
        return try XCTUnwrap(certificates[index]["ca"] as? String)
    }

    private func trust(_ ca: String, retirement: UInt64, host: String = "overalls.example") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "ca": ca, "management_host": host, "zone": "apps.overalls.example", "retirement": retirement])
    }

    func testReconcileAcceptsFetchedTrustForHostAndRefusesForeignHost() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let fetched = try trust(try ca(0), retirement: 3_000)
        let selected = try MilaTrustDocument.reconcile(pinned: nil, fetched: fetched, host: "overalls.example", now: now)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: selected) as? [String: Any])
        XCTAssertEqual(value["retirement"] as? Int, 3_000)
        XCTAssertThrowsError(try MilaTrustDocument.reconcile(pinned: nil, fetched: fetched, host: "other.example", now: now))
        XCTAssertThrowsError(try MilaTrustDocument.reconcile(pinned: nil, fetched: Data("{}".utf8), host: "overalls.example", now: now))
        let pinned = try MilaTrustDocument.reconcile(pinned: selected, fetched: nil, host: "overalls.example", now: now)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: pinned) as? [String: Any])["ca"] as? String, try ca(0))
        XCTAssertEqual(MilaTrustDocument.url(host: "localhost", port: 8443)?.absoluteString, "https://localhost:8443/bin/ssh-trust.json")
        XCTAssertEqual(MilaTrustDocument.url(host: "overalls.example")?.absoluteString, "https://overalls.example/bin/ssh-trust.json")
    }
}

/// Fixture descriptor v1 (see the hermetic Marshall+Porsche journey fixture).
struct MilaJourneyDescriptor: Decodable {
    struct Deployment: Decodable { let host: String; let sshPort: UInt16; let httpsPort: UInt16
        enum CodingKeys: String, CodingKey { case host, sshPort = "ssh_port", httpsPort = "https_port" } }
    struct TLS: Decodable { let caPEM: String; let serverName: String
        enum CodingKeys: String, CodingKey { case caPEM = "ca_pem", serverName = "server_name" } }
    struct Approver: Decodable { let url: URL; let bearerToken: String; let fixtureURL: URL?
        enum CodingKeys: String, CodingKey { case url, bearerToken = "bearer_token", fixtureURL = "fixture_url" } }
    struct Seed: Decodable { let machineName: String; let sharePrincipal: String; let machineID: UUID?
        /// The guest-backed terminal machine, when the fixture runs its terminal stand-in.
        let terminalMachineID: UUID?; let terminalMachineName: String?
        enum CodingKeys: String, CodingKey { case machineName = "machine_name", sharePrincipal = "share_principal", machineID = "machine_id",
                                             terminalMachineID = "terminal_machine_id", terminalMachineName = "terminal_machine_name" } }
    let version: Int
    let deployment: Deployment
    let tls: TLS
    let approver: Approver
    let seed: Seed

    static func load(_ path: String) throws -> MilaJourneyDescriptor {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 64 * 1024 else { throw MilaTrustError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, !value.deployment.host.isEmpty, value.deployment.sshPort > 0, value.deployment.httpsPort > 0,
              value.tls.caPEM.contains("BEGIN CERTIFICATE"), value.approver.url.scheme == "https" || value.approver.url.scheme == "http",
              !value.approver.bearerToken.isEmpty, !value.seed.machineName.isEmpty,
              value.seed.terminalMachineName.map({ !$0.isEmpty && $0.utf8.count <= 63 }) ?? true,
              value.approver.fixtureURL.map({ $0.scheme == "https" && $0.absoluteString.hasSuffix("/fixture/") }) ?? true else { throw MilaTrustError.invalid }
        return value
    }

    func anchor() throws -> SecCertificate {
        let body = tls.caPEM.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw MilaTrustError.invalid
        }
        return certificate
    }
}

/// Validates HTTPS only against the fixture CA and server name.
private final class MilaPinnedTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchor: SecCertificate
    let serverName: String
    init(anchor: SecCertificate, serverName: String) { self.anchor = anchor; self.serverName = serverName }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, serverName as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Disposable software P-256 key for the fixture journey only. Production
/// custody remains Secure Enclave (`MilaDeviceSigner`); this lives in the test target.
private final class MilaFixtureSigner: MilaSessionSigner, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()
    var openSSHPublicKey: String {
        var blob = Data()
        for field in [Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), key.publicKey.x963Representation] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return "ecdsa-sha2-nistp256 " + blob.base64EncodedString()
    }
    func sign(message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// Results of the fixture's closed stand-in actions (`POST <fixture_url><action>`).
struct MilaFixtureObserved: Decodable { let observedState: String
    enum CodingKeys: String, CodingKey { case observedState = "observed_state" } }
struct MilaFixtureThreadCreated: Decodable { let threadID: UUID; let status: String
    enum CodingKeys: String, CodingKey { case threadID = "thread_id", status } }
struct MilaFixtureThreadReady: Decodable { let status: String; let machineID: UUID?
    enum CodingKeys: String, CodingKey { case status, machineID = "machine_id" } }
struct MilaFixtureQuestion: Decodable { let questionID: UUID
    enum CodingKeys: String, CodingKey { case questionID = "question_id" } }
struct MilaFixtureProposal: Decodable { let planID: UUID
    enum CodingKeys: String, CodingKey { case planID = "plan_id" } }

/// The closed set of fixture hooks; each carries only its canonical UUID input.
enum MilaFixtureHook {
    case observe(machine: UUID)
    case threadCreate
    case threadReady(thread: UUID)
    case threadQuestion(thread: UUID)
    case threadProposal(thread: UUID)

    var action: String {
        switch self {
        case .observe: "observe"; case .threadCreate: "thread-create"; case .threadReady: "thread-ready"
        case .threadQuestion: "thread-question"; case .threadProposal: "thread-proposal"
        }
    }

    var body: [String: String] {
        switch self {
        case .observe(let machine): ["machine_id": machine.uuidString.lowercased()]
        case .threadCreate: [:]
        case .threadReady(let thread), .threadQuestion(let thread), .threadProposal(let thread): ["thread_id": thread.uuidString.lowercased()]
        }
    }
}

/// The `MilaLiveSession` behind the journey's adapter, so steps without an
/// adapter method (named terminal attach, `request show`, `show`, `web set`)
/// use the same authenticated Rust session the app model holds.
final class MilaFixtureLiveSession: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MilaLiveSession?
    var current: MilaLiveSession? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// The machine detail `show MACHINE --json` reports (requested state and size).
struct MilaFixtureMachineDetail: Decodable {
    let id: UUID
    let desiredState: String
    let vcpu: UInt32?
    let memoryBytes: UInt64?
    enum CodingKeys: String, CodingKey { case id, desiredState = "desired_state", vcpu, memoryBytes = "memory_bytes" }
}

/// A signed-in fixture journey: the pinned HTTPS client and the app model.
@MainActor struct MilaFixtureJourney {
    let descriptor: MilaJourneyDescriptor
    let http: URLSession
    let model: MilaAppModel
    let env: MilaIsolatedDefaults
    let live: MilaFixtureLiveSession

    /// Loads the descriptor named by `MILA_JOURNEY_DESCRIPTOR`, or skips.
    static func descriptor() throws -> MilaJourneyDescriptor {
        guard let path = ProcessInfo.processInfo.environment["MILA_JOURNEY_DESCRIPTOR"], !path.isEmpty else {
            throw XCTSkip("MILA_JOURNEY_DESCRIPTOR is not set; the live fixture journey is not configured")
        }
        return try MilaJourneyDescriptor.load(path)
    }

    /// Fetches and reconciles trust, then signs in through the approver.
    static func signIn(_ descriptor: MilaJourneyDescriptor) async throws -> MilaFixtureJourney {
        let tls = MilaPinnedTLSDelegate(anchor: try descriptor.anchor(), serverName: descriptor.tls.serverName)
        let http = URLSession(configuration: .ephemeral, delegate: tls, delegateQueue: nil)
        let trustURL = try XCTUnwrap(MilaTrustDocument.url(host: descriptor.deployment.host, port: descriptor.deployment.httpsPort))
        let (fetched, response) = try await http.data(from: trustURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let trust = try MilaTrustDocument.reconcile(pinned: nil, fetched: fetched, host: descriptor.deployment.host)

        let env = MilaIsolatedDefaults()
        let deployment = MilaDeployment(host: descriptor.deployment.host, port: descriptor.deployment.sshPort, trust: trust)
        XCTAssertTrue(env.store.upsert(deployment))
        let signer = MilaFixtureSigner()
        let live = MilaFixtureLiveSession()
        let sessions = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { value in
            let session = try MilaLiveSession(trust: value.trust, host: value.host, port: value.port, sessionSigner: signer)
            live.current = session
            return LinkedMilaFFIAdapter(session: session)
        }
        let model = MilaAppModel(session: sessions, signIn: MilaSignInController(session: sessions, pollInterval: .seconds(1), approvalLifetime: 120))
        model.signIn.signIn(deployment)

        let approvalSeen = await eventually({ model.signIn.approvalURL != nil || model.signIn.isSignedIn }, iterations: 6_000)
        XCTAssertTrue(approvalSeen, "phase: \(model.signIn.phase)")
        if case .awaitingApproval(_, let info) = model.signIn.phase {
            XCTAssertEqual(info.url.host, descriptor.deployment.host)
            var request = URLRequest(url: descriptor.approver.url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(descriptor.approver.bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["approval_url": info.url.absoluteString, "fingerprint": info.fingerprint])
            let (_, approved) = try await http.data(for: request)
            XCTAssertTrue((200..<300).contains((approved as? HTTPURLResponse)?.statusCode ?? 0))
        }
        await model.signIn.settle()
        guard case .signedIn = model.signIn.phase else {
            http.invalidateAndCancel(); env.tearDown()
            // A configured fixture that cannot sign in is a failed journey, not a skip.
            XCTFail("sign-in ended in \(model.signIn.phase)")
            throw MilaJourneyFailure.signIn
        }
        await assertEventually({ model.machines.state == .loaded || model.machines.state == .failed }, iterations: 6_000)
        XCTAssertEqual(model.machines.state, .loaded)
        return MilaFixtureJourney(descriptor: descriptor, http: http, model: model, env: env, live: live)
    }

    func finish() {
        model.signIn.signOut()
        XCTAssertEqual(model.machines.state, .signedOut)
        http.invalidateAndCancel()
        env.tearDown()
    }

    /// Runs one fixture stand-in action and decodes its result.
    func hook<Result: Decodable>(_ hook: MilaFixtureHook, as type: Result.Type) async throws -> Result {
        guard let base = descriptor.approver.fixtureURL else {
            throw XCTSkip("the fixture descriptor has no approver.fixture_url")
        }
        var request = URLRequest(url: base.appendingPathComponent(hook.action))
        request.httpMethod = "POST"
        request.setValue("Bearer \(descriptor.approver.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: hook.body)
        request.timeoutInterval = 300
        let (data, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, data.count <= 64 * 1024 else { throw MilaJourneyFailure.hook(action: hook.action, status: status) }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// The seed machine as currently listed.
    func seedMachine() async throws -> MilaMachinePresentation {
        await model.machines.refresh()
        let name = descriptor.seed.machineName
        return try XCTUnwrap(model.machines.machines.first { $0.machine.name == name }, "seed machine \(name) is not listed")
    }

    // MARK: Steps shared with the Windows (`JourneyPages.cs`) and Linux (`journey.rs`) journeys.

    /// Marshall's closed refusals that mean "busy, retry with a fresh request ID".
    static let busyRefusals: Set<String> = ["vm_busy", "temporarily_unavailable", "workload_not_stable"]
    /// Refusals a terminal open answers while the guest terminal is still coming up.
    static let terminalReadiness: Set<String> = ["terminal_open_pending", "terminal_unavailable", "temporarily_unavailable"]

    /// A machine name unique to this run, in Rust's accepted alphabet.
    static func machineName(_ purpose: String) -> String {
        "mila-apple-\(purpose)-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }

    /// The authenticated Rust session behind the model's adapter.
    func session() throws -> MilaLiveSession {
        try XCTUnwrap(live.current, "no live session")
    }

    /// The session's most recent closed refusal code (`{"error": …}`), if any.
    func refusal() -> String? {
        guard let json = model.adapter?.lastRefusal(), let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["error"] as? String
    }

    /// The named machine in a freshly loaded listing; nil only when a loaded listing lacks it.
    func listed(_ name: String) async throws -> MilaMachinePresentation? {
        await model.machines.refresh()
        _ = await eventually({ model.machines.state != .loading }, iterations: 2_000)
        guard model.machines.state == .loaded else { throw MilaJourneyFailure.step("machine listing \(model.machines.state)") }
        return model.machines.machines.first { $0.machine.name == name }
    }

    /// Polls `check` until it yields a value or `seconds` pass.
    func until<Value>(_ name: String, seconds: Double = 60, _ check: () async throws -> Value?) async throws -> Value {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let value = try await check() { return value }
            guard Date() < deadline else { throw MilaJourneyFailure.step("\(name): timeout") }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Runs one mutation, retrying a closed busy refusal with a fresh request ID
    /// until the step deadline; any other failure fails the step. Returns the
    /// admitted request ID.
    func submit(_ name: String, _ operation: (UUID) async throws -> Void) async throws -> UUID {
        let deadline = Date().addingTimeInterval(60)
        while true {
            let request = UUID()
            do {
                try await operation(request)
                return request
            } catch let failure as MilaJourneyFailure {
                throw failure
            } catch {
                let reason = refusal()
                guard let reason, Self.busyRefusals.contains(reason), Date() < deadline else {
                    throw MilaJourneyFailure.step("\(name): \(reason ?? String(describing: error))")
                }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The fixture's provisioner stand-in observes `machine`'s desired state.
    func observe(_ machine: UUID) async throws -> String {
        try await hook(.observe(machine: machine), as: MilaFixtureObserved.self).observedState
    }

    /// Creates a machine through the adapter call the SwiftUI create sheet makes, and waits for it to be listed.
    func create(_ name: String) async throws -> MilaMachinePresentation {
        let adapter = try XCTUnwrap(model.adapter)
        _ = try await submit("lifecycle create") { request in
            try await adapter.createMachine(name: name, cpu: 1, memory: 512, disk: 2, requestID: request)
        }
        return try await until("lifecycle create") { try await listed(name) }
    }

    /// Submits one lifecycle action through `MilaMachineWorkflow`, as the machine
    /// page does; the action must be one the Rust projection offers for the
    /// machine's current listing row. Returns the admitted request ID.
    func lifecycle(_ action: MilaMachineAction, name: String) async throws -> UUID {
        let adapter = try XCTUnwrap(model.adapter)
        return try await submit("lifecycle \(action)") { request in
            guard let machine = try await listed(name) else { throw MilaJourneyFailure.step("lifecycle \(action): \(name) is not listed") }
            guard machine.actions.values.contains(action) else {
                throw MilaJourneyFailure.step("lifecycle \(action) is not offered for \(machine.machine.desiredState)/\(machine.machine.observedState ?? "none")")
            }
            let workflow = MilaMachineWorkflow(adapter: adapter)
            workflow.submit(action, machine: machine, requestID: request)
            await workflow.settle()
            guard case .applied(_, let applied) = workflow.state, applied == action else {
                throw MilaSessionError.unavailable
            }
        }
    }

    /// The `request show` receipt reports the request accepted or succeeded
    /// (the receipt's own status or its result's, as the Linux and Windows journeys read it).
    func requestAdmitted(_ request: UUID) throws -> Bool {
        let data = try session().requestShow(requestID: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        func admitted(_ value: Any?) -> Bool {
            guard let status = (value as? [String: Any])?["status"] as? String else { return false }
            return status == "accepted" || status == "succeeded"
        }
        return admitted(root) || admitted(root["result"])
    }

    /// `show MACHINE`, bound to the requested machine.
    func machineDetail(_ machine: UUID) throws -> MilaFixtureMachineDetail {
        let detail = try MilaPorscheEnvelope<MilaFixtureMachineDetail>.decode(try session().machineShow(machine: machine))
        guard detail.id == machine else { throw MilaJourneyFailure.step("machine show answered for another machine") }
        return detail
    }

    /// Best-effort removal of a machine this run created: observe it (an open
    /// operation keeps it busy) and ask to delete it until the step deadline.
    func remove(_ machine: UUID) async {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            _ = try? await observe(machine)
            if (try? session().machineAction(machine: machine, action: "rm", requestID: UUID())) != nil { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Reads the PTY until its output contains `wanted`; a closed stream or the deadline fails the step.
    func read(_ terminal: UInt64, until wanted: String, step: String, seconds: Double = 60) throws {
        let session = try self.session()
        var seen = Data()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            switch try session.terminalRead(terminal, waitMilliseconds: 250) {
            case .data(let chunk):
                seen.append(chunk)
                if seen.count > 512 * 1024 { seen = Data(seen.suffix(256 * 1024)) }
                if String(decoding: seen, as: UTF8.self).contains(wanted) { return }
            case .idle:
                continue
            case .closed:
                throw MilaJourneyFailure.step("\(step): stream closed")
            }
        }
        throw MilaJourneyFailure.step("\(step): timeout")
    }
}

enum MilaJourneyFailure: Error, Equatable { case signIn, hook(action: String, status: Int), step(String) }

/// Reports one completed journey step on stdout, where `swift test` shows it in
/// the CI log; the same `journey: <step> ok` form as the Windows journey.
func journeyStep(_ name: String) { print("journey: \(name) ok") }

private extension Data {
    /// Unpadded base64url, the encoding of Susan push keys and X25519 poke keys.
    var base64URLUnpadded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func random(count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }) }
}

/// The CI runner's `swift test` process has no app bundle, so UserNotifications
/// cannot be asked. The journey grants (stand-in); the refusal path is proven by
/// `MilaNotificationsTests.testRegistrationIsRefusedWithoutUserNotificationsAuthorization`.
private struct MilaJourneyGrantedAuthorization: MilaNotificationAuthorizing {
    func requestAuthorization() async -> Bool { true }
}

/// A disposable X25519 poke key for the journey only; it lives in the test target.
private struct MilaJourneyPokeKey: MilaPokeKeySource {
    let encoded = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLUnpadded
    func publicKey(deployment: String) -> String? { _ = deployment; return encoded }
}

/// The fixture has no Susan: a key-issuance reply in Susan's shape (stand-in),
/// as the Android, Windows and headless journeys use. It first checks that the
/// Rust-encoded request is Susan's closed APNs body, so a wrong body fails here.
private struct MilaJourneyStandInSusan: MilaSusanKeyIssuing {
    struct UnexpectedBody: Error {}
    func issue(_ body: Data) async throws -> MilaSusanKeyReply {
        guard let request = try JSONSerialization.jsonObject(with: body) as? [String: String],
              Set(request.keys) == ["provider", "token", "app_id", "environment", "deployment"],
              request["provider"] == "apns", request["app_id"] == MilaApplePushRegistration.appID,
              request["environment"] == "development" else { throw UnexpectedBody() }
        let reply = try JSONSerialization.data(withJSONObject: [
            "push_key": Data.random(count: 48).base64URLUnpadded,
            "key_id": "mila-apple-journey",
            "expires_at": "2099-01-01T00:00:00Z",
        ])
        return MilaSusanKeyReply(status: 201, body: reply)
    }
}

/// End-to-end journeys against the hermetic fixture. They run only when
/// `MILA_JOURNEY_DESCRIPTOR` names a descriptor file; otherwise skipped.
@MainActor final class MilaFixtureJourneyTests: XCTestCase {
    func testSignInApprovalListingShareAndKeysAgainstFixture() async throws {
        let journey = try await MilaFixtureJourney.signIn(try MilaFixtureJourney.descriptor())
        defer { journey.finish() }
        let model = journey.model
        let machine = try await journey.seedMachine()
        if let seeded = journey.descriptor.seed.machineID { XCTAssertEqual(machine.id, seeded) }

        let sharing = MilaMachineSharingController(adapter: try XCTUnwrap(model.adapter))
        sharing.setSession(signedIn: true, machine: machine)
        sharing.submit(principal: journey.descriptor.seed.sharePrincipal, role: .viewer)
        await assertEventually({ if case .submitting = sharing.state { return false }; return true }, iterations: 6_000)
        guard case .applied(_, _, false) = sharing.state else { return XCTFail("share add: \(sharing.state)") }
        sharing.submit(principal: journey.descriptor.seed.sharePrincipal, remove: true)
        await assertEventually({ if case .submitting = sharing.state { return false }; return true }, iterations: 6_000)
        guard case .applied(_, _, true) = sharing.state else { return XCTFail("share remove: \(sharing.state)") }

        let keys = try await XCTUnwrap(model.adapter).listSSHKeys()
        XCTAssertFalse(keys.isEmpty, "the approved device key is listed")
    }

    /// Stop then start the seed machine through the UI workflow. The fixture's
    /// `observe` hook stands in for the absent provisioner after each intent, so
    /// this proves recorded lifecycle intent, not guest execution.
    func testStopAndStartRecordLifecycleIntentAgainstFixture() async throws {
        let journey = try await MilaFixtureJourney.signIn(try MilaFixtureJourney.descriptor())
        defer { journey.finish() }
        let adapter = try XCTUnwrap(journey.model.adapter)
        var machine = try await journey.seedMachine()
        _ = try await journey.hook(.observe(machine: machine.id), as: MilaFixtureObserved.self)
        for (action, desired) in [(MilaMachineAction.stop, "stopped"), (.start, "running")] {
            machine = try await journey.seedMachine()
            XCTAssertTrue(machine.actions.values.contains(action), "\(action) is not offered for \(machine.machine.desiredState)")
            let workflow = MilaMachineWorkflow(adapter: adapter)
            workflow.submit(action, machine: machine)
            await workflow.settle()
            guard case .applied(_, let applied) = workflow.state, applied == action else { return XCTFail("\(action): \(workflow.state)") }
            let observed = try await journey.hook(.observe(machine: machine.id), as: MilaFixtureObserved.self)
            XCTAssertEqual(observed.observedState, desired)
            machine = try await journey.seedMachine()
            XCTAssertEqual(machine.machine.desiredState, desired)
        }
    }

    /// List, prompt, answer a question and approve a plan through the threads
    /// controller; the fixture hooks stand in for the agent's question and plan.
    func testThreadPromptAnswerAndPlanApprovalAgainstFixture() async throws {
        let journey = try await MilaFixtureJourney.signIn(try MilaFixtureJourney.descriptor())
        defer { journey.finish() }
        let threads = journey.model.threads
        let created = try await journey.hook(.threadCreate, as: MilaFixtureThreadCreated.self)
        let ready = try await journey.hook(.threadReady(thread: created.threadID), as: MilaFixtureThreadReady.self)
        XCTAssertEqual(ready.status, "ready")
        let thread = created.threadID

        await threads.list()
        XCTAssertEqual(threads.state, .loaded)
        XCTAssertTrue(threads.threads.contains { $0.id == thread }, "created thread is listed")

        await threads.perform(.prompt(thread: thread, text: "Report the hostname please"))
        guard case .applied = threads.mutation else { return XCTFail("prompt: \(threads.mutation)") }

        let question = try await journey.hook(.threadQuestion(thread: thread), as: MilaFixtureQuestion.self)
        await threads.show(thread)
        XCTAssertEqual(threads.detail?.pendingQuestion?.id, question.questionID)
        await threads.perform(.answer(thread: thread, question: question.questionID, text: #"{"approach":{"selected":"First","text":""}}"#))
        guard case .applied = threads.mutation else { return XCTFail("answer: \(threads.mutation)") }

        let plan = try await journey.hook(.threadProposal(thread: thread), as: MilaFixtureProposal.self)
        await threads.show(thread)
        XCTAssertEqual(threads.detail?.latestPlan?.id, plan.planID)
        await threads.perform(.planApprove(thread: thread, plan: plan.planID))
        guard case .applied = threads.mutation else { return XCTFail("plan approve: \(threads.mutation)") }
    }

    /// Register a notification device, list it, disable and enable it reading
    /// each back, and remove it, through the Rust core against the fixture's
    /// Marshall and Porsche (ADR-0278 item 1). The fixture has no APNs or Susan:
    /// an APNs-shaped token and Susan's reply are stand-ins, so Rust's Susan
    /// body encoding, reply validation and stdin push-key path still run.
    /// Delivery is not proven here.
    func testNotificationDeviceRegisterListPreferencesAndRemoveAgainstFixture() async throws {
        let journey = try await MilaFixtureJourney.signIn(try MilaFixtureJourney.descriptor())
        defer { journey.finish() }
        let adapter = try XCTUnwrap(journey.model.adapter)
        func refusal() -> String { adapter.lastRefusal() ?? "none" }

        let registration = MilaApplePushRegistration(authorization: MilaJourneyGrantedAuthorization(), keys: MilaJourneyPokeKey(),
                                                     susan: MilaJourneyStandInSusan())
        // APNs device tokens are 32 opaque bytes; Rust receives them as 64 lowercase hex characters.
        let outcome = await registration.register(adapter: adapter, deployment: journey.descriptor.deployment.host,
                                                  deviceToken: Data.random(count: 32), environment: .sandbox, label: "Mila journey")
        guard case .registered(let device) = outcome else { return XCTFail("device register: \(outcome) (\(refusal()))") }
        journeyStep("notifications: device registered (APNs token and Susan stand-ins)")

        func listed() async throws -> MilaAccountNotificationDevice? {
            try await adapter.notificationDevices().first(where: { $0.id == device })
        }
        guard let row = try await listed() else { return XCTFail("device \(device) is not listed (\(refusal()))") }
        XCTAssertEqual(row.platform, MilaDevicePlatform.current.wireName)
        XCTAssertTrue(row.enabled, "a new device is listed enabled")
        journeyStep("notifications: device listed")

        do { try await adapter.setNotificationDeviceEnabled(device, enabled: false) }
        catch { return XCTFail("device disable: \(refusal())") }
        let disabled = try await listed()
        XCTAssertEqual(disabled?.enabled, false, "device disabled (read back)")
        journeyStep("notifications: device disabled (read back)")

        do { try await adapter.setNotificationDeviceEnabled(device, enabled: true) }
        catch { return XCTFail("device enable: \(refusal())") }
        let enabled = try await listed()
        XCTAssertEqual(enabled?.enabled, true, "device enabled (read back)")
        journeyStep("notifications: device enabled (read back)")

        do { try await adapter.removeNotificationDevice(device) }
        catch { return XCTFail("device remove: \(refusal())") }
        // Porsche lists active devices; a revoked row, if listed, must say so.
        let removed = try await listed()
        XCTAssertTrue(removed == nil || removed?.state == "revoked", "device still listed as \(removed?.state ?? "unknown")")
        journeyStep("notifications: device removed (read back)")
    }

    /// @cc [owner:ghuntley,label:verification] mila-apple-journey-lifecycle
    /// Create, stop, start, pause, resume and delete a machine this run creates,
    /// then resize a second one, through the adapter calls and
    /// `MilaMachineWorkflow` the SwiftUI machine pages use. Each step MUST be
    /// read back (listing desired state, `request show`, `show`), not only the
    /// mutation's status. The fixture's `observe` hook stands in for the
    /// provisioner, so this proves recorded intent, not guest execution.
    /// Pause and resume follow the Windows and Linux journeys: the pause is not
    /// observed, because an observed pause turns resume into a checkpoint wake
    /// whose `request show` receipt Marshall refuses (ADR-0264 open gap
    /// `ssh-wake-receipt-physical-readiness`). The Rust projection offers Resume
    /// only for an observed paused machine, so resume is dispatched through
    /// `MilaLiveSession.machineAction`, not the workflow. Resize runs on a second
    /// machine because an unapplied resize keeps its machine busy
    /// (`resize_in_progress`).
    func testCreateLifecycleDeleteAndResizeAgainstFixture() async throws {
        let journey = try await MilaFixtureJourney.signIn(try MilaFixtureJourney.descriptor())
        defer { journey.finish() }
        let name = MilaFixtureJourney.machineName("life")
        let machine = try await journey.create(name).id
        _ = try await journey.observe(machine)
        journeyStep("lifecycle create")

        for (action, desired) in [(MilaMachineAction.stop, "stopped"), (.start, "running")] {
            _ = try await journey.lifecycle(action, name: name)
            _ = try await journey.until("lifecycle \(action)") { () async throws -> Bool? in
                try await journey.listed(name)?.machine.desiredState == desired ? true : nil
            }
            let observed = try await journey.observe(machine)
            XCTAssertEqual(observed, desired, "lifecycle \(action) observed")
            journeyStep("lifecycle \(action) (\(desired))")
        }

        _ = try await journey.lifecycle(.pause, name: name)
        _ = try await journey.until("lifecycle pause") { () async throws -> Bool? in
            try await journey.listed(name)?.machine.desiredState == "paused" ? true : nil
        }
        journeyStep("lifecycle pause (paused)")

        // Resume is a durable wake request; with no checkpoint in the fixture it
        // passes when Marshall admits the request or the machine is requested running.
        let wake = try await journey.submit("lifecycle resume") { request in
            try journey.session().machineAction(machine: machine, action: "resume", requestID: request)
        }
        let resumed = try await journey.until("lifecycle resume") { () async throws -> String? in
            if try journey.requestAdmitted(wake) { return "wake_requested" }
            return try await journey.listed(name)?.machine.desiredState == "running" ? "running" : nil
        }
        journeyStep("lifecycle resume (\(resumed))")

        _ = try await journey.lifecycle(.delete, name: name)
        let deleted = try await journey.until("lifecycle delete") { () async throws -> String? in
            guard let row = try await journey.listed(name) else { return "absent" }
            return row.machine.desiredState == "deleted" ? "deleted" : nil
        }
        // The deletion holds capacity until the provisioner stand-in observes it.
        _ = try? await journey.observe(machine)
        journeyStep("lifecycle delete (\(deleted))")

        let resizeName = MilaFixtureJourney.machineName("resize")
        let target = try await journey.create(resizeName)
        _ = try await journey.observe(target.id)
        let adapter = try XCTUnwrap(journey.model.adapter)
        let resize = try await journey.submit("lifecycle resize") { request in
            guard let row = try await journey.listed(resizeName) else { throw MilaJourneyFailure.step("lifecycle resize: \(resizeName) is not listed") }
            try await adapter.resize(machine: row, cpu: 2, memory: 1024, disk: 3, requestID: request)
        }
        // As on Linux and Windows: the machine reports the new size, or (a
        // deployment that pins resizes for the provisioner) the request was admitted.
        let resized = try await journey.until("lifecycle resize") { () async throws -> String? in
            let detail = try journey.machineDetail(target.id)
            if detail.vcpu == 2, detail.memoryBytes.map({ $0 / (1024 * 1024) }) == 1024 { return "resized" }
            return try journey.requestAdmitted(resize) ? "resize_requested" : nil
        }
        journeyStep("lifecycle \(resized)")
        await journey.remove(target.id)
    }

    /// @cc [owner:ghuntley,label:verification] mila-apple-journey-web
    /// Web show through the adapter's `web show` projection, then public and
    /// back to private through `MilaLiveSession.webSet`, each at the current
    /// policy revision and read back at a newer one. It runs on a machine this
    /// test creates, not the seed: the Windows journey sets the seed's web
    /// policy against the same tunnelled fixture, and two clients racing one
    /// optimistic revision would refuse each other.
    func testWebShowAndSetPublicThenPrivateAgainstFixture() async throws {
        let journey = try await MilaFixtureJourney.signIn(try MilaFixtureJourney.descriptor())
        defer { journey.finish() }
        let adapter = try XCTUnwrap(journey.model.adapter)
        let machine = try await journey.create(MilaFixtureJourney.machineName("web")).id
        _ = try await journey.observe(machine)

        let before = try await adapter.webEndpointProjection(machine: machine)
        XCTAssertEqual(before.machineID, machine)
        XCTAssertTrue(before.visibility == "private" || before.visibility == "public", "web show visibility \(before.visibility)")
        journeyStep("web show")

        for isPublic in [true, false] {
            let current = try await adapter.webEndpointProjection(machine: machine)
            _ = try await journey.submit("web set") { request in
                try journey.session().webSet(machine: machine, port: before.port, publicAccess: isPublic, revision: current.policyRevision, requestID: request)
            }
            let wanted = isPublic ? "public" : "private"
            _ = try await journey.until("web set \(wanted)") { () async throws -> Bool? in
                let after = try await adapter.webEndpointProjection(machine: machine)
                return after.visibility == wanted && after.policyRevision > current.policyRevision ? true : nil
            }
            journeyStep("web set \(wanted)")
        }
        await journey.remove(machine)
    }

    /// @cc [owner:ghuntley,label:verification;terminal] mila-apple-journey-guest-terminal
    /// The fixture's guest-backed terminal machine (descriptor
    /// `seed.terminal_machine_id`), as the Windows and Linux journeys drive it:
    /// `terminal new` and a named attach, a shell-computed echo, a resize to
    /// 132x40 read back with `stty size`, a local detach and named reattach
    /// whose output MUST come back from the server's replay, and `terminal
    /// kill`, confirmed when the ended session can no longer be attached. Each
    /// `terminal new` uses a fresh request ID, so this session is distinct from
    /// the Windows journey's on the same machine. The PTY is the fixture's
    /// terminal stand-in, not a real guest. This drives `MilaLiveSession`
    /// directly; the SwiftUI `MilaTerminalController` stream is not exercised.
    func testGuestTerminalEchoResizeReplayAndEndAgainstFixture() async throws {
        let descriptor = try MilaFixtureJourney.descriptor()
        guard let machine = descriptor.seed.terminalMachineID else {
            throw XCTSkip("the fixture descriptor names no seed.terminal_machine_id")
        }
        let journey = try await MilaFixtureJourney.signIn(descriptor)
        defer { journey.finish() }
        let session = try journey.session()

        // Open and attach, retrying only the closed readiness refusals for 180 s.
        let (named, first) = try await journey.until("guest terminal attach", seconds: 180) { () async throws -> (UUID, UInt64)? in
            do {
                let opened = try session.terminalOpen(machine: machine, requestID: UUID())
                return (opened, try session.terminalAttach(machine: machine, session: opened, columns: 100, rows: 30))
            } catch {
                let reason = journey.refusal()
                guard let reason, MilaFixtureJourney.terminalReadiness.contains(reason) else {
                    throw MilaJourneyFailure.step("guest terminal attach: \(reason ?? String(describing: error))")
                }
                try await Task.sleep(for: .seconds(2))
                return nil
            }
        }
        journeyStep("guest terminal attach (named session)")

        let marker = "mila-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
        try session.terminalInput(first, data: Data("echo \(marker)-$((6*7))\r".utf8))
        try journey.read(first, until: "\(marker)-42", step: "guest terminal echo")
        journeyStep("guest terminal echo")

        try session.terminalResize(first, columns: 132, rows: 40)
        try session.terminalInput(first, data: Data("stty size\r".utf8))
        try journey.read(first, until: "40 132", step: "guest terminal resize", seconds: 30)
        journeyStep("guest terminal resize 132x40")

        // Detach this viewport only, then attach a fresh one to the same named
        // session: the earlier output must come back from the server's replay.
        session.terminalKill(first)
        let second = try session.terminalAttach(machine: machine, session: named, columns: 132, rows: 40)
        try journey.read(second, until: "\(marker)-42", step: "guest terminal replay")
        journeyStep("guest terminal detach and reattach with replay")

        session.terminalKill(second)
        guard try session.terminalEnd(machine: machine, session: named, requestID: UUID()) else {
            throw MilaJourneyFailure.step("guest terminal end: the session is not reported closed (\(journey.refusal() ?? "none"))")
        }
        // Marshall confirms the close asynchronously: a named attach must come
        // to be refused, or its stream must end at once.
        let ended = try await journey.until("guest terminal end") { () async throws -> String? in
            guard let probe = try? session.terminalAttach(machine: machine, session: named, columns: 80, rows: 24) else { return "refused" }
            defer { session.terminalKill(probe) }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                guard let chunk = try? session.terminalRead(probe, waitMilliseconds: 250) else { return "stream_failed" }
                if case .closed = chunk { return "stream_closed" }
            }
            try await Task.sleep(for: .seconds(2))
            return nil
        }
        journeyStep("guest terminal end (server session closed: \(ended))")
    }
}

/// Descriptor v1 parsing and hook encoding, without a live fixture.
final class MilaJourneyDescriptorTests: XCTestCase {
    private func write(_ object: [String: Any]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mila-descriptor-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func descriptor(fixtureURL: String?) -> [String: Any] {
        var approver: [String: Any] = ["url": "https://localhost:8444/approve", "bearer_token": "token"]
        approver["fixture_url"] = fixtureURL
        return [
            "version": 1,
            "deployment": ["host": "localhost", "ssh_port": 2222, "https_port": 8443],
            "tls": ["ca_pem": "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n", "server_name": "localhost"],
            "approver": approver,
            "seed": ["machine_name": "journey", "share_principal": "member@example.test",
                     "machine_id": "0b6f5a52-6a4e-4c39-9d3b-6f3c1d1e2f30", "account_email": "owner@example.test"],
        ]
    }

    func testDescriptorCarriesFixtureHookAndSeedMachine() throws {
        let value = try MilaJourneyDescriptor.load(try write(descriptor(fixtureURL: "https://localhost:8444/fixture/")))
        XCTAssertEqual(value.approver.fixtureURL?.appendingPathComponent("thread-create").absoluteString, "https://localhost:8444/fixture/thread-create")
        XCTAssertEqual(value.seed.machineID, UUID(uuidString: "0b6f5a52-6a4e-4c39-9d3b-6f3c1d1e2f30"))
        XCTAssertNil(try MilaJourneyDescriptor.load(try write(descriptor(fixtureURL: nil))).approver.fixtureURL)
    }

    func testDescriptorCarriesTheOptionalTerminalMachine() throws {
        var object = descriptor(fixtureURL: "https://localhost:8444/fixture/")
        XCTAssertNil(try MilaJourneyDescriptor.load(try write(object)).seed.terminalMachineID)
        var seed = try XCTUnwrap(object["seed"] as? [String: Any])
        seed["terminal_machine_id"] = "cf2dc277-763f-4c33-9fa5-503956fe6af8"
        seed["terminal_machine_name"] = "vm-cf2dc277763f4c339fa5503956fe6af8"
        object["seed"] = seed
        let value = try MilaJourneyDescriptor.load(try write(object))
        XCTAssertEqual(value.seed.terminalMachineID, UUID(uuidString: "cf2dc277-763f-4c33-9fa5-503956fe6af8"))
        XCTAssertEqual(value.seed.terminalMachineName, "vm-cf2dc277763f4c339fa5503956fe6af8")
        for bad in ["not-a-uuid", 7] as [Any] {
            seed["terminal_machine_id"] = bad
            object["seed"] = seed
            XCTAssertThrowsError(try MilaJourneyDescriptor.load(try write(object)), "\(bad)")
        }
        seed["terminal_machine_id"] = "cf2dc277-763f-4c33-9fa5-503956fe6af8"
        seed["terminal_machine_name"] = ""
        object["seed"] = seed
        XCTAssertThrowsError(try MilaJourneyDescriptor.load(try write(object)), "empty terminal machine name")
    }

    func testDescriptorRefusesAFixtureHookOutsideTLSOrItsPath() throws {
        for url in ["http://localhost:8444/fixture/", "https://localhost:8444/approve"] {
            XCTAssertThrowsError(try MilaJourneyDescriptor.load(try write(descriptor(fixtureURL: url))), url)
        }
    }

    func testHooksCarryOnlyTheirCanonicalUUIDInput() {
        let id = UUID(uuidString: "0B6F5A52-6A4E-4C39-9D3B-6F3C1D1E2F30")!
        XCTAssertEqual(MilaFixtureHook.observe(machine: id).body, ["machine_id": "0b6f5a52-6a4e-4c39-9d3b-6f3c1d1e2f30"])
        XCTAssertEqual(MilaFixtureHook.threadCreate.body, [:])
        XCTAssertEqual(MilaFixtureHook.threadProposal(thread: id).body, ["thread_id": "0b6f5a52-6a4e-4c39-9d3b-6f3c1d1e2f30"])
        XCTAssertEqual(
            [MilaFixtureHook.observe(machine: id), .threadCreate, .threadReady(thread: id), .threadQuestion(thread: id), .threadProposal(thread: id)].map(\.action),
            ["observe", "thread-create", "thread-ready", "thread-question", "thread-proposal"]
        )
    }
}
