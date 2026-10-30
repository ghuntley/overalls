import XCTest
@testable import MilaNativeUI

final class MilaRouteTests: XCTestCase {
    func testParsesSupportedRoutes() {
        let machineID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/machines"), .machines)
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/machines/\(machineID.uuidString)"), .machine(id: machineID))
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/threads"), .threads)
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/threads/\(machineID.uuidString)"), .thread(id: machineID))
        XCTAssertEqual(MilaRouteParser.parse("overalls://overalls.example/settings"), .settings)
    }

    func testRejectsOversizedAndControlCharacterRoutes() {
        XCTAssertNil(MilaRouteParser.parse("overalls://overalls.example/" + String(repeating: "a", count: 2049)))
        XCTAssertNil(MilaRouteParser.parse("overalls://overalls.example/machines\u{0000}"))
        XCTAssertNil(MilaRouteParser.parse("overalls:///machines"))
    }

    func testRejectsRoutesContainingSensitiveOrAmbiguousComponents() {
        let machineID = "11111111-1111-1111-1111-111111111111"
        let invalid = [
            "https://machines",
            "overalls://overalls.example/machines/\(machineID)?token=secret",
            "overalls://overalls.example/machines/\(machineID)#fragment",
            "overalls://overalls.example/machines/\(machineID)/terminal",
            "overalls://overalls.example/machines/not-a-uuid",
            "overalls://overalls.example/machines/%2F\(machineID)",
            "overalls://user@machines",
            "overalls://overalls.example:8443/machines",
        ]
        for value in invalid {
            XCTAssertNil(MilaRouteParser.parse(value), "unexpectedly accepted \(value)")
        }
    }
}

final class MilaFFIRequestTests: XCTestCase {
    func testRequestsAreCodableAndPreservePayload() throws {
        let request = MilaFFIRequest(operation: .refresh, payload: Data([0, 1, 2, 255]))
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MilaFFIRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
    }
}


final class MilaRustLinkTests: XCTestCase {
    func testLinkedRustCanonicalizesRoute() throws {
        let adapter = LinkedMilaFFIAdapter()
        XCTAssertEqual(try adapter.canonicalRoute("overalls://overalls.example/machines"), "overalls://overalls.example/machines")
    }

    func testLinkedRustProjectsClosedCommandCatalogs() throws {
        let adapter = LinkedMilaFFIAdapter()
        do {
            let threadList = try adapter.classifyThreadCommand("thread ls")
            XCTAssertEqual(threadList, .list)
            let planApprove = try adapter.classifyThreadCommand("thread plan approve abc")
            XCTAssertEqual(planApprove, .planApprove)
            let shareAdd = try adapter.classifyMachineCommand("share add abc user read")
            XCTAssertEqual(shareAdd, .shareAdd)
            let webShow = try adapter.classifyMachineCommand("web show abc")
            XCTAssertEqual(webShow, .webShow)
            do {
                _ = try adapter.classifyMachineCommand("thread delete abc")
                XCTFail("unknown command must be rejected")
            } catch MilaFFIError.unavailable {
                throw XCTSkip("Rust ABI is not linked in this package test environment")
            } catch {
                // Expected invalid-command refusal.
            }
        } catch MilaFFIError.unavailable, MilaFFIError.incompatibleABI {
            throw XCTSkip("Rust ABI is not linked in this package test environment")
        }
    }

    func testTypedPushRegistrationEnumsRejectInvalidMetadata() throws {
        let adapter = LinkedMilaFFIAdapter()
        do {
            try adapter.validatePushRegistration(provider: .apple, environment: .sandbox, token: "short", appID: "com.example.mila", deployment: "mila.example.test", endpoint: "https://mila.example.test/push")
            XCTFail("short token must be rejected by Rust")
        } catch MilaFFIError.unavailable, MilaFFIError.incompatibleABI {
            throw XCTSkip("Rust ABI is not linked in this package test environment")
        } catch {
            // Rust validation rejected malformed registration.
        }
    }

    func testTypedWebCommandsUseRustCatalogAndRejectUnsafeURLs() throws {
        let adapter = LinkedMilaFFIAdapter()
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        do {
            let show = try adapter.classifyWebCommand(.show(machineID: id))
            XCTAssertEqual(show, .webShow)
            let set = try adapter.classifyWebCommand(.set(machineID: id, url: "https://public.example/path"))
            XCTAssertEqual(set, .webSet)
            XCTAssertThrowsError(try adapter.classifyWebCommand(.set(machineID: id, url: "http://public.example"))) { error in XCTAssertEqual(error as? MilaWebCommandError, .invalidURL) }
        } catch MilaFFIError.unavailable, MilaFFIError.incompatibleABI {
            throw XCTSkip("Rust ABI is not linked in this package test environment")
        }
    }

