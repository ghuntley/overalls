import CryptoKit
import Foundation
import Security
import XCTest
@testable import MilaNativeUI

/// Trust reconciliation through the linked Rust ABI, with the shared transport fixture.
final class MilaTrustDocumentTests: XCTestCase {
    private func ca(_ index: Int) throws -> String {
        // Tests/MilaNativeUITests/<file> -> mila/native/apple -> mila
        let mila = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: mila.appendingPathComponent("rust/mila-transport/tests/fixtures/ssh_host_certificates.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let certificates = try XCTUnwrap(root["certificates"] as? [[String: Any]])
        return try XCTUnwrap(certificates[index]["ca"] as? String)
    }

    private func trust(_ ca: String, retirement: UInt64, host: String = "overalls.example") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "ca": ca, "management_host": host, "zone": "apps.overalls.example", "retirement": retirement])
    }

    func testReconcileAcceptsFetchedTrustForHostAndRefusesForeignHost() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let fetched = try trust(try ca(0), retirement: 3_000)
        let selected = try MilaTrustDocument.reconcile(pinned: nil, fetched: fetched, host: "overalls.example", now: now)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: selected) as? [String: Any])
        XCTAssertEqual(value["retirement"] as? Int, 3_000)
        XCTAssertThrowsError(try MilaTrustDocument.reconcile(pinned: nil, fetched: fetched, host: "other.example", now: now))
        XCTAssertThrowsError(try MilaTrustDocument.reconcile(pinned: nil, fetched: Data("{}".utf8), host: "overalls.example", now: now))
        let pinned = try MilaTrustDocument.reconcile(pinned: selected, fetched: nil, host: "overalls.example", now: now)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: pinned) as? [String: Any])["ca"] as? String, try ca(0))
        XCTAssertEqual(MilaTrustDocument.url(host: "localhost", port: 8443)?.absoluteString, "https://localhost:8443/bin/ssh-trust.json")
        XCTAssertEqual(MilaTrustDocument.url(host: "overalls.example")?.absoluteString, "https://overalls.example/bin/ssh-trust.json")
    }
}

/// Fixture descriptor v1 (see the hermetic Marshall+Porsche journey fixture).
struct MilaJourneyDescriptor: Decodable {
    struct Deployment: Decodable { let host: String; let sshPort: UInt16; let httpsPort: UInt16
        enum CodingKeys: String, CodingKey { case host, sshPort = "ssh_port", httpsPort = "https_port" } }
    struct TLS: Decodable { let caPEM: String; let serverName: String
        enum CodingKeys: String, CodingKey { case caPEM = "ca_pem", serverName = "server_name" } }
    struct Approver: Decodable { let url: URL; let bearerToken: String
        enum CodingKeys: String, CodingKey { case url, bearerToken = "bearer_token" } }
    struct Seed: Decodable { let machineName: String; let sharePrincipal: String
        enum CodingKeys: String, CodingKey { case machineName = "machine_name", sharePrincipal = "share_principal" } }
    let version: Int
    let deployment: Deployment
    let tls: TLS
    let approver: Approver
    let seed: Seed

    static func load(_ path: String) throws -> MilaJourneyDescriptor {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 64 * 1024 else { throw MilaTrustError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, !value.deployment.host.isEmpty, value.deployment.sshPort > 0, value.deployment.httpsPort > 0,
              value.tls.caPEM.contains("BEGIN CERTIFICATE"), value.approver.url.scheme == "https" || value.approver.url.scheme == "http",
              !value.approver.bearerToken.isEmpty, !value.seed.machineName.isEmpty else { throw MilaTrustError.invalid }
        return value
    }

    func anchor() throws -> SecCertificate {
        let body = tls.caPEM.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw MilaTrustError.invalid
        }
        return certificate
    }
}

