import Foundation
import Combine
#if canImport(UserNotifications)
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#endif

/// Registration state for the current Apple device and deployment.
public enum MilaNotificationState: Equatable, Sendable { case off, registering, on, failed }

/// Public device projection. Push tokens are deliberately excluded.
public struct MilaNotificationDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let deployment: String
    public var enabled: Bool
    public init(id: String, deployment: String, enabled: Bool) { self.id = id; self.deployment = deployment; self.enabled = enabled }
}

/// @cc [owner:ghuntley,label:security] notification-device-deployment-scope
/// Notification metadata MUST be keyed by the pair `(deployment, id)`. The
/// deployment-scoped list and removal operations MUST NOT expose or mutate
/// another deployment's device record.
public protocol MilaNotificationDeviceStore: AnyObject {
    func list(deployment: String) -> [MilaNotificationDevice]
    @discardableResult func upsert(_ device: MilaNotificationDevice) -> Bool
    @discardableResult func remove(id: String, deployment: String) -> Bool
}

/// UserDefaults-backed metadata store. Tokens remain owned by the OS and are never persisted.
public final class MilaUserDefaultsNotificationStore: MilaNotificationDeviceStore {
    private let defaults: UserDefaults
    private let key = "mila.notification.devices"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func all() -> [MilaNotificationDevice] {
        guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([MilaNotificationDevice].self, from: data) else { return [] }
        return values.filter { !$0.id.isEmpty && $0.id.utf8.count <= 256 && !$0.deployment.isEmpty && $0.deployment.utf8.count <= 256 }.prefix(128).map { $0 }
    }
    public func list(deployment: String) -> [MilaNotificationDevice] { all().filter { $0.deployment == deployment } }
    @discardableResult public func upsert(_ device: MilaNotificationDevice) -> Bool {
        guard !device.id.isEmpty, device.id.utf8.count <= 256, !device.deployment.isEmpty, device.deployment.utf8.count <= 256 else { return false }
        var values = all().filter { !($0.id == device.id && $0.deployment == device.deployment) }
        values.append(device)
        if values.count > 128 { values.removeFirst(values.count - 128) }
        guard let data = try? JSONEncoder().encode(values) else { return false }
        defaults.set(data, forKey: key); return true
    }
    @discardableResult public func remove(id: String, deployment: String) -> Bool {
        let values = all(); let next = values.filter { !($0.id == id && $0.deployment == deployment) }
        guard next.count != values.count, let data = try? JSONEncoder().encode(next) else { return false }
        defaults.set(data, forKey: key); return true
    }
}

#if canImport(UserNotifications)
/// Thin platform bridge. The app delegate supplies the APNs token to `register`.
public final class MilaAppleNotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main queue when the user taps a notification. The payload is
    /// intentionally reduced to a bounded category so UI code never handles raw APNs data.
    public var onAction: (@Sendable (String) -> Void)?

    /// Accept only the small, documented notification action vocabulary. Raw
    /// APNs category identifiers must never become navigation commands.
    public static func boundedActionCategory(_ category: String) -> String? {
        let value = String(category.prefix(64))
        guard !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }),
              ["machine", "thread", "deployment", "terminal"].contains(value.split(separator: ".").first.map(String.init) ?? "")
        else { return nil }
        return value
    }

    public override init() { super.init() }

    public func installAsNotificationDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let category = response.notification.request.content.categoryIdentifier
        if let bounded = Self.boundedActionCategory(category) { onAction?(bounded) }
        completionHandler()
    }
    /// APNs delivers the token as opaque bytes. Encode it deterministically for
    /// the Rust validation boundary and never retain the bytes in this object.
    public static func tokenString(from deviceToken: Data) -> String? {
        guard !deviceToken.isEmpty else { return nil }
        return deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    public static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
    #if os(iOS)
    public func registerForRemoteNotifications() {
        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
    }
    #elseif os(macOS)
    /// macOS APNs registration is explicit as well; requesting authorization
    /// alone never causes `didRegisterForRemoteNotifications` to fire.
    public func registerForRemoteNotifications() {
        DispatchQueue.main.async { NSApplication.shared.registerForRemoteNotifications() }
    }
    #endif

    @MainActor public func requestAuthorizationAndRegister() async -> Bool {
        do {
            let granted = try await Self.requestAuthorization()
            guard granted else { return false }
            installAsNotificationDelegate()
            #if os(iOS) || os(macOS)
            registerForRemoteNotifications()
            #endif
            return true
        } catch {
            return false
        }
    }
}
#endif

