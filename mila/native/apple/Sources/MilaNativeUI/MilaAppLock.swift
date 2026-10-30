import Foundation
import LocalAuthentication
import SwiftUI

public enum MilaAppLockState: Equatable, Sendable {
    case unavailable
    case locked
    case unlocked
    case failed
}

public protocol MilaBiometricEvaluator: Sendable {
    func availability() -> Bool
    func authenticate(reason: String) async -> Bool
}

public struct LocalAuthenticationEvaluator: MilaBiometricEvaluator {
    public init() {}

    public func availability() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

@MainActor
public final class MilaAppLockController: ObservableObject {
    @Published public private(set) var state: MilaAppLockState
    private let evaluator: any MilaBiometricEvaluator
    private let reason: String
    private let defaults: UserDefaults
    private let enabledKey = "mila.appLockEnabled"
    private var authenticationGeneration: UInt64 = 0

    /// The controller is the single lifecycle boundary for app locking. The enabled preference
    /// is durable, while an unlocked state is deliberately process-scoped and never persisted.
    public init(enabled: Bool? = nil, reason: String = MilaStrings.text(.lockReason), evaluator: any MilaBiometricEvaluator = LocalAuthenticationEvaluator(), defaults: UserDefaults = .standard) {
        self.evaluator = evaluator
        self.reason = reason
        self.defaults = defaults
        let configured = enabled ?? defaults.bool(forKey: enabledKey)
        guard configured, evaluator.availability() else {
            self.state = configured ? .unavailable : .unlocked
            return
        }
        self.state = .locked
    }

    public var isEnabled: Bool { state != .unlocked && state != .unavailable }
    public var canEnable: Bool { evaluator.availability() }

    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: enabledKey)
        guard enabled else { state = .unlocked; return }
        guard evaluator.availability() else { state = .unavailable; return }
        state = .locked
        await unlock()
    }

    public func unlock() async {
        guard state == .locked || state == .failed else { return }
        let generation = authenticationGeneration
        let authenticated = await evaluator.authenticate(reason: reason)
        guard generation == authenticationGeneration, state == .locked || state == .failed else { return }
        state = authenticated ? .unlocked : .failed
    }

    public func lock() {
        authenticationGeneration &+= 1
        guard canEnable else { state = .unavailable; return }
        state = .locked
    }

    /// Called when the scene leaves the foreground. Locking is synchronous for
    /// ordinary lifecycle transitions; a system authentication scene keeps its
    /// in-flight attempt alive.
    public func sceneDidEnterBackground() {
        guard defaults.bool(forKey: enabledKey) else { return }
        // LocalAuthentication presents its own system scene. Leaving the app's
        // scene while that prompt is visible must not cancel the current attempt.
        if state == .unlocked { lock() }
    }

    /// Called when the scene returns to the foreground. Authentication is explicit and remains
    /// asynchronous, allowing the view to present a stable locked state immediately.
    public func sceneWillEnterForeground() async {
        guard defaults.bool(forKey: enabledKey), state != .unavailable else { return }
        if state == .unlocked { lock() }
        await unlock()
    }
}

public struct MilaAppLockView<Content: View>: View {
    @ObservedObject private var controller: MilaAppLockController
    private let content: () -> Content

    public init(controller: MilaAppLockController, @ViewBuilder content: @escaping () -> Content) {
        self.controller = controller
        self.content = content
    }

    public var body: some View {
        Group {
            switch controller.state {
            case .unlocked: content()
            case .unavailable:
                ContentUnavailableView(MilaStrings.text(.lockUnavailable), systemImage: "lock.open")
            case .locked, .failed:
                VStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                    Text(MilaStrings.text(.lockedTitle)).font(.title2)
                    Button(MilaStrings.text(.lockUnlock)) { Task { await controller.unlock() } }
                    if controller.state == .failed { Text(MilaStrings.text(.lockFailed)).font(.caption) }
                }.padding()
            }
        }
    }
}
