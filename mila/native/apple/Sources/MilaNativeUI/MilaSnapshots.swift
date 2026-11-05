import Foundation
import Darwin
import CryptoKit

/// @cc [owner:ghuntley,label:security;privacy] mila-apple-durable-snapshot
/// Only Rust-validated complete snapshot bytes for this host and SSH port may
/// reach disk. A bind invalidates all earlier writes. Files and their directory
/// are owner-only, regular (never symlinks), bounded, atomically replaced, and
/// newest-wins. Every valid host and port MUST fit the filesystem filename bound
/// and keep their own validated cache. Cached records grant no session authority.
public final class MilaSnapshotStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var target: String?
    private let validator = LinkedMilaFFIAdapter()
    public static let maximumBytes = 1 << 20

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mila/snapshots", isDirectory: true)
    }

    @discardableResult public func bind(host: String?, port: UInt16?) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        target = host.flatMap { host in port.map { Self.key(host, $0) } }
        return generation
    }

    public func load(host: String, port: UInt16) throws -> MilaValidatedSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try read(host: host, port: port) else { return nil }
        return try validator.projectOfflineSnapshot(data, host: host, port: port)
    }

    public func save(_ data: Data, host: String, port: UInt16, generation expected: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected, target == Self.key(host, port) else { return }
        let fresh = try validator.validateSnapshot(data, host: host, port: port)
        if let existing = try read(host: host, port: port),
           try validator.validateSnapshot(existing, host: host, port: port).savedAt >= fresh.savedAt { return }
        try ensureDirectory()
        let destination = try path(host: host, port: port)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".new")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MilaFFIError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw MilaFFIError.unavailable }
    }

    public func forget(host: String, port: UInt16) throws {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        let destination = try path(host: host, port: port)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    }

    private static func key(_ host: String, _ port: UInt16) -> String { "\(host):\(port)" }

    private func path(host: String, port: UInt16) throws -> URL {
        // The Rust validator is the authority for host grammar. Bound a filename
        // independently before touching disk, then validation binds its contents.
        guard !host.isEmpty, host.utf8.count <= 253, port > 0,
              host.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }) else { throw MilaFFIError.invalidRoute }
        let digest = SHA256.hash(data: Data(Self.key(host, port).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    private func ensureDirectory() throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try requireOwnerOnly(directory, directory: true)
    }

    private func read(host: String, port: UInt16) throws -> Data? {
        let file = try path(host: host, port: port)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try requireOwnerOnly(directory, directory: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        try requireOwnerOnly(file, directory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else { throw MilaFFIError.outputTooSmall }
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MilaFFIError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw MilaFFIError.outputTooSmall }
        _ = try validator.validateSnapshot(data, host: host, port: port)
        return data
    }

    private func requireOwnerOnly(_ url: URL, directory: Bool) throws {
        let resource = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard resource.isSymbolicLink != true else { throw MilaFFIError.unavailable }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == (directory ? .typeDirectory : .typeRegular),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.uint16Value & 0o077 == 0,
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else { throw MilaFFIError.unavailable }
    }
}