/// Owns notification registration without retaining or logging the device token.
@MainActor public final class MilaNotificationController: ObservableObject {
    @Published public private(set) var state: MilaNotificationState = .off
    @Published public private(set) var devices: [MilaNotificationDevice]
    /// Mutations and device projections are available only for an authenticated deployment session.
    @Published public private(set) var sessionActive: Bool = true
    private let adapter: any MilaFFIAdapter
    private let appID: String
    private let deployment: String
    private let store: MilaNotificationDeviceStore
    public init(adapter: any MilaFFIAdapter, appID: String, deployment: String, store: MilaNotificationDeviceStore = MilaUserDefaultsNotificationStore()) {
        self.adapter = adapter; self.appID = appID; self.deployment = deployment; self.store = store; self.devices = store.list(deployment: deployment)
    }
    public func setSessionActive(_ active: Bool) {
        sessionActive = active
        if active { refreshDevices() } else { devices = []; state = .off }
    }
    public func refreshDevices() { guard sessionActive else { devices = []; return }; devices = store.list(deployment: deployment) }
    @discardableResult public func removeDevice(id: String) -> Bool {
        guard sessionActive, store.list(deployment: deployment).contains(where: { $0.id == id }) else { return false }
        let ok = store.remove(id: id, deployment: deployment); refreshDevices(); return ok
    }
    /// @cc [owner:ghuntley,label:security] mila-apple-push-token-boundary
    /// Registration MUST require an active session and a 32–200 byte token, and
    /// MUST cross to the Rust validator with no endpoint: APNs has a fixed
    /// origin and Rust refuses an APNs registration that carries one. Any
    /// refusal or validator failure MUST leave the state failed and MUST NOT
    /// store a device record.
    public func register(token: String, environment: MilaPushEnvironment = .production) {
        guard sessionActive, (32...200).contains(token.utf8.count) else { state = .failed; return }
        state = .registering
        do { try adapter.validatePushRegistration(provider: MilaPushProvider.apple.rawValue, environment: environment.rawValue, token: token, appID: appID, deployment: deployment, endpoint: nil); _ = store.upsert(MilaNotificationDevice(id: appID, deployment: deployment, enabled: true)); refreshDevices(); state = .on } catch { state = .failed }
    }

    /// Handles the token callback from APNs without exposing token bytes to UI
    /// state. The token is converted and immediately passed to the validator.
    public func register(deviceToken: Data, environment: MilaPushEnvironment = .production) {
        #if canImport(UserNotifications)
        guard let token = MilaAppleNotificationService.tokenString(from: deviceToken) else { state = .failed; return }
        register(token: token, environment: environment)
        #else
        _ = deviceToken; _ = environment; state = .failed
        #endif
    }
    public func disable() { guard sessionActive else { state = .off; return }; _ = store.upsert(MilaNotificationDevice(id: appID, deployment: deployment, enabled: false)); refreshDevices(); state = .off }
}

/// The OS notification permission decision. Production asks UserNotifications;
/// tests inject a fixed answer so the gate is observable without a prompt.
public protocol MilaNotificationAuthorizing: Sendable {
    /// Returns whether the user has granted notification authorization.
    func requestAuthorization() async -> Bool
}

#if canImport(UserNotifications)
/// Asks UserNotifications. An error or a denial is a refusal.
public struct MilaUserNotificationsAuthorization: MilaNotificationAuthorizing {
    public init() {}
    public func requestAuthorization() async -> Bool {
        (try? await MilaAppleNotificationService.requestAuthorization()) ?? false
    }
}
#endif

