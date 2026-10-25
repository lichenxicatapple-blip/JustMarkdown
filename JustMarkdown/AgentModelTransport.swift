import Foundation

struct AgentAttachment: Codable, Sendable, Equatable {
    let text: String
    let markdown: String
    let mode: String
    let scope: String?
    let location: String?
    let start: Int?
    let end: Int?
    var documentName: String? = nil
    var documentMarkdown: String? = nil
}

struct AgentSourceChange: Codable, Sendable, Equatable {
    let before: String
    let after: String
    let status: String
}

struct AgentHistoryTurn: Codable, Sendable, Equatable {
    let role: String
    let markdown: String
    let attachment: AgentAttachment?
    var status: String? = nil
    var change: AgentSourceChange? = nil
    var intent: String? = nil
    var document: AgentAttachment? = nil
    var changes: [AgentSourceChange]? = nil
}

struct AgentSnapshot: Codable, Sendable, Equatable {
    let question: String
    let attachment: AgentAttachment?
    let history: [AgentHistoryTurn]

    var document: AgentAttachment? = nil
    var id: String? = nil

    func messages(intent: String) throws -> [ChatMessage] {
        try AgentContextBuilder.build(self, intent: intent)
    }

}

struct AgentFailure: Codable, Sendable, Equatable {
    let kind: String
    let retryAfterSeconds: TimeInterval?

    init(_ error: any Error) {
        retryAfterSeconds = if case ModelError.rateLimited(let seconds) = error { seconds } else { nil }
        kind =
            switch error {
            case ModelError.configuration: "configuration"
            case ModelError.missingKey: "authentication"
            case ModelError.sharingPermission: "permission"
            case ModelError.rateLimited: "rateLimit"
            case ModelError.service(let status, _) where [401, 403].contains(status): "authentication"
            case ModelError.service(let status, _) where [400, 404, 422].contains(status): "configuration"
            case ModelError.invalidResponse: "response"
            case ModelError.interrupted: "network"
            case ModelError.incomplete: "incomplete"
            case ModelError.contextLimit: "contextLimit"
            case ModelError.requestTooLarge: "requestTooLarge"
            case is ModelError: "service"
            case let value as URLError where value.code == .timedOut: "timeout"
            case is URLError: "network"
            default: "service"
            }
    }
}

struct AgentModelEvent: Encodable, Sendable {
    let id: String
    let token: String
    let type: String
    var text: String?
    var failure: AgentFailure?
    var change: AgentDocumentChange?
}

/// One model request at a time. The UI supplies immutable turn snapshots, never credentials.
@MainActor
final class AgentModelTransport {
    private static let pausedToolOutput =
        "{\"error\":\"repeated_without_progress\",\"message\":\"相同调用得到相同结果且文档没有变化。已停止继续调用工具，请如实说明结果。\"}"
    private let client: ModelClient
    private var task: Task<Void, Never>?
    private(set) var activeID: String?
    private final class Run {
        let key: String
        var exchanges: [ModelToolExchange] = []
        var pending: Pending?
        var seenToolResults = Set<String>()
        var toolsPaused = false
        init(key: String) { self.key = key }
    }
    private final class Pending {
        let turn: ModelTurn
        var outputs: [ModelToolOutput] = []
        init(turn: ModelTurn) { self.turn = turn }
    }
    private var run: Run?

    init(client: ModelClient = ModelClient()) { self.client = client }
    deinit { task?.cancel() }

    func cancel(id: String? = nil) {
        guard id == nil || id == activeID else { return }
        activeID = nil
        task?.cancel()
        task = nil
    }

    func reset() {
        cancel()
        run = nil
    }

