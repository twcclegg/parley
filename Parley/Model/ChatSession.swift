import Foundation
import Observation
import ParleyCore
import ParleySSH

/// A conversation with Claude Code on one server: the SSH connection, the `claude` process on
/// the other end, and the transcript built from what it says.
@MainActor @Observable
final class ChatSession {
    enum Phase: Equatable {
        /// Not started; the chat view offers to start or continue.
        case idle
        case connecting
        case connected
        /// The connection or the process ended. The transcript stays; reconnecting continues.
        case ended(String?)
    }

    private(set) var host: Host
    private(set) var phase: Phase = .idle
    private(set) var transcript = Transcript()
    var draft = ""

    private let store: HostStore
    private let keys: DeviceKeyStore
    private let prompter: HostKeyPrompter
    private var connection: SSHConnection?
    private var process: SSHExecChannel?
    private var requestCounter = 0
    private var lineBuffer = Data()
    private var stderrTail = ""
    /// Set while connecting or connected, to tell an intended stop from a dropped connection.
    private var generation = 0

    init(host: Host, store: HostStore, keys: DeviceKeyStore, prompter: HostKeyPrompter) {
        self.host = host
        self.store = store
        self.keys = keys
        self.prompter = prompter
    }

    var canSend: Bool {
        phase == .connected && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasPendingQuestion: Bool {
        transcript.items.contains { item in
            switch item.kind {
            case .permission(let request): request.state == .pending
            case .question(let request): request.state == .pending
            default: false
            }
        }
    }

    // MARK: - Connecting

    /// Starts Claude Code on the server: a new conversation, or the last one continued.
    func start(continuing: Bool) async {
        if let current = store.host(host.id) { host = current }
        await stop(reason: nil)
        generation += 1
        let generation = self.generation
        phase = .connecting
        lineBuffer = Data()
        stderrTail = ""

        do {
            let key = try keys.deviceKey()
            let host = self.host
            let prompter = self.prompter
            let connection = try await SSHConnection.connect(
                host: host.hostname,
                port: host.port,
                username: host.username,
                authentication: [.privateKey(key.privateKey)],
                validateHostKey: { line in await prompter.validate(line, for: host) }
            )
            guard generation == self.generation else {
                await connection.close()
                return
            }
            let command = ClaudeCommand(
                directory: host.directory,
                executable: host.claudePath,
                resumeSessionId: continuing ? (transcript.sessionId ?? host.lastSessionId) : nil,
                permissionMode: host.permissionMode
            )
            let process = try await connection.exec(command.shellCommand)
            self.connection = connection
            self.process = process
            phase = .connected
            if continuing, transcript.items.isEmpty {
                transcript.notice("Continuing your last conversation. Earlier messages aren't shown here.")
            }
            Task { await self.readOutput(process, generation: generation) }
            Task { await self.readErrors(process) }
            try await send(Outgoing.initialize(requestId: nextRequestId(prefix: "init")))
        } catch {
            guard generation == self.generation else { return }
            let reason = prompter.mismatch(for: host) ?? Self.describe(error)
            phase = .ended(reason)
            transcript.notice(reason, isError: true)
        }
    }

    /// Stops the process and closes the connection.
    func disconnect() async {
        await stop(reason: nil)
        phase = .ended(nil)
    }

    /// After the app comes back from the background: reconnect if the connection was lost
    /// while a conversation was open.
    func resumeIfDropped() async {
        if case .ended(let reason) = phase, reason != nil, transcript.sessionId != nil {
            await start(continuing: true)
        }
    }

    private func stop(reason: String?) async {
        generation += 1
        let process = self.process, connection = self.connection
        self.process = nil
        self.connection = nil
        await process?.closeInput()
        await process?.close()
        await connection?.close()
        transcript.connectionEnded()
    }

    // MARK: - Talking

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase == .connected else { return }
        draft = ""
        transcript.beginUserTurn(text)
        do {
            try await send(Outgoing.user(text))
        } catch {
            draft = text
            transcript.notice("Couldn't send: \(Self.describe(error))", isError: true)
        }
    }

    func interrupt() async {
        try? await send(Outgoing.interrupt(requestId: nextRequestId(prefix: "interrupt")))
    }

    func allow(_ request: PermissionRequest, always: Bool) async {
        let rules = always ? request.suggestedRules : []
        try? await send(Outgoing.allow(requestId: request.requestId, input: request.input, rules: rules))
        transcript.resolvePermission(requestId: request.requestId, state: always ? .allowedAlways : .allowed)
    }

