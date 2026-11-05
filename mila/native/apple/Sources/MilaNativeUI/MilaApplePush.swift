import CryptoKit
import Foundation
import Security
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Production sources for `MilaApplePushRegistration`: Keychain custody of the
// X25519 poke key, Susan's HTTPS key-issuance client, and the APNs token path
// from the application delegate (ADR-0224, ADR-0235, ADR-0278).

public enum MilaKeychainError: Error, Equatable {
    case status(OSStatus)
    case malformed
}

/// The generic-password Keychain operations poke-key custody needs. Production
/// uses Security.framework; tests inject an in-memory Keychain because an
/// unsigned `swift test` process has no Keychain entitlement.
public protocol MilaKeychainAccess: Sendable {
    /// The item's data, or nil when no item exists for `account`.
    func read(account: String) throws -> Data?
    /// Adds a new item. Returns false, leaving the stored item unchanged, when
    /// one already exists: an existing item is never overwritten.
    func add(account: String, data: Data) throws -> Bool
}

/// Security.framework generic-password items, readable after first unlock on
/// this device only and never synchronized to iCloud Keychain.
public struct MilaSecItemKeychain: MilaKeychainAccess {
    public static let pokeService = "dev.overalls.mila.poke"
    private let service: String
    private let accessGroup: String?

    /// `accessGroup` is nil until a Notification Service extension shares the
    /// keys (ADR-0235 decision 2); nil selects the app's default group.
    public init(service: String = MilaSecItemKeychain.pokeService, accessGroup: String? = nil) {
        self.service = service; self.accessGroup = accessGroup
    }

    // Security.framework takes heterogeneous CFDictionary attributes; values here
    // are constructed locally, as in `MilaDeviceSigner`.
    private func query(account: String) -> NSMutableDictionary {
        let query = NSMutableDictionary(dictionary: [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as NSString,
            kSecAttrAccount as String: account as NSString,
            kSecAttrSynchronizable as String: NSNumber(value: false),
        ])
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup as NSString }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = NSNumber(value: true)
        #endif
        return query
    }

    public func read(account: String) throws -> Data? {
        let query = query(account: account)
        query[kSecReturnData as String] = NSNumber(value: true)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MilaKeychainError.status(status) }
        guard let data = item as? Data else { throw MilaKeychainError.malformed }
        return data
    }

    public func add(account: String, data: Data) throws -> Bool {
        let attributes = query(account: account)
        attributes[kSecValueData as String] = data as NSData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw MilaKeychainError.status(status) }
        return true
    }
}

/// @cc [owner:ghuntley,label:security;privacy] mila-apple-poke-key-custody
/// Each deployment MUST get one CryptoKit X25519 key pair, created on first use
/// and reused afterwards, whose private key exists only inside CryptoKit and as
/// a Keychain item that is `AfterFirstUnlockThisDeviceOnly` and not
/// synchronizable. Only the 32-byte raw public key (RFC 7748 u-coordinate,
/// unpadded base64url, 43 characters) leaves this type. A stored item that is
/// not a valid private key, or a Keychain failure, MUST report the key
/// unavailable and MUST NOT replace the stored item.
public final class MilaKeychainPokeKeyStore: MilaPokeKeySource, @unchecked Sendable {
    private let keychain: any MilaKeychainAccess
    // Serializes read-then-create so this process creates at most one key per deployment.
    private let lock = NSLock()

    public init(keychain: any MilaKeychainAccess = MilaSecItemKeychain()) { self.keychain = keychain }

    public func publicKey(deployment: String) -> String? {
        rawPublicKey(deployment: deployment).map(Self.base64URL)
    }

