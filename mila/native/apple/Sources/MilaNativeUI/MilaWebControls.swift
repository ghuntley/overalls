import Foundation
import SwiftUI

/// A validated HTTPS endpoint exposed by a machine's web control.
public struct MilaWebEndpoint: Equatable, Sendable {
    public let url: URL
    public init(_ value: String) throws {
        guard value.utf8.count <= 2048,
              let parsed = URL(string: value), parsed.scheme?.lowercased() == "https",
              parsed.user == nil, parsed.password == nil, parsed.fragment == nil,
              let host = parsed.host, !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 }),
              parsed.port.map({ (1...65_535).contains($0) }) ?? true else { throw MilaWebEndpointError.invalid }
        self.url = parsed
    }
}

public enum MilaWebEndpointError: Error, Equatable, Sendable {
    case invalid
    case unavailable
    case conflict
    /// The projection is valid but the deployment publishes no web address
    /// (Marshall has no ingress zone), so there is nothing to open.
    case noAddress
}

/// Authenticated projection returned by Rust's `web show --json` command.
/// The endpoint is bound to the requested machine before it can reach WebKit.
public struct MilaWebEndpointProjection: Codable, Equatable, Sendable {
    public let machineID: UUID
    public let label: String
    public let port: UInt16
    public let visibility: String
    public let policyRevision: UInt64
    public let url: String?
    public let route: String

    enum CodingKeys: String, CodingKey {
        case machineID = "machine_id"
        case label, port, visibility
        case policyRevision = "policy_revision"
        case url, route
    }

    /// @cc [owner:ghuntley,label:security;protocol] mila-apple-web-route-host
    /// Marshall's `web show` route is the host-qualified application route
    /// `overalls://<host>/machines/<id>/web` for its public host (ADR-0221,
    /// `Marshall.AppRoutes`). The projection MUST be refused unless its route
    /// is exactly that form for the requested machine and the signed-in
    /// deployment's host: no other host, no port, no hostless form, no query,
    /// fragment or trailing segment. Hosts compare case-insensitively; the
    /// machine identifier MUST be canonical lowercase.
    public static func route(machine: UUID, deploymentHost: String) -> String? {
        guard let host = canonicalHost(deploymentHost) else { return nil }
        return scheme + host + path(machine)
    }

    private static let scheme = "overalls://"
    private static func path(_ machine: UUID) -> String { "/machines/\(machine.uuidString.lowercased())/web" }

    /// A lowercase DNS name of letters, digits, `-` and `.`; nil for anything else.
    private static func canonicalHost(_ value: String) -> String? {
        let host = value.lowercased()
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."),
              host.unicodeScalars.allSatisfy({ scalar in
                  (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 45 || scalar.value == 46
              }) else { return nil }
        return host
    }

    /// True only for `overalls://<deploymentHost>/machines/<machine>/web`.
    static func routeMatches(_ route: String, machine: UUID, deploymentHost: String) -> Bool {
        guard route.utf8.count <= 2048, route.hasPrefix(scheme),
              let expectedHost = canonicalHost(deploymentHost) else { return false }
        let rest = route.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return false }
        let host = String(rest[..<slash])
        // The host is compared case-insensitively but must itself be a plain
        // DNS name: a port, userinfo or any other character is refused.
        return canonicalHost(host) == expectedHost && String(rest[slash...]) == path(machine)
    }

    /// The endpoint to open for `machine` on the signed-in deployment `deploymentHost`.
    /// Throws `.invalid` when the projection is not this machine's on this
    /// deployment, and `.noAddress` when it is but no web address is published.
    public func endpoint(for machine: UUID, deploymentHost: String) throws -> MilaWebEndpoint {
        guard machineID == machine, !label.isEmpty, label.utf8.count <= 256,
              (visibility == "private" || visibility == "public"),
              Self.routeMatches(route, machine: machine, deploymentHost: deploymentHost) else { throw MilaWebEndpointError.invalid }
        guard let value = url else { throw MilaWebEndpointError.noAddress }
        return try MilaWebEndpoint(value)
    }
}

/// Who can open a machine's web address (`web set --public|--private`).
public enum MilaWebVisibility: String, CaseIterable, Identifiable, Sendable {
    case privateAccess = "private"
    case publicAccess = "public"
    public var id: String { rawValue }
}

public enum MilaWebPolicyState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case submitting
    case failed(MilaWebEndpointError)
}

/// @cc [owner:ghuntley,label:security;protocol] mila-apple-web-policy-control
/// The SwiftUI public/private control for one machine. A change MUST be sent
/// through the adapter's `MilaLiveSession.webSet` at the policy revision of the
/// projection last read for this machine, keeping its port, under a fresh
/// request ID. It is reported applied only when a re-read shows the wanted
/// visibility at a newer revision. A refusal re-reads the projection so the
/// control shows the server's current value, and `revision_conflict` is
/// reported as a conflict. A projection for another machine is never shown.
@MainActor public final class MilaWebPolicyController: ObservableObject {
    @Published public private(set) var projection: MilaWebEndpointProjection?
    @Published public private(set) var state: MilaWebPolicyState = .idle
    public let machine: UUID
    private let adapter: any MilaFFIAdapter

