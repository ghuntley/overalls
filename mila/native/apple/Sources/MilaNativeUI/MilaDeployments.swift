import Foundation

public extension UUID { static let zero = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) }

public struct MilaDeployment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var host: String
    public var port: UInt16
    public var trust: Data

    public init(id: UUID = UUID(), host: String, port: UInt16, trust: Data) {
        self.id = id; self.host = host; self.port = port; self.trust = trust
    }
}

/// @cc [owner:ghuntley,label:security] deployment-store-validation
/// Persisted deployments must have a valid host, non-zero port and non-empty pinned trust.
public final class MilaDeploymentStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "mila.deployments"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func list() -> [MilaDeployment] {
        guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([MilaDeployment].self, from: data) else { return [] }
        return Array(values.filter(Self.isValid).prefix(128))
    }
    @discardableResult public func upsert(_ deployment: MilaDeployment) -> Bool {
        guard Self.isValid(deployment) else { return false }
        var values = list().filter { $0.id != deployment.id }; values.append(deployment)
        guard let data = try? JSONEncoder().encode(values) else { return false }; defaults.set(data, forKey: key); return true
    }
    public func remove(_ id: UUID) {
        let remaining = list().filter { $0.id != id }
        if remaining.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(remaining) { defaults.set(data, forKey: key) }
    }
    public static func isValid(_ value: MilaDeployment) -> Bool {
        guard value.id != UUID.zero, value.port > 0,
              !value.trust.isEmpty, value.trust.count <= 64 * 1024 else { return false }
        return MilaHostValidation.validHost(value.host)
    }
}