    /// The deployment's raw 32-byte public key, created on first use.
    func rawPublicKey(deployment: String) -> Data? {
        guard MilaDeviceSigner.validHost(deployment) else { return nil }
        return lock.withLock { () -> Data? in
            do {
                if let stored = try keychain.read(account: deployment) { return try Self.publicKey(stored: stored) }
                let key = Curve25519.KeyAgreement.PrivateKey()
                if try keychain.add(account: deployment, data: key.rawRepresentation) { return key.publicKey.rawRepresentation }
                // Another process created the item first; use its key, never ours.
                guard let stored = try keychain.read(account: deployment) else { return nil }
                return try Self.publicKey(stored: stored)
            } catch {
                return nil
            }
        }
    }

    private static func publicKey(stored: Data) throws -> Data {
        guard stored.count == 32 else { throw MilaKeychainError.malformed }
        let publicKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored).publicKey.rawRepresentation
        guard publicKey.count == 32 else { throw MilaKeychainError.malformed }
        return publicKey
    }

    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

public enum MilaSusanClientError: Error, Equatable {
    case invalidOrigin
    case invalidRequest
    case notHTTP
    case oversizedReply
    case malformedReply
}

/// @cc [owner:ghuntley,label:security;privacy] mila-apple-susan-https-client
/// Susan's key-issuance client MUST POST the Rust-encoded body only to
/// `https://<Susan host>/api/push/v1/keys` with the system's default TLS
/// validation, no custom trust, no cookies, no cache and no redirects; MUST
/// bound the request to Susan's 1 KiB cap, the reply to 4 KiB and the exchange
/// to 15 seconds; MUST refuse a 201 reply that is not a JSON object; and MUST
/// NOT log the token, request body or reply.
public struct MilaSusanHTTPSClient: MilaSusanKeyIssuing {
    /// ADR-0224's fixed Susan host; the Windows client uses the same origin.
    public static let defaultHost = "notifications.overalls.dev"
    /// Susan's key-issuance route (`Susan.HTTP`).
    public static let keysPath = "/api/push/v1/keys"
    public static let maxRequestBytes = 1024
    public static let maxReplyBytes = 4096
    public static let timeout: TimeInterval = 15
    private let host: String
    private let session: URLSession

    /// `configuration` is for tests (a stub `URLProtocol`); production uses an
    /// ephemeral session. Timeouts and cache/cookie policy are always applied.
    public init(host: String = MilaSusanHTTPSClient.defaultHost, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.host = host
        self.session = URLSession(configuration: configuration)
    }

    public func issue(_ body: Data) async throws -> MilaSusanKeyReply {
        guard (1...Self.maxRequestBytes).contains(body.count) else { throw MilaSusanClientError.invalidRequest }
        guard MilaDeviceSigner.validHost(host) else { throw MilaSusanClientError.invalidOrigin }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = Self.keysPath
        guard let url = components.url else { throw MilaSusanClientError.invalidOrigin }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (bytes, response) = try await session.bytes(for: request, delegate: MilaSusanRedirectRefusal())
        guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw MilaSusanClientError.notHTTP }
        if http.expectedContentLength > Int64(Self.maxReplyBytes) { bytes.task.cancel(); throw MilaSusanClientError.oversizedReply }
        var reply = Data()
        for try await byte in bytes {
            reply.append(byte)
            if reply.count > Self.maxReplyBytes { bytes.task.cancel(); throw MilaSusanClientError.oversizedReply }
        }
        // Only the 201 body is consumed (by Rust); it must be Susan's JSON object.
        if http.statusCode == 201 {
            guard http.mimeType?.lowercased() == "application/json",
                  (try? JSONSerialization.jsonObject(with: reply)) is NSDictionary
            else { throw MilaSusanClientError.malformedReply }
        }
        return MilaSusanKeyReply(status: http.statusCode, body: reply)
    }
}

/// Refuses every redirect, so the request body only ever reaches Susan's origin;
/// the redirect response itself is returned and maps to `relayUnavailable`.
final class MilaSusanRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        _ = session; _ = task; _ = response; _ = request
        return nil
    }
}

