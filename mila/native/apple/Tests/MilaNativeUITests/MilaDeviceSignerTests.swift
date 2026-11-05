import CryptoKit
import Foundation
import XCTest
@testable import MilaNativeUI

final class MilaDeviceSignerTests: XCTestCase {
    func testSoftwareKeysRequireTheExplicitDevelopmentCompilationCondition() {
        #if os(macOS) && MILA_SOFTWARE_KEYS
        XCTAssertTrue(MilaDeviceSigner.allowsSoftwareKeys)
        #else
        XCTAssertFalse(MilaDeviceSigner.allowsSoftwareKeys)
        #endif
    }

    func testDeploymentHostValidation() {
        for host in ["example.com", "a-b.example", "123.example"] {
            XCTAssertTrue(MilaDeviceSigner.validHost(host))
        }
        for host in ["", "localhost", "EXAMPLE.com", "a_b.example", "a..com", "a.com.", "-a.com", "a-.com", "a/b.com", "a\u{0}.com", String(repeating: "a", count: 64) + ".com"] {
            XCTAssertFalse(MilaDeviceSigner.validHost(host))
        }
    }

    func testDERConversionPreservesSignature() throws {
        // Ephemeral test-only key tests encoding; it is never an application fallback.
        let key = P256.Signing.PrivateKey()
        for length in [1, 32, 255, 4096, 65_536] {
            let message = Data(repeating: 0x42, count: length)
            let signature = try key.signature(for: message)
            let raw = try MilaDeviceSigner.rawSignature(der: signature.derRepresentation)
            XCTAssertEqual(raw.count, 64)
            XCTAssertTrue(key.publicKey.isValidSignature(
                try P256.Signing.ECDSASignature(rawRepresentation: raw), for: message))
        }
        XCTAssertThrowsError(try MilaDeviceSigner.rawSignature(der: Data()))
    }
}
