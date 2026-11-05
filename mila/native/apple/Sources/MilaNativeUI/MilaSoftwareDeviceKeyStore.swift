#if os(macOS) && DEBUG && MILA_SOFTWARE_KEYS
import CryptoKit
import Foundation
import Darwin

/// @cc [owner:ghuntley,label:security;privacy] mila-macos-development-key-files
/// Only a macOS DEBUG build with MILA_SOFTWARE_KEYS may persist software device
/// keys. Each canonical host MUST retain one P-256 identity in a distinct
/// development namespace. Reads MUST refuse non-owner, shared, symlinked,
/// hard-linked or malformed storage without replacing it. Creation MUST publish
/// a complete owner-only file atomically and never overwrite a winning creator.
final class MilaSoftwareDeviceKeyStore {
    private static let creationLock = NSLock()
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mila/dev-software-keys", isDirectory: true)
    }

    init(directory: URL) { self.directory = directory }

    func loadOrCreate(host: String) throws -> P256.Signing.PrivateKey {
        guard MilaDeviceSigner.validHost(host) else { throw MilaDeviceSignerError.invalidHost }
        // Swift's concurrentPerform invokes this path from multiple threads in
        // one process. Serialize those callers before the filesystem race, while
        // renameatx_np(RENAME_EXCL) below remains the cross-process guard.
        Self.creationLock.lock()
        defer { Self.creationLock.unlock() }
        // DNS hosts may be 253 bytes, longer than NAME_MAX after a filename
        // prefix. A fixed-width digest also keeps hostnames out of directory
        // listings; the software-key directory separates it from hardware keys.
        let hostDigest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        let filename = "dev-software-key.\(hostDigest).bin"
        let directoryDescriptor = try openDirectory()
        defer { close(directoryDescriptor) }
        if let existing = try load(filename: filename, directoryDescriptor: directoryDescriptor) { return existing }

        let key = P256.Signing.PrivateKey()
        let temporary = ".\(UUID().uuidString).new"
        let descriptor = openat(directoryDescriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MilaDeviceSignerError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            _ = unlinkat(directoryDescriptor, temporary, 0)
        }
        try handle.write(contentsOf: key.rawRepresentation)
        try handle.synchronize()
        try requireOwnerOnly(descriptor, directory: false)
        // renameatx_np is an atomic no-replace publication, so a racing process never
        // observes a partially written identity or loses the identity it won.
        if renameatx_np(directoryDescriptor, temporary, directoryDescriptor, filename, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST,
                  let existing = try load(filename: filename, directoryDescriptor: directoryDescriptor) else {
                throw MilaDeviceSignerError.unavailable
            }
            return existing
        }
        guard fsync(directoryDescriptor) == 0 else { throw MilaDeviceSignerError.unavailable }
        return key
    }

    private func openDirectory() throws -> Int32 {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MilaDeviceSignerError.unavailable }
        do { try requireOwnerOnly(descriptor, directory: true); return descriptor }
        catch { close(descriptor); throw error }
    }

    private func load(filename: String, directoryDescriptor: Int32) throws -> P256.Signing.PrivateKey? {
        // The checked directory is pinned by its descriptor. O_NONBLOCK avoids
        // blocking on a FIFO before fstat rejects anything but a regular file.
        let descriptor = openat(directoryDescriptor, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw MilaDeviceSignerError.unavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try requireOwnerOnly(descriptor, directory: false)
        let data = try handle.read(upToCount: 33) ?? Data()
        guard data.count == 32 else { throw MilaDeviceSignerError.invalidKey }
        do { return try P256.Signing.PrivateKey(rawRepresentation: data) }
        catch { throw MilaDeviceSignerError.invalidKey }
    }

    private func requireOwnerOnly(_ descriptor: Int32, directory: Bool) throws {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0,
              attributes.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || (attributes.st_nlink == 1 && attributes.st_size == 32) else {
            throw MilaDeviceSignerError.unavailable
        }
    }
}
#endif
