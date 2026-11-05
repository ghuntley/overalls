import XCTest
@testable import MilaNativeUI

@MainActor
final class MilaNotificationsTests: XCTestCase {
    #if canImport(UserNotifications)
    func testAPNsTokenEncodingIsStableAndEmptyTokensAreRejected() {
        XCTAssertEqual(MilaAppleNotificationService.tokenString(from: Data([0x00, 0xab, 0xff])), "00abff")
        XCTAssertNil(MilaAppleNotificationService.tokenString(from: Data()))
    }

    func testNotificationActionsAreBoundedToDocumentedCategories() {
        XCTAssertEqual(MilaAppleNotificationService.boundedActionCategory("machine.open"), "machine.open")
        XCTAssertEqual(MilaAppleNotificationService.boundedActionCategory("thread.reply"), "thread.reply")
        XCTAssertNil(MilaAppleNotificationService.boundedActionCategory("javascript:alert(1)"))
        XCTAssertNil(MilaAppleNotificationService.boundedActionCategory("unknown.open"))
    }
    #endif

    private final class Adapter: MilaFFIAdapter, @unchecked Sendable {
        var calls: [(UInt8, UInt8, String, String, String, String?)] = []
        var error: Error?

        func call(_ request: MilaFFIRequest) async throws -> MilaFFIResponse { throw MilaFFIError.unavailable }
        func validatePushRegistration(provider: UInt8, environment: UInt8, token: String, appID: String, deployment: String, endpoint: String?) throws {
            calls.append((provider, environment, token, appID, deployment, endpoint))
            if let error { throw error }
        }
    }

    private final class Store: MilaNotificationDeviceStore {
        var values: [MilaNotificationDevice] = []
        func list(deployment: String) -> [MilaNotificationDevice] { values.filter { $0.deployment == deployment } }
        func all() -> [MilaNotificationDevice] { values }
        func upsert(_ device: MilaNotificationDevice) -> Bool {
            guard !device.id.isEmpty, device.id.utf8.count <= 256,
                  !device.deployment.isEmpty, device.deployment.utf8.count <= 256 else { return false }
            values.removeAll { $0.id == device.id && $0.deployment == device.deployment }
            values.append(device)
            if values.count > 128 { values.removeFirst(values.count - 128) }
            return true
        }
        func remove(id: String, deployment: String) -> Bool {
            let old = values.count
            values.removeAll { $0.id == id && $0.deployment == deployment }
            return values.count != old
        }
    }

    func testStoreRejectsOversizedMetadataAndBoundsProjection() {
        let store = Store()
        XCTAssertFalse(store.upsert(MilaNotificationDevice(id: String(repeating: "x", count: 257), deployment: "mila.example.test", enabled: true)))
        XCTAssertFalse(store.upsert(MilaNotificationDevice(id: "device", deployment: String(repeating: "x", count: 257), enabled: true)))
        for index in 0..<140 { XCTAssertTrue(store.upsert(MilaNotificationDevice(id: "device-\(index)", deployment: "mila.example.test", enabled: true))) }
        XCTAssertLessThanOrEqual(store.all().count, 128)
    }

    func testRegistrationUsesRustBoundaryAndDoesNotRetainTokenInControllerState() {
        let adapter = Adapter()
        let store = Store()
        let controller = MilaNotificationController(adapter: adapter, appID: "com.example.mila", deployment: "mila.example.test", store: store)
        let token = String(repeating: "a", count: 64)
        controller.register(token: token, environment: .sandbox)
        XCTAssertEqual(controller.state, .on)
        XCTAssertEqual(adapter.calls.count, 1)
        XCTAssertEqual(adapter.calls[0].0, MilaPushProvider.apple.rawValue)
        XCTAssertEqual(adapter.calls[0].1, MilaPushEnvironment.sandbox.rawValue)
        XCTAssertNil(adapter.calls[0].5, "APNs registration crosses no endpoint")
        XCTAssertEqual(controller.devices.count, 1)
        XCTAssertEqual(controller.devices[0].enabled, true)
        controller.disable()
        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(controller.devices[0].enabled, false)
        XCTAssertTrue(controller.removeDevice(id: "com.example.mila"))
        XCTAssertTrue(controller.devices.isEmpty)
    }

