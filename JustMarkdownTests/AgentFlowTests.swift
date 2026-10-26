import UIKit
import WebKit
import XCTest

@testable import JustMarkdown

private struct AgentFixture: Sendable {
    var status = 200
    var text = ""
    var delay: TimeInterval = 0
    var waitsForCancellation = false
    var complete = true
    var headers: [String: String] = [:]
    var calls: [ModelToolCall] = []
}

private final class AgentFixtureQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [AgentFixture] = []
    private var bodies: [Data] = []
    func reset(_ values: [AgentFixture]) {
        lock.withLock {
            fixtures = values
            bodies = []
        }
    }
    func next(_ request: URLRequest) -> AgentFixture {
        lock.withLock {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let length = stream.read(&buffer, maxLength: buffer.count)
                    guard length > 0 else { break }
                    body.append(contentsOf: buffer.prefix(length))
                }
            }
            bodies.append(body)
            return fixtures.isEmpty ? AgentFixture(status: 503) : fixtures.removeFirst()
        }
    }
    func requests() -> [Data] { lock.withLock { bodies } }
}

private final class AgentFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let queue = AgentFixtureQueue()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "agent.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.queue.next(request)
        if fixture.waitsForCancellation { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                headerFields: fixture.headers.merging(
                    ["Content-Type": "text/event-stream"], uniquingKeysWith: { a, _ in a }))!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if fixture.status == 200 {
                let responses = request.url?.path.hasSuffix("/responses") == true
                if !fixture.calls.isEmpty {
                    let calls = fixture.calls.map { call -> [String: Any] in
                        responses
                            ? [
                                "type": "function_call", "id": "fc_" + call.id, "call_id": call.id, "name": call.name,
                                "arguments": call.arguments,
                            ]
                            : [
                                "id": call.id, "type": "function",
                                "function": ["name": call.name, "arguments": call.arguments],
                            ]
                    }
                    let payload: [String: Any] =
                        responses
                        ? ["type": "response.completed", "response": ["status": "completed", "output": calls]]
                        : [
                            "choices": [
                                [
                                    "delta": [
                                        "tool_calls": calls.enumerated().map {
                                            $0.element.merging(["index": $0.offset], uniquingKeysWith: { a, _ in a })
                                        }
                                    ], "finish_reason": fixture.complete ? "tool_calls" : "length",
                                ]
                            ]
                        ]
                    let data = try! JSONSerialization.data(withJSONObject: payload)
                    client?.urlProtocol(self, didLoad: Data("data: ".utf8) + data + Data("\n\n".utf8))
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                let payload: [String: Any] =
                    responses
                    ? ["type": "response.output_text.delta", "delta": fixture.text]
                    : ["choices": [["delta": ["content": fixture.text]]]]
                let json = try! JSONSerialization.data(withJSONObject: payload)
                var data = Data("data: ".utf8)
                data.append(json)
                data.append(Data("\n\n".utf8))
                if fixture.complete {
                    data.append(
                        Data(
                            (responses
                                ? "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
                                : "data: [DONE]\n\n").utf8))
                }
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@MainActor
final class AgentFlowTests: AgentReaderTestCase {
    private func reader(
        _ text: String, api: ModelAPIProtocol = .chatCompletions,
        baseURL: String = "https://agent.example.test/v1", model: String = "fixture-model",
        modelKey: @escaping @MainActor () -> String = { "fixture-key" }, dataSharingAllowed: Bool = true
    ) async throws -> (ReaderSession, ReaderBridge, UIWindow, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        return try await makeReader(
            text, api: api, baseURL: baseURL, model: model,
            modelClient: ModelClient(session: URLSession(configuration: configuration)),
            modelKey: modelKey, dataSharingAllowed: dataSharingAllowed)
    }

    private func completed(_ bridge: ReaderBridge, count: Int = 2, timeout: TimeInterval = 30) async throws {
        try await wait(timeout: timeout) {
            let status = try await self.state(bridge)
            return (status["turns"] as? [[String: Any]])?.count == count
                && (status["turns"] as? [[String: Any]])?.last?["state"] as? String == "complete"
        }
    }

    func testFirstSendWaitsForConsentAndCancelPreservesDraftAndSelection() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "第一轮回答。"), AgentFixture(text: "第二轮回答。")])
        let (session, bridge, _, _) = try await reader(
            "# 文档\n\nSELECTED_ONLY\n\n完整文档背景。\n", dataSharingAllowed: false)
        try await sourceMode(bridge)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection")
        try await send("解释这段。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        var result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "解释这段。")
        XCTAssertTrue((result["reference"] as? String)?.contains("SELECTED_ONLY") == true)
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.count, 0)
        // A second submission while the native alert is open cannot queue a send.
        try await send("解释这段。", bridge: bridge)
        session.finishDataSharingConsent(allowed: false)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "解释这段。")
        XCTAssertTrue((result["reference"] as? String)?.contains("SELECTED_ONLY") == true)
        try await send("解释这段。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        session.finishDataSharingConsent(allowed: true)
        try await completed(bridge)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        XCTAssertTrue(String(decoding: AgentFixtureProtocol.queue.requests()[0], as: UTF8.self).contains("完整文档背景"))
        try await send("继续。", bridge: bridge)
        try await completed(bridge, count: 4)
        XCTAssertFalse(session.needsDataSharingConsent)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 2)
    }

    func testConsentCannotAuthorizeAChangedServiceOrAnotherDocument() async throws {
        AgentFixtureProtocol.queue.reset([])
        let (session, bridge, _, file) = try await reader("# 原文\n", dataSharingAllowed: false)
        let originalService = try ModelDataConsent.service(for: session.configuration)
        _ = try await bridge.call("toggleAgent")
        try await send("待发送的问题。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        session.configuration.baseURL = "https://agent.example.test/another/v1"
        session.finishDataSharingConsent(allowed: true)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        XCTAssertFalse(session.dataConsent.allows(originalService))
        XCTAssertFalse(try session.dataConsent.allows(ModelDataConsent.service(for: session.configuration)))
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        try await send("待发送的问题。", bridge: bridge)
        try await wait { session.needsDataSharingConsent }
        let next = file.deletingLastPathComponent().appendingPathComponent("another.md")
        try Data("# 另一份文档\n".utf8).write(to: next)
        await session.open(next)
        // This harness hosts WebKit directly rather than SwiftUI's observed
        // ReaderWebView, so forward the document update explicitly.
        bridge.update()
        session.finishDataSharingConsent(allowed: true)
        try await wait { session.rendererReady }
        XCTAssertFalse(session.needsDataSharingConsent)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        XCTAssertFalse(try session.dataConsent.allows(ModelDataConsent.service(for: session.configuration)))

        // The native request boundary also rejects a snapshot that skipped the UI gate.
        session.requestAgent(
            id: "without-permission", token: session.documentToken,
            snapshot: AgentSnapshot(question: "禁止发送", attachment: nil, history: []), intent: "question")
        XCTAssertNil(session.agentTransport.activeID)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
    }

    func testRetryToAnotherServiceRequiresConsentAndPreservesReplyAndDraft() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "已经收到的部分回答。", complete: false), AgentFixture(text: "重新生成的回答。"),
        ])
        let (session, bridge, _, _) = try await reader("# 文档\n\n原始全文。\n")
        _ = try await bridge.call("toggleAgent")
        try await send("解释。", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        session.configuration.baseURL = "https://agent.example.test/another/v1"
        _ = try await bridge.webView.evaluateJavaScript(
            "const input = document.querySelector('.mdv-composer textarea'); input.value = '下一轮草稿'; input.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('[data-agent-action=retry]').click();"
        )
        try await wait { session.needsDataSharingConsent }
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
        session.finishDataSharingConsent(allowed: false)
        try await wait {
            try await bridge.webView.evaluateJavaScript("!document.querySelector('.mdv-agent-send').disabled") as? Bool
                == true
        }
        let cancelled = try await state(bridge)
        XCTAssertEqual(cancelled["draft"] as? String, "下一轮草稿")
        XCTAssertTrue(((cancelled["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('[data-agent-action=retry]').click();")
        try await wait { session.needsDataSharingConsent }
        session.finishDataSharingConsent(allowed: true)
        try await completed(bridge)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 2)
        let completedState = try await state(bridge)
        XCTAssertEqual(completedState["draft"] as? String, "下一轮草稿")
    }

    func testRichRepliesHistoryAndGlobalContextUseCurrentBuffer() async throws {
        let original = "# 原始文档\n\n需要解释的 **概念**。\n"
        let rich = """
            **回答**与 `code`。

            | 项目 | 内容 |
            | --- | --- |
            | A | B |

            行内公式 $x^2$ 与脚注[^a]。

            ```mermaid
            flowchart LR
              A --> B
            ```

            [^a]: 引用说明。
            """
        AgentFixtureProtocol.queue.reset([AgentFixture(text: rich), AgentFixture(text: "第二轮**回答**。")])
        let (session, bridge, _, _) = try await reader(original)
        _ = try await bridge.call("toggleAgent")
        try await wait { session.agentOpen }
        try await send("解释 **概念**。", bridge: bridge)
        try await completed(bridge)
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-assistant-turn .katex').length === 1 && document.querySelectorAll('.mdv-assistant-turn .mdv-mermaid svg').length === 1"
            ) as? Bool == true
        }
        let first = try await state(bridge)
        XCTAssertEqual((first["turns"] as? [[String: Any]])?.count, 2)
        let unsafe =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-turn script,.mdv-turn iframe,.mdv-turn [onerror]').length") as? Int
        XCTAssertEqual(unsafe, 0)
        let updated = "# 新文档内容\n\n更新后的内容。\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: updated)
        await session.closeAgent()
        _ = try await bridge.call("toggleAgent")
        try await send("继续解释。", bridge: bridge)
        try await completed(bridge, count: 4)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 2)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] ?? "" }, ["system", "user", "assistant", "user"])
        let firstContext = try ModelWireFormat.object(Data(try XCTUnwrap(messages[1]["content"]).utf8))
        let latestContext = try ModelWireFormat.object(Data(try XCTUnwrap(messages[3]["content"]).utf8))
        let background = try XCTUnwrap(latestContext["background"] as? [String: Any])
        let versions = try XCTUnwrap(background["documents"] as? [[String: String]])
        XCTAssertEqual(versions.count, 2)
        let firstID = (firstContext["reference"] as? [String: String])?["documentID"]
        let latestID = (latestContext["reference"] as? [String: String])?["documentID"]
        XCTAssertEqual(versions.first { $0["id"] == firstID }?["content"], original)
        XCTAssertEqual(versions.first { $0["id"] == latestID }?["content"], updated)
        XCTAssertNil(firstContext["background"])
        XCTAssertFalse(String(decoding: requests[1], as: UTF8.self).contains("fixture-key"))
    }

    func testInterruptedRetryReusesSnapshotAndKeepsNewDraft() async throws {
        AgentFixtureProtocol.queue.reset([
            AgentFixture(text: "已经收到的**部分回答**。", complete: false),
            AgentFixture(text: "完整的**重试回答**。", delay: 0.5),
        ])
        let (_, bridge, _, _) = try await reader("# 原文\n\n原始引用。\n")
        _ = try await bridge.call("toggleAgent")
        try await send("解释这段。", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        _ = try await bridge.webView.evaluateJavaScript(
            "document.querySelector('.mdv-composer textarea').value = '尚未发送的新草稿'; document.querySelector('.mdv-composer textarea').dispatchEvent(new Event('input',{bubbles:true}));"
        )
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: "# 后续文档\n\n不应进入重试请求。\n")
        _ = try await bridge.webView.evaluateJavaScript(
            "const retry = document.querySelector('[data-agent-action=retry]'); retry.click(); retry.click();")
        var result = try await state(bridge)
        XCTAssertTrue(((result["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        try await completed(bridge)
        result = try await state(bridge)
        XCTAssertEqual(result["draft"] as? String, "尚未发送的新草稿")
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.count, 2)
        XCTAssertFalse(((result["turns"] as? [[String: Any]])?.last?["text"] as? String)?.contains("部分回答") == true)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 2)
        let firstBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(requests.first)) as? NSDictionary)
        let lastBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last)) as? NSDictionary)
        XCTAssertEqual(firstBody, lastBody)
    }

    func testResponsesGlobalContextRefreshesAtSendAndSelectionCancelDoesNotLeak() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "**真实桥接的回答**。")])
        let (session, bridge, _, _) = try await reader("# 原始文档\n\nSELECTED_ONLY\n\nUNSELECTED\n", api: .responses)
        try await sourceMode(bridge)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection", arguments: ["payload": "SELECTED_ONLY"])
        try await wait { session.agentOpen }
        await session.closeAgent()
        _ = try await bridge.call("toggleAgent")
        let current = "# 当前文档\n\n完整的新内容。\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: current)
        try await send("总结现在的全文。", bridge: bridge)
        try await completed(bridge)
        let bodies = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(bodies.count, 1)
        let body = try ModelWireFormat.object(XCTUnwrap(bodies.first))
        let messages = try XCTUnwrap(body["input"] as? [[String: String]])
        let context = try ModelWireFormat.object(Data(try XCTUnwrap(messages.last?["content"]).utf8))
        XCTAssertEqual((context["reference"] as? [String: String])?["scope"], "document")
        let background = try XCTUnwrap(context["background"] as? [String: Any])
        let versions = try XCTUnwrap(background["documents"] as? [[String: String]])
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions.first?["content"], current)
        XCTAssertEqual(background["currentDocumentID"] as? String, versions.first?["id"])
        XCTAssertFalse(String(decoding: bodies[0], as: UTF8.self).contains("SELECTED_ONLY"))
    }

    func testUnconfiguredSelectionWaitsAndResumesWithOnlyItsQuote() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(text: "所选内容的解释。")])
        final class Credential { var value = "" }
        let key = Credential()
        let (session, bridge, _, _) = try await reader("# 标题\n\nSELECTED_ONLY\n\nUNSELECTED\n", modelKey: { key.value })
        try await sourceMode(bridge)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection")
        try await wait { session.needsModelConfiguration }
        XCTAssertFalse(session.agentOpen)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0)
        session.needsModelConfiguration = false
        session.finishAgentConfiguration(saved: false)
        try selectSource("SELECTED_ONLY", bridge: bridge)
        _ = try await bridge.call("askSelection")
        try await wait { session.needsModelConfiguration }
        key.value = "fixture-key"
        session.needsModelConfiguration = false
        session.finishAgentConfiguration(saved: true)
        try await wait { session.agentOpen }
        let result = try await state(bridge)
        XCTAssertTrue((result["reference"] as? String)?.contains("SELECTED_ONLY") == true)
        XCTAssertFalse((result["reference"] as? String)?.contains("UNSELECTED") == true)
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 0, "Configuration must not submit a question")
        try await send("解释", bridge: bridge)
        try await completed(bridge)
        let body = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().first))
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let context = try ModelWireFormat.object(Data(try XCTUnwrap(messages.last?["content"]).utf8))
        XCTAssertEqual((context["reference"] as? [String: String])?["content"], "SELECTED_ONLY")
        let background = try XCTUnwrap(context["background"] as? [String: Any])
        let versions = try XCTUnwrap(background["documents"] as? [[String: String]])
        XCTAssertEqual(versions.first?["content"], "# 标题\n\nSELECTED_ONLY\n\nUNSELECTED\n")
    }

    func testCollapseKeepsRequestAndExplicitStopCancelsIt() async throws {
        AgentFixtureProtocol.queue.reset([AgentFixture(waitsForCancellation: true)])
        let (session, bridge, _, _) = try await reader("# 需要总结的文档\n\n正文。\n")
        _ = try await bridge.call("toggleAgent")
        try await send("总结全文。", bridge: bridge)
        try await wait {
            session.agentTransport.activeID != nil && AgentFixtureProtocol.queue.requests().count == 1
        }
        await session.closeAgent()
        XCTAssertNotNil(session.agentTransport.activeID)
        _ = try await bridge.call("toggleAgent")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click();")
        try await wait { session.agentTransport.activeID == nil }
        let result = try await state(bridge)
        XCTAssertEqual((result["turns"] as? [[String: Any]])?.last?["state"] as? String, "stopped")
        XCTAssertEqual(AgentFixtureProtocol.queue.requests().count, 1)
    }

    private func selectSource(_ text: String, bridge: ReaderBridge) throws {
        let range = (bridge.sourceEditor.history.text as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { throw CocoaError(.coderReadCorrupt) }
        bridge.sourceEditor.textView.selectedRange = range
    }

    private func editCall(_ text: String, before: String, after: String, id: String = "edit-1") throws -> ModelToolCall
    {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "revision": AgentDocumentTools.revision(text), "edits": [["before": before, "after": after]],
            ], options: .sortedKeys)
        return ModelToolCall(id: id, name: "edit_document", arguments: String(decoding: data, as: UTF8.self))
    }

    func testSourceAgentEditsFileAndSharesUndoRedoWithManualEditing() async throws {
        let original = "# 文档\n\n需要修改的原文。\n\n保留这一段。\n"
        let applied = original.replacingOccurrences(of: "需要修改的原文。", with: "新的 **内容**。")
        for api in ModelAPIProtocol.allCases {
            AgentFixtureProtocol.queue.reset([
                AgentFixture(calls: [try editCall(original, before: "需要修改的原文。", after: "新的 **内容**。")]),
                AgentFixture(text: "已修改，其他段落保持原样。"), AgentFixture(text: "这是原文的解释。"),
            ])
            let (session, bridge, _, url) = try await reader(original, api: api)
            try await sourceMode(bridge)
            _ = try await bridge.call("toggleAgent")
            try await send("把第一段改为新的 **内容**。", bridge: bridge)
            try await completed(bridge)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), applied)
            let requests = AgentFixtureProtocol.queue.requests()
            XCTAssertEqual(requests.count, 2)
            let continuation = try ModelWireFormat.object(requests[1])
            let wire = String(decoding: requests[1], as: UTF8.self)
            XCTAssertTrue(wire.contains("edit-1"))
            XCTAssertTrue(wire.contains("saved"))
            XCTAssertEqual((continuation["tools"] as? [[String: Any]])?.count, 2)
            XCTAssertFalse(wire.contains("fixture-key"))
            // Deliver the native save acknowledgement only after a later history action.
            _ = try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const deliver = window.JustMarkdown.agentUndoResult.bind(window.JustMarkdown);
                  window.JustMarkdown.agentUndoResult = payload => {
                    window.delayedUndoResult = () => {
                      window.JustMarkdown.agentUndoResult = deliver;
                      delete window.delayedUndoResult;
                      deliver(payload);
                    };
                  };
                })();
                """)
            _ = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('[data-agent-action=undo]').click();")
            try await wait { session.document?.text == original }
            await session.flushChanges()
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
            try await wait {
                try await bridge.webView.evaluateJavaScript("typeof window.delayedUndoResult === 'function'")
                    as? Bool == true
            }
            let redone = bridge.moveSourceHistory(forward: true)
            XCTAssertEqual(redone, true)
            try await wait { session.document?.text == applied }
            _ = try await bridge.webView.evaluateJavaScript("window.delayedUndoResult();")
            let undoVisible =
                try await bridge.webView.evaluateJavaScript(
                    "!document.querySelector('[data-agent-action=undo]').hidden") as? Bool
            XCTAssertEqual(undoVisible, true)
            _ = bridge.moveSourceHistory(forward: false)
            _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: original + "手动追加。\n")
            let unavailable =
                bridge.moveSourceHistory(forward: true)
            XCTAssertEqual(unavailable, false)
            try await send("只解释原文，不要修改。", bridge: bridge)
            try await completed(bridge, count: 4)
            XCTAssertEqual(session.document?.text, original + "手动追加。\n")
            let body = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
            let history = try XCTUnwrap(body[api == .responses ? "input" : "messages"] as? [[String: Any]])
            let previousReply = try ModelWireFormat.object(
                Data(try XCTUnwrap(history.first { $0["role"] as? String == "assistant" }?["content"] as? String).utf8))
            XCTAssertEqual((previousReply["sourceChanges"] as? [[String: String]])?.first?["status"], "undone")
        }
    }

    func testDelayedUndoProjectionCannotOverwriteANewerNativeRedo() async throws {
        let original = "# Document\n\nOriginal paragraph.\n"
        let applied = original.replacingOccurrences(of: "Original", with: "Revised")
        let (session, bridge, _, url) = try await reader(original)
        try await sourceMode(bridge)
        let execution = await session.agentDocuments.execute(
            try editCall(original, before: "Original", after: "Revised"), token: session.documentToken)
        let change = try XCTUnwrap(execution.change)
        XCTAssertEqual(change.saved, true)
        _ = try await bridge.webView.evaluateJavaScript(
            """
            (() => {
              const deliver = window.JustMarkdown.sourceState.bind(window.JustMarkdown);
              window.JustMarkdown.sourceState = payload => {
                if (!payload.events.some(event => event.status === 'undone')) return deliver(payload);
                return new Promise(resolve => {
                  window.releaseUndoProjection = () => {
                    delete window.releaseUndoProjection;
                    window.JustMarkdown.sourceState = deliver;
                    resolve(deliver(payload));
                  };
                });
              };
            })();
            """)
        let token = session.documentToken
        var undoFinished = false
        let undo = Task {
            let result = await session.agentDocuments.undo(change.id, token: token)
            undoFinished = true
            return result
        }
        try await wait {
            let held =
                try await bridge.webView.evaluateJavaScript("typeof window.releaseUndoProjection === 'function'")
                as? Bool == true
            return session.document?.text == original && held
        }
        bridge.sourceEditor.history.undoManager.redo()
        XCTAssertEqual(session.document?.text, applied)
        try await wait { undoFinished }
        XCTAssertEqual(session.document?.text, applied)
        _ = try await bridge.webView.evaluateJavaScript("window.releaseUndoProjection();")
        let result = await undo.value
        XCTAssertEqual(result["status"], "undone")
        XCTAssertEqual(session.document?.text, applied, "A delayed renderer response cannot write an old snapshot")
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), applied)
        _ = try await bridge.call("toggleAgent")
        let source = try await bridge.webView.evaluateJavaScript("window.JustMarkdown.diagnostics().source") as? String
        XCTAssertEqual(source, applied, "The renderer eventually receives the latest native revision")
    }

    func testSourceToolRejectsStaleAmbiguousAndOverlappingChangesAtomically() async throws {
        let original = "# 文档\n\n重复。重复。\n\n唯一原文。\n"
        let (session, bridge, _, url) = try await reader(original)
        try await sourceMode(bridge)
        let token = session.documentToken
        let ambiguous = try editCall(original, before: "重复。", after: "错误")
        let rejected = await session.agentDocuments.execute(ambiguous, token: token)
        XCTAssertTrue(rejected.output.contains("invalid_edit"))
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": AgentDocumentTools.revision(original),
            "edits": [["before": "唯一原文。", "after": "x"], ["before": "原文。", "after": "y"]],
        ])
        let overlap = await session.agentDocuments.execute(
            .init(id: "overlap", name: "edit_document", arguments: String(decoding: data, as: UTF8.self)), token: token)
        XCTAssertTrue(overlap.output.contains("invalid_edit"))
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: original + "手动编辑。")
        let stale = await session.agentDocuments.execute(
            try editCall(original, before: "唯一原文。", after: "新内容。"), token: token)
        XCTAssertTrue(stale.output.contains("stale_document"))
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original + "手动编辑。")
        _ = try await bridge.call("toggleMode")
        try await wait { (try await bridge.call("diagnostics") as? [String: Any])?["mode"] as? String == "preview" }
        let readOnly = await session.agentDocuments.execute(ambiguous, token: token)
        XCTAssertTrue(readOnly.output.contains("read_only"))
        XCTAssertEqual(session.document?.text, original + "手动编辑。")
    }

    func testRetryAfterAppliedToolDoesNotExecuteTheEditTwice() async throws {
        let original = "# 文档\n\n原文。\n"
        let call = try editCall(original, before: "原文。", after: "新文。")
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [call]), AgentFixture(status: 503), AgentFixture(text: "修改已保存。"),
        ])
        let (session, bridge, _, _) = try await reader(original, api: .responses)
        try await sourceMode(bridge)
        _ = try await bridge.call("toggleAgent")
        try await send("把原文改为新文。", bridge: bridge)
        try await wait {
            (try await self.state(bridge)["turns"] as? [[String: Any]])?.last?["state"] as? String == "failed"
        }
        XCTAssertEqual(session.document?.text, "# 文档\n\n新文。\n")
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('[data-agent-action=retry]').click();")
        try await completed(bridge)
        let requests = AgentFixtureProtocol.queue.requests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1], requests[2])
        let cards =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('[data-component=DocumentChange]').length") as? Int
        XCTAssertEqual(cards, 1)
        _ = bridge.moveSourceHistory(forward: false)
        try await wait { session.document?.text == original }
        XCTAssertFalse(session.canUndoSource)
    }

    func testStoppingAfterAToolEditKeepsTheChangeVisibleAndUndoable() async throws {
        let original = "# 文档\n\n原文。\n"
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [try editCall(original, before: "原文。", after: "新文。")]),
            AgentFixture(text: "这条延迟的说明不应出现在停止后的回答中。", delay: 3),
        ])
        let (session, bridge, _, url) = try await reader(original, api: .responses)
        try await sourceMode(bridge)
        _ = try await bridge.call("toggleAgent")
        try await send("把原文改为新文。", bridge: bridge)
        try await wait { session.document?.text == "# 文档\n\n新文。\n" }
        _ = try await bridge.webView.evaluateJavaScript("document.querySelector('.mdv-agent-send').click();")
        try await wait { session.agentTransport.activeID == nil }
        try await wait {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('[data-component=DocumentChange]').length") as? Int == 1
        }
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# 文档\n\n新文。\n")
        let turns = try await state(bridge)["turns"] as? [[String: Any]]
        XCTAssertEqual(turns?.last?["state"] as? String, "stopped")
        _ = bridge.moveSourceHistory(forward: false)
        try await wait { session.document?.text == original }
        _ = bridge.moveSourceHistory(forward: true)
        try await wait { session.document?.text == "# 文档\n\n新文。\n" }
    }

    func testRepeatedToolsPauseRemainingCallsInTheSameModelTurn() async throws {
        let doc = AgentAttachment(
            text: "Document", markdown: "Document", mode: "source", scope: "document", location: nil, start: nil,
            end: nil)
        let snapshot = AgentSnapshot(
            question: "Read and edit the document", attachment: doc,
            history: [.init(role: "user", markdown: "Read and edit the document", attachment: doc, document: doc)],
            document: doc)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        let transport = AgentModelTransport(client: ModelClient(session: URLSession(configuration: configuration)))
        AgentFixtureProtocol.queue.reset([
            AgentFixture(calls: [
                ModelToolCall(id: "first", name: "read_document", arguments: "{}"),
                ModelToolCall(id: "repeated", name: "read_document", arguments: "{}"),
                ModelToolCall(id: "remaining", name: "edit_document", arguments: "{}"),
            ]), AgentFixture(text: "Stopped tools"),
        ])
        var executed: [String] = []
        var finished = false
        transport.start(
            id: UUID().uuidString, token: "document", snapshot: snapshot, intent: "question",
            configuration: .init(
                baseURL: "https://agent.example.test/v1", model: "fixture", apiProtocol: .chatCompletions),
            key: "fixture-key",
            toolsAvailable: { true },
            executeTool: { call, _ in
                executed.append(call.name)
                return AgentToolExecution(output: "unchanged", revision: "same")
            },
            emit: { event in
                if event.type == "failure" { XCTFail("Unexpected transport failure") }
                if event.type == "complete" { finished = true }
            })
        try await wait { finished }
        XCTAssertEqual(executed, ["read_document", "read_document"])
        let last = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
        XCTAssertEqual((last["tools"] as? [[String: Any]])?.count, 0)
        let messages = try XCTUnwrap(last["messages"] as? [[String: Any]])
        let outputs = messages.filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(outputs.count, 3, "Every declared call still needs a result in the following model request")
        XCTAssertTrue((outputs.last?["content"] as? String)?.contains("repeated_without_progress") == true)
    }

    func testToolLoopGuardUsesRepeatedResultsRatherThanFixedRoundCount() async throws {
        let doc = AgentAttachment(
            text: "正文", markdown: "正文", mode: "source", scope: "document", location: nil, start: nil, end: nil)
        let snapshot = AgentSnapshot(
            question: "读取文档", attachment: doc,
            history: [.init(role: "user", markdown: "读取文档", attachment: doc, document: doc)], document: doc)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentFixtureProtocol.self]
        let transport = AgentModelTransport(client: ModelClient(session: URLSession(configuration: configuration)))
        let call = ModelToolCall(id: "read", name: "read_document", arguments: "{}")
        for progress in [true, false] {
            let rounds = progress ? 11 : 2
            AgentFixtureProtocol.queue.reset(
                Array(repeating: AgentFixture(calls: [call]), count: rounds) + [AgentFixture(text: "完成")])
            var count = 0
            var finished = false
            transport.reset()
            transport.start(
                id: UUID().uuidString, token: "document", snapshot: snapshot, intent: "question",
                configuration: .init(baseURL: "https://agent.example.test/v1", model: "fixture"), key: "fixture-key",
                toolsAvailable: { true },
                executeTool: { _, _ in
                    count += 1
                    let revision = progress ? String(count) : "unchanged"
                    return AgentToolExecution(output: "{\"revision\":\"" + revision + "\"}", revision: revision)
                },
                emit: { event in
                    if event.type == "failure" { XCTFail("Unexpected transport failure") }
                    if event.type == "complete" { finished = true }
                })
            try await wait { finished }
            XCTAssertEqual(count, rounds)
            let last = try ModelWireFormat.object(XCTUnwrap(AgentFixtureProtocol.queue.requests().last))
            XCTAssertEqual((last["tools"] as? [[String: Any]])?.count, progress ? 2 : 0)
        }
    }
}