    func start(
        id: String, token: String, snapshot: AgentSnapshot, intent: String,
        configuration: ModelConfiguration, key: String,
        toolsAvailable: @escaping @MainActor () -> Bool = { false },
        executeTool:
            @escaping @MainActor (
                ModelToolCall, @escaping @MainActor (AgentDocumentChange) async -> Void
            ) async -> AgentToolExecution = { _, _ in AgentToolExecution(output: "{\"error\":\"read_only\"}") },
        emit: @escaping @MainActor (AgentModelEvent) async -> Void
    ) {
        guard activeID == nil else { return }
        activeID = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let requestKey =
            token + ":"
            + (snapshot.id
                ?? AgentDocumentTools.revision(
                    String(decoding: (try? encoder.encode(snapshot)) ?? Data(), as: UTF8.self)))
        let currentRun = run?.key == requestKey ? run! : Run(key: requestKey)
        run = currentRun
        task = Task { [weak self, client] in
            do {
                let messages = try snapshot.messages(intent: intent)
                while true {
                    try Task.checkCancellation()
                    if let pending = currentRun.pending {
                        while pending.outputs.count < pending.turn.calls.count {
                            try Task.checkCancellation()
                            let call = pending.turn.calls[pending.outputs.count]
                            let execution: AgentToolExecution
                            if currentRun.toolsPaused {
                                execution = AgentToolExecution(output: Self.pausedToolOutput)
                            } else if snapshot.document?.mode == "source" && toolsAvailable() {
                                execution = await executeTool(call) { change in
                                    await emit(AgentModelEvent(id: id, token: token, type: "change", change: change))
                                }
                            } else {
                                execution = AgentToolExecution(
                                    output: "{\"error\":\"read_only\",\"message\":\"请切换到源码后修改。\"}")
                            }
                            // Journal successful effects before observing cancellation. A retry
                            // resumes after these results instead of executing the same edit twice.
                            let arguments =
                                (try? JSONSerialization.data(
                                    withJSONObject: ModelWireFormat.object(Data(call.arguments.utf8)),
                                    options: .sortedKeys)) ?? Data(call.arguments.utf8)
                            let signature = AgentDocumentTools.revision(
                                call.name + String(decoding: arguments, as: UTF8.self) + execution.output
                                    + (execution.revision ?? ""))
                            let repeated = !currentRun.seenToolResults.insert(signature).inserted
                            if repeated { currentRun.toolsPaused = true }
                            pending.outputs.append(
                                ModelToolOutput(
                                    id: call.id,
                                    content: repeated ? Self.pausedToolOutput : execution.output))
                            if let change = execution.change {
                                await emit(AgentModelEvent(id: id, token: token, type: "change", change: change))
                            }
                        }
                        currentRun.exchanges.append(ModelToolExchange(turn: pending.turn, outputs: pending.outputs))
                        currentRun.pending = nil
                    }
                    try Task.checkCancellation()
                    let tools =
                        snapshot.document?.mode == "source" && toolsAvailable() && !currentRun.toolsPaused
                        ? AgentDocumentTools.definitions : []
                    let turn = try await client.stream(
                        configuration: configuration, key: key, messages: messages,
                        tools: tools, exchanges: currentRun.exchanges
                    ) { [weak self] chunk in
                        guard await self?.activeID == id else { return }
                        await emit(AgentModelEvent(id: id, token: token, type: "text", text: chunk))
                    }
                    try Task.checkCancellation()
                    guard !tools.isEmpty || turn.calls.isEmpty else { throw ModelError.invalidResponse }
                    if turn.calls.isEmpty {
                        await emit(AgentModelEvent(id: id, token: token, type: "complete"))
                        break
                    }
                    currentRun.pending = Pending(turn: turn)
                }
            } catch {
                if self?.activeID == id && !Task.isCancelled {
                    await emit(AgentModelEvent(id: id, token: token, type: "failure", failure: AgentFailure(error)))
                }
            }
            if Task.isCancelled { await emit(AgentModelEvent(id: id, token: token, type: "cancelled")) }
            guard let self, self.activeID == id else { return }
            self.activeID = nil
            self.task = nil
        }
    }
}
