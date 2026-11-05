import XCTest
@testable import MilaNativeUI

final class MilaDeploymentSessionTests: XCTestCase {
    private func deployment(_ host: String = "mila.example") -> MilaDeployment { MilaDeployment(id: UUID(), host: host, port: 22, trust: Data([1, 2, 3])) }
    func testSelectionAndReconnectUseDurableDeployment() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults); let value = deployment(); XCTAssertTrue(store.upsert(value));
        let coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults) { _ in UnavailableMilaFFIAdapter() }
        XCTAssertTrue(coordinator.select(value)); XCTAssertEqual(coordinator.selectedDeployment?.id, value.id); XCTAssertTrue(coordinator.reconnect());
        if case .signedIn(let id, let generation) = coordinator.state { XCTAssertEqual(id, value.id); XCTAssertGreaterThan(generation, 0); XCTAssertNotNil(coordinator.adapter(for: generation)) } else { XCTFail("expected signed in") }
    }
    func testSignOutFencesOldGeneration() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults); let value = deployment(); XCTAssertTrue(store.upsert(value));
        let coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults) { _ in UnavailableMilaFFIAdapter() }; XCTAssertTrue(coordinator.signIn(value)); let generation = coordinator.currentGeneration(); coordinator.signOut(); XCTAssertNil(coordinator.adapter(for: generation)); XCTAssertEqual(coordinator.state, .signedOut)
    }

    func testSelectingDifferentDeploymentFencesAuthenticatedSession() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults); let first = deployment(); let second = deployment("other.example")
        XCTAssertTrue(store.upsert(first)); XCTAssertTrue(store.upsert(second))
        let coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults) { _ in UnavailableMilaFFIAdapter() }
        XCTAssertTrue(coordinator.signIn(first)); let oldGeneration = coordinator.currentGeneration()
        XCTAssertTrue(coordinator.select(second)); XCTAssertEqual(coordinator.state, .signedOut)
        XCTAssertNil(coordinator.adapter(for: oldGeneration)); XCTAssertGreaterThan(coordinator.currentGeneration(), oldGeneration)
    }
    func testFailedReconnectFencesPriorAuthenticatedGeneration() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults); let value = deployment(); XCTAssertTrue(store.upsert(value))
        final class AttemptCounter: @unchecked Sendable { nonisolated(unsafe) var value = 0 }
        let attempts = AttemptCounter()
        let coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults) { _ in
            attempts.value += 1
            if attempts.value == 1 { return UnavailableMilaFFIAdapter() }
            throw NSError(domain: "test", code: 1)
        }
        XCTAssertTrue(coordinator.signIn(value)); let oldGeneration = coordinator.currentGeneration()
        XCTAssertFalse(coordinator.reconnect())
        XCTAssertNil(coordinator.adapter(for: oldGeneration))
        if case .failed(let id, _) = coordinator.state { XCTAssertEqual(id, value.id) } else { XCTFail("expected failed reconnect") }
    }

    func testForgettingSelectedDeploymentSignsOutAndClearsSelection() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults); let value = deployment(); XCTAssertTrue(store.upsert(value))
        let coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults) { _ in UnavailableMilaFFIAdapter() }
        XCTAssertTrue(coordinator.signIn(value)); let generation = coordinator.currentGeneration()
        XCTAssertTrue(coordinator.remove(value.id)); XCTAssertNil(coordinator.selectedDeployment); XCTAssertEqual(coordinator.state, .signedOut); XCTAssertNil(coordinator.adapter(for: generation)); XCTAssertTrue(store.list().isEmpty)
    }

    func testDeploymentStoreRejectsUnsafeHostAndOversizedTrust() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults)
        XCTAssertFalse(store.upsert(MilaDeployment(id: .zero, host: "mila.example", port: 22, trust: Data([1]))))
        XCTAssertFalse(store.upsert(deployment("bad host.example")))
        XCTAssertFalse(store.upsert(deployment("bad_host.example")))
        XCTAssertFalse(store.upsert(deployment("Mila.example")))
        XCTAssertFalse(store.upsert(MilaDeployment(host: "-bad.example", port: 22, trust: Data([1]))))
        XCTAssertFalse(store.upsert(MilaDeployment(host: "mila.example", port: 22, trust: Data(repeating: 1, count: 65_537))))
    }

    func testSignInRequiresTheExactPersistedDeployment() {
        let suite = "mila.session.\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let store = MilaDeploymentStore(defaults: defaults)
        let persisted = deployment()
        XCTAssertTrue(store.upsert(persisted))
        final class FactoryCounter: @unchecked Sendable { nonisolated(unsafe) var value = 0 }
        let factoryCalls = FactoryCounter()
        let coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults) { _ in
            factoryCalls.value += 1
            return UnavailableMilaFFIAdapter()
        }
        let altered = MilaDeployment(id: persisted.id, host: "other.example", port: persisted.port, trust: persisted.trust)
        XCTAssertFalse(coordinator.signIn(altered))
        XCTAssertEqual(factoryCalls.value, 0, "an altered same-ID deployment must not reach the adapter factory")
        XCTAssertEqual(coordinator.state, .signedOut)
    }
}
