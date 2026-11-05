import Foundation
import XCTest
@testable import MilaNativeUI

final class MilaSnapshotsTests: XCTestCase {
    private func snapshot(_ savedAt: UInt64, host: String = "mgmt.example.test", port: UInt16 = 22) -> Data {
        Data("""
        {"version":1,"host":"\(host)","port":\(port),"saved_at":\(savedAt),"machines":[{"id":"11111111-1111-1111-1111-111111111111","name":"Test","desired_state":"running","observed_state":null,"pinned":false,"owner":null,"read":true,"write":true,"manage":true}]}
        """.utf8)
    }

    func testRestartNewestWinsDeploymentGenerationAndReadOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MilaSnapshotStore(directory: directory)
        let generation = store.bind(host: "mgmt.example.test", port: 22)
        try store.save(snapshot(20), host: "mgmt.example.test", port: 22, generation: generation)
        try store.save(snapshot(10), host: "mgmt.example.test", port: 22, generation: generation)
        _ = store.bind(host: "other.example.test", port: 22)
        try store.save(snapshot(30), host: "mgmt.example.test", port: 22, generation: generation)
        let restarted = MilaSnapshotStore(directory: directory)
        let cached = try XCTUnwrap(restarted.load(host: "mgmt.example.test", port: 22))
        XCTAssertEqual(cached.metadata.savedAt, 20)
        XCTAssertTrue(cached.machines[0].actions.values.isEmpty)
        XCTAssertFalse(cached.machines[0].machine.read)
        XCTAssertFalse(cached.machines[0].machine.write)
        XCTAssertFalse(cached.machines[0].machine.manage)
        XCTAssertNil(try restarted.load(host: "mgmt.example.test", port: 2222))
        try restarted.forget(host: "mgmt.example.test", port: 22)
        XCTAssertNil(try restarted.load(host: "mgmt.example.test", port: 22))
    }

    func testMalformedCrossDeploymentAndUnsafePermissionsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MilaSnapshotStore(directory: directory)
        let generation = store.bind(host: "mgmt.example.test", port: 22)
        XCTAssertThrowsError(try store.save(Data("{}".utf8), host: "mgmt.example.test", port: 22, generation: generation))
        try store.save(snapshot(1), host: "mgmt.example.test", port: 22, generation: generation)
        let path = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        XCTAssertThrowsError(try store.load(host: "mgmt.example.test", port: 22))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try store.load(host: "mgmt.example.test", port: 22))
    }

    func testMaximumLengthHostFitsAndHostPortCachesRemainDistinct() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MilaSnapshotStore(directory: directory)
        let host = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                    String(repeating: "c", count: 63), String(repeating: "d", count: 61)].joined(separator: ".")
        XCTAssertEqual(host.utf8.count, 253)
        let targets: [(String, UInt16, UInt64)] = [(host, 65_535, 10), (host, 22, 20), ("other.example.test", 65_535, 30)]
        for (host, port, savedAt) in targets {
            let generation = store.bind(host: host, port: port)
            try store.save(snapshot(savedAt, host: host, port: port), host: host, port: port, generation: generation)
        }
        let restarted = MilaSnapshotStore(directory: directory)
        for (host, port, savedAt) in targets {
            let cached = try XCTUnwrap(restarted.load(host: host, port: port))
            XCTAssertEqual(cached.metadata.savedAt, savedAt)
            XCTAssertTrue(cached.machines[0].actions.values.isEmpty)
            XCTAssertFalse(cached.machines[0].machine.read)
            XCTAssertFalse(cached.machines[0].machine.write)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, targets.count)
        XCTAssertTrue(files.allSatisfy { $0.lastPathComponent.utf8.count <= 255 })
        XCTAssertNil(try restarted.load(host: "other.example.test", port: 22))
        try restarted.forget(host: host, port: 65_535)
        XCTAssertNil(try restarted.load(host: host, port: 65_535))
        XCTAssertNotNil(try restarted.load(host: host, port: 22))
    }
}