    func testSignedOutSessionHidesDevicesAndRefusesMutations() {
        let adapter = Adapter()
        let store = Store()
        let controller = MilaNotificationController(adapter: adapter, appID: "com.example.mila", deployment: "mila.example.test", store: store)
        controller.register(token: String(repeating: "a", count: 64))
        XCTAssertEqual(controller.state, .on)
        controller.setSessionActive(false)
        XCTAssertTrue(controller.devices.isEmpty)
        controller.register(token: String(repeating: "b", count: 64))
        XCTAssertEqual(controller.state, .failed)
        XCTAssertFalse(controller.removeDevice(id: "com.example.mila"))
        controller.setSessionActive(true)
        XCTAssertEqual(controller.devices.count, 1)
    }

    func testDeviceProjectionAndRemovalAreBoundToDeployment() {
        let adapter = Adapter()
        let store = Store()
        XCTAssertTrue(store.upsert(MilaNotificationDevice(id: "shared-id", deployment: "first.example.test", enabled: true)))
        XCTAssertTrue(store.upsert(MilaNotificationDevice(id: "shared-id", deployment: "second.example.test", enabled: true)))
        let first = MilaNotificationController(adapter: adapter, appID: "app", deployment: "first.example.test", store: store)
        let second = MilaNotificationController(adapter: adapter, appID: "app", deployment: "second.example.test", store: store)
        XCTAssertEqual(first.devices.map(\.deployment), ["first.example.test"])
        XCTAssertEqual(second.devices.map(\.deployment), ["second.example.test"])
        XCTAssertTrue(first.removeDevice(id: "shared-id"))
        XCTAssertTrue(second.devices.isEmpty == false, "a removal in the first deployment must not hide the second")
        second.refreshDevices()
        XCTAssertEqual(second.devices.map(\.deployment), ["second.example.test"])
        XCTAssertFalse(first.removeDevice(id: "shared-id"))
        XCTAssertEqual(store.all().map(\.deployment), ["second.example.test"])
    }


    func testRegistrationRejectsInvalidTokenBeforeBoundary() {
        let adapter = Adapter()
        let controller = MilaNotificationController(adapter: adapter, appID: "com.example.mila", deployment: "mila.example.test", store: Store())
        controller.register(token: String(repeating: "a", count: 31))
        XCTAssertEqual(controller.state, .failed)
        controller.register(token: String(repeating: "a", count: 201))
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(adapter.calls.isEmpty)
    }

    /// Rust refuses an APNs registration that carries an endpoint, so the
    /// controller once failed every real registration. Against the linked
    /// Rust validator an endpoint is refused and the controller's
    /// endpoint-free registration is accepted.
    func testAPNsRegistrationPassesTheLinkedRustValidatorWithoutAnEndpoint() throws {
        let adapter = LinkedMilaFFIAdapter()
        let token = String(repeating: "ab", count: 32)
        do {
            try adapter.validatePushRegistration(provider: .apple, environment: .production, token: token, appID: "dev.overalls.mila",
                                                 deployment: "mila.example.test", endpoint: nil)
        } catch MilaFFIError.unavailable, MilaFFIError.incompatibleABI {
            throw XCTSkip("Rust ABI is not linked in this package test environment")
        }
        XCTAssertThrowsError(try adapter.validatePushRegistration(provider: .apple, environment: .production, token: token, appID: "dev.overalls.mila",
                                                                  deployment: "mila.example.test", endpoint: "https://mila.example.test/push"))
        let controller = MilaNotificationController(adapter: adapter, appID: "dev.overalls.mila", deployment: "mila.example.test", store: Store())
        controller.register(token: token)
        XCTAssertEqual(controller.state, .on)
        controller.register(deviceToken: Data(repeating: 0xab, count: 32), environment: .sandbox)
        XCTAssertEqual(controller.state, .on)
    }

    func testEmptyTokenFailsBeforeCrossingBoundary() {
        let adapter = Adapter()
        let controller = MilaNotificationController(adapter: adapter, appID: "com.example.mila", deployment: "mila.example.test")
        controller.register(token: "")
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(adapter.calls.isEmpty)
    }

    private struct FixedAuthorization: MilaNotificationAuthorizing {
        let granted: Bool
        func requestAuthorization() async -> Bool { granted }
    }