    public init(adapter: any MilaFFIAdapter, machine: UUID) {
        self.adapter = adapter
        self.machine = machine
    }

    /// The server's current visibility, once a projection has been read.
    public var visibility: MilaWebVisibility? { projection.flatMap { MilaWebVisibility(rawValue: $0.visibility) } }
    public var isBusy: Bool { state == .loading || state == .submitting }

    public func load() async {
        guard !isBusy else { return }
        state = .loading
        do {
            projection = try await read()
            state = .loaded
        } catch {
            projection = nil
            state = .failed(.unavailable)
        }
    }

    public func set(_ wanted: MilaWebVisibility, requestID: UUID = UUID()) async {
        guard !isBusy, let current = projection, current.policyRevision > 0,
              current.visibility != wanted.rawValue, requestID != UUID.zero else { return }
        state = .submitting
        do {
            try await adapter.setWebVisibility(machine: machine, port: current.port, publicAccess: wanted == .publicAccess,
                                               revision: current.policyRevision, requestID: requestID)
        } catch {
            projection = (try? await read()) ?? current
            state = .failed((error as? MilaWebEndpointError) ?? .unavailable)
            return
        }
        do {
            let after = try await read()
            projection = after
            state = after.visibility == wanted.rawValue && after.policyRevision > current.policyRevision ? .loaded : .failed(.conflict)
        } catch {
            state = .failed(.unavailable)
        }
    }

    private func read() async throws -> MilaWebEndpointProjection {
        let value = try await adapter.webEndpointProjection(machine: machine)
        guard value.machineID == machine else { throw MilaWebEndpointError.invalid }
        return value
    }
}

@MainActor public final class MilaWebControlsController: ObservableObject {
    @Published public private(set) var endpoint: MilaWebEndpoint?
    @Published public private(set) var policyRevision: UInt64 = 0
    @Published public private(set) var error: MilaWebEndpointError?
    public init() {}
    @discardableResult public func set(_ value: String) -> Bool {
        do { endpoint = try MilaWebEndpoint(value); error = nil; return true }
        catch { endpoint = nil; self.error = MilaWebEndpointError.invalid; return false }
    }
    public func open(_ endpoint: MilaWebEndpoint) { self.endpoint = endpoint; error = nil }
    /// Commits an endpoint only while the authenticated session is still active.
    /// A reconnect/sign-out race therefore cannot publish stale WebView state.
    @discardableResult public func openAuthenticated(_ endpoint: MilaWebEndpoint, sessionActive: Bool) -> Bool {
        guard sessionActive else { clear(); error = MilaWebEndpointError.unavailable; return false }
        open(endpoint)
        return true
    }
    /// Commits a projection only when the optimistic policy revision still matches.
    @discardableResult public func openAuthenticated(_ endpoint: MilaWebEndpoint, sessionActive: Bool,
                                                     policyRevision: UInt64, expectedRevision: UInt64) -> Bool {
        guard sessionActive else { clear(); error = MilaWebEndpointError.unavailable; return false }
        guard policyRevision > 0, policyRevision == expectedRevision else {
            self.endpoint = nil
            error = MilaWebEndpointError.conflict
            return false
        }
        self.endpoint = endpoint
        self.policyRevision = policyRevision
        error = nil
        return true
    }
    /// Invalidates all web state when the authenticated session ends or changes.
    /// This prevents a previous deployment endpoint from surviving sign-out.
    public func invalidateSession() { clear() }
    public func clear() { endpoint = nil; policyRevision = 0; error = nil }
}

public enum MilaWebViewPhase: Equatable, Sendable {
    case idle
    case loading(generation: UInt64)
    case loaded(generation: UInt64)
    case failed(generation: UInt64)
    case blocked(generation: UInt64)
    case closed
}

/// @cc [owner:ghuntley,label:security] mila-apple-webview-lifecycle
/// A web view is bound to one endpoint and one generation. Navigation events
/// from an earlier generation MUST NOT change the phase; `invalidate` (sign-out,
/// session change, dismissal) ends the generation and requests teardown, which
/// stops loading, detaches the delegate and discards the view's ephemeral
/// (non-persistent) website data store.
@MainActor public final class MilaWebViewLifecycle: ObservableObject {
    @Published public private(set) var phase: MilaWebViewPhase = .idle
    @Published public private(set) var endpoint: MilaWebEndpoint?
    public private(set) var generation: UInt64 = 0
    public init() {}

    /// Starts a new generation for an authenticated endpoint.
    @discardableResult public func begin(_ endpoint: MilaWebEndpoint, sessionActive: Bool) -> UInt64? {
        generation &+= 1
        guard sessionActive else { self.endpoint = nil; phase = .closed; return nil }
        self.endpoint = endpoint
        phase = .loading(generation: generation)
        return generation
    }

