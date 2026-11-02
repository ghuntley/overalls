import WebKit
import XCTest
@testable import MilaNativeUI

@MainActor private final class PolicyBox { var policy: WKNavigationActionPolicy? }

private final class StubNavigationAction: WKNavigationAction {
    private let stubRequest: URLRequest
    init(_ url: String) { stubRequest = URLRequest(url: URL(string: url)!); super.init() }
    override var request: URLRequest { stubRequest }
}

final class MilaWebControlsTests: XCTestCase {
    @MainActor func testHTTPSOnlyAndCredentialFreeEndpoint() {
        let controller = MilaWebControlsController()
        XCTAssertTrue(controller.set("https://console.example.test/control"))
        XCTAssertNotNil(controller.endpoint)
        XCTAssertFalse(controller.set("http://console.example.test"))
        XCTAssertNil(controller.endpoint)
        XCTAssertFalse(controller.set("https://user:secret@console.example.test"))
        XCTAssertFalse(controller.set("https://console.example.test/#fragment"))
        XCTAssertFalse(controller.set("https://console.example.test:0"))
        XCTAssertFalse(controller.set("https://console.example.test:65536"))
        XCTAssertFalse(controller.set("https://console example.test"))
        XCTAssertFalse(controller.set("https://:443/control"))
    }

    @MainActor func testAsyncEndpointCommitRejectsSignedOutSession() throws {
        let controller = MilaWebControlsController()
        let endpoint = try MilaWebEndpoint("https://console.example.test/")
        XCTAssertFalse(controller.openAuthenticated(endpoint, sessionActive: false))
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(controller.error, .unavailable)
        XCTAssertTrue(controller.openAuthenticated(endpoint, sessionActive: true))
        XCTAssertEqual(controller.endpoint, endpoint)
    }

    @MainActor func testOptimisticRevisionConflictFailsClosed() throws {
        let controller = MilaWebControlsController()
        let endpoint = try MilaWebEndpoint("https://console.example.test/")
        XCTAssertTrue(controller.openAuthenticated(endpoint, sessionActive: true, policyRevision: 4, expectedRevision: 4))
        XCTAssertFalse(controller.openAuthenticated(endpoint, sessionActive: true, policyRevision: 5, expectedRevision: 4))
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(controller.error, .conflict)
        XCTAssertFalse(controller.openAuthenticated(endpoint, sessionActive: true, policyRevision: 0, expectedRevision: 0))
    }

    private func projection(_ id: UUID, route: String, url: String? = "https://console.example.test/") throws -> MilaWebEndpointProjection {
        var object: [String: Any] = ["machine_id": id.uuidString.lowercased(), "label": "Console", "port": 443, "visibility": "private",
                                     "policy_revision": 7, "route": route]
        if let url { object["url"] = url } else { object["url"] = NSNull() }
        return try JSONDecoder().decode(MilaWebEndpointProjection.self, from: try JSONSerialization.data(withJSONObject: object))
    }

    func testAuthenticatedProjectionIsMachineBoundAndHTTPSOnly() throws {
        let id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let accepted = try projection(id, route: "overalls://overalls.example/machines/\(id.uuidString.lowercased())/web")
        XCTAssertEqual(try accepted.endpoint(for: id, deploymentHost: "overalls.example").url.absoluteString, "https://console.example.test/")
        XCTAssertThrowsError(try accepted.endpoint(for: UUID(), deploymentHost: "overalls.example")) { XCTAssertEqual($0 as? MilaWebEndpointError, .invalid) }
        let insecure = try projection(id, route: "overalls://overalls.example/machines/\(id.uuidString.lowercased())/web", url: "http://console.example.test/")
        XCTAssertThrowsError(try insecure.endpoint(for: id, deploymentHost: "overalls.example")) { XCTAssertEqual($0 as? MilaWebEndpointError, .invalid) }
    }