/// A refusal for hosts without UserNotifications.
struct MilaDeniedNotificationAuthorization: MilaNotificationAuthorizing {
    func requestAuthorization() async -> Bool { false }
}

public extension MilaPushEnvironment {
    /// Dev builds (debug configuration) are signed with a development profile,
    /// whose APNs entitlement is the sandbox gateway; release builds use production.
    static var buildDefault: MilaPushEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

public extension MilaApplePushRegistration {
    /// UserNotifications authorization, Keychain poke-key custody and Susan over HTTPS.
    static func production() -> MilaApplePushRegistration {
        #if canImport(UserNotifications)
        let authorization: any MilaNotificationAuthorizing = MilaUserNotificationsAuthorization()
        #else
        let authorization: any MilaNotificationAuthorizing = MilaDeniedNotificationAuthorization()
        #endif
        return MilaApplePushRegistration(authorization: authorization, keys: MilaKeychainPokeKeyStore(), susan: MilaSusanHTTPSClient())
    }
}

/// @cc [owner:ghuntley,label:security;privacy] mila-apple-apns-token-relay
/// The APNs token from the application delegate MUST go only to the
/// coordinator and request generation that asked for it, only once per request.
/// Reset MUST cancel that coordinator's pending request; callbacks without a
/// current request MUST be dropped. The relay MUST NOT retain the token.
@MainActor public final class MilaApplePushTokenRelay {
    public static let shared = MilaApplePushTokenRelay()
    private weak var recipient: MilaApplePushCoordinator?
    private var requestID: UInt64?
    private let requestToken: @MainActor () -> Void

    /// `requestToken` is for tests; production asks the application to register with APNs.
    public init(requestToken: (@MainActor () -> Void)? = nil) {
        self.requestToken = requestToken ?? { MilaApplePushTokenRelay.registerWithAPNs() }
    }

    static func registerWithAPNs() {
        #if os(macOS) && MILA_SOFTWARE_KEYS
        // Ad-hoc macOS development builds have no APNs entitlement. The
        // compile-time custody policy must make this path unreachable.
        return
        #else
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        #endif
    }

    func request(for coordinator: MilaApplePushCoordinator, requestID: UInt64) {
        recipient = coordinator
        self.requestID = requestID
        requestToken()
    }

    func cancel(for coordinator: MilaApplePushCoordinator) {
        guard recipient === coordinator else { return }
        recipient = nil
        requestID = nil
    }

    /// The `didRegisterForRemoteNotificationsWithDeviceToken` path.
    @discardableResult public func deliver(deviceToken: Data) -> Task<Void, Never>? {
        guard let recipient, let requestID else { return nil }
        self.recipient = nil
        self.requestID = nil
        return Task { _ = await recipient.register(deviceToken: deviceToken, requestID: requestID) }
    }

    /// The `didFailToRegisterForRemoteNotificationsWithError` path.
    public func failed() {
        if let requestID { recipient?.tokenUnavailable(requestID: requestID) }
        recipient = nil
        requestID = nil
    }
}

/// @cc [owner:ghuntley,label:security;privacy] apple-push-request-generation
/// Enabling push MUST capture its approved deployment target before requesting
/// an APNs token. Reset or a newer request MUST invalidate old callbacks and
/// completions; they MUST NOT register another target or overwrite newer state.
@MainActor public final class MilaApplePushCoordinator: ObservableObject {
    public struct Target: Sendable {
        public let adapter: any MilaFFIAdapter
        public let deployment: String
        public let generation: UInt64
        public init(adapter: any MilaFFIAdapter, deployment: String, generation: UInt64) {
            self.adapter = adapter; self.deployment = deployment; self.generation = generation
        }
    }

    @Published public private(set) var state: MilaNotificationState = .off
    @Published public private(set) var outcome: MilaPushRegistrationOutcome?
    private let registration: MilaApplePushRegistration
    private let environment: MilaPushEnvironment
    private let relay: MilaApplePushTokenRelay
    private var target: @MainActor () -> Target? = { nil }
    private var isCurrent: @MainActor (UInt64) -> Bool = { _ in false }
    private var requestGeneration: UInt64 = 0
    private var pendingTarget: Target?

