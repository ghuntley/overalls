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
        enum CodingKeys: String, CodingKey { case machineName = "machine_name", sharePrincipal = "share_principal", machineID = "machine_id" } }
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

/// A signed-in fixture journey: the pinned HTTPS client and the app model.
@MainActor struct MilaFixtureJourney {
    let descriptor: MilaJourneyDescriptor
    let http: URLSession
    let model: MilaAppModel
    let env: MilaIsolatedDefaults

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
        let sessions = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { value in
            LinkedMilaFFIAdapter(session: try MilaLiveSession(trust: value.trust, host: value.host, port: value.port, sessionSigner: signer))
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
        return MilaFixtureJourney(descriptor: descriptor, http: http, model: model, env: env)
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
}

enum MilaJourneyFailure: Error, Equatable { case signIn, hook(action: String, status: Int) }

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
