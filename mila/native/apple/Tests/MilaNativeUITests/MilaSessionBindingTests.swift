import XCTest
@testable import MilaNativeUI
#if canImport(WebKit)
import WebKit
#endif

/// Terminal PTY binding to the authenticated Rust session (`MilaPtySession`).
@MainActor final class MilaPtyBindingTests: XCTestCase {
    func testAttachStreamsOutputThroughAuthenticatedTransport() async throws {
        let session = RecordingSession()
        session.ptyOutput = [Data("hello ".utf8), Data(), Data("world".utf8)]
        let adapter = LinkedMilaFFIAdapter(session: session)
        let transport = try XCTUnwrap(adapter.terminalTransport())
        let controller = MilaTerminalController(transport: transport)
        await controller.attach(columns: 100, rows: 30)
        XCTAssertEqual(controller.state, .attached)
        await assertEventually { String(decoding: controller.output, as: UTF8.self) == "hello world" }
        await controller.sendInput(Data("ls\n".utf8))
        await controller.resize(columns: 120, rows: 40)
        await controller.close()
        let terminal: UInt64 = 101
        XCTAssertEqual(session.calls.first, .ptyAttach(100, 30))
        XCTAssertTrue(session.calls.contains(.ptyInput(terminal, Data("ls\n".utf8))))
        XCTAssertTrue(session.calls.contains(.ptyResize(terminal, 120, 40)))
        XCTAssertTrue(session.calls.contains(.ptyKill(terminal)))
        XCTAssertEqual(session.calls.filter { if case .ptyAttach = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(controller.output.isEmpty)
    }

    func testReattachKillsPreviousHandleAndAdvancesGeneration() async throws {
        let session = RecordingSession()
        let transport = MilaLiveSessionTerminalTransport(session: session, idle: .milliseconds(1))
        try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true)
        let first = transport.currentGeneration
        try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true)
        XCTAssertGreaterThan(transport.currentGeneration, first)
        XCTAssertTrue(session.calls.contains(.ptyKill(101)))
        await transport.close()
        XCTAssertEqual(transport.currentGeneration, 0)
        XCTAssertEqual(session.calls.last, .ptyKill(102))
        let ended = try await transport.receiveOutput()
        XCTAssertNil(ended, "a closed transport ends the stream")
    }

    func testDeauthenticatedSessionEndsStreamAndRefusesOperations() async throws {
        let session = RecordingSession()
        let transport = MilaLiveSessionTerminalTransport(session: session, idle: .milliseconds(1))
        try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true)
        session.close()
        let ended = try await transport.receiveOutput()
        XCTAssertNil(ended)
        XCTAssertTrue(session.calls.contains(.ptyKill(101)))
        do { try await transport.sendInput(Data("x".utf8)); XCTFail() } catch { XCTAssertEqual(error as? MilaTerminalError, .unavailable) }
        do { try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true); XCTFail() } catch { XCTAssertEqual(error as? MilaTerminalError, .unavailable) }
        do { try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: false); XCTFail() } catch { XCTAssertEqual(error as? MilaTerminalError, .permissionDenied) }
    }

    func testAuthenticatedWrapperForwardsOutput() async throws {
        let session = RecordingSession()
        session.ptyOutput = [Data("ok".utf8)]
        let transport = MilaAuthenticatedTerminalTransport(session: session)
        try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true)
        let chunk = try await transport.receiveOutput()
        XCTAssertEqual(chunk, Data("ok".utf8))
        let unsignedAdapter = LinkedMilaFFIAdapter()
        XCTAssertNil(unsignedAdapter.terminalTransport())
    }
}