    private struct FixedPokeKey: MilaPokeKeySource {
        // The `enc_public_key` of protocol/test/fixtures/porsche_device_results.json.
        func publicKey(deployment: String) -> String? { _ = deployment; return "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU" }
    }

    private final class RecordingSusan: MilaSusanKeyIssuing, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        var status = 201
        var issued: [Data] { lock.withLock { bodies } }
        func issue(_ body: Data) async throws -> MilaSusanKeyReply {
            let status = lock.withLock { () -> Int in bodies.append(body); return self.status }
            return MilaSusanKeyReply(status: status, body: Data(#"{"push_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","key_id":"k","expires_at":"2099-01-01T00:00:00Z"}"#.utf8))
        }
    }

    private static func registerCalls(_ session: RecordingSession) -> Int {
        session.calls.filter { if case .deviceRegister = $0 { return true }; return false }.count
    }

    /// ADR-0278 item 1: without UserNotifications authorization nothing is
    /// encoded, Susan is not asked and no register call reaches the Rust core.
    /// The granted control runs the same workflow to the core's register call,
    /// so the refusal is the gate's doing.
    func testRegistrationIsRefusedWithoutUserNotificationsAuthorization() async throws {
        let (adapter, session) = recordingAdapter()
        let susan = RecordingSusan()
        let token = Data((0..<32).map { UInt8($0) })
        func registration(granted: Bool) -> MilaApplePushRegistration {
            MilaApplePushRegistration(authorization: FixedAuthorization(granted: granted), keys: FixedPokeKey(), susan: susan,
                                      platform: .macos, clock: { 1_000 })
        }

        let denied = await registration(granted: false).register(adapter: adapter, deployment: "mila.example.test", deviceToken: token, environment: .sandbox)
        XCTAssertEqual(denied, .notAuthorized)
        XCTAssertTrue(susan.issued.isEmpty, "Susan is not asked without authorization")
        XCTAssertEqual(Self.registerCalls(session), 0, "no register call reaches the core without authorization")
        XCTAssertTrue(session.calls.isEmpty)

        let granted = await registration(granted: true).register(adapter: adapter, deployment: "mila.example.test", deviceToken: token,
                                                                 environment: .sandbox, label: "Mila")
        XCTAssertEqual(granted, .registered(try XCTUnwrap(UUID(uuidString: "5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b"))))
        XCTAssertEqual(Self.registerCalls(session), 1)
        XCTAssertEqual(session.calls.last, RecordingSession.Call.deviceRegister(.macos, "BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU", "Mila"))
        // Rust encoded Susan's closed APNs body; the token is the hex of the APNs bytes.
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(susan.issued.first)) as? [String: String])
        XCTAssertEqual(body, ["provider": "apns", "token": token.map { String(format: "%02x", $0) }.joined(), "app_id": "dev.overalls.mila",
                              "environment": "development", "deployment": "mila.example.test"])
    }

    func testSusanRefusalOrMissingPokeKeyNeverRegisters() async {
        let (adapter, session) = recordingAdapter()
        let susan = RecordingSusan()
        susan.status = 410
        let token = Data(repeating: 0xab, count: 32)
        let unregistered = await MilaApplePushRegistration(authorization: FixedAuthorization(granted: true), keys: FixedPokeKey(), susan: susan)
            .register(adapter: adapter, deployment: "mila.example.test", deviceToken: token)
        XCTAssertEqual(unregistered, .relayUnregistered)
        XCTAssertEqual(Self.registerCalls(session), 0)
        let empty = await MilaApplePushRegistration(authorization: FixedAuthorization(granted: true), keys: FixedPokeKey(), susan: susan)
            .register(adapter: adapter, deployment: "mila.example.test", deviceToken: Data())
        XCTAssertEqual(empty, .invalidToken)
        XCTAssertEqual(susan.issued.count, 1)
    }

    func testRustRejectionDoesNotEnableNotifications() {
        let adapter = Adapter()
        adapter.error = MilaFFIError.unavailable
        let controller = MilaNotificationController(adapter: adapter, appID: "com.example.mila", deployment: "mila.example.test")
        controller.register(token: String(repeating: "b", count: 64))
        XCTAssertEqual(controller.state, .failed)
    }
}
