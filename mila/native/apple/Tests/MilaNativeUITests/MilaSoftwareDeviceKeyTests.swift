#if os(macOS) && DEBUG && MILA_SOFTWARE_KEYS
import CryptoKit
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import MilaNativeUI

/// Exercises the real owner-only development store in isolated directories.
final class MilaSoftwareDeviceKeyTests: XCTestCase {
    private let host = "mila.example.test"

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaSoftwareKeyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root.appendingPathComponent("keys", isDirectory: true))
    }

    private func keyFile(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        return try XCTUnwrap(files.first)
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    func testCreatesOwnerOnlyIdentityAndReloadsItAcrossInstances() throws {
        try withDirectory { directory in
            let first = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            let file = try keyFile(in: directory)
            let bytes = try Data(contentsOf: file)
            XCTAssertEqual(bytes.count, 32)
            XCTAssertEqual(try mode(directory), 0o700)
            XCTAssertEqual(try mode(file), 0o600)

            let reopened = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            XCTAssertEqual(reopened.publicPoint, first.publicPoint)
            XCTAssertEqual(reopened.openSSHPublicKey, first.openSSHPublicKey)
            XCTAssertEqual(try Data(contentsOf: file), bytes)

            let message = Data("development device proof".utf8)
            let signature = try reopened.sign(message: message)
            XCTAssertEqual(signature.count, 64)
            let publicKey = try P256.Signing.PublicKey(x963Representation: first.publicPoint)
            XCTAssertTrue(publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: signature), for: message))
            XCTAssertThrowsError(try reopened.sign(message: Data()))
            XCTAssertThrowsError(try reopened.sign(message: Data(repeating: 7, count: 65_537)))
        }
    }

    func testSeparatesDeploymentHostsAndAcceptsMaximumLengthHost() throws {
        try withDirectory { directory in
            let first = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            let other = try MilaDeviceSigner(deploymentHost: "other.example.test", softwareKeyDirectory: directory)
            XCTAssertNotEqual(first.publicPoint, other.publicPoint)

            let longestHost = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                               String(repeating: "c", count: 63), String(repeating: "d", count: 61)].joined(separator: ".")
            XCTAssertEqual(longestHost.utf8.count, 253)
            XCTAssertTrue(MilaDeviceSigner.validHost(longestHost))
            let longest = try MilaDeviceSigner(deploymentHost: longestHost, softwareKeyDirectory: directory)
            XCTAssertNotEqual(first.publicPoint, longest.publicPoint)
            XCTAssertEqual(try MilaDeviceSigner(deploymentHost: longestHost, softwareKeyDirectory: directory).publicPoint,
                           longest.publicPoint)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 3)
            XCTAssertTrue(files.allSatisfy { $0.lastPathComponent.utf8.count <= 255 })
        }
    }

    func testInvalidHostsNeverCreateStorage() throws {
        try withDirectory { directory in
            for invalid in ["", "localhost", "EXAMPLE.test", "../mila.example.test", "mila.example.test/"] {
                XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: invalid, softwareKeyDirectory: directory))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testMalformedStoredKeysAreRefusedWithoutReplacement() throws {
        for malformed in [Data(repeating: 1, count: 31), Data(repeating: 0, count: 32), Data(repeating: 1, count: 33)] {
            try withDirectory { directory in
                _ = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
                let file = try keyFile(in: directory)
                try malformed.write(to: file)
                XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
                XCTAssertEqual(try Data(contentsOf: file), malformed)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
            }
        }
    }

    func testSharedFilesAndDirectoriesAreRefusedWithoutChangingIdentity() throws {
        try withDirectory { directory in
            _ = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            let file = try keyFile(in: directory)
            let bytes = try Data(contentsOf: file)
            for permissions in [0o640, 0o604, 0o660] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
                XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testSymlinkedDirectoryIsRefusedWithoutCreatingKeysInItsTarget() throws {
        try withDirectory { directory in
            let target = directory.deletingLastPathComponent().appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: target.path)
            XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testSymlinkedKeyIsRefusedWithoutChangingItsTarget() throws {
        try withDirectory { directory in
            _ = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            let file = try keyFile(in: directory)
            let target = directory.deletingLastPathComponent().appendingPathComponent("actual-key")
            try FileManager.default.moveItem(at: file, to: target)
            let bytes = try Data(contentsOf: target)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target.path)
            XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        }
    }

    func testHardLinkedKeyIsRefusedWithoutChangingEitherLink() throws {
        try withDirectory { directory in
            _ = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            let file = try keyFile(in: directory)
            let alias = directory.deletingLastPathComponent().appendingPathComponent("linked-key")
            let bytes = try Data(contentsOf: file)
            try FileManager.default.linkItem(at: file, to: alias)
            XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(try Data(contentsOf: alias), bytes)
        }
    }

    func testNonRegularKeyIsRefusedWithoutBlockingOnAFIFO() throws {
        try withDirectory { directory in
            _ = try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory)
            let file = try keyFile(in: directory)
            try FileManager.default.removeItem(at: file)
            XCTAssertEqual(mkfifo(file.path, mode_t(0o600)), 0)
            XCTAssertThrowsError(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory))
        }
    }

    func testConcurrentCreatorsAllRetainOneCompleteIdentity() throws {
        try withDirectory { directory in
            let results = ConcurrentPublicPoints()
            let deploymentHost = host
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                do {
                    let signer = try MilaDeviceSigner(deploymentHost: deploymentHost, softwareKeyDirectory: directory)
                    results.record(point: signer.publicPoint)
                } catch {
                    results.recordFailure()
                }
            }
            let (points, failures) = results.values
            XCTAssertEqual(failures, 0)
            XCTAssertEqual(points.count, 16)
            XCTAssertEqual(Set(points).count, 1)
            XCTAssertEqual(try Data(contentsOf: keyFile(in: directory)).count, 32)
            XCTAssertEqual(try MilaDeviceSigner(deploymentHost: host, softwareKeyDirectory: directory).publicPoint,
                           try XCTUnwrap(points.first))
        }
    }
}

private final class ConcurrentPublicPoints: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [Data] = []
    private var failures = 0

    var values: ([Data], Int) { lock.withLock { (points, failures) } }
    func record(point: Data) { lock.withLock { points.append(point) } }
    func recordFailure() { lock.withLock { failures += 1 } }
}
#endif
