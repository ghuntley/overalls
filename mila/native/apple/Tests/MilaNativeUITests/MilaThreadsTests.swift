import XCTest
@testable import MilaNativeUI

@MainActor final class MilaThreadsControllerTests: XCTestCase {
    private let thread = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let question = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let plan = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

    private func session() -> RecordingSession {
        let session = RecordingSession()
        session.threadResponses["thread ls"] = Data(#"{"version":1,"status":"succeeded","result":{"items":[{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"Fix the build","status":"ready","unread":2,"route":"overalls://x/threads/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","title":null,"status":"provisioning","unread":0}],"next_cursor":null}}"#.utf8)
        session.threadResponses["thread show"] = Data(#"{"version":1,"status":"succeeded","result":{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","title":"Fix the build","status":"ready","busy":false,"pending_question":{"id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","questions":[]},"latest_plan":{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","text":"plan","implemented":false}}}"#.utf8)
        for command in ["thread prompt", "thread answer", "thread plan approve", "thread plan revise"] {
            session.threadResponses[command] = Data(#"{"version":1,"status":"succeeded","request_id":"r","result":{}}"#.utf8)
        }
        return session
    }

    func testListAndShowDecodePorscheEnvelopeWithoutRequestIDs() async {
        let recording = session()
        let controller = MilaThreadsController()
        XCTAssertEqual(controller.state, .signedOut)
        controller.bind(LinkedMilaFFIAdapter(session: recording))
        await controller.list()
        XCTAssertEqual(controller.state, .loaded)
        XCTAssertEqual(controller.threads.map(\.title), ["Fix the build", nil])
        XCTAssertEqual(controller.threads.first?.unread, 2)
        await controller.show(thread)
        XCTAssertEqual(controller.detail?.pendingQuestion?.id, question)
        XCTAssertEqual(controller.detail?.latestPlan?.id, plan)
        XCTAssertEqual(recording.calls, [
            .thread(nil, "thread ls", nil, nil, nil),
            .thread(thread, "thread show", nil, nil, nil),
        ])
    }

    func testMutationsCarryCanonicalIdentitiesAndAreAtMostOnce() async {
        let recording = session()
        let controller = MilaThreadsController()
        controller.bind(LinkedMilaFFIAdapter(session: recording))
        let answer = UUID(), approve = UUID(), revise = UUID(), prompt = UUID()
        await controller.perform(.answer(thread: thread, question: question, text: "yes"), requestID: answer)
        XCTAssertEqual(controller.mutation, .applied(answer))
        await controller.perform(.planApprove(thread: thread, plan: plan), requestID: approve)
        await controller.perform(.planRevise(thread: thread, plan: plan, text: "smaller"), requestID: revise)
        await controller.perform(.prompt(thread: thread, text: "go"), requestID: prompt)
        let mutations = recording.calls.filter { if case .thread(_, let command, _, _, _) = $0 { return command != "thread show" }; return false }
        XCTAssertEqual(mutations, [
            .thread(thread, "thread answer", question.uuidString.lowercased(), "yes", answer),
            .thread(thread, "thread plan approve", plan.uuidString.lowercased(), nil, approve),
            .thread(thread, "thread plan revise", plan.uuidString.lowercased(), "smaller", revise),
            .thread(thread, "thread prompt", nil, "go", prompt),
        ])
        let before = recording.calls.count
        await controller.perform(.prompt(thread: thread, text: "again"), requestID: prompt)
        XCTAssertEqual(controller.mutation, .failed(prompt))
        await controller.perform(.prompt(thread: thread, text: "   "))
        await controller.perform(.list)
        XCTAssertEqual(recording.calls.count, before, "reused IDs, malformed text and reads never reach the session as mutations")
    }

    func testRebindFencesLateResultsAndSignedOutRefuses() async {
        let recording = session()
        let controller = MilaThreadsController()
        await controller.perform(.prompt(thread: thread, text: "x"))
        XCTAssertEqual(controller.mutation, .failed(nil))
        controller.bind(LinkedMilaFFIAdapter(session: recording))
        await controller.list()
        controller.bind(nil)
        XCTAssertTrue(controller.threads.isEmpty)
        XCTAssertNil(controller.detail)
        XCTAssertEqual(controller.state, .signedOut)
    }

    func testRefusedMutationAndMalformedRowsFail() async {
        let recording = session()
        recording.failMutations = true
        recording.threadResponses["thread ls"] = Data(#"{"version":1,"status":"succeeded","result":{"items":[{"id":"not-a-uuid","status":"ready"}],"next_cursor":null}}"#.utf8)
        let controller = MilaThreadsController()
        controller.bind(LinkedMilaFFIAdapter(session: recording))
        await controller.list()
        XCTAssertEqual(controller.state, .failed)
        let id = UUID()
        await controller.perform(.prompt(thread: thread, text: "x"), requestID: id)
        XCTAssertEqual(controller.mutation, .failed(id))
        recording.threadResponses["thread ls"] = Data(#"{"version":1,"status":"error","error":"forbidden"}"#.utf8)
        await controller.list()
        XCTAssertEqual(controller.state, .failed)
    }
}
