import Foundation

public enum MilaDeploymentSessionState: Equatable, Sendable {
    case signedOut
    case connecting(UUID)
    case signedIn(UUID, UInt64)
    case failed(UUID, String)
}

/// @cc [owner:ghuntley,label:security] deployment-session-generation
/// Every sign-in/reconnect gets a fresh generation; consumers must discard work from
/// an earlier generation after sign-out or switching deployments. Ending a
/// generation closes its adapter's authenticated Rust session immediately, so a
/// view that still holds the old adapter cannot keep using the connection.
///
/// Coordinates the durable deployment selection with the authenticated adapter.
/// The coordinator is the single owner of session generation fencing for native UI.
public final class MilaDeploymentSessionCoordinator: @unchecked Sendable {
    public typealias AdapterFactory = @Sendable (MilaDeployment) throws -> any MilaFFIAdapter

    private let store: MilaDeploymentStore
    private let defaults: UserDefaults
    private let factory: AdapterFactory
    private let selectionKey = "mila.selectedDeployment"
    private let lock = NSLock()
    private var adapter: (any MilaFFIAdapter)?
    private var generation: UInt64 = 0
    private var currentState: MilaDeploymentSessionState = .signedOut

    public init(store: MilaDeploymentStore = MilaDeploymentStore(), defaults: UserDefaults = .standard, factory: @escaping AdapterFactory) {
        self.store = store; self.defaults = defaults; self.factory = factory
    }

    public var state: MilaDeploymentSessionState { lock.lock(); defer { lock.unlock() }; return currentState }
    public var selectedDeployment: MilaDeployment? {
        lock.lock(); defer { lock.unlock() }
        guard let raw = defaults.string(forKey: selectionKey), let id = UUID(uuidString: raw) else { return nil }
        return store.list().first { $0.id == id }
    }
    public func select(_ deployment: MilaDeployment) -> Bool {
        guard store.list().contains(where: { $0.id == deployment.id }) else { return false }
        // Read the prior selection before taking `lock`. `selectedDeployment` also
        // acquires this non-reentrant lock; calling it while holding the lock would
        // deadlock every deployment switch (including the initial selection).
        let previousID = selectedDeployment?.id
        lock.lock()
        let changed = previousID != deployment.id
        defaults.set(deployment.id.uuidString, forKey: selectionKey)
        var ended: (any MilaFFIAdapter)?
        if changed {
            generation &+= 1
            ended = adapter
            adapter = nil
            currentState = .signedOut
        }
        lock.unlock()
        ended?.close()
        return true
    }
    /// Removes a persisted deployment and fences any session that was using it.
    @discardableResult public func remove(_ id: UUID) -> Bool {
        guard store.list().contains(where: { $0.id == id }) else { return false }
        let selected = selectedDeployment?.id == id
        store.remove(id)
        lock.lock()
        var ended: (any MilaFFIAdapter)?
        if selected {
            generation &+= 1
            ended = adapter
            adapter = nil
            currentState = .signedOut
            defaults.removeObject(forKey: selectionKey)
        }
        lock.unlock()
        ended?.close()
        return true
    }
    @discardableResult public func signIn(_ deployment: MilaDeployment) -> Bool {
        guard Self.valid(deployment), store.list().contains(where: { $0.id == deployment.id }) else { return false }
        lock.lock(); generation &+= 1; let next = generation; let ended = adapter; adapter = nil; currentState = .connecting(deployment.id); lock.unlock()
        ended?.close()
        do {
            let created = try factory(deployment)
            lock.lock()
            guard generation == next else { lock.unlock(); created.close(); return false }
            adapter = created; defaults.set(deployment.id.uuidString, forKey: selectionKey); currentState = .signedIn(deployment.id, next); lock.unlock(); return true
        } catch {
            lock.lock()
            if generation == next { currentState = .failed(deployment.id, String(describing: error)) }
            lock.unlock(); return false
        }
    }
    public func reconnect() -> Bool { guard let deployment = selectedDeployment else { return false }; return signIn(deployment) }
    public func signOut() {
        lock.lock(); generation &+= 1; let ended = adapter; adapter = nil; currentState = .signedOut; lock.unlock()
        ended?.close()
    }
    public func adapter(for expectedGeneration: UInt64) -> (any MilaFFIAdapter)? {
        lock.lock(); defer { lock.unlock() }
        guard case .signedIn(_, let actual) = currentState, actual == expectedGeneration else { return nil }; return adapter
    }
    public func currentGeneration() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    private static func valid(_ value: MilaDeployment) -> Bool { !value.host.isEmpty && value.host.count <= 253 && value.port > 0 && !value.trust.isEmpty }
}

/// Main-actor observable bridge used by SwiftUI to render durable deployment sign-in.
@MainActor
public final class MilaDeploymentSessionController: ObservableObject {
    @Published public private(set) var state: MilaDeploymentSessionState = .signedOut
    @Published public private(set) var deployments: [MilaDeployment] = []
    private let coordinator: MilaDeploymentSessionCoordinator
    private let store: MilaDeploymentStore

    public init(store: MilaDeploymentStore = MilaDeploymentStore(), defaults: UserDefaults = .standard,
                factory: @escaping MilaDeploymentSessionCoordinator.AdapterFactory) {
        self.store = store
        self.coordinator = MilaDeploymentSessionCoordinator(store: store, defaults: defaults, factory: factory)
        self.deployments = store.list()
        self.state = coordinator.state
    }

    public var selectedDeployment: MilaDeployment? { coordinator.selectedDeployment }
    public var generation: UInt64 { coordinator.currentGeneration() }
    public func select(_ deployment: MilaDeployment) { _ = coordinator.select(deployment); state = coordinator.state }
    @discardableResult public func signIn(_ deployment: MilaDeployment) -> Bool {
        let result = coordinator.signIn(deployment); state = coordinator.state; return result
    }
    @discardableResult public func reconnect() -> Bool { let result = coordinator.reconnect(); state = coordinator.state; return result }
    public func signOut() { coordinator.signOut(); state = coordinator.state }
    public func adapter() -> (any MilaFFIAdapter)? {
        guard case .signedIn(_, let generation) = state else { return nil }
        return coordinator.adapter(for: generation)
    }
    public func reload() { deployments = store.list() }
    /// Persists a validated deployment and refreshes the observable list.
    @discardableResult public func upsert(_ deployment: MilaDeployment) -> Bool {
        let result = store.upsert(deployment)
        if result { reload() }
        return result
    }
    /// Forgets a deployment, fencing the authenticated session when necessary.
    @discardableResult public func remove(_ id: UUID) -> Bool {
        let result = coordinator.remove(id)
        if result { state = coordinator.state; reload() }
        return result
    }
}
