import XCTest
@testable import MilaNativeUI

/// Machine list/detail binding over `LinkedMilaFFIAdapter` and a recording session.
@MainActor final class MilaMachinesControllerTests: XCTestCase {
    func testListingProjectsRustPolicyBits() throws {
        let snapshot = try MilaListingFixture.snapshot(MilaListingFixture.allPages)
        XCTAssertEqual(snapshot.machines.map(\.machine.name), ["alpha", "beta", "gamma"])
        XCTAssertEqual(snapshot.machines[0].actions.values, [.stop, .pause, .pin, .delete])
        XCTAssertEqual(snapshot.machines[0].actions.lifecycle, [.stop, .pause, .delete])
        XCTAssertEqual(snapshot.machines[1].actions.lifecycle, [.start, .delete])
        XCTAssertEqual(snapshot.machines[2].actions.lifecycle, [.resume, .delete])
        XCTAssertFalse(snapshot.metadata.hasMore)
        let noBits = MilaListingFixture.listing([#"{"id":"11111111-1111-4111-8111-111111111111","name":"x","desired_state":"running","observed_state":null,"pinned":false,"owner":null,"read":true,"write":true,"manage":false}"#])
        XCTAssertTrue(try MilaListingFixture.snapshot(noBits).machines[0].actions.values.isEmpty, "absent Rust policy presents no actions")
        XCTAssertThrowsError(try MilaListingFixture.snapshot(MilaListingFixture.listing([MilaListingFixture.row(UUID(), name: "bad\\u0007", state: "running", bits: 0)])))
    }

    func testRefreshLoadMoreAndDetailSelection() async throws {
        let (adapter, session) = recordingAdapter()
        let controller = MilaMachinesController()
        XCTAssertEqual(controller.state, .signedOut)
        controller.bind(adapter)
        await controller.refresh()
        XCTAssertEqual(controller.state, .loaded)
        XCTAssertEqual(controller.machines.count, 2)
        XCTAssertTrue(controller.hasMore)
        controller.select(MilaListingFixture.stopped)
        XCTAssertEqual(controller.detail?.machine.name, "beta")
        await controller.loadMore()
        XCTAssertEqual(controller.machines.map(\.machine.name), ["alpha", "beta", "gamma"])
        XCTAssertFalse(controller.hasMore)
        XCTAssertEqual(controller.detail?.machine.name, "beta", "selection survives pagination")
        XCTAssertEqual(session.calls, [.refresh, .readMore])
        controller.select(UUID())
        XCTAssertNil(controller.detail, "unknown identities never synthesize detail")
    }

    func testSignOutClearsAndFencesLateListing() async {
        let (adapter, _) = recordingAdapter()
        let controller = MilaMachinesController()
        controller.bind(adapter)
        let pending = Task { await controller.refresh() }
        controller.bind(nil)
        await pending.value
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertTrue(controller.machines.isEmpty)
    }

    func testClosedSessionFailsListing() async {
        let (adapter, session) = recordingAdapter()
        let controller = MilaMachinesController()
        controller.bind(adapter)
        await controller.refresh()
        let unavailable = MilaMachinesController()
        unavailable.bind(UnavailableMilaFFIAdapter())
        await unavailable.refresh()
        XCTAssertEqual(unavailable.state, .failed)
        _ = session
    }
}

/// Lifecycle verbs reach the Rust session with the right token and request ID.
@MainActor final class MilaMachineLifecycleTests: XCTestCase {
    func testEveryLifecycleActionDispatchesThroughSession() async throws {
        let cases: [(UUID, MilaMachineAction, String)] = [
            (MilaListingFixture.stopped, .start, "start"),
            (MilaListingFixture.running, .stop, "stop"),
            (MilaListingFixture.running, .pause, "pause"),
            (MilaListingFixture.paused, .resume, "resume"),
            (MilaListingFixture.running, .delete, "rm"),
        ]
        for (machineID, action, token) in cases {
            let (adapter, session) = recordingAdapter()
            let workflow = MilaMachineWorkflow(adapter: adapter)
            var applied: [MilaMachineAction] = []
            workflow.onApplied = { applied.append($0) }
            let machine = try MilaListingFixture.machine(machineID)
            let request = UUID()
            workflow.submit(action, machine: machine, requestID: request)
            await workflow.settle()
            XCTAssertEqual(workflow.state, .applied(requestID: request, action: action), "\(action)")
            XCTAssertEqual(session.calls, [.action(machineID, token, request)])
            XCTAssertEqual(applied, [action])
        }
    }

    func testSettledOutcomeAcceptsNextActionAndRejectsDuplicates() async throws {
        let (adapter, session) = recordingAdapter()
        let workflow = MilaMachineWorkflow(adapter: adapter)
        let machine = try MilaListingFixture.machine(MilaListingFixture.running)
        let first = UUID()
        workflow.submit(.pause, machine: machine, requestID: first)
        workflow.submit(.stop, machine: machine)
        await workflow.settle()
        XCTAssertEqual(session.calls.count, 1, "one mutation at a time")
        workflow.submit(.stop, machine: machine, requestID: UUID())
        await workflow.settle()
        XCTAssertEqual(session.calls.count, 2, "a settled outcome accepts the next action")
        workflow.submit(.pause, machine: machine, requestID: first)
        XCTAssertEqual(workflow.state, .failed(requestID: first, action: .pause, error: .actionNotAllowed))
        XCTAssertEqual(session.calls.count, 2)
    }

    func testPinAndPolicyAbsentActionsNeverReachSession() async throws {
        let (adapter, session) = recordingAdapter()
        let machine = try MilaListingFixture.machine(MilaListingFixture.running)
        let workflow = MilaMachineWorkflow(adapter: adapter)
        workflow.submit(.pin, machine: machine)
        guard case .failed(_, .pin, .actionNotAllowed) = workflow.state else { return XCTFail() }
        workflow.reset()
        workflow.submit(.start, machine: machine)
        guard case .failed(_, .start, .actionNotAllowed) = workflow.state else { return XCTFail("start is not projected for a running machine") }
        do { try await adapter.submit(.pin, machine: machine, requestID: UUID()); XCTFail() }
        catch { XCTAssertEqual(error as? MilaFFIError, .actionNotAllowed) }
        XCTAssertTrue(session.calls.isEmpty)
    }

    func testSessionRefusalIsTypedFailure() async throws {
        let session = RecordingSession(); session.failMutations = true
        let workflow = MilaMachineWorkflow(adapter: LinkedMilaFFIAdapter(session: session))
        let request = UUID()
        workflow.submit(.stop, machine: try MilaListingFixture.machine(), requestID: request)
        await workflow.settle()
        XCTAssertEqual(workflow.state, .failed(requestID: request, action: .stop, error: .unavailable))
    }
}

/// Sharing through the adapter's authenticated share transport.
@MainActor final class MilaMachineShareTransportTests: XCTestCase {
    func testAddAndRemoveCrossAsTypedShareMutation() async throws {
        let (adapter, session) = recordingAdapter()
        let machine = try MilaListingFixture.machine()
        let controller = MilaMachineSharingController(adapter: adapter)
        controller.setSession(signedIn: true, machine: machine)
        let add = UUID()
        controller.submit(principal: "  friend@example.test ", role: .operatorRole, requestID: add)
        await assertEventually { if case .applied = controller.state { return true }; return false }
        let remove = UUID()
        controller.submit(principal: "friend@example.test", role: .manager, remove: true, requestID: remove)
        await assertEventually { if case .applied(_, _, true) = controller.state { return true }; return false }
        XCTAssertEqual(session.calls, [
            .share(machine.id, "friend@example.test", "operator", true, add),
            .share(machine.id, "friend@example.test", nil, false, remove),
        ])
    }

    func testReadOnlyMachineAndRefusalFailClosed() async throws {
        let session = RecordingSession()
        let readOnly = try XCTUnwrap(MilaListingFixture.snapshot(MilaListingFixture.listing([
            MilaListingFixture.row(MilaListingFixture.running, name: "ro", state: "running", bits: 16, write: false),
        ])).machines.first)
        do {
            try await LinkedMilaFFIAdapter(session: session).submitShare(try MilaSharePrincipal("a@example.test"), role: .viewer, machine: readOnly, remove: false, requestID: UUID())
            XCTFail("write permission is required")
        } catch { XCTAssertEqual(error as? MilaMachineSharingError, .unavailable) }
        XCTAssertTrue(session.calls.isEmpty)

        session.failMutations = true
        let controller = MilaMachineSharingController(adapter: LinkedMilaFFIAdapter(session: session))
        controller.setSession(signedIn: true, machine: try MilaListingFixture.machine())
        controller.submit(principal: "a@example.test")
        await assertEventually { if case .failed(_, _, _, .unavailable) = controller.state { return true }; return false }
    }

    func testSignOutDiscardsInFlightShareOutcome() async throws {
        let (adapter, _) = recordingAdapter()
        let controller = MilaMachineSharingController(adapter: adapter)
        controller.setSession(signedIn: true, machine: try MilaListingFixture.machine())
        controller.submit(principal: "a@example.test")
        controller.setSession(signedIn: false, machine: nil)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.state, .signedOut)
    }
}

/// The app model binds feature controllers to the approved generation only.
@MainActor final class MilaAppModelBindingTests: XCTestCase {
    func testApprovedSignInBindsAndSignOutClearsFeatures() async {
        let session = RecordingSession()
        session.whoamiResponses = [MilaWhoami.approved]
        let env = MilaIsolatedDefaults(); defer { env.tearDown() }
        let deployment = MilaDeployment(host: "mila.example.test", port: 22, trust: Data([1]))
        XCTAssertTrue(env.store.upsert(deployment))
        let model = MilaAppModel(session: MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { _ in LinkedMilaFFIAdapter(session: session) })
        XCTAssertEqual(model.machines.state, .signedOut)
        model.signIn.signIn(deployment)
        XCTAssertEqual(model.machines.state, .signedOut, "connecting is not signed in")
        await model.signIn.settle()
        await assertEventually { model.machines.state == .loaded }
        XCTAssertEqual(model.machines.machines.count, 2)
        XCTAssertEqual(model.threads.state, .idle)
        model.signIn.signOut()
        XCTAssertEqual(model.machines.state, .signedOut)
        XCTAssertTrue(model.machines.machines.isEmpty)
        XCTAssertEqual(model.threads.state, .signedOut)
        XCTAssertEqual(model.web.phase, .closed)
        XCTAssertTrue(session.calls.contains(.close))
    }
}
