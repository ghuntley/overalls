import XCTest
@testable import MilaNativeUI

final class MilaWatchTests: XCTestCase {
    func testGroupsCoverEveryDisplayedIdentityWithBoundedFilters() {
        let machines = (0..<500).map { _ in UUID() }
        let threads = (0..<256).map { _ in UUID() }
        let groups = MilaWatchFilters.groups(machines: machines, threads: threads)
        XCTAssertTrue(groups.allSatisfy { $0.machines.count + $0.threads.count <= 64 })
        XCTAssertEqual(Set(groups.flatMap(\.machines)), Set(machines))
        XCTAssertEqual(Set(groups.flatMap(\.threads)), Set(threads))
        XCTAssertEqual(MilaWatchFilters.groups(machines: [], threads: []).count, 1, "session-only watch still observes authority loss")
    }
    func testOnlyInvalidationNoticesRefresh() throws {
        XCTAssertEqual(try MilaWatchRead.decode(Data(#"{"version":1,"event":"heartbeat"}"#.utf8)), .idle)
        XCTAssertEqual(try MilaWatchRead.decode(Data(#"{"version":1,"event":"resync"}"#.utf8)), .hint)
        XCTAssertThrowsError(try MilaWatchRead.decode(Data(#"{"version":2,"event":"machine"}"#.utf8)))
    }

    func testDuplicateRowsDoNotConsumeTheBoundedIdentityWindow() {
        let repeated = UUID()
        let later = UUID()
        let groups = MilaWatchFilters.groups(machines: Array(repeating: repeated, count: 256) + [later], threads: [])
        let watched = Set(groups.flatMap(\.machines))
        XCTAssertEqual(watched.count, 2)
        XCTAssertTrue(watched.contains(later))
    }
}

/// @cc [owner:ghuntley,label:verification;security] apple-watch-session-races
/// Watch callback regressions MUST suspend real app-model reads across a
/// deployment switch and verify the replacement adapter receives no stale read
/// or thread identity. Waits MUST be bounded and pending reads released.
@MainActor final class MilaWatchSessionBindingTests: XCTestCase {
    private actor SuspendedReads: MilaFFIAdapter {
        enum Operation: Hashable, Sendable { case machines, threads }
        private let snapshot: MilaValidatedSnapshot
        private var delayed = Set<Operation>()
        private var pending: [Operation: CheckedContinuation<Void, Never>] = [:]
        private(set) var listCount = 0
        private(set) var shownThreads: [UUID] = []

        init(snapshot: MilaValidatedSnapshot) { self.snapshot = snapshot }

        func delay(_ operation: Operation) { delayed.insert(operation) }
        func waitUntilPending(_ operation: Operation) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while pending[operation] == nil && ContinuousClock.now < deadline { await Task.yield() }
            return pending[operation] != nil
        }
        func release(_ operation: Operation) {
            delayed.remove(operation)
            pending.removeValue(forKey: operation)?.resume()
        }
        private func suspend(_ operation: Operation) async {
            guard delayed.contains(operation) else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                precondition(pending[operation] == nil)
                pending[operation] = continuation
            }
        }

        func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse { throw MilaFFIError.unavailable }
        func checkApproval() async throws -> Data { MilaWhoami.approved }
        func refreshSnapshot() async throws -> MilaValidatedSnapshot {
            await suspend(.machines)
            return snapshot
        }
        func threadAction(thread: UUID?, command: String, secondary: String?, input: String?, requestID: UUID?) async throws -> Data {
            if command == "thread ls" {
                listCount += 1
                await suspend(.threads)
                return Data(#"{"version":1,"status":"succeeded","result":{"items":[]}}"#.utf8)
            }
            guard command == "thread show", let thread else { throw MilaFFIError.unavailable }
            shownThreads.append(thread)
            return Data(#"{"version":1,"status":"succeeded","result":{"id":"\#(thread.uuidString.lowercased())","status":"ready"}}"#.utf8)
        }
    }

    private func harness(_ first: SuspendedReads, _ second: SuspendedReads) -> (MilaAppModel, MilaDeployment, MilaDeployment, MilaIsolatedDefaults) {
        let env = MilaIsolatedDefaults()
        let firstDeployment = MilaDeployment(host: "watch-first.example.test", port: 22, trust: Data([1]))
        let secondDeployment = MilaDeployment(host: "watch-second.example.test", port: 22, trust: Data([2]))
        XCTAssertTrue(env.store.upsert(firstDeployment))
        XCTAssertTrue(env.store.upsert(secondDeployment))
        let firstID = firstDeployment.id
        let session = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { deployment in
            deployment.id == firstID ? first : second
        }
        return (MilaAppModel(session: session), firstDeployment, secondDeployment, env)
    }

    private func signIn(_ deployment: MilaDeployment, model: MilaAppModel) async {
        model.signIn.signIn(deployment)
        await model.signIn.settle()
        await assertEventually { model.machines.state == .loaded }
        XCTAssertTrue(model.signIn.isSignedIn)
    }

    func testOldMachineRefreshCannotStartThreadReadOnReplacementSession() async throws {
        let snapshot = try MilaListingFixture.snapshot()
        let first = SuspendedReads(snapshot: snapshot), second = SuspendedReads(snapshot: snapshot)
        let (model, firstDeployment, secondDeployment, env) = harness(first, second)
        defer { model.signIn.signOut(); env.tearDown() }
        await signIn(firstDeployment, model: model)
        await first.delay(.machines)
        let hint = Task { await model.watch.onHint?() }
        let pending = await first.waitUntilPending(.machines)
        XCTAssertTrue(pending)

        await signIn(secondDeployment, model: model)
        await first.release(.machines)
        await hint.value

        let lists = await second.listCount
        XCTAssertEqual(lists, 0, "old watch work must not read through the replacement adapter")
        XCTAssertEqual(model.threads.state, .idle)
    }

    func testOldThreadRefreshCannotSendItsDetailIdentityToReplacementSession() async throws {
        let snapshot = try MilaListingFixture.snapshot()
        let first = SuspendedReads(snapshot: snapshot), second = SuspendedReads(snapshot: snapshot)
        let (model, firstDeployment, secondDeployment, env) = harness(first, second)
        defer { model.signIn.signOut(); env.tearDown() }
        await signIn(firstDeployment, model: model)
        let oldThread = UUID(), currentThread = UUID()
        await model.threads.show(oldThread)
        await first.delay(.threads)
        let hint = Task { await model.watch.onHint?() }
        let pending = await first.waitUntilPending(.threads)
        XCTAssertTrue(pending)

        await signIn(secondDeployment, model: model)
        await model.threads.show(currentThread)
        await first.release(.threads)
        await hint.value

        let shown = await second.shownThreads
        XCTAssertEqual(shown, [currentThread], "an old detail UUID must not cross session authority")
        XCTAssertEqual(model.threads.detail?.id, currentThread)
    }

    func testCurrentWatchHintRefreshesThreadsAndRetainsDetail() async throws {
        let snapshot = try MilaListingFixture.snapshot()
        let first = SuspendedReads(snapshot: snapshot), second = SuspendedReads(snapshot: snapshot)
        let (model, firstDeployment, _, env) = harness(first, second)
        defer { model.signIn.signOut(); env.tearDown() }
        await signIn(firstDeployment, model: model)
        let thread = UUID()
        await model.threads.show(thread)

        await model.watch.onHint?()

        let lists = await first.listCount
        let shown = await first.shownThreads
        XCTAssertEqual(lists, 1)
        XCTAssertEqual(shown, [thread, thread])
        XCTAssertEqual(model.threads.detail?.id, thread)
        XCTAssertEqual(model.threads.state, .loaded)
    }
}
