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

    public func endpoint(for machine: UUID) throws -> MilaWebEndpoint {
        guard machineID == machine, !label.isEmpty, label.utf8.count <= 256,
              (visibility == "private" || visibility == "public"),
              route == "overalls://machines/\(machine.uuidString.lowercased())/web",
              let value = url else { throw MilaWebEndpointError.unavailable }
        return try MilaWebEndpoint(value)
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
