import XCTest
@testable import MilaNativeUI

final class MilaApprovalTests: XCTestCase {
    func testPendingApprovalIsBoundToHttpsDeploymentHost() throws {
        guard case .pending(let info) = try MilaApprovalDecoder.decode(MilaWhoami.pending(), expectedHost: "mila.example.test") else { return XCTFail() }
        XCTAssertEqual(info.url.host, "mila.example.test")
        XCTAssertEqual(info.fingerprint, "SHA256:q3Zx+9fixture/AbC=")
    }

    func testApprovalRefusesHostMismatchNonHttpsAndUnsafeFingerprint() {
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(MilaWhoami.pending(host: "evil.example"), expectedHost: "mila.example.test"))
        let insecure = Data(#"{"version":1,"status":"approval_required","fingerprint":"SHA256:x","approval_url":"http://mila.example.test/approve"}"#.utf8)
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(insecure, expectedHost: "mila.example.test"))
        let credential = Data(#"{"version":1,"status":"approval_required","fingerprint":"SHA256:x","approval_url":"https://user:pw@mila.example.test/approve"}"#.utf8)
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(credential, expectedHost: "mila.example.test"))
        let spaced = Data(#"{"version":1,"status":"approval_required","fingerprint":"SHA256 x","approval_url":"https://mila.example.test/approve"}"#.utf8)
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(spaced, expectedHost: "mila.example.test"))
        let missing = Data(#"{"version":1,"status":"approval_required","approval_url":"https://mila.example.test/approve"}"#.utf8)
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(missing))
    }

    /// Marshall's authenticated `whoami` is `status: succeeded` with a result object.
    func testSucceededEnvelopeCompletesApproval() throws {
        XCTAssertEqual(try MilaApprovalDecoder.decode(MilaWhoami.approved), .approved)
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(Data(#"{"version":1,"status":"succeeded"}"#.utf8)))
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(Data(#"{"version":1,"status":"approved"}"#.utf8)),
                             "`approved` is not a Porsche status")
    }

    func testErrorEnvelopesAreTyped() throws {
        XCTAssertEqual(try MilaApprovalDecoder.decode(MilaWhoami.refused), .refused)
        XCTAssertEqual(try MilaApprovalDecoder.decode(Data(#"{"version":1,"status":"error","error":"forbidden"}"#.utf8)), .refused)
        XCTAssertEqual(try MilaApprovalDecoder.decode(Data(#"{"version":1,"status":"error","error":"temporarily_unavailable"}"#.utf8)), .unavailable)
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(Data(#"{"version":1,"status":"error","error":"mystery"}"#.utf8)))
        XCTAssertThrowsError(try MilaApprovalDecoder.decode(Data(#"{"version":2,"status":"succeeded","result":{}}"#.utf8)))
    }
}

/// Sign-in lifecycle over the real coordinator and adapter, with a recording session.
@MainActor final class MilaSignInLifecycleTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private func harness(_ session: RecordingSession, clock: Clock = Clock(), lifetime: TimeInterval = 600,
                         advancePerPoll: TimeInterval = 1) -> (MilaSignInController, MilaDeploymentSessionController, MilaDeployment, MilaIsolatedDefaults) {
        let env = MilaIsolatedDefaults()
        let deployment = MilaDeployment(host: "mila.example.test", port: 22, trust: Data([1]))
        XCTAssertTrue(env.store.upsert(deployment))
        let controller = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { _ in LinkedMilaFFIAdapter(session: session) }
        let signIn = MilaSignInController(session: controller, pollInterval: .milliseconds(1), approvalLifetime: lifetime,
                                          now: { clock.now }, sleep: { _ in clock.advance(advancePerPoll); await Task.yield() })
        return (signIn, controller, deployment, env)
    }

    func testPendingApprovalThenSucceededSignsInOnTheSameSession() async {
        let session = RecordingSession()
        session.whoamiResponses = [MilaWhoami.pending(), MilaWhoami.pending(), MilaWhoami.approved]
        let (signIn, controller, deployment, env) = harness(session); defer { env.tearDown() }
        signIn.signIn(deployment)
        await assertEventually { if case .awaitingApproval = signIn.phase { return true }; return signIn.isSignedIn }
        await signIn.settle()
        guard case .signedIn(let id, let generation) = signIn.phase else { return XCTFail("expected signed in, got \(signIn.phase)") }
        XCTAssertEqual(id, deployment.id)
        XCTAssertEqual(generation, controller.generation)
        XCTAssertNotNil(signIn.adapter)
        XCTAssertEqual(session.calls.filter { $0 == .whoami }.count, 3)
        XCTAssertFalse(session.calls.contains(.close), "approval must not reconnect")
    }

    func testAwaitingApprovalExposesValidatedURL() async {
        let session = RecordingSession()
        session.whoamiResponses = [MilaWhoami.pending()]
        let (signIn, _, deployment, env) = harness(session, lifetime: 1_000_000); defer { env.tearDown() }
        signIn.signIn(deployment)
        await assertEventually { signIn.approvalURL != nil }
        XCTAssertEqual(signIn.approvalURL?.absoluteString, "https://mila.example.test/ssh/approve/abc")
        XCTAssertNil(signIn.adapter, "a pending approval is not signed in")
        signIn.signOut()
        XCTAssertEqual(signIn.phase, .signedOut)
        XCTAssertTrue(session.calls.contains(.close))
    }

    func testApprovalExpiresAndClosesSession() async {
        let session = RecordingSession()
        session.whoamiResponses = [MilaWhoami.pending()]
        let (signIn, _, deployment, env) = harness(session, lifetime: 5, advancePerPoll: 2); defer { env.tearDown() }
        signIn.signIn(deployment)
        await signIn.settle()
        XCTAssertEqual(signIn.phase, .expired(deployment.id))
        XCTAssertTrue(session.calls.contains(.close))
        XCTAssertNil(signIn.adapter)
    }

    func testRefusalAndProtocolFailureAreTerminal() async {
        let refused = RecordingSession(); refused.whoamiResponses = [MilaWhoami.refused]
        let (signIn, _, deployment, env) = harness(refused); defer { env.tearDown() }
        signIn.signIn(deployment); await signIn.settle()
        XCTAssertEqual(signIn.phase, .failed(deployment.id, .refused))
        XCTAssertTrue(refused.calls.contains(.close))

        let foreign = RecordingSession(); foreign.whoamiResponses = [MilaWhoami.pending(host: "evil.example")]
        let (other, _, otherDeployment, otherEnv) = harness(foreign); defer { otherEnv.tearDown() }
        other.signIn(otherDeployment); await other.settle()
        XCTAssertEqual(other.phase, .failed(otherDeployment.id, .protocolError))
    }

    func testTransportFailureAndConnectFailureAreUnreachable() async {
        let silent = RecordingSession() // whoami throws a transport error
        let (signIn, _, deployment, env) = harness(silent); defer { env.tearDown() }
        signIn.signIn(deployment); await signIn.settle()
        XCTAssertEqual(signIn.phase, .failed(deployment.id, .unreachable))

        let env2 = MilaIsolatedDefaults(); defer { env2.tearDown() }
        let value = MilaDeployment(host: "mila.example.test", port: 22, trust: Data([1]))
        XCTAssertTrue(env2.store.upsert(value))
        let failing = MilaDeploymentSessionController(store: env2.store, defaults: env2.defaults) { _ in throw MilaSessionError.transport(-11) }
        let controller = MilaSignInController(session: failing)
        controller.signIn(value)
        XCTAssertEqual(controller.phase, .failed(value.id, .unreachable))
    }

    func testSignOutDuringPollingFencesLateApproval() async {
        let session = RecordingSession()
        session.whoamiResponses = [MilaWhoami.pending(), MilaWhoami.approved]
        let env = MilaIsolatedDefaults(); defer { env.tearDown() }
        let deployment = MilaDeployment(host: "mila.example.test", port: 22, trust: Data([1]))
        XCTAssertTrue(env.store.upsert(deployment))
        let controller = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { _ in LinkedMilaFFIAdapter(session: session) }
        let signIn = MilaSignInController(session: controller, pollInterval: .seconds(30))
        signIn.signIn(deployment)
        await assertEventually { signIn.approvalURL != nil }
        signIn.signOut()
        await signIn.settle()
        XCTAssertEqual(signIn.phase, .signedOut)
        XCTAssertNil(signIn.adapter)
    }

    /// Reconnect starts a new generation and closes the previous session.
    func testReconnectUsesFreshGeneration() async {
        let first = RecordingSession(); first.whoamiResponses = [MilaWhoami.approved]
        let second = RecordingSession(); second.whoamiResponses = [MilaWhoami.approved]
        let env = MilaIsolatedDefaults(); defer { env.tearDown() }
        let deployment = MilaDeployment(host: "mila.example.test", port: 22, trust: Data([1]))
        XCTAssertTrue(env.store.upsert(deployment))
        final class Sessions: @unchecked Sendable { var queue: [RecordingSession] = [] }
        let sessions = Sessions(); sessions.queue = [first, second]
        let controller = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { _ in LinkedMilaFFIAdapter(session: sessions.queue.removeFirst()) }
        let signIn = MilaSignInController(session: controller)
        signIn.signIn(deployment); await signIn.settle()
        guard case .signedIn(_, let g1) = signIn.phase else { return XCTFail() }
        signIn.reconnect(); await signIn.settle()
        guard case .signedIn(_, let g2) = signIn.phase else { return XCTFail() }
        XCTAssertGreaterThan(g2, g1)
        XCTAssertTrue(first.calls.contains(.close))
        XCTAssertFalse(second.calls.contains(.close))
    }
}
