import XCTest
@testable import MilaNativeUI

final class MilaDeepLinkRouterTests: XCTestCase {
    func testSignedOutLinksDoNotOpen() {
        var router = MilaDeepLinkRouter()
        XCTAssertEqual(router.decide("overalls://fleet.example/machines"), .signedOut(.machines))
    }

    func testGenerationFencesAuthenticatedLinks() {
        var router = MilaDeepLinkRouter()
        router.setSession(signedIn: true, deploymentHost: "fleet.example")
        let decision = router.decide("overalls://fleet.example/settings")
        guard case .open(_, let generation) = decision else { return XCTFail("expected open") }
        XCTAssertTrue(router.accepts(decision, generation: generation))
        router.setSession(signedIn: false)
        XCTAssertFalse(router.accepts(decision, generation: generation))
    }

    func testSignedOutDecisionCannotBeAcceptedAfterSessionReset() {
        var router = MilaDeepLinkRouter()
        router.setSession(signedIn: true, deploymentHost: "fleet.example")
        let authenticated = router.decide("overalls://fleet.example/machines")
        guard case .open(_, let generation) = authenticated else { return XCTFail("expected open") }
        router.setSession(signedIn: false)
        let signedOut = router.decide("overalls://fleet.example/machines")
        XCTAssertEqual(signedOut, .signedOut(.machines))
        XCTAssertFalse(router.accepts(signedOut, generation: generation))
        XCTAssertFalse(router.accepts(authenticated, generation: generation))
    }

    func testAnotherDeploymentCannotNavigateAuthenticatedSession() {
        var router = MilaDeepLinkRouter()
        router.setSession(signedIn: true, deploymentHost: "fleet.example")
        XCTAssertEqual(router.decide("overalls://other.example/settings"), .unknown)
    }

    func testMalformedLinksAreUnknown() {
        var router = MilaDeepLinkRouter()
        router.setSession(signedIn: true, deploymentHost: "fleet.example")
        XCTAssertEqual(router.decide("overalls://fleet.example/settings?command=delete"), .unknown)
    }
}