    func testLinkedRustRejectsMalformedPushMetadata() throws {
        let adapter = LinkedMilaFFIAdapter()
        do {
            try adapter.validatePushRegistration(
                provider: 9,
                environment: 0,
                token: String(repeating: "a", count: 32),
                appID: "com.example.mila",
                deployment: "mila.example.test",
                endpoint: "")
            XCTFail("invalid provider must be rejected")
        } catch let error as MilaFFIError {
            if error == .unavailable {
                throw XCTSkip("Rust ABI is not linked in this package test environment")
            }
        }
    }
}

final class MilaSnapshotPolicyTests: XCTestCase {
    private func snapshot(write: Bool = true) -> Data {
        Data("""
        {"version":1,"host":"mgmt.example.test","port":null,"saved_at":42,"machines":[{"id":"11111111-1111-1111-1111-111111111111","name":"Test","desired_state":"running","observed_state":"running","pinned":false,"owner":"owner","read":true,"write":\(write),"manage":false}]}
        """.utf8)
    }

    func testProjectsRustActionsAndMachineTogether() throws {
        let projection = try LinkedMilaFFIAdapter().projectSnapshot(snapshot(), host: "mgmt.example.test")
        XCTAssertEqual(projection.metadata.machineCount, 1)
        XCTAssertEqual(projection.metadata.savedAt, 42)
        XCTAssertEqual(Set(projection.machines[0].actions.values), Set([.stop, .pause, .pin]))
        XCTAssertEqual(projection.machines[0].machine.name, "Test")
    }

    func testFormatsCanonicalMutationIdentityAndRejectsMissingIdentity() throws {
        let adapter = LinkedMilaFFIAdapter()
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        XCTAssertEqual(try adapter.formatMachineAction(.stop, machineID: id, requestID: id),
                       "stop 11111111-1111-1111-1111-111111111111 --json --request-id=porsche-11111111111111111111111111111111")
        XCTAssertThrowsError(try adapter.formatMachineAction(.stop, machineID: id))
    }

    func testRejectsMalformedAndForeignSnapshot() {
        let adapter = LinkedMilaFFIAdapter()
        XCTAssertThrowsError(try adapter.projectSnapshot(Data("{}".utf8), host: "mgmt.example.test"))
        XCTAssertThrowsError(try adapter.projectSnapshot(snapshot(), host: "foreign.example.test"))
        XCTAssertThrowsError(try adapter.projectSnapshot(snapshot(), host: "mgmt.example.test", port: 443))
    }

    func testRequestsCannotClaimSubmissionWithoutSession() async throws {
        let adapter = LinkedMilaFFIAdapter()
        let projection = try adapter.projectSnapshot(snapshot(), host: "mgmt.example.test")
        do {
            try await adapter.submit(.stop, machine: projection.machines[0], requestID: UUID())
            XCTFail("Formatting is not submission")
        } catch { XCTAssertEqual(error as? MilaFFIError, .unavailable) }
        do {
            try await adapter.submit(.delete, machine: projection.machines[0], requestID: UUID())
            XCTFail("Absent action must be refused")
        } catch { XCTAssertEqual(error as? MilaFFIError, .actionNotAllowed) }
        do {
            _ = try await adapter.call(MilaFFIRequest(operation: .refresh))
            XCTFail("An ABI version check is not a connection")
        } catch { XCTAssertEqual(error as? MilaFFIError, .unavailable) }
    }
}

@MainActor
final class MilaTerminalControllerTests: XCTestCase {
    private final class Transport: MilaTerminalTransport, @unchecked Sendable {
        var attachments: [(UInt64, UInt16, UInt16, Bool)] = []
        var inputs: [Data] = []
        var resizes: [(UInt16, UInt16)] = []
        var closed = 0
        func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws { attachments.append((from, columns, rows, readWrite)) }
        // Keep the receive side open while exercising the controller operations.
        // An immediate EOF races the attach continuation and marks the controller
        // failed before input/resize assertions run.
        func receiveOutput() async throws -> Data? {
            try await Task.sleep(for: .milliseconds(100))
            return nil
        }
        func sendInput(_ input: Data) async throws { inputs.append(input) }
        func resize(columns: UInt16, rows: UInt16) async throws { resizes.append((columns, rows)) }
        func close() async { closed += 1 }
    }

    func testAttachInputResizeReconnectAndCloseStayBounded() async {
        let transport = Transport()
        let controller = MilaTerminalController(transport: transport)
        await controller.attach(from: 4, columns: 100, rows: 30)
        XCTAssertEqual(controller.state, .attached)
        await controller.sendInput(Data("ls\n".utf8))
        await controller.resize(columns: 120, rows: 40)
        XCTAssertEqual(transport.inputs, [Data("ls\n".utf8)])
        XCTAssertEqual(transport.resizes.count, 1)
        controller.appendOutput(Data(repeating: 65, count: MilaTerminalController.maximumRenderedOutput + 1))
        XCTAssertEqual(controller.state, .failed)
        await controller.reconnect()
        XCTAssertEqual(controller.state, .attached)
        await controller.close()
        XCTAssertEqual(controller.state, .detached)
        XCTAssertGreaterThanOrEqual(transport.closed, 2)
    }