    public func didStart(_ generation: UInt64) { guard live(generation) else { return }; phase = .loading(generation: generation) }
    public func didFinish(_ generation: UInt64) { guard live(generation) else { return }; phase = .loaded(generation: generation) }
    public func didFail(_ generation: UInt64) { guard live(generation) else { return }; phase = .failed(generation: generation) }
    public func didBlock(_ generation: UInt64) { guard live(generation) else { return }; phase = .blocked(generation: generation) }

    public func invalidate() { generation &+= 1; endpoint = nil; phase = .closed }

    /// Ends `candidate` only if it is still current (a dismissed view must not
    /// close a newer one that replaced it).
    public func end(_ candidate: UInt64) { if candidate == generation { invalidate() } }

    private func live(_ candidate: UInt64) -> Bool { candidate == generation && endpoint != nil && phase != .closed }
}

#if canImport(WebKit)
import WebKit

/// Native embedded web controls for iOS and macOS. Navigation remains HTTPS-only.
public struct MilaWebView: View {
    public let endpoint: MilaWebEndpoint
    @ObservedObject private var lifecycle: MilaWebViewLifecycle
    private let generation: UInt64
    public init(endpoint: MilaWebEndpoint, lifecycle: MilaWebViewLifecycle, generation: UInt64) {
        self.endpoint = endpoint; self.lifecycle = lifecycle; self.generation = generation
    }
    public var body: some View {
        Group {
            if lifecycle.generation == generation, lifecycle.endpoint == endpoint {
                MilaWebViewRepresentable(url: endpoint.url, lifecycle: lifecycle, generation: generation)
            } else {
                ContentUnavailableView(MilaStrings.text(.webFailed), systemImage: "globe")
            }
        }
    }
}

/// @cc [owner:ghuntley,label:security] web-navigation-same-origin
/// WebKit MUST consult this delegate for every navigation, so its method MUST
/// match `WKNavigationDelegate`'s `@MainActor @Sendable` handler signature; a
/// near miss is silently never called. It MUST cancel any navigation that is
/// not HTTPS, carries credentials, or leaves the endpoint's host and port.
@MainActor final class MilaWebNavigationGuard: NSObject, WKNavigationDelegate {
    let origin: URL
    let lifecycle: MilaWebViewLifecycle?
    let generation: UInt64
    init(origin: URL, lifecycle: MilaWebViewLifecycle? = nil, generation: UInt64 = 0) {
        self.origin = origin; self.lifecycle = lifecycle; self.generation = generation
    }
    func allows(_ candidate: URL?) -> Bool {
        guard let candidate,
              candidate.scheme?.lowercased() == "https",
              candidate.user == nil, candidate.password == nil,
              candidate.host?.lowercased() == origin.host?.lowercased(),
              candidate.port == origin.port else { return false }
        return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = allows(navigationAction.request.url)
        if !allowed { lifecycle?.didBlock(generation) }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { lifecycle?.didStart(generation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { lifecycle?.didFinish(generation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { lifecycle?.didFail(generation) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { lifecycle?.didFail(generation) }
}

/// Creates and tears down the platform web view for one lifecycle generation.
@MainActor enum MilaWebViewFactory {
    static func make(url: URL, delegate: MilaWebNavigationGuard) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Cookies and storage for a machine endpoint never outlive this view.
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = delegate
        view.load(URLRequest(url: url))
        return view
    }

    static func update(_ view: WKWebView, url: URL, lifecycle: MilaWebViewLifecycle?, generation: UInt64) {
        guard let lifecycle, lifecycle.generation == generation, lifecycle.endpoint?.url == url else {
            teardown(view)
            return
        }
        guard view.url != url, !view.isLoading else { return }
        view.load(URLRequest(url: url))
    }

    static func teardown(_ view: WKWebView) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
}

#if os(iOS)
struct MilaWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let lifecycle: MilaWebViewLifecycle
    let generation: UInt64
    func makeCoordinator() -> MilaWebNavigationGuard { MilaWebNavigationGuard(origin: url, lifecycle: lifecycle, generation: generation) }
    func makeUIView(context: Context) -> WKWebView { MilaWebViewFactory.make(url: url, delegate: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { MilaWebViewFactory.update(view, url: url, lifecycle: lifecycle, generation: generation) }
    static func dismantleUIView(_ view: WKWebView, coordinator: MilaWebNavigationGuard) {
        MilaWebViewFactory.teardown(view)
        coordinator.lifecycle?.end(coordinator.generation)
    }
}
#elseif os(macOS)
struct MilaWebViewRepresentable: NSViewRepresentable {
    let url: URL
    let lifecycle: MilaWebViewLifecycle
    let generation: UInt64
    func makeCoordinator() -> MilaWebNavigationGuard { MilaWebNavigationGuard(origin: url, lifecycle: lifecycle, generation: generation) }
    func makeNSView(context: Context) -> WKWebView { MilaWebViewFactory.make(url: url, delegate: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { MilaWebViewFactory.update(view, url: url, lifecycle: lifecycle, generation: generation) }
    static func dismantleNSView(_ view: WKWebView, coordinator: MilaWebNavigationGuard) {
        MilaWebViewFactory.teardown(view)
        coordinator.lifecycle?.end(coordinator.generation)
    }
}
#endif
#endif