/// Supplies this device's X25519 poke-decryption public key for a deployment
/// (unpadded base64url, 43 characters), or nil when custody is unavailable.
public protocol MilaPokeKeySource: Sendable {
    func publicKey(deployment: String) -> String?
}

/// Status and body of Susan's key-issuance reply.
public struct MilaSusanKeyReply: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

/// POSTs a Rust-encoded body to Susan's `/api/push/v1/keys`.
public protocol MilaSusanKeyIssuing: Sendable {
    func issue(_ body: Data) async throws -> MilaSusanKeyReply
}

public enum MilaPushRegistrationOutcome: Equatable, Sendable {
    case registered(UUID)
    case notAuthorized
    case invalidToken
    case keyUnavailable
    case relayRefused
    case relayUnregistered
    case relayRateLimited
    case relayUnavailable
    case deploymentRefused
}

/// @cc [owner:ghuntley,label:security;privacy] mila-apple-push-registration-authorization
/// APNs registration with the deployment: OS authorization, Rust validation
/// and encoding of Susan's body, Susan key issuance, then Porsche
/// `device register` through the authenticated Rust session. APNs delivery
/// itself is Susan's concern (ADR-0278). Registration MUST ask the injected
/// authorization source first and, unless it grants, MUST return
/// `notAuthorized` before the token is encoded, Susan is contacted or any
/// register call reaches the Rust core. The APNs token MUST NOT be retained
/// after the exchange.
public struct MilaApplePushRegistration: Sendable {
    public static let appID = "dev.overalls.mila"
    private let authorization: any MilaNotificationAuthorizing
    private let keys: any MilaPokeKeySource
    private let susan: any MilaSusanKeyIssuing
    private let platform: MilaDevicePlatform
    private let clock: @Sendable () -> UInt64

    public init(authorization: any MilaNotificationAuthorizing, keys: any MilaPokeKeySource, susan: any MilaSusanKeyIssuing,
                platform: MilaDevicePlatform = .current,
                clock: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.authorization = authorization; self.keys = keys; self.susan = susan; self.platform = platform; self.clock = clock
    }

    public func register(adapter: any MilaFFIAdapter, deployment: String, deviceToken: Data,
                         environment: MilaPushEnvironment = .production, label: String? = nil) async -> MilaPushRegistrationOutcome {
        #if os(macOS) && MILA_SOFTWARE_KEYS
        // Ad-hoc macOS development builds have no APNs entitlement and must
        // never send an injected token to Susan or the Rust device API.
        return .deploymentRefused
        #else
        guard await authorization.requestAuthorization() else { return .notAuthorized }
        // APNs tokens are opaque bytes; Rust accepts 32...200 lowercase hex characters.
        guard (16...100).contains(deviceToken.count) else { return .invalidToken }
        guard let encryptionKey = keys.publicKey(deployment: deployment), encryptionKey.utf8.count == 43 else { return .keyUnavailable }
        // Porsche bounds labels to 64 UTF-8 bytes; an over-long label is omitted.
        let label = label.flatMap { (1...64).contains($0.utf8.count) ? $0 : nil }
        let body: Data
        do {
            body = try adapter.encodePushKeyRequest(token: deviceToken.map { String(format: "%02x", $0) }.joined(),
                                                    environment: environment, appID: Self.appID, deployment: deployment)
        } catch { return .invalidToken }
        let reply: MilaSusanKeyReply
        do { reply = try await susan.issue(body) } catch { return .relayUnavailable }
        switch reply.status {
        case 201: break
        case 400: return .relayRefused
        case 410: return .relayUnregistered
        case 429: return .relayRateLimited
        default: return .relayUnavailable
        }
        do {
            return .registered(try await adapter.registerNotificationDevice(platform: platform, susanReply: reply.body,
                                                                            encryptionPublicKey: encryptionKey, label: label, now: clock(), requestID: UUID()))
        } catch { return .deploymentRefused }
        #endif
    }
}