/// Wire decoding of Rust session outputs reached through the adapter.
final class MilaAdapterWireTests: XCTestCase {
    func testSSHKeysAcceptPorscheEnvelopeAndRevokeByOpaqueIdentity() async throws {
        let session = RecordingSession()
        session.sshKeyData = Data(#"{"version":1,"status":"succeeded","result":{"keys":[{"id":"55555555-5555-4555-8555-555555555555","label":"laptop","algorithm":"ecdsa-sha2-nistp256","fingerprint":"SHA256:abc","inserted_at":"2026-10-01T00:00:00Z"}]}}"#.utf8)
        let adapter = LinkedMilaFFIAdapter(session: session)
        let keys = try await adapter.listSSHKeys()
        XCTAssertEqual(keys.map(\.label), ["laptop"])
        let request = UUID()
        try await adapter.revokeSSHKey(keys[0], requestID: request)
        XCTAssertEqual(session.calls, [.sshKeys, .revoke(keys[0].id, request)])
        do { try await adapter.revokeSSHKey(keys[0], requestID: .zero); XCTFail() } catch {}
        XCTAssertEqual(session.calls.count, 2)
        XCTAssertEqual(try LinkedMilaFFIAdapter.decodeSSHKeys(Data(#"{"keys":[]}"#.utf8)), [])
        XCTAssertThrowsError(try LinkedMilaFFIAdapter.decodeSSHKeys(Data(#"{"version":1,"status":"error","error":"unauthorized"}"#.utf8)))
        XCTAssertThrowsError(try LinkedMilaFFIAdapter.decodeSSHKeys(Data(#"{"keys":[{"id":"55555555-5555-4555-8555-555555555555","algorithm":"ecdsa sha2","fingerprint":"f"}]}"#.utf8)))
    }

    /// The SSH keys controller over the real adapter: load, revoke, reload.
    @MainActor func testSSHKeysControllerOverAdapter() async throws {
        let session = RecordingSession()
        session.sshKeyData = Data(#"{"version":1,"status":"succeeded","result":{"keys":[{"id":"55555555-5555-4555-8555-555555555555","label":null,"algorithm":"ecdsa-sha2-nistp256","fingerprint":"SHA256:abc"}]}}"#.utf8)
        let adapter = LinkedMilaFFIAdapter(session: session)
        let controller = MilaSSHKeysController(loader: { try await adapter.listSSHKeys() },
                                               revoker: { id in try await adapter.revokeSSHKey(MilaSSHKey(id: id, fingerprint: "", algorithm: ""), requestID: UUID()) })
        await controller.load(signedIn: true)
        guard case .loaded(let keys) = controller.state, let key = keys.first else { return XCTFail() }
        await controller.revoke(key)
        XCTAssertEqual(session.calls.filter { $0 == .sshKeys }.count, 2, "revocation reloads the list")
        XCTAssertTrue(session.calls.contains { if case .revoke(let id, _) = $0 { return id == key.id }; return false })
    }

    func testWebShowAcceptsPorscheEnvelopeAndBindsMachine() async throws {
        let session = RecordingSession()
        let machine = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        session.webData = Data(#"{"version":1,"status":"succeeded","result":{"machine_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","label":"app","port":3000,"visibility":"private","policy_revision":4,"url":"https://app.web.example.test","route":"overalls://machines/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/web"}}"#.utf8)
        let adapter = LinkedMilaFFIAdapter(session: session)
        let endpoint = try await adapter.webEndpoint(machine: machine)
        XCTAssertEqual(endpoint.url.absoluteString, "https://app.web.example.test")
        do { _ = try await adapter.webEndpoint(machine: UUID()); XCTFail("projection is machine-bound") } catch {}
        session.webData = Data(#"{"version":1,"status":"error","error":"not_found"}"#.utf8)
        do { _ = try await adapter.webEndpointProjection(machine: machine); XCTFail() } catch {}
    }
}

/// Exercises every `MilaLiveSession` entry point against the linked Rust ABI with
/// a handle Rust never issued: each call must reach Rust and be refused as stale.
final class MilaLiveSessionRustLinkTests: XCTestCase {
    func testUnissuedHandleIsRefusedByRustForEveryOperation() {
        let session = MilaLiveSession(unconnectedHandleForTesting: 0xDEAD_BEEF)
        let id = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let operations: [(String, () throws -> Void)] = [
            ("refresh", { _ = try session.refresh() }),
            ("readMore", { _ = try session.readMore() }),
            ("whoami", { _ = try session.whoami() }),
            ("sshKeys", { _ = try session.sshKeys() }),
            ("revoke", { try session.revokeSSHKey(id: id, requestID: id) }),
            ("action", { try session.machineAction(machine: id, action: "stop", requestID: id) }),
            ("resize", { try session.machineResize(machine: id, cpu: 2, memory: 2048, disk: 20, requestID: id) }),
            ("create", { try session.machineCreate(name: "x", cpu: 2, memory: 2048, disk: 20, requestID: id) }),
            ("share", { try session.shareMutation(machine: id, email: "a@example.test", role: "viewer", add: true, requestID: id) }),
            ("thread", { _ = try session.threadAction(thread: nil, command: "thread ls", secondary: nil, input: nil, requestID: nil) }),
            ("webShow", { _ = try session.webShow(machine: id) }),
            ("webSet", { try session.webSet(machine: id, port: 443, publicAccess: false, revision: 1, requestID: id) }),
            ("ptyAttach", { _ = try session.terminalAttach(columns: 80, rows: 24) }),
            ("ptyPoll", { _ = try session.terminalPoll(0xDEAD_BEEF) }),
            ("ptyInput", { try session.terminalInput(0xDEAD_BEEF, data: Data("x".utf8)) }),
            ("ptyResize", { try session.terminalResize(0xDEAD_BEEF, columns: 80, rows: 24) }),
        ]
        for (name, operation) in operations {
            XCTAssertThrowsError(try operation(), name) { error in
                XCTAssertEqual(error as? MilaSessionError, .staleHandle, name)
            }
        }
        session.close()
        XCTAssertFalse(session.isAuthenticated)
        XCTAssertThrowsError(try session.refresh()) { XCTAssertEqual($0 as? MilaSessionError, .staleHandle) }
    }

    func testSwiftBoundsRejectBeforeRust() {
        let session = MilaLiveSession(unconnectedHandleForTesting: 0xDEAD_BEEF)
        XCTAssertThrowsError(try session.terminalAttach(columns: 0, rows: 24)) { XCTAssertEqual($0 as? MilaSessionError, .invalidInput) }
        XCTAssertThrowsError(try session.terminalInput(1, data: Data())) { XCTAssertEqual($0 as? MilaSessionError, .invalidInput) }
        XCTAssertThrowsError(try session.machineResize(machine: UUID(), cpu: 0, memory: 2048, disk: 20, requestID: UUID())) { XCTAssertEqual($0 as? MilaSessionError, .invalidInput) }
        XCTAssertThrowsError(try session.webSet(machine: UUID(), port: 0, publicAccess: true, revision: 1, requestID: UUID())) { XCTAssertEqual($0 as? MilaSessionError, .invalidInput) }
        XCTAssertEqual(milaRequestID(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!), "porsche-aaaaaaaaaaaa4aaa8aaaaaaaaaaaaaaa")
    }
}

#if canImport(WebKit)
/// WKWebView lifecycle: generation fencing, ephemeral storage and teardown.
@MainActor final class MilaWebViewLifecycleTests: XCTestCase {
    private let endpoint = try! MilaWebEndpoint("https://app.web.example.test/")

    func testNavigationEventsAreFencedToCurrentGeneration() throws {
        let lifecycle = MilaWebViewLifecycle()
        XCTAssertNil(lifecycle.begin(endpoint, sessionActive: false))
        XCTAssertEqual(lifecycle.phase, .closed)
        let first = try XCTUnwrap(lifecycle.begin(endpoint, sessionActive: true))
        XCTAssertEqual(lifecycle.phase, .loading(generation: first))
        let second = try XCTUnwrap(lifecycle.begin(endpoint, sessionActive: true))
        lifecycle.didFinish(first)
        XCTAssertEqual(lifecycle.phase, .loading(generation: second), "a replaced view cannot report")
        lifecycle.didFinish(second)
        XCTAssertEqual(lifecycle.phase, .loaded(generation: second))
        lifecycle.end(first)
        XCTAssertEqual(lifecycle.phase, .loaded(generation: second), "ending a stale generation is a no-op")
        lifecycle.invalidate()
        XCTAssertEqual(lifecycle.phase, .closed)
        XCTAssertNil(lifecycle.endpoint)
        lifecycle.didFail(second)
        XCTAssertEqual(lifecycle.phase, .closed)
    }

    func testDelegateReportsProgressAndBlockedNavigation() throws {
        let lifecycle = MilaWebViewLifecycle()
        let generation = try XCTUnwrap(lifecycle.begin(endpoint, sessionActive: true))
        let guardian = MilaWebNavigationGuard(origin: endpoint.url, lifecycle: lifecycle, generation: generation)
        let view = WKWebView(frame: .zero)
        let delegate: any WKNavigationDelegate = guardian
        delegate.webView?(view, didStartProvisionalNavigation: nil)
        XCTAssertEqual(lifecycle.phase, .loading(generation: generation))
        delegate.webView?(view, didFinish: nil)
        XCTAssertEqual(lifecycle.phase, .loaded(generation: generation))
        delegate.webView?(view, didFail: nil, withError: URLError(.cancelled))
        XCTAssertEqual(lifecycle.phase, .failed(generation: generation))
        guardian.lifecycle?.didBlock(generation)
        XCTAssertEqual(lifecycle.phase, .blocked(generation: generation))
    }

    func testFactoryUsesEphemeralStoreAndTeardownDetachesDelegate() throws {
        let lifecycle = MilaWebViewLifecycle()
        let generation = try XCTUnwrap(lifecycle.begin(endpoint, sessionActive: true))
        let guardian = MilaWebNavigationGuard(origin: endpoint.url, lifecycle: lifecycle, generation: generation)
        let view = MilaWebViewFactory.make(url: endpoint.url, delegate: guardian)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(view.navigationDelegate === guardian)
        lifecycle.invalidate()
        MilaWebViewFactory.update(view, url: endpoint.url, lifecycle: lifecycle, generation: generation)
        XCTAssertNil(view.navigationDelegate, "an invalidated generation tears the view down")
    }
}
#endif
