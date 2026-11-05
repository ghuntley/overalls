import Dispatch
import Foundation
import XCTest
@testable import MilaNativeUI

@MainActor
final class MilaTerminalTests: XCTestCase {
    func testTerminalImageProjectsOpaqueRGBAWithoutOverflow() throws {
        let json = #"{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":4,"height":1,"pixels":[16711680,65280,255,1193046]}]}"#
        let frame = try MilaTerminalFrame.decode(Data(json.utf8))
        XCTAssertEqual(frame.images[0].rgbaBytes, Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 18, 52, 86, 255]))
        XCTAssertNotNil(frame.images[0].cgImage)
    }

    func testTerminalImageRejectsOutOfRangePixels() {
        let json = #"{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":1,"height":1,"pixels":[16777216]}]}"#
        XCTAssertThrowsError(try MilaTerminalFrame.decode(Data(json.utf8)))
    }

    func testTerminalFrameRefusesTheCombinedImageBudget() {
        let pixels = Array(repeating: "0", count: 1024 * 513).joined(separator: ",")
        let image = "{\"x\":0,\"y\":0,\"width\":1024,\"height\":513,\"pixels\":[\(pixels)]}"
        let json = "{\"version\":1,\"columns\":1,\"rows\":1,\"cursor_column\":0,\"cursor_row\":0,\"lines\":[],\"images\":[\(image),\(image)]}"
        XCTAssertThrowsError(try MilaTerminalFrame.decode(Data(json.utf8)))
    }

    private struct EOFTransport: MilaTerminalTransport {
        func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws {}
        func receiveOutput() async throws -> Data? { nil }
        func sendInput(_ input: Data) async throws {}
        func resize(columns: UInt16, rows: UInt16) async throws {}
        func close() async {}
    }

    private actor DelayedTransport: MilaTerminalTransport {
        enum Operation: Hashable, Sendable { case attach, input, resize, close }
        private var delayed = Set<Operation>()
        private var pending: [Operation: CheckedContinuation<Void, Error>] = [:]

        func delay(_ operation: Operation) { delayed.insert(operation) }
        func waitUntilPending(_ operation: Operation) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while pending[operation] == nil && ContinuousClock.now < deadline { await Task.yield() }
            return pending[operation] != nil
        }
        func complete(_ operation: Operation, fail: Bool = false) {
            delayed.remove(operation)
            let continuation = pending.removeValue(forKey: operation)
            if fail { continuation?.resume(throwing: MilaTerminalError.unavailable) }
            else { continuation?.resume() }
        }
        private func suspend(_ operation: Operation) async throws {
            guard delayed.contains(operation) else { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending[operation] = continuation
            }
        }
        func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws { try await suspend(.attach) }
        func receiveOutput() async throws -> Data? {
            try await Task.sleep(for: .milliseconds(5))
            return Data()
        }
        func sendInput(_ input: Data) async throws { try await suspend(.input) }
        func resize(columns: UInt16, rows: UInt16) async throws { try await suspend(.resize) }
        func close() async { try? await suspend(.close) }
    }

    private func waitUntilPending(_ operation: DelayedTransport.Operation, on transport: DelayedTransport) async {
        let started = await transport.waitUntilPending(operation)
        XCTAssertTrue(started, "operation did not reach the transport before the deadline")
    }

    func testDelayedAttachCannotResurrectAClosedController() async {
        for fail in [false, true] {
            let transport = DelayedTransport()
            await transport.delay(.attach)
            let controller = MilaTerminalController(transport: transport)
            let attaching = Task { await controller.attach() }
            await waitUntilPending(.attach, on: transport)
            await controller.close()
            await transport.complete(.attach, fail: fail)
            await attaching.value
            XCTAssertEqual(controller.state, .detached)
            XCTAssertFalse(controller.canSendInput)
            XCTAssertTrue(controller.output.isEmpty)
            XCTAssertNil(controller.frame)
        }
    }

    func testDelayedReconnectCannotResurrectAClosedController() async {
        let transport = DelayedTransport()
        let controller = MilaTerminalController(transport: transport)
        await controller.attach()
        await transport.delay(.attach)
        let reconnecting = Task { await controller.reconnect() }
        await waitUntilPending(.attach, on: transport)
        await controller.close()
        await transport.complete(.attach)
        await reconnecting.value
        XCTAssertEqual(controller.state, .detached)
        XCTAssertFalse(controller.canSendInput)
    }

    func testDelayedCloseCannotDetachANewerAttachment() async {
        let transport = DelayedTransport()
        let controller = MilaTerminalController(transport: transport)
        await controller.attach()
        await transport.delay(.close)
        let closing = Task { await controller.close() }
        await waitUntilPending(.close, on: transport)
        await controller.attach(columns: 100, rows: 30)
        await transport.complete(.close)
        await closing.value
        XCTAssertEqual(controller.state, .attached)
        XCTAssertEqual(controller.columns, 100)
        XCTAssertTrue(controller.canSendInput)
        await controller.close()
    }

    func testLateInputFailureCannotFailANewerAttachment() async {
        let transport = DelayedTransport()
        let controller = MilaTerminalController(transport: transport)
        await controller.attach()
        await transport.delay(.input)
        let input = Task { await controller.sendInput(Data("x".utf8)) }
        await waitUntilPending(.input, on: transport)
        await controller.attach(columns: 100, rows: 30)
        await transport.complete(.input, fail: true)
        await input.value
        XCTAssertEqual(controller.state, .attached)
        XCTAssertEqual(controller.columns, 100)
        await controller.close()
    }

    func testLateResizeResultOrFailureCannotChangeANewerAttachment() async {
        for fail in [false, true] {
            let transport = DelayedTransport()
            let controller = MilaTerminalController(transport: transport)
            await controller.attach()
            await transport.delay(.resize)
            let resizing = Task { await controller.resize(columns: 132, rows: 40) }
            await waitUntilPending(.resize, on: transport)
            await controller.attach(columns: 100, rows: 30)
            await transport.complete(.resize, fail: fail)
            await resizing.value
            XCTAssertEqual(controller.state, .attached)
            XCTAssertEqual(controller.columns, 100)
            XCTAssertEqual(controller.rows, 30)
            await controller.close()
        }
    }

    private final class BlockingAttachSession: MilaPtySession, @unchecked Sendable {
        private let lock = NSLock()
        private let releaseGate = DispatchSemaphore(value: 0)
        private var next: UInt64 = 100
        private var started = false
        private var kills: [UInt64] = []
        private var inputs: [UInt64] = []
        private func locked<T>(_ operation: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return operation()
        }
        var isAuthenticated: Bool { true }
        var attachmentStarted: Bool { locked { started } }
        var killed: [UInt64] { locked { kills } }
        var inputHandles: [UInt64] { locked { inputs } }
        func release() { releaseGate.signal() }
        func terminalAttach(machine: UUID, columns: UInt32, rows: UInt32) throws -> UInt64 {
            let handle = locked { next += 1; return next }
            if handle == 101 {
                locked { started = true }
                guard releaseGate.wait(timeout: .now() + 5) == .success else { throw MilaTerminalError.unavailable }
            }
            return handle
        }
        func terminalPoll(_ terminal: UInt64) throws -> Data { Data() }
        func terminalRead(_ terminal: UInt64, waitMilliseconds: UInt32) throws -> MilaTerminalRead { .idle }
        func terminalInput(_ terminal: UInt64, data: Data) throws { locked { inputs.append(terminal) } }
        func terminalResize(_ terminal: UInt64, columns: UInt32, rows: UInt32) throws {}
        func terminalKill(_ terminal: UInt64) { locked { kills.append(terminal) } }
    }

    private func waitUntilNativeAttachStarted(_ session: BlockingAttachSession) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !session.attachmentStarted && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(session.attachmentStarted)
    }

    func testNativeHandleReturnedAfterCloseIsKilledWithoutPublication() async {
        let session = BlockingAttachSession()
        let transport = MilaLiveSessionTerminalTransport(session: session, machine: UUID())
        let attaching = Task.detached { () -> Bool in
            do { try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true); return true }
            catch { return false }
        }
        await waitUntilNativeAttachStarted(session)
        await transport.close()
        session.release()
        let attached = await attaching.value
        XCTAssertFalse(attached)
        XCTAssertEqual(transport.currentGeneration, 0)
        XCTAssertEqual(session.killed, [101])
        let ended = try? await transport.receiveOutput()
        XCTAssertNil(ended)
    }

    func testSupersededNativeAttachKillsOnlyItsOwnHandle() async throws {
        let session = BlockingAttachSession()
        defer { session.release() }
        let transport = MilaLiveSessionTerminalTransport(session: session, machine: UUID())
        let older = Task.detached { () -> Bool in
            do { try await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true); return true }
            catch { return false }
        }
        await waitUntilNativeAttachStarted(session)
        try await transport.attach(from: 0, columns: 100, rows: 30, readWrite: true)
        session.release()
        let oldAttached = await older.value
        XCTAssertFalse(oldAttached)
        XCTAssertNotEqual(transport.currentGeneration, 0)
        XCTAssertEqual(session.killed, [101])
        try await transport.sendInput(Data("x".utf8))
        XCTAssertEqual(session.inputHandles, [102])
        await transport.close()
        XCTAssertEqual(session.killed, [101, 102])
    }

    private actor FrameThenRefuseTransport: MilaTerminalTransport {
        private let frame: MilaTerminalFrame
        private var attaches = 0
        private var delivered = false

        init(frame: MilaTerminalFrame) { self.frame = frame }
        func attach(from: UInt64, columns: UInt16, rows: UInt16, readWrite: Bool) async throws {
            attaches += 1
            guard attaches == 1 else { throw MilaTerminalError.unavailable }
        }
        func receiveOutput() async throws -> Data? {
            if delivered {
                try await Task.sleep(for: .milliseconds(5))
                return Data()
            }
            delivered = true
            return Data("stale".utf8)
        }
        func renderedFrame() async -> MilaTerminalFrame? { frame }
        func sendInput(_ input: Data) async throws {}
        func resize(columns: UInt16, rows: UInt16) async throws {}
        func close() async {}
    }

    private func controllerWithRenderedFrame() async throws -> MilaTerminalController {
        let json = #"{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[[{"text":"stale","foreground":null,"background":null,"bold":false,"italic":false,"underline":false,"inverse":false}]],"images":[{"x":0,"y":0,"width":1,"height":1,"pixels":[16711680]}]}"#
        let frame = try MilaTerminalFrame.decode(Data(json.utf8))
        let controller = MilaTerminalController(transport: FrameThenRefuseTransport(frame: frame))
        await controller.attach()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while controller.frame == nil && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(controller.frame?.text, "stale")
        XCTAssertEqual(controller.frame?.images.count, 1)
        XCTAssertEqual(controller.output, Data("stale".utf8))
        return controller
    }

    func testFailedReconnectClearsPreviousGenerationTextAndImages() async throws {
        let controller = try await controllerWithRenderedFrame()
        await controller.reconnect()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.output.isEmpty)
        XCTAssertNil(controller.frame)
    }

    func testFailedFreshAttachClearsPreviousGenerationTextAndImages() async throws {
        let controller = try await controllerWithRenderedFrame()
        await controller.attach()
        XCTAssertEqual(controller.state, .failed)
        XCTAssertTrue(controller.output.isEmpty)
        XCTAssertNil(controller.frame)
    }

    func testAttachRequestIDIsAtMostOnce() async {
        let controller = MilaTerminalController()
        let id = UUID()
        await controller.attach(requestID: id)
        XCTAssertEqual(controller.state, .attached)
        await controller.attach(requestID: id)
        XCTAssertEqual(controller.state, .failed)
    }

    func testReconnectClearsPreviousGenerationOutput() async {
        let controller = MilaTerminalController(transport: EOFTransport())
        await controller.attach()
        controller.appendOutput(Data("stale".utf8))
        XCTAssertFalse(controller.output.isEmpty)
        await controller.reconnect()
        XCTAssertTrue(controller.output.isEmpty)
    }

    func testCleanEOFMarksTransportFailed() async {
        let controller = MilaTerminalController(transport: EOFTransport())
        await controller.attach()
        for _ in 0..<20 where controller.state == .attached {
            await Task.yield()
        }
        XCTAssertEqual(controller.state, .failed)
    }

    func testOutputArrivingAfterCloseIsIgnored() async {
        let controller = MilaTerminalController(transport: EOFTransport())
        await controller.attach()
        await controller.close()
        controller.appendOutput(Data("late".utf8))
        XCTAssertTrue(controller.output.isEmpty)
    }
}
