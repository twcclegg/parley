import Foundation

/// One entry in the conversation as Parley shows it.
public struct TranscriptItem: Identifiable, Sendable, Equatable {
    public let id: String
    public var kind: Kind

    public enum Kind: Sendable, Equatable {
        /// What you sent.
        case user(String)
        /// Claude's reply, as Markdown. Grows while it streams.
        case assistant(String)
        /// Claude's visible reasoning, when the model shares it.
        case thinking(String)
        /// A tool Claude ran, with its result once it arrives.
        case tool(ToolCall)
        /// Claude Code asking whether it may run a tool.
        case permission(PermissionRequest)
        /// Claude asking you to choose between options (the AskUserQuestion tool).
        case question(QuestionRequest)
        /// A line from Parley or Claude Code about the session itself.
        case notice(String, isError: Bool)
    }
}

public struct ToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: JSON
    public var result: String?
    public var isError: Bool

    /// One line saying what the call does, such as the command or the file.
    public var summary: String { Self.summary(name: name, input: input) }

    public static func summary(name: String, input: JSON) -> String {
        func path(_ key: String) -> String? {
            guard let value = input[key]?.string else { return nil }
            let parts = value.split(separator: "/")
            return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : value
        }
        switch name {
        case "Bash", "BashOutput":
            return input["command"]?.string ?? input["description"]?.string ?? ""
        case "Read", "Write", "Edit", "MultiEdit":
            return path("file_path") ?? ""
        case "NotebookEdit":
            return path("notebook_path") ?? ""
        case "Grep", "Glob":
            return input["pattern"]?.string ?? ""
        case "WebFetch":
            return input["url"]?.string ?? ""
        case "WebSearch":
            return input["query"]?.string ?? ""
        case "Task", "Agent":
            return input["description"]?.string ?? ""
        case "TodoWrite":
            return input["todos"]?.array.map { "\($0.count) items" } ?? ""
        default:
            for (_, value) in (input.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                if let text = value.string { return text }
            }
            return ""
        }
    }
}

public struct PermissionRequest: Sendable, Equatable {
    public let requestId: String
    public let toolName: String
    public let displayName: String
    public let description: String?
    public let input: JSON
    /// Permission updates Claude Code offers for "always allow", such as a rule for this command.
    public let suggestedRules: [JSON]
    public var state: State

    public enum State: Sendable, Equatable {
        case pending
        case allowed
        case allowedAlways
        case denied
        case cancelled
    }

    public var summary: String { ToolCall.summary(name: toolName, input: input) }
}

public struct QuestionRequest: Sendable, Equatable {
    public let requestId: String
    public let input: JSON
    public let questions: [Question]
    public var state: State

    public struct Question: Sendable, Equatable, Identifiable {
        public var id: String { question }
        public let question: String
        public let header: String?
        public let options: [Option]
        public let multiSelect: Bool
    }

    public struct Option: Sendable, Equatable, Identifiable {
        public var id: String { label }
        public let label: String
        public let description: String?
    }

    public enum State: Sendable, Equatable {
        case pending
        case answered([String: String])
        case declined
        case cancelled
    }
}

public struct SlashCommand: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let argumentHint: String?
}

/// Something the transcript asks its owner to do after reading a message.
public enum TranscriptEffect: Sendable, Equatable {
    /// Claude Code started or resumed a session with this id.
    case sessionStarted(String)
    /// Claude Code sent a control request Parley doesn't handle; answer it with an error.
    case unsupportedControlRequest(String)
}

