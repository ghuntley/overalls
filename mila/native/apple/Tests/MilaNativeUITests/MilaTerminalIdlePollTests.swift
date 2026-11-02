import Foundation
import XCTest
@testable import MilaNativeUI

/// A `MilaPtySession` that models the Rust PTY registry's per-terminal lock
/// (`mila-ffi/src/session.rs`): a read holds the lock for its whole wait plus a
/// fixed call time, and input, resize or kill that finds it held is refused
/// with `Busy` (-13), as Rust's `try_lock` does. Reads follow
/// `mila_session_terminal_read_within`: scripted chunks, then `.idle` while the
/// channel stays open, or `.closed` once `closeAfterScript` is set.
final class LockModelPtySession: MilaPtySession, @unchecked Sendable {
    static let busy = MilaSessionError.transport(-13)
    /// Time one read holds the PTY lock even when it does not wait.
    let callTime: TimeInterval
    private let state = NSLock()
    private var script: [Data]
    private var closeAfterScript: Bool
    private var held = false
    private var reads = 0
    private var idleReads = 0
    private var longestWait: UInt32 = 0
    private var busyRefusals = 0
    private var inputs: [Data] = []
    private var resizes: [(UInt32, UInt32)] = []
    private var kills: [UInt64] = []
    private var next: UInt64 = 500

    init(script: [Data] = [], closeAfterScript: Bool = false, callTime: TimeInterval = 0.002) {
        self.script = script
        self.closeAfterScript = closeAfterScript
        self.callTime = callTime
    }

    private func locked<T>(_ body: () -> T) -> T { state.lock(); defer { state.unlock() }; return body() }

    var readCount: Int { locked { reads } }
    var idleReadCount: Int { locked { idleReads } }
    var longestRequestedWait: UInt32 { locked { longestWait } }
    var busyRefusalCount: Int { locked { busyRefusals } }
    var receivedInputs: [Data] { locked { inputs } }
    var receivedResizes: [(UInt32, UInt32)] { locked { resizes } }
    var killed: [UInt64] { locked { kills } }

    var isAuthenticated: Bool { true }

    func terminalAttach(machine: UUID, columns: UInt32, rows: UInt32) throws -> UInt64 {
        _ = machine; _ = columns; _ = rows
        return locked { next += 1; return next }
    }

    func terminalPoll(_ terminal: UInt64) throws -> Data {
        _ = terminal
        XCTFail("the transport must not use the session-timeout poll")
        throw MilaSessionError.unavailable
    }

    func terminalRead(_ terminal: UInt64, waitMilliseconds: UInt32) throws -> MilaTerminalRead {
        _ = terminal
        let acquired: Bool = locked {
            guard !held else { busyRefusals += 1; return false }
            held = true
            reads += 1
            longestWait = max(longestWait, waitMilliseconds)
            return true
        }
        guard acquired else { throw Self.busy }
        // The lock stays held for the read: the call itself, plus the wait when idle.
        let chunk: MilaTerminalRead = locked {
            if !script.isEmpty { return .data(script.removeFirst()) }
            return closeAfterScript ? .closed : .idle
        }
        let idle = chunk == .idle
        Thread.sleep(forTimeInterval: callTime + (idle ? Double(waitMilliseconds) / 1_000 : 0))
        locked { held = false; if idle { idleReads += 1 } }
        return chunk
    }

    /// Input, resize and kill take the PTY lock with `try_lock`, as Rust does.
    private func exclusive(_ body: () -> Void) throws {
        let acquired: Bool = locked {
            guard !held else { busyRefusals += 1; return false }
            body()
            return true
        }
        guard acquired else { throw Self.busy }
    }

    func terminalInput(_ terminal: UInt64, data: Data) throws {
        _ = terminal
        try exclusive { inputs.append(data) }
    }

    func terminalResize(_ terminal: UInt64, columns: UInt32, rows: UInt32) throws {
        _ = terminal
        try exclusive { resizes.append((columns, rows)) }
    }

    func terminalKill(_ terminal: UInt64) {
        try? exclusive { kills.append(terminal) }
    }
}