    func deny(_ request: PermissionRequest) async {
        try? await send(Outgoing.deny(requestId: request.requestId, message: "The user declined this from Parley."))
        transcript.resolvePermission(requestId: request.requestId, state: .denied)
    }

    func answer(_ request: QuestionRequest, with answers: [String: String]) async {
        var input = request.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0) })
        try? await send(Outgoing.allow(requestId: request.requestId, input: .object(input)))
        transcript.resolveQuestion(requestId: request.requestId, state: .answered(answers))
    }

    func decline(_ request: QuestionRequest) async {
        try? await send(Outgoing.deny(requestId: request.requestId, message: "The user chose not to answer."))
        transcript.resolveQuestion(requestId: request.requestId, state: .declined)
    }

    func setPermissionMode(_ mode: PermissionMode) async {
        store.update(host.id) { $0.permissionMode = mode.rawValue }
        host.permissionMode = mode.rawValue
        guard phase == .connected else { return }
        try? await send(Outgoing.setPermissionMode(requestId: nextRequestId(prefix: "mode"), mode: mode.rawValue))
        transcript.setPermissionMode(mode.rawValue)
    }

    private func send(_ message: JSON) async throws {
        guard let process else { throw SSHError.connectionClosed }
        try await process.write(try message.line())
    }

    private func nextRequestId(prefix: String) -> String {
        requestCounter += 1
        return "\(prefix)-\(requestCounter)"
    }

    // MARK: - Reading

    private func readOutput(_ process: SSHExecChannel, generation: Int) async {
        for await chunk in process.stdout {
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                let line = Data(lineBuffer[lineBuffer.startIndex..<newline])
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                if let message = JSON.parseLine(line) { await handle(message) }
            }
        }
        let status = await process.exitStatus
        guard generation == self.generation else { return }
        self.process = nil
        await connection?.close()
        connection = nil
        transcript.connectionEnded()
        let reason = endReason(status: status)
        transcript.notice(reason ?? "Claude Code ended the session.", isError: reason != nil)
        phase = .ended(reason)
    }

    private func readErrors(_ process: SSHExecChannel) async {
        for await chunk in process.stderr {
            stderrTail = String((stderrTail + String(decoding: chunk, as: UTF8.self)).suffix(2000))
        }
    }

    private func handle(_ message: JSON) async {
        for effect in transcript.apply(message) {
            switch effect {
            case .sessionStarted(let id):
                store.update(host.id) { $0.lastSessionId = id }
                host.lastSessionId = id
            case .unsupportedControlRequest(let requestId):
                try? await send(Outgoing.controlError(requestId: requestId, message: "Parley doesn't support this request."))
            }
        }
    }

    private func endReason(status: Int?) -> String? {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 127 || detail.contains("command not found") || detail.contains("not found") && transcript.sessionId == nil {
            return "Claude Code wasn't found on the server. Install it there, or set its path in the server's settings."
                + (detail.isEmpty ? "" : "\n\n" + detail)
        }
        if let status, status != 0 {
            return "Claude Code exited with status \(status)." + (detail.isEmpty ? "" : "\n\n" + detail)
        }
        if status == nil, transcript.sessionId != nil {
            return "The connection was lost."
        }
        return nil
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        let text = String(describing: error)
        if text.contains("connectTimeout") || text.contains("timedOut") {
            return "The server didn't answer. Check the address and that you're on a network that reaches it."
        }
        if text.contains("NIOConnectionError") || text.contains("connectFailed") {
            return "Couldn't reach the server. Check the address and port."
        }
        return text
    }
}

/// Keeps one conversation per server alive while you move around the app.
@MainActor @Observable
final class SessionStore {
    private var sessions: [Host.ID: ChatSession] = [:]

    func session(for host: Host, store: HostStore, keys: DeviceKeyStore, prompter: HostKeyPrompter) -> ChatSession {
        if let session = sessions[host.id] { return session }
        let session = ChatSession(host: host, store: store, keys: keys, prompter: prompter)
        sessions[host.id] = session
        return session
    }

    func existing(_ id: Host.ID) -> ChatSession? { sessions[id] }

    func remove(_ id: Host.ID) async {
        await sessions[id]?.disconnect()
        sessions[id] = nil
    }

    func resumeDropped() async {
        for session in sessions.values { await session.resumeIfDropped() }
    }
}