/// The conversation, built from Claude Code's stream-json output.
public struct Transcript: Sendable, Equatable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var sessionId: String?
    public private(set) var model: String?
    public private(set) var permissionMode: String?
    /// True from the moment a message is sent until Claude Code reports the turn's result.
    public private(set) var isBusy = false
    public private(set) var slashCommands: [SlashCommand] = []
    /// Bumped on every change, for views that follow the end of the conversation.
    public private(set) var revision = 0

    private var positions: [String: Int] = [:]
    private var streamingMessageId: String?
    /// Stream event block index → transcript item id, for the message being streamed.
    private var streamingBlocks: [Int: String] = [:]
    /// How many text and thinking blocks each message has had, from stream events and from
    /// complete messages separately, so both name the same block the same way.
    private var streamedCounts: [String: Int] = [:]
    private var completeCounts: [String: Int] = [:]
    private var localCounter = 0

    public init() {}

    /// Adds what you sent and marks the turn busy.
    public mutating func beginUserTurn(_ text: String) {
        append(TranscriptItem(id: nextLocalId(), kind: .user(text)))
        isBusy = true
    }

    /// Adds a line about the session, such as a connection error.
    public mutating func notice(_ text: String, isError: Bool = false) {
        append(TranscriptItem(id: nextLocalId(), kind: .notice(text, isError: isError)))
    }

    /// The connection ended: nothing is running any more, and nothing pending can be answered.
    public mutating func connectionEnded() {
        isBusy = false
        for index in items.indices {
            switch items[index].kind {
            case .permission(var request) where request.state == .pending:
                request.state = .cancelled
                items[index].kind = .permission(request)
            case .question(var request) where request.state == .pending:
                request.state = .cancelled
                items[index].kind = .question(request)
            default:
                break
            }
        }
        revision += 1
    }

    public mutating func resolvePermission(requestId: String, state: PermissionRequest.State) {
        guard let index = positions[requestId], case .permission(var request) = items[index].kind else { return }
        request.state = state
        items[index].kind = .permission(request)
        revision += 1
    }

    public mutating func resolveQuestion(requestId: String, state: QuestionRequest.State) {
        guard let index = positions[requestId], case .question(var request) = items[index].kind else { return }
        request.state = state
        items[index].kind = .question(request)
        revision += 1
    }

    public mutating func setPermissionMode(_ mode: String) {
        permissionMode = mode
        revision += 1
    }

    /// Reads one stream-json message from Claude Code.
    @discardableResult
    public mutating func apply(_ message: JSON) -> [TranscriptEffect] {
        defer { revision += 1 }
        switch message["type"]?.string {
        case "system":
            return applySystem(message)
        case "stream_event":
            if isTopLevel(message), let event = message["event"] { applyStreamEvent(event) }
        case "assistant":
            if isTopLevel(message), let body = message["message"] { applyAssistant(body) }
        case "user":
            if isTopLevel(message), let body = message["message"] { applyToolResults(body) }
        case "result":
            applyResult(message)
        case "control_request":
            return applyControlRequest(message)
        case "control_response":
            applyControlResponse(message)
        case "control_cancel_request":
            if let requestId = message["request_id"]?.string { cancel(requestId: requestId) }
        case "rate_limit_event":
            if let status = message["rate_limit_info"]?["status"]?.string, status != "allowed", status != "allowed_warning" {
                notice("Usage limit reached. Claude Code will continue when it resets.", isError: true)
            }
        default:
            break
        }
        return []
    }

    // MARK: - Messages

    private func isTopLevel(_ message: JSON) -> Bool {
        message["parent_tool_use_id"]?.string == nil
    }

    private mutating func applySystem(_ message: JSON) -> [TranscriptEffect] {
        switch message["subtype"]?.string {
        case "init":
            model = message["model"]?.string
            permissionMode = message["permissionMode"]?.string ?? permissionMode
            if let id = message["session_id"]?.string {
                sessionId = id
                return [.sessionStarted(id)]
            }
        case "compact_boundary":
            notice("Earlier messages were summarized to make room.")
        default:
            break
        }
        return []
    }

    private mutating func applyStreamEvent(_ event: JSON) {
        switch event["type"]?.string {
        case "message_start":
            streamingMessageId = event["message"]?["id"]?.string
            streamingBlocks = [:]
        case "content_block_start":
            guard let messageId = streamingMessageId,
                let index = event["index"]?.number.map(Int.init),
                let block = event["content_block"]
            else { return }
            switch block["type"]?.string {
            case "text":
                let id = blockId(messageId: messageId, kind: "text", counts: &streamedCounts)
                streamingBlocks[index] = id
                upsert(id: id, kind: .assistant(block["text"]?.string ?? ""))
            case "thinking":
                let id = blockId(messageId: messageId, kind: "thinking", counts: &streamedCounts)
                streamingBlocks[index] = id
                upsert(id: id, kind: .thinking(block["thinking"]?.string ?? ""))
            default:
                break
            }
        case "content_block_delta":
            guard let index = event["index"]?.number.map(Int.init),
                let id = streamingBlocks[index],
                let position = positions[id],
                let delta = event["delta"]
            else { return }
            switch (items[position].kind, delta["type"]?.string) {
            case (.assistant(let text), "text_delta"):
                items[position].kind = .assistant(text + (delta["text"]?.string ?? ""))
            case (.thinking(let text), "thinking_delta"):
                items[position].kind = .thinking(text + (delta["thinking"]?.string ?? ""))
            default:
                break
            }
        default:
            break
        }
    }

    private mutating func applyAssistant(_ body: JSON) {
        let messageId = body["id"]?.string ?? nextLocalId()
        for block in body["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                let id = blockId(messageId: messageId, kind: "text", counts: &completeCounts)
                upsert(id: id, kind: .assistant(block["text"]?.string ?? ""))
            case "thinking":
                let id = blockId(messageId: messageId, kind: "thinking", counts: &completeCounts)
                // A redacted thought arrives empty; it mustn't wipe out what streamed.
                if let text = block["thinking"]?.string, !text.isEmpty {
                    upsert(id: id, kind: .thinking(text))
                }
            case "tool_use":
                guard let id = block["id"]?.string else { continue }
                if positions[id] == nil {
                    let call = ToolCall(
                        id: id,
                        name: block["name"]?.string ?? "Tool",
                        input: block["input"] ?? .object([:]),
                        result: nil,
                        isError: false
                    )
                    append(TranscriptItem(id: id, kind: .tool(call)))
                }
            default:
                break
            }
        }
    }

    private mutating func applyToolResults(_ body: JSON) {
        for block in body["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
            guard let id = block["tool_use_id"]?.string,
                let position = positions[id],
                case .tool(var call) = items[position].kind
            else { continue }
            call.result = Self.text(of: block["content"])
            call.isError = block["is_error"]?.bool ?? false
            items[position].kind = .tool(call)
        }
    }

    private mutating func applyResult(_ message: JSON) {
        isBusy = false
        let isError = message["is_error"]?.bool ?? false
        let subtype = message["subtype"]?.string ?? "success"
        if isError || subtype != "success" {
            let detail = message["result"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            switch subtype {
            case "error_max_turns":
                notice("Claude stopped after reaching the turn limit.", isError: true)
            case "error_during_execution":
                notice(detail ?? "The turn ended with an error.", isError: true)
            default:
                notice(detail ?? "The turn ended with an error (\(subtype)).", isError: true)
            }
        }
    }

    private mutating func applyControlRequest(_ message: JSON) -> [TranscriptEffect] {
        guard let requestId = message["request_id"]?.string, let request = message["request"] else { return [] }
        guard request["subtype"]?.string == "can_use_tool" else {
            return [.unsupportedControlRequest(requestId)]
        }
        let toolName = request["tool_name"]?.string ?? "Tool"
        let input = request["input"] ?? .object([:])
        if toolName == "AskUserQuestion" {
            let questions = (input["questions"]?.array ?? []).compactMap { question -> QuestionRequest.Question? in
                guard let text = question["question"]?.string else { return nil }
                return QuestionRequest.Question(
                    question: text,
                    header: question["header"]?.string,
                    options: (question["options"]?.array ?? []).compactMap { option in
                        guard let label = option["label"]?.string else { return nil }
                        return QuestionRequest.Option(label: label, description: option["description"]?.string)
                    },
                    multiSelect: question["multiSelect"]?.bool ?? false
                )
            }
            let item = QuestionRequest(requestId: requestId, input: input, questions: questions, state: .pending)
            append(TranscriptItem(id: requestId, kind: .question(item)))
        } else {
            let suggestions = (request["permission_suggestions"]?.array ?? []).filter {
                $0["type"]?.string == "addRules"
            }
            let item = PermissionRequest(
                requestId: requestId,
                toolName: toolName,
                displayName: request["display_name"]?.string ?? toolName,
                description: request["description"]?.string,
                input: input,
                suggestedRules: suggestions,
                state: .pending
            )
            append(TranscriptItem(id: requestId, kind: .permission(item)))
        }
        return []
    }

    private mutating func applyControlResponse(_ message: JSON) {
        guard let response = message["response"], response["subtype"]?.string == "success" else { return }
        if let commands = response["response"]?["commands"]?.array {
            slashCommands = commands.compactMap { command in
                guard let name = command["name"]?.string else { return nil }
                return SlashCommand(
                    name: name,
                    description: command["description"]?.string ?? "",
                    argumentHint: command["argumentHint"]?.string
                )
            }
        }
    }

    private mutating func cancel(requestId: String) {
        guard let position = positions[requestId] else { return }
        switch items[position].kind {
        case .permission(var request) where request.state == .pending:
            request.state = .cancelled
            items[position].kind = .permission(request)
        case .question(var request) where request.state == .pending:
            request.state = .cancelled
            items[position].kind = .question(request)
        default:
            break
        }
    }

    // MARK: - Helpers

    private func blockId(messageId: String, kind: String, counts: inout [String: Int]) -> String {
        let key = messageId + "-" + kind
        let ordinal = counts[key, default: 0]
        counts[key] = ordinal + 1
        return "\(key)-\(ordinal)"
    }

    private mutating func upsert(id: String, kind: TranscriptItem.Kind) {
        if let position = positions[id] {
            items[position].kind = kind
        } else {
            append(TranscriptItem(id: id, kind: kind))
        }
    }

    private mutating func append(_ item: TranscriptItem) {
        positions[item.id] = items.count
        items.append(item)
        revision += 1
    }

    private mutating func nextLocalId() -> String {
        localCounter += 1
        return "local-\(localCounter)"
    }

    /// A tool result's text: a string, or the text blocks of a content array.
    static func text(of content: JSON?) -> String {
        switch content {
        case .string(let text):
            return text
        case .array(let blocks):
            return blocks.compactMap { block in
                if block["type"]?.string == "text" { return block["text"]?.string }
                if block["type"]?.string == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        default:
            return ""
        }
    }
}