/// Validates HTTPS only against the fixture CA and server name.
private final class MilaPinnedTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let anchor: SecCertificate
    let serverName: String
    init(anchor: SecCertificate, serverName: String) { self.anchor = anchor; self.serverName = serverName }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, serverName as CFString))
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Disposable software P-256 key for the fixture journey only. Production
/// custody remains Secure Enclave (`MilaDeviceSigner`); this lives in the test target.
private final class MilaFixtureSigner: MilaSessionSigner, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()
    var openSSHPublicKey: String {
        var blob = Data()
        for field in [Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), key.publicKey.x963Representation] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { blob.append(contentsOf: $0) }
            blob.append(field)
        }
        return "ecdsa-sha2-nistp256 " + blob.base64EncodedString()
    }
    func sign(message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// End-to-end journey against the hermetic fixture. Runs only when
/// `MILA_JOURNEY_DESCRIPTOR` names a descriptor file; otherwise skipped.
@MainActor final class MilaFixtureJourneyTests: XCTestCase {
    func testSignInApprovalListingShareAndKeysAgainstFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["MILA_JOURNEY_DESCRIPTOR"], !path.isEmpty else {
            throw XCTSkip("MILA_JOURNEY_DESCRIPTOR is not set; the live fixture journey is not configured")
        }
        let descriptor = try MilaJourneyDescriptor.load(path)
        let tls = MilaPinnedTLSDelegate(anchor: try descriptor.anchor(), serverName: descriptor.tls.serverName)
        let http = URLSession(configuration: .ephemeral, delegate: tls, delegateQueue: nil)
        defer { http.invalidateAndCancel() }

        let trustURL = try XCTUnwrap(MilaTrustDocument.url(host: descriptor.deployment.host, port: descriptor.deployment.httpsPort))
        let (fetched, response) = try await http.data(from: trustURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let trust = try MilaTrustDocument.reconcile(pinned: nil, fetched: fetched, host: descriptor.deployment.host)

        let env = MilaIsolatedDefaults(); defer { env.tearDown() }
        let deployment = MilaDeployment(host: descriptor.deployment.host, port: descriptor.deployment.sshPort, trust: trust)
        XCTAssertTrue(env.store.upsert(deployment))
        let signer = MilaFixtureSigner()
        let sessions = MilaDeploymentSessionController(store: env.store, defaults: env.defaults) { value in
            LinkedMilaFFIAdapter(session: try MilaLiveSession(trust: value.trust, host: value.host, port: value.port, sessionSigner: signer))
        }
        let model = MilaAppModel(session: sessions, signIn: MilaSignInController(session: sessions, pollInterval: .seconds(1), approvalLifetime: 120))
        model.signIn.signIn(deployment)

        let approvalSeen = await eventually({ model.signIn.approvalURL != nil || model.signIn.isSignedIn }, iterations: 6_000)
        XCTAssertTrue(approvalSeen, "phase: \(model.signIn.phase)")
        if case .awaitingApproval(_, let info) = model.signIn.phase {
            XCTAssertEqual(info.url.host, descriptor.deployment.host)
            var request = URLRequest(url: descriptor.approver.url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(descriptor.approver.bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["approval_url": info.url.absoluteString, "fingerprint": info.fingerprint])
            let (_, approved) = try await http.data(for: request)
            XCTAssertTrue((200..<300).contains((approved as? HTTPURLResponse)?.statusCode ?? 0))
        }
        await model.signIn.settle()
        guard case .signedIn = model.signIn.phase else { return XCTFail("sign-in ended in \(model.signIn.phase)") }

        await assertEventually({ model.machines.state == .loaded || model.machines.state == .failed }, iterations: 6_000)
        XCTAssertEqual(model.machines.state, .loaded)
        let machine = try XCTUnwrap(model.machines.machines.first { $0.machine.name == descriptor.seed.machineName })

        let sharing = MilaMachineSharingController(adapter: try XCTUnwrap(model.adapter))
        sharing.setSession(signedIn: true, machine: machine)
        sharing.submit(principal: descriptor.seed.sharePrincipal, role: .viewer)
        await assertEventually({ if case .submitting = sharing.state { return false }; return true }, iterations: 6_000)
        guard case .applied(_, _, false) = sharing.state else { return XCTFail("share add: \(sharing.state)") }
        sharing.submit(principal: descriptor.seed.sharePrincipal, remove: true)
        await assertEventually({ if case .submitting = sharing.state { return false }; return true }, iterations: 6_000)
        guard case .applied(_, _, true) = sharing.state else { return XCTFail("share remove: \(sharing.state)") }

        let keys = try await XCTUnwrap(model.adapter).listSSHKeys()
        XCTAssertFalse(keys.isEmpty, "the approved device key is listed")
        await model.threads.list()
        XCTAssertEqual(model.threads.state, .loaded)

        model.signIn.signOut()
        XCTAssertEqual(model.machines.state, .signedOut)
    }
}