/// Evidence for `mila-apple-pty-idle-poll`: the SwiftUI terminal controller over
/// the production transport survives an idle PTY, and its input and resize are
/// not refused by the reader's PTY lock.
@MainActor final class MilaTerminalIdlePollTests: XCTestCase {
    private let machine = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func controller(_ session: LockModelPtySession) -> MilaTerminalController {
        MilaTerminalController(transport: MilaLiveSessionTerminalTransport(session: session, machine: machine, idle: .milliseconds(1)))
    }

    func testIdleReadsKeepTheControllerAttachedUntilOutputArrives() async {
        let session = LockModelPtySession()
        let terminal = controller(session)
        await terminal.attach(columns: 80, rows: 24)
        XCTAssertEqual(terminal.state, .attached)
        // Many idle reads in a row: the stream is quiet, not failed.
        await assertEventually({ session.idleReadCount >= 50 }, iterations: 2_000)
        XCTAssertEqual(terminal.state, .attached)
        XCTAssertTrue(terminal.output.isEmpty)
        await terminal.close()
        XCTAssertEqual(terminal.state, .detached)
    }

    func testOutputAfterAnIdleStretchIsRendered() async {
        let session = LockModelPtySession(script: [])
        let transport = MilaLiveSessionTerminalTransport(session: session, machine: machine, idle: .milliseconds(1))
        try? await transport.attach(from: 0, columns: 80, rows: 24, readWrite: true)
        for _ in 0..<10 {
            let step = try? await transport.receiveOutput()
            XCTAssertEqual(step, Data(), "an idle read is an empty step, not an end or an error")
        }
        await transport.close()
        let ended = try? await transport.receiveOutput()
        XCTAssertNil(ended, "a closed transport ends the stream")

        let scripted = LockModelPtySession(script: [Data("late".utf8)])
        let terminal = controller(scripted)
        await terminal.attach(columns: 80, rows: 24)
        await assertEventually { String(decoding: terminal.output, as: UTF8.self) == "late" }
        await assertEventually({ scripted.idleReadCount >= 20 }, iterations: 2_000)
        XCTAssertEqual(terminal.state, .attached, "idle reads after output keep the stream open")
        await terminal.close()
    }

    func testReadsNeverWaitWhileHoldingThePTYLock() async {
        let session = LockModelPtySession()
        let terminal = controller(session)
        await terminal.attach(columns: 80, rows: 24)
        await assertEventually({ session.readCount >= 20 }, iterations: 2_000)
        XCTAssertEqual(session.longestRequestedWait, 0, "a read that holds the PTY lock must not wait for output")
        await terminal.close()
    }

    func testInputAndResizeGoThroughWhileTheReaderPolls() async {
        // A longer per-read lock hold makes an unserialized input meet it.
        let session = LockModelPtySession(callTime: 0.005)
        let terminal = controller(session)
        await terminal.attach(columns: 80, rows: 24)
        await assertEventually({ session.readCount >= 5 }, iterations: 2_000)
        for index in 0..<40 {
            await terminal.sendInput(Data("echo \(index)\r".utf8))
            XCTAssertEqual(terminal.state, .attached, "input \(index) was refused")
            if index % 10 == 0 {
                await terminal.resize(columns: 132, rows: 40)
                XCTAssertEqual(terminal.state, .attached, "resize at \(index) was refused")
            }
        }
        XCTAssertEqual(session.receivedInputs.count, 40)
        XCTAssertEqual(session.receivedResizes.count, 4)
        XCTAssertTrue(session.receivedResizes.allSatisfy { $0 == (132, 40) })
        XCTAssertEqual(terminal.columns, 132)
        XCTAssertEqual(terminal.rows, 40)
        XCTAssertEqual(session.busyRefusalCount, 0, "no operation met the reader's PTY lock")
        XCTAssertGreaterThan(session.readCount, 5, "the reader kept polling while input ran")
        await terminal.close()
        XCTAssertEqual(session.killed.count, 1, "detach kills the handle even while the reader polls")
        XCTAssertEqual(session.busyRefusalCount, 0)
    }

    func testAClosedChannelEndsTheStream() async {
        let session = LockModelPtySession(script: [Data("bye".utf8)], closeAfterScript: true)
        let terminal = controller(session)
        await terminal.attach(columns: 80, rows: 24)
        // A clean PTY close still ends the session: the controller refuses further input.
        await assertEventually { terminal.state == .failed }
        XCTAssertEqual(session.busyRefusalCount, 0)
    }
}
