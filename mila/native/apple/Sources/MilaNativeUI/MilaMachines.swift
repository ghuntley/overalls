import Foundation
import Combine

public enum MilaMachinesState: Equatable, Sendable {
    case signedOut
    case loading
    case loaded
    case offline
    case failed
}

/// @cc [owner:ghuntley,label:security] mila-apple-machine-list-binding
/// Live rows derive from the authenticated Rust listing; offline rows derive
/// from a Rust-validated deployment-bound snapshot with all actions removed.
/// Each bind starts a new token; results from an earlier token MUST NOT publish
/// or persist. Rows are capped at Rust's 500-machine listing limit; cached rows
/// grant no session authority.
@MainActor public final class MilaMachinesController: ObservableObject {
    public static let maximumRows = 500
    @Published public private(set) var state: MilaMachinesState = .signedOut
    @Published public private(set) var machines: [MilaMachinePresentation] = []
    @Published public private(set) var hasMore = false
    @Published public private(set) var selectedID: UUID?
    private var adapter: (any MilaFFIAdapter)?
    private var token: UInt64 = 0
    private var inFlight = false
    private let snapshots: MilaSnapshotStore
    private var deployment: MilaDeployment?
    private var snapshotGeneration: UInt64 = 0

    public init(snapshots: MilaSnapshotStore = MilaSnapshotStore()) { self.snapshots = snapshots }

    /// @cc [owner:ghuntley,label:security;privacy] mila-apple-snapshot-seed
    /// An injected snapshot MUST be displayed only as an offline projection. It
    /// MUST NOT create an authenticated adapter, expose lifecycle actions, or
    /// survive the next session-generation bind.
    public func seed(_ snapshot: MilaValidatedSnapshot) {
        token &+= 1
        inFlight = false
        machines = Array(snapshot.machines.prefix(Self.maximumRows))
        hasMore = false
        selectedID = nil
        state = .offline
    }

    /// Binds the controller to an authenticated adapter, or clears it on sign-out.
    public func bind(_ adapter: (any MilaFFIAdapter)?, deployment: MilaDeployment? = nil) {
        token &+= 1
        inFlight = false
        self.adapter = adapter
        self.deployment = deployment
        snapshotGeneration = snapshots.bind(host: deployment?.host, port: deployment?.port)
        machines = []
        hasMore = false
        selectedID = nil
        state = adapter == nil ? .signedOut : .loading
        if adapter == nil { showOffline() }
    }

    public var detail: MilaMachinePresentation? {
        guard let selectedID else { return nil }
        return machine(selectedID)
    }

    public func machine(_ id: UUID) -> MilaMachinePresentation? { machines.first { $0.id == id } }

    /// Selects a machine present in the current listing; unknown identities clear selection.
    public func select(_ id: UUID?) {
        selectedID = id.flatMap { machine($0)?.id }
    }

    public func refresh() async { await load(more: false) }

    public func loadMore() async {
        guard hasMore, state == .loaded else { return }
        await load(more: true)
    }

    private func showOffline() {
        guard let deployment, let cached = try? snapshots.load(host: deployment.host, port: deployment.port) else { return }
        machines = Array(cached.machines.prefix(Self.maximumRows))
        hasMore = false
        selectedID = nil
        state = .offline
    }

    private func load(more: Bool) async {
        guard let adapter, !inFlight else { return }
        let requested = token
        inFlight = true
        if !more { state = .loading }
        do {
            let snapshot = more ? try await adapter.loadMoreSnapshot() : try await adapter.refreshSnapshot()
            guard requested == token else { return }
            inFlight = false
            machines = Array(snapshot.machines.prefix(Self.maximumRows))
            hasMore = snapshot.metadata.hasMore && machines.count < Self.maximumRows
            if let selectedID, machine(selectedID) == nil { self.selectedID = nil }
            state = .loaded
            if !snapshot.metadata.hasMore, let deployment {
                let cacheGeneration = snapshotGeneration
                let savedAt = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
                if let bytes = try? await adapter.snapshotData(savedAt: savedAt), requested == token {
                    try? snapshots.save(bytes, host: deployment.host, port: deployment.port, generation: cacheGeneration)
                }
            }
        } catch {
            guard requested == token else { return }
            inFlight = false
            state = .failed
            showOffline()
        }
    }
}
