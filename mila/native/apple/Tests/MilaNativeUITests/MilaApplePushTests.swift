import CryptoKit
import XCTest
@testable import MilaNativeUI

/// An in-memory generic-password Keychain that records every call. An unsigned
/// `swift test` process has no Keychain entitlement, so custody is exercised
/// through the store's injectable Keychain seam.
private final class MemoryKeychain: MilaKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var log: [String] = []
    /// When set, the first `add` loses a race: this item appears and `add` reports a duplicate.
    var racingItem: Data?

    var calls: [String] { lock.withLock { log } }
    func seed(_ account: String, _ data: Data) { lock.withLock { items[account] = data } }
    func stored(_ account: String) -> Data? { lock.withLock { items[account] } }

    func read(account: String) throws -> Data? {
        lock.withLock { log.append("read \(account)"); return items[account] }
    }

    func add(account: String, data: Data) throws -> Bool {
        lock.withLock {
            log.append("add \(account)")
            if let racingItem, items[account] == nil { items[account] = racingItem; self.racingItem = nil }
            guard items[account] == nil else { return false }
            items[account] = data
            return true
        }
    }
}

/// Answers every request with a configured reply and records what was sent.
final class MilaSusanStubProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    struct Seen: Sendable {
        let method: String?
        let url: URL?
        let contentType: String?
        let body: Data
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var reply = Reply(status: 503, headers: [:], body: Data())
        var seen: [Seen] = []
    }

    private static let state = State()

    static func reset(_ reply: Reply) { state.lock.withLock { state.reply = reply; state.seen = [] } }
    static var seen: [Seen] { state.lock.withLock { state.seen } }

    override class func canInit(with request: URLRequest) -> Bool { _ = request; return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        let seen = Seen(method: request.httpMethod, url: request.url, contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body)
        let reply = Self.state.lock.withLock { () -> Reply in Self.state.seen.append(seen); return Self.state.reply }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}

/// Counts APNs registration requests; main-actor state, as the relay's callback is.
@MainActor private final class RequestCounter {
    var value = 0
}

