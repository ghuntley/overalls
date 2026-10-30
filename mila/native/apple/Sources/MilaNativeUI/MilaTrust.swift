import Foundation
import MilaFFIShim

public enum MilaTrustError: Error, Equatable, Sendable {
    case invalid
    case unavailable
}

/// @cc [owner:ghuntley,label:security] mila-apple-trust-reconcile
/// Fetched SSH trust documents are accepted only through Rust
/// `mila_trust_document_reconcile`, which validates the document for the
/// deployment host and reconciles it with any existing pin. Native code
/// persists exactly the canonical bytes Rust returns and never parses trust
/// itself. An empty fetch selects a still-current pin (transport failure).
public enum MilaTrustDocument {
    public static let maximumBytes = 8192

    public static func reconcile(pinned: Data?, fetched: Data?, host: String, now: Date = Date()) throws -> Data {
        let pinned = pinned ?? Data(), fetched = fetched ?? Data()
        guard pinned.count <= maximumBytes, fetched.count <= maximumBytes, !host.isEmpty, host.utf8.count <= 253 else {
            throw MilaTrustError.invalid
        }
        var output = [UInt8](repeating: 0, count: 4 * maximumBytes)
        var written = 0
        let seconds = UInt64(max(0, now.timeIntervalSince1970))
        let status = pinned.withUnsafeBytes { pinnedRaw in
            fetched.withUnsafeBytes { fetchedRaw in
                host.withCString { hostPointer in
                    output.withUnsafeMutableBufferPointer { buffer in
                        withUnsafeMutablePointer(to: &written) { writtenPointer in
                            mila_trust_document_reconcile(
                                pinnedRaw.bindMemory(to: UInt8.self).baseAddress, pinned.count,
                                fetchedRaw.bindMemory(to: UInt8.self).baseAddress, fetched.count,
                                hostPointer, seconds,
                                MilaRouteOutput(bytes: buffer.baseAddress, capacity: buffer.count, written: writtenPointer)
                            ).rawValue
                        }
                    }
                }
            }
        }
        switch status {
        case 0 where written > 0 && written <= output.count: return Data(output.prefix(written))
        case -4: throw MilaTrustError.invalid
        default: throw MilaTrustError.unavailable
        }
    }

    /// The well-known trust document location for a management host.
    public static func url(host: String, port: UInt16 = 443) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port == 443 ? nil : Int(port)
        components.path = "/bin/ssh-trust.json"
        return components.url
    }
}