    public init(registration: MilaApplePushRegistration? = nil, environment: MilaPushEnvironment = .buildDefault,
                relay: MilaApplePushTokenRelay? = nil) {
        self.registration = registration ?? .production()
        self.environment = environment
        self.relay = relay ?? .shared
    }

    public func bind(target: @escaping @MainActor () -> Target?, isCurrent: @escaping @MainActor (UInt64) -> Bool) {
        reset()
        self.target = target; self.isCurrent = isCurrent
    }

    /// Asks APNs for a device token; registration continues in `register(deviceToken:)`.
    @discardableResult public func enable() -> Bool {
        #if os(macOS) && MILA_SOFTWARE_KEYS
        state = .failed
        return false
        #else
        outcome = nil
        guard let target = target(), isCurrent(target.generation) else { state = .failed; return false }
        requestGeneration &+= 1
        pendingTarget = target
        state = .registering
        relay.request(for: self, requestID: requestGeneration)
        return true
        #endif
    }

    /// Registers an APNs token with Susan and the deployment. Authorization is
    /// asked first, inside `MilaApplePushRegistration`, before the poke key or
    /// Susan is touched.
    @discardableResult public func register(deviceToken: Data) async -> MilaPushRegistrationOutcome? {
        #if os(macOS) && MILA_SOFTWARE_KEYS
        // Keep the direct callback/test entry point closed as well as the
        // user-facing enable path. Ad-hoc software-key builds have no APNs.
        state = .failed
        outcome = .deploymentRefused
        return .deploymentRefused
        #else
        guard let target = target(), isCurrent(target.generation) else { state = .off; outcome = nil; return nil }
        requestGeneration &+= 1
        pendingTarget = nil
        relay.cancel(for: self)
        return await register(deviceToken: deviceToken, target: target, requestID: requestGeneration)
        #endif
    }

    fileprivate func register(deviceToken: Data, requestID: UInt64) async -> MilaPushRegistrationOutcome? {
        guard requestID == requestGeneration, let target = pendingTarget,
              isCurrent(target.generation) else { return nil }
        pendingTarget = nil
        return await register(deviceToken: deviceToken, target: target, requestID: requestID)
    }

    private func register(deviceToken: Data, target: Target, requestID: UInt64) async -> MilaPushRegistrationOutcome? {
        state = .registering
        let result = await registration.register(adapter: target.adapter, deployment: target.deployment,
                                                 deviceToken: deviceToken, environment: environment)
        guard requestID == requestGeneration else { return nil }
        guard isCurrent(target.generation) else { state = .off; outcome = nil; return nil }
        outcome = result
        if case .registered = result { state = .on } else { state = .failed }
        return result
    }

    fileprivate func tokenUnavailable(requestID: UInt64) {
        guard requestID == requestGeneration, let target = pendingTarget,
              isCurrent(target.generation) else { return }
        pendingTarget = nil
        outcome = nil; state = .failed
    }

    /// Sign-out, expiry or a deployment switch.
    public func reset() {
        requestGeneration &+= 1
        pendingTarget = nil
        relay.cancel(for: self)
        outcome = nil; state = .off
    }
}

#if os(iOS)
/// Forwards APNs registration callbacks to the token relay; holds no token.
@MainActor final class MilaAppleAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        _ = application
        MilaApplePushTokenRelay.shared.deliver(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        _ = application; _ = error
        MilaApplePushTokenRelay.shared.failed()
    }
}
#elseif os(macOS)
/// Forwards APNs registration callbacks to the token relay; holds no token.
@MainActor final class MilaAppleAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        _ = application
        MilaApplePushTokenRelay.shared.deliver(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        _ = application; _ = error
        MilaApplePushTokenRelay.shared.failed()
    }
}
#endif
