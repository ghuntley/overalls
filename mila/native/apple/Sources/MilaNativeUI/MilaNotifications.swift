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

public protocol MilaNotificationDeviceStore: AnyObject {
    func list() -> [MilaNotificationDevice]
    @discardableResult func upsert(_ device: MilaNotificationDevice) -> Bool
    @discardableResult func remove(id: String) -> Bool
}

/// UserDefaults-backed metadata store. Tokens remain owned by the OS and are never persisted.
public final class MilaUserDefaultsNotificationStore: MilaNotificationDeviceStore {
    private let defaults: UserDefaults
    private let key = "mila.notification.devices"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func list() -> [MilaNotificationDevice] {
        guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([MilaNotificationDevice].self, from: data) else { return [] }
        return values.filter { !$0.id.isEmpty && $0.id.utf8.count <= 256 && !$0.deployment.isEmpty && $0.deployment.utf8.count <= 256 }.prefix(128).map { $0 }
    }
    @discardableResult public func upsert(_ device: MilaNotificationDevice) -> Bool {
        guard !device.id.isEmpty, device.id.utf8.count <= 256, !device.deployment.isEmpty, device.deployment.utf8.count <= 256 else { return false }
        var values = list().filter { $0.id != device.id }
        values.append(device)
        if values.count > 128 { values.removeFirst(values.count - 128) }
        guard let data = try? JSONEncoder().encode(values) else { return false }
        defaults.set(data, forKey: key); return true
    }
    @discardableResult public func remove(id: String) -> Bool {
        let values = list(); let next = values.filter { $0.id != id }
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
        self.adapter = adapter; self.appID = appID; self.deployment = deployment; self.store = store; self.devices = store.list()
    }
    public func setSessionActive(_ active: Bool) {
        sessionActive = active
        if active { refreshDevices() } else { devices = []; state = .off }
    }
    public func refreshDevices() { guard sessionActive else { devices = []; return }; devices = store.list() }
    @discardableResult public func removeDevice(id: String) -> Bool { guard sessionActive else { return false }; let ok = store.remove(id: id); refreshDevices(); return ok }
    /// @cc [owner:ghuntley,label:security] mila-apple-push-token-boundary
    /// Registration MUST require an active session, a 32–200 byte token and an
    /// HTTPS endpoint without credentials or fragment; any refusal or validator
    /// failure MUST leave the state failed and MUST NOT store a device record.
    public func register(token: String, endpoint: String, environment: MilaPushEnvironment = .production) {
        guard sessionActive,
              (32...200).contains(token.utf8.count),
              let url = URL(string: endpoint),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              host.utf8.count <= 253,
              !host.isEmpty,
              !host.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f }),
              url.user == nil,
              url.fragment == nil
        else { state = .failed; return }
        state = .registering
        do { try adapter.validatePushRegistration(provider: MilaPushProvider.apple.rawValue, environment: environment.rawValue, token: token, appID: appID, deployment: deployment, endpoint: endpoint); _ = store.upsert(MilaNotificationDevice(id: appID, deployment: deployment, enabled: true)); refreshDevices(); state = .on } catch { state = .failed }
    }

    /// Handles the token callback from APNs without exposing token bytes to UI
    /// state. The token is converted and immediately passed to the validator.
    public func register(deviceToken: Data, endpoint: String, environment: MilaPushEnvironment = .production) {
        #if canImport(UserNotifications)
        guard let token = MilaAppleNotificationService.tokenString(from: deviceToken) else { state = .failed; return }
        register(token: token, endpoint: endpoint, environment: environment)
        #else
        _ = deviceToken; _ = endpoint; _ = environment; state = .failed
        #endif
    }
    public func disable() { guard sessionActive else { state = .off; return }; _ = store.upsert(MilaNotificationDevice(id: appID, deployment: deployment, enabled: false)); refreshDevices(); state = .off }
}
