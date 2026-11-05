import Foundation

public enum MilaDeepLinkDecision: Equatable, Sendable {
    case unknown
    case signedOut(MilaRoute)
    case open(MilaRoute, generation: UInt64)
}

/// Navigation-only external activation gate. Links never create sessions or issue commands.
public struct MilaDeepLinkRouter: Sendable {
    private var generation: UInt64 = 0
    private var signedIn = false
    private var deploymentHost: String?

    public init() {}

    public mutating func setSession(signedIn: Bool, deploymentHost: String? = nil) {
        self.signedIn = signedIn
        self.deploymentHost = deploymentHost?.lowercased()
        generation &+= 1
    }

    public mutating func decide(_ value: String) -> MilaDeepLinkDecision {
        guard let route = MilaRouteParser.parse(value) else { return .unknown }
        guard signedIn else { return .signedOut(route) }
        guard let deploymentHost, URL(string: value)?.host?.lowercased() == deploymentHost else { return .unknown }
        return .open(route, generation: generation)
    }

    public func accepts(_ decision: MilaDeepLinkDecision, generation expected: UInt64) -> Bool {
        guard case .open(_, let actual) = decision else { return false }
        return signedIn && actual == expected && actual == generation
    }
}