    func testInvalidResizeAndInputFailClosedBeforeHostTransport() async {
        let transport = Transport()
        let controller = MilaTerminalController(transport: transport)
        await controller.attach(from: 9, columns: 80, rows: 24)
        await controller.resize(columns: 0, rows: 24)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(transport.resizes.count, 0)
        await controller.sendInput(Data(repeating: 65, count: 64 * 1024 + 1))
        XCTAssertEqual(transport.inputs.count, 0)
    }
}

@MainActor
final class MilaAuthenticatedTerminalTransportTests: XCTestCase {
    private final class Transport: MilaTerminalTransport, @unchecked Sendable {
        var attaches = 0
        var inputs = 0
        var resizes = 0
        func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws { attaches += 1 }
        func sendInput(_ input: Data) async throws { inputs += 1 }
        func resize(columns: UInt16, rows: UInt16) async throws { resizes += 1 }
        func close() async {}
    }

    func testUnauthenticatedSessionNeverReachesHostTransport() async {
        let host = Transport()
        let transport = MilaAuthenticatedTerminalTransport(authorized: { false }, transport: host)
        do {
            try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true)
            XCTFail("unauthenticated attach must be refused")
        } catch { XCTAssertEqual(error as? MilaTerminalError, .unavailable) }
        XCTAssertEqual(host.attaches, 0)
        do {
            try await transport.sendInput(Data("pwd\n".utf8))
            XCTFail("unauthenticated input must be refused")
        } catch { XCTAssertEqual(error as? MilaTerminalError, .unavailable) }
        XCTAssertEqual(host.inputs, 0)
    }

    func testAuthenticatedSessionDelegatesValidatedOperations() async throws {
        let host = Transport()
        let transport = MilaAuthenticatedTerminalTransport(authorized: { true }, transport: host)
        try await transport.attach(from: 7, columns: 80, rows: 24, readWrite: true)
        try await transport.sendInput(Data("pwd\n".utf8))
        try await transport.resize(columns: 100, rows: 30)
        XCTAssertEqual(host.attaches, 1)
        XCTAssertEqual(host.inputs, 1)
        XCTAssertEqual(host.resizes, 1)
    }
}

final class MilaThreadActionTests: XCTestCase {
    private let thread = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let other = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    /// Each action carries exactly the shape `mila-session` accepts.
    func testActionsMatchRustSessionVocabulary() {
        XCTAssertEqual(MilaThreadAction.list.command, "thread ls")
        XCTAssertNil(MilaThreadAction.list.thread)
        XCTAssertFalse(MilaThreadAction.list.isMutation)
        XCTAssertEqual(MilaThreadAction.show(thread: thread).command, "thread show")
        XCTAssertEqual(MilaThreadAction.turns(thread: thread).command, "thread turns")
        let prompt = MilaThreadAction.prompt(thread: thread, text: "hello")
        XCTAssertEqual(prompt.command, "thread prompt"); XCTAssertNil(prompt.secondary); XCTAssertEqual(prompt.input, "hello"); XCTAssertTrue(prompt.isMutation)
        let answer = MilaThreadAction.answer(thread: thread, question: other, text: "yes")
        XCTAssertEqual(answer.command, "thread answer"); XCTAssertEqual(answer.secondary, other.uuidString.lowercased()); XCTAssertEqual(answer.input, "yes")
        let approve = MilaThreadAction.planApprove(thread: thread, plan: other)
        XCTAssertEqual(approve.command, "thread plan approve"); XCTAssertEqual(approve.secondary, other.uuidString.lowercased()); XCTAssertNil(approve.input)
        let revise = MilaThreadAction.planRevise(thread: thread, plan: other, text: "smaller")
        XCTAssertEqual(revise.command, "thread plan revise"); XCTAssertEqual(revise.input, "smaller"); XCTAssertEqual(revise.thread, thread)
    }

    func testTextBoundsAndControlCharacters() {
        XCTAssertTrue(MilaThreadAction.prompt(thread: thread, text: "line one\nline two").isWellFormed)
        XCTAssertFalse(MilaThreadAction.prompt(thread: thread, text: "   ").isWellFormed)
        XCTAssertFalse(MilaThreadAction.prompt(thread: thread, text: "nul\u{0000}").isWellFormed)
        XCTAssertFalse(MilaThreadAction.answer(thread: thread, question: other, text: "bell\u{0007}").isWellFormed)
        XCTAssertFalse(MilaThreadAction.planRevise(thread: thread, plan: other, text: String(repeating: "x", count: 64 * 1024 + 1)).isWellFormed)
        XCTAssertTrue(MilaThreadAction.planApprove(thread: thread, plan: other).isWellFormed)
    }
}