@MainActor
final class MilaApplePushTests: XCTestCase {
    private static let deployment = "mila.example.test"
    private static let json = ["Content-Type": "application/json; charset=utf-8"]
    private static let susanKey = Data(#"{"push_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","key_id":"k","expires_at":"2099-01-01T00:00:00Z"}"#.utf8)
    private static let receiptID = UUID(uuidString: "5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b")

    private struct FixedAuthorization: MilaNotificationAuthorizing {
        let granted: Bool
        func requestAuthorization() async -> Bool { granted }
    }

    private static func stubbedSusan() -> MilaSusanHTTPSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MilaSusanStubProtocol.self]
        return MilaSusanHTTPSClient(configuration: configuration)
    }

    private static func registerCalls(_ session: RecordingSession) -> Int {
        session.calls.filter { if case .deviceRegister = $0 { return true }; return false }.count
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    private static func issueError(_ client: MilaSusanHTTPSClient, _ body: Data) async -> MilaSusanClientError? {
        do { _ = try await client.issue(body); return nil } catch { return error as? MilaSusanClientError }
    }

    // MARK: Keychain poke-key custody

    func testPokeKeyIsGeneratedOnceAndReusedFromTheKeychain() throws {
        let keychain = MemoryKeychain()
        let store = MilaKeychainPokeKeyStore(keychain: keychain)
        let first = try XCTUnwrap(store.publicKey(deployment: Self.deployment))
        XCTAssertEqual(first.utf8.count, 43)
        XCTAssertFalse(first.contains("=") || first.contains("+") || first.contains("/"), "unpadded base64url")
        XCTAssertEqual(Self.base64URLDecode(first)?.count, 32)

        XCTAssertEqual(store.publicKey(deployment: Self.deployment), first)
        XCTAssertEqual(MilaKeychainPokeKeyStore(keychain: keychain).publicKey(deployment: Self.deployment), first,
                       "a new store over the same Keychain reuses the stored key")
        XCTAssertEqual(keychain.calls.filter { $0.hasPrefix("add") }, ["add \(Self.deployment)"], "the key is created exactly once")

        // The Keychain holds the private key whose RFC 7748 public key was published.
        let stored = try XCTUnwrap(keychain.stored(Self.deployment))
        let reopened = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored)
        XCTAssertEqual(MilaKeychainPokeKeyStore.base64URL(reopened.publicKey.rawRepresentation), first)

        let other = try XCTUnwrap(store.publicKey(deployment: "other.example.test"))
        XCTAssertNotEqual(other, first, "each deployment has its own key")
    }

    func testPokeKeyCustodyRefusesMalformedItemsAndHostsWithoutReplacingThem() {
        let keychain = MemoryKeychain()
        let malformed = Data(repeating: 7, count: 7)
        keychain.seed(Self.deployment, malformed)
        let store = MilaKeychainPokeKeyStore(keychain: keychain)
        XCTAssertNil(store.publicKey(deployment: Self.deployment))
        XCTAssertEqual(keychain.stored(Self.deployment), malformed, "a malformed item is never replaced")
        XCTAssertFalse(keychain.calls.contains { $0.hasPrefix("add") })

        XCTAssertNil(store.publicKey(deployment: "Not A Host"))
        XCTAssertNil(store.publicKey(deployment: ""))
        XCTAssertFalse(keychain.calls.contains { $0.hasSuffix("Not A Host") || $0 == "read " }, "an invalid host never reaches the Keychain")
    }

    func testPokeKeyCreationRaceUsesTheKeyThatWasStoredFirst() throws {
        let keychain = MemoryKeychain()
        let winner = Curve25519.KeyAgreement.PrivateKey()
        keychain.racingItem = winner.rawRepresentation
        let key = try XCTUnwrap(MilaKeychainPokeKeyStore(keychain: keychain).publicKey(deployment: Self.deployment))
        XCTAssertEqual(key, MilaKeychainPokeKeyStore.base64URL(winner.publicKey.rawRepresentation))
        XCTAssertEqual(keychain.stored(Self.deployment), winner.rawRepresentation)
    }

    // MARK: Susan HTTPS client

    func testSusanClientPostsTheEncodedBodyToSusansKeysRoute() async throws {
        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: Self.susanKey))
        let body = Data(#"{"provider":"apns"}"#.utf8)
        let reply = try await Self.stubbedSusan().issue(body)
        XCTAssertEqual(reply.status, 201)
        XCTAssertEqual(reply.body, Self.susanKey)
        let seen = MilaSusanStubProtocol.seen
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.method, "POST")
        XCTAssertEqual(seen.first?.url?.absoluteString, "https://notifications.overalls.dev/api/push/v1/keys")
        XCTAssertEqual(seen.first?.contentType, "application/json")
        XCTAssertEqual(seen.first?.body, body)
    }

    func testSusanClientRefusesOversizedAndNonJSONReplies() async {
        let client = Self.stubbedSusan()
        let body = Data(#"{"provider":"apns"}"#.utf8)
        let oversized = Data(#"{"push_key":""#.utf8) + Data(repeating: 0x41, count: 5000) + Data(#""}"#.utf8)
        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: oversized))
        let streamed = await Self.issueError(client, body)
        XCTAssertEqual(streamed, .oversizedReply)
        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json.merging(["Content-Length": "99999"]) { $1 }, body: Self.susanKey))
        let declared = await Self.issueError(client, body)
        XCTAssertEqual(declared, .oversizedReply)
        MilaSusanStubProtocol.reset(.init(status: 201, headers: ["Content-Type": "text/html"], body: Data("<html></html>".utf8)))
        let html = await Self.issueError(client, body)
        XCTAssertEqual(html, .malformedReply)
        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: Data("[1]".utf8)))
        let array = await Self.issueError(client, body)
        XCTAssertEqual(array, .malformedReply)
        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: Data("{not json".utf8)))
        let broken = await Self.issueError(client, body)
        XCTAssertEqual(broken, .malformedReply)

        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: Self.susanKey))
        let empty = await Self.issueError(client, Data())
        XCTAssertEqual(empty, .invalidRequest)
        let overCap = await Self.issueError(client, Data(repeating: 0x20, count: MilaSusanHTTPSClient.maxRequestBytes + 1))
        XCTAssertEqual(overCap, .invalidRequest)
        XCTAssertTrue(MilaSusanStubProtocol.seen.isEmpty, "a refused request body is never sent")
    }

    /// The Windows client's status cases (`MilaWindowsPushRegistration`):
    /// 201 registers, 400/410/429 are refusals, anything else (and any client
    /// refusal) is relay-unavailable. Only 201 reaches the core's register call.
    func testSusanStatusesMapLikeTheWindowsClient() async throws {
        let (adapter, session) = recordingAdapter()
        let keychain = MemoryKeychain()
        let keys = MilaKeychainPokeKeyStore(keychain: keychain)
        let registration = MilaApplePushRegistration(authorization: FixedAuthorization(granted: true), keys: keys, susan: Self.stubbedSusan(),
                                                     platform: .macos, clock: { 1_000 })
        let token = Data(repeating: 0xab, count: 32)
        let cases: [(MilaSusanStubProtocol.Reply, MilaPushRegistrationOutcome)] = [
            (.init(status: 400, headers: Self.json, body: Data(#"{"error":"rejected"}"#.utf8)), .relayRefused),
            (.init(status: 410, headers: Self.json, body: Data(#"{"error":"unregistered"}"#.utf8)), .relayUnregistered),
            (.init(status: 429, headers: Self.json.merging(["Retry-After": "30"]) { $1 }, body: Data(#"{"error":"rate_limited"}"#.utf8)), .relayRateLimited),
            (.init(status: 503, headers: Self.json, body: Data(#"{"error":"unavailable"}"#.utf8)), .relayUnavailable),
            (.init(status: 500, headers: [:], body: Data()), .relayUnavailable),
            (.init(status: 302, headers: ["Location": "https://elsewhere.example.test/"], body: Data()), .relayUnavailable),
            (.init(status: 201, headers: ["Content-Type": "text/plain"], body: Data("ok".utf8)), .relayUnavailable),
            (.init(status: 201, headers: Self.json, body: Data(repeating: 0x20, count: 5000)), .relayUnavailable),
        ]
        for (reply, expected) in cases {
            MilaSusanStubProtocol.reset(reply)
            let outcome = await registration.register(adapter: adapter, deployment: Self.deployment, deviceToken: token, environment: .sandbox)
            XCTAssertEqual(outcome, expected, "status \(reply.status)")
        }
        XCTAssertEqual(Self.registerCalls(session), 0)

        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: Self.susanKey))
        let registered = await registration.register(adapter: adapter, deployment: Self.deployment, deviceToken: token, environment: .sandbox)
        XCTAssertEqual(registered, .registered(try XCTUnwrap(Self.receiptID)))
        XCTAssertEqual(Self.registerCalls(session), 1)
        let key = try XCTUnwrap(keys.publicKey(deployment: Self.deployment))
        XCTAssertEqual(session.calls.last, RecordingSession.Call.deviceRegister(.macos, key, nil))
        XCTAssertEqual(keychain.calls.filter { $0.hasPrefix("add") }.count, 1, "the poke key is reused across registrations")
    }

    // MARK: APNs token wiring

    private func coordinator(granted: Bool, keychain: MemoryKeychain, adapter: any MilaFFIAdapter,
                             requests: @escaping @MainActor () -> Void) -> (MilaApplePushCoordinator, MilaApplePushTokenRelay) {
        let relay = MilaApplePushTokenRelay(requestToken: requests)
        let registration = MilaApplePushRegistration(authorization: FixedAuthorization(granted: granted),
                                                     keys: MilaKeychainPokeKeyStore(keychain: keychain), susan: Self.stubbedSusan(),
                                                     platform: .macos, clock: { 1_000 })
        let coordinator = MilaApplePushCoordinator(registration: registration, environment: .sandbox, relay: relay)
        coordinator.bind(target: { MilaApplePushCoordinator.Target(adapter: adapter, deployment: Self.deployment, generation: 1) },
                         isCurrent: { $0 == 1 })
        return (coordinator, relay)
    }

    /// ADR-0278 item 1 on the production path: an APNs token delivered through
    /// the application delegate's relay, with authorization denied, reaches
    /// neither the Keychain poke-key store nor Susan, nor the core's register
    /// call. The granted control reaches all three.
    func testDeniedAuthorizationReachesNeitherKeychainNorSusan() async throws {
        MilaSusanStubProtocol.reset(.init(status: 201, headers: Self.json, body: Self.susanKey))
        let (adapter, session) = recordingAdapter()
        let keychain = MemoryKeychain()
        let requests = RequestCounter()
        let (denied, relay) = coordinator(granted: false, keychain: keychain, adapter: adapter, requests: { requests.value += 1 })
        XCTAssertNil(relay.deliver(deviceToken: Data(repeating: 0xab, count: 32)), "a token nobody asked for is dropped")
        XCTAssertTrue(denied.enable())
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(denied.state, .registering)
        await relay.deliver(deviceToken: Data(repeating: 0xab, count: 32))?.value
        XCTAssertEqual(denied.outcome, .notAuthorized)
        XCTAssertEqual(denied.state, .failed)
        XCTAssertTrue(keychain.calls.isEmpty, "the Keychain is not touched without authorization")
        XCTAssertTrue(MilaSusanStubProtocol.seen.isEmpty, "Susan is not contacted without authorization")
        XCTAssertEqual(Self.registerCalls(session), 0)
        XCTAssertNil(relay.deliver(deviceToken: Data(repeating: 0xab, count: 32)), "one token per request")

        let (granted, grantedRelay) = coordinator(granted: true, keychain: keychain, adapter: adapter, requests: {})
        XCTAssertTrue(granted.enable())
        await grantedRelay.deliver(deviceToken: Data(repeating: 0xab, count: 32))?.value
        XCTAssertEqual(granted.outcome, .registered(try XCTUnwrap(Self.receiptID)))
        XCTAssertEqual(granted.state, .on)
        XCTAssertEqual(keychain.calls.filter { $0.hasPrefix("add") }.count, 1)
        XCTAssertEqual(MilaSusanStubProtocol.seen.count, 1)
        XCTAssertEqual(Self.registerCalls(session), 1)
    }

    func testSignedOutCoordinatorRequestsNoTokenAndDiscardsSupersededOutcomes() async {
        let keychain = MemoryKeychain()
        let requests = RequestCounter()
        let relay = MilaApplePushTokenRelay(requestToken: { requests.value += 1 })
        let registration = MilaApplePushRegistration(authorization: FixedAuthorization(granted: false),
                                                     keys: MilaKeychainPokeKeyStore(keychain: keychain), susan: Self.stubbedSusan())
        let coordinator = MilaApplePushCoordinator(registration: registration, environment: .sandbox, relay: relay)
        XCTAssertFalse(coordinator.enable(), "no signed-in deployment")
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(coordinator.state, .failed)

        let (adapter, _) = recordingAdapter()
        coordinator.bind(target: { MilaApplePushCoordinator.Target(adapter: adapter, deployment: Self.deployment, generation: 1) },
                         isCurrent: { _ in false })
        let outcome = await coordinator.register(deviceToken: Data(repeating: 0xab, count: 32))
        XCTAssertNil(outcome, "an outcome for a superseded sign-in is discarded")
        XCTAssertEqual(coordinator.state, .off)
    }
}
