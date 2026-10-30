import Foundation
import Combine

public enum MilaMachinesState: Equatable, Sendable {
    case signedOut
    case loading
    case loaded
    case failed
}

/// @cc [owner:ghuntley,label:security] mila-apple-machine-list-binding
/// The machine list and detail are projections of the authenticated Rust
/// listing only (`refreshSnapshot`/`loadMoreSnapshot`). Each bind starts a new
/// token; results from an earlier token, or arriving after sign-out, MUST NOT
/// publish. Rows are capped at 256 and detail is looked up by identity in the
/// current listing, never synthesized.
@MainActor public final class MilaMachinesController: ObservableObject {
    public static let maximumRows = 256
    @Published public private(set) var state: MilaMachinesState = .signedOut
    @Published public private(set) var machines: [MilaMachinePresentation] = []
    @Published public private(set) var hasMore = false
    @Published public private(set) var selectedID: UUID?
    private var adapter: (any MilaFFIAdapter)?
    private var token: UInt64 = 0
    private var inFlight = false

    public init() {}

    /// Binds the controller to an authenticated adapter, or clears it on sign-out.
    public func bind(_ adapter: (any MilaFFIAdapter)?) {
        token &+= 1
        inFlight = false
        self.adapter = adapter
        machines = []
        hasMore = false
        selectedID = nil
        state = adapter == nil ? .signedOut : .loading
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
        } catch {
            guard requested == token else { return }
            inFlight = false
            state = .failed
        }
    }
}