    /// Marshall's route (`Marshall.AppRoutes`, protocol/test/fixtures/porsche_client_results.json)
    /// is host-qualified; only the signed-in deployment's exact form is accepted.
    func testProjectionRouteMustBeTheSignedInDeploymentsHostQualifiedRoute() throws {
        let id = UUID(uuidString: "019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a")!
        let canonical = "overalls://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web"
        XCTAssertEqual(MilaWebEndpointProjection.route(machine: id, deploymentHost: "marshall.example.test"), canonical)
        XCTAssertEqual(MilaWebEndpointProjection.route(machine: id, deploymentHost: "Marshall.Example.Test"), canonical)
        XCTAssertNil(MilaWebEndpointProjection.route(machine: id, deploymentHost: "marshall.example.test:443"))
        XCTAssertNil(MilaWebEndpointProjection.route(machine: id, deploymentHost: ""))

        XCTAssertNoThrow(try projection(id, route: canonical).endpoint(for: id, deploymentHost: "marshall.example.test"))
        XCTAssertNoThrow(try projection(id, route: canonical).endpoint(for: id, deploymentHost: "MARSHALL.example.test"))
        let refused = [
            "overalls://machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web",
            "overalls://other.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web",
            "overalls://marshall.example.test:8443/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web",
            "overalls://user@marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web",
            "overalls://marshall.example.test/machines/019A0F6E-7C1D-7B52-9B1E-4C3A2D1E0F9A/web",
            "overalls://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web/",
            "overalls://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web?x=1",
            "overalls://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web#f",
            "overalls://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a",
            "overalls://marshall.example.test/machines/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/web",
            "https://marshall.example.test/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web",
            "overalls://marshall.example.test.evil.example/machines/019a0f6e-7c1d-7b52-9b1e-4c3a2d1e0f9a/web",
        ]
        for route in refused {
            XCTAssertThrowsError(try projection(id, route: route).endpoint(for: id, deploymentHost: "marshall.example.test"), route) {
                XCTAssertEqual($0 as? MilaWebEndpointError, .invalid, route)
            }
        }
        // The route is accepted but the deployment publishes no address (no ingress zone).
        XCTAssertThrowsError(try projection(id, route: canonical, url: nil).endpoint(for: id, deploymentHost: "marshall.example.test")) {
            XCTAssertEqual($0 as? MilaWebEndpointError, .noAddress)
        }
    }

    @MainActor func testSessionInvalidationClearsPublishedWebState() throws {
        let controller = MilaWebControlsController()
        let endpoint = try MilaWebEndpoint("https://console.example.test/")
        XCTAssertTrue(controller.openAuthenticated(endpoint, sessionActive: true, policyRevision: 3, expectedRevision: 3))
        controller.invalidateSession()
        XCTAssertNil(controller.endpoint)
        XCTAssertEqual(controller.policyRevision, 0)
        XCTAssertNil(controller.error)
    }

    /// Calls the delegate the way WebKit does, through the optional protocol
    /// requirement, so a signature that no longer matches fails here.
    @MainActor func testNavigationGuardIsReachedThroughWebKitProtocol() {
        let delegate: any WKNavigationDelegate = MilaWebNavigationGuard(origin: URL(string: "https://console.example.test:8443/app")!)
        let cases: [(String, WKNavigationActionPolicy)] = [
            ("https://console.example.test:8443/other", .allow),
            ("https://CONSOLE.example.test:8443/", .allow),
            ("http://console.example.test:8443/", .cancel),
            ("https://console.example.test/", .cancel),
            ("https://evil.example.test:8443/", .cancel),
            ("https://user:secret@console.example.test:8443/", .cancel),
        ]
        for (url, expected) in cases {
            let decision = PolicyBox()
            let reached: Void? = delegate.webView?(WKWebView(frame: .zero), decidePolicyFor: StubNavigationAction(url),
                                                   decisionHandler: { decision.policy = $0 })
            XCTAssertNotNil(reached, "WebKit cannot reach the navigation guard")
            XCTAssertEqual(decision.policy, expected, url)
        }
    }
}
