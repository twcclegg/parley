import Foundation
import UIKit
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
    /// Images to send with the next message.
    var attachments: [ImageAttachment] = []

    private let store: HostStore
    private let keys: DeviceKeyStore
    private let prompter: HostKeyPrompter
    /// A terminal on the same server, for running commands yourself.
    @ObservationIgnored private(set) lazy var shell = ShellSession(
        host: { [unowned self] in self.host }, keys: keys, prompter: prompter)
    private var connection: SSHConnection?
    /// Writes to Claude Code's stdin on the server.
    private var input: SSHExecChannel?
    /// Follows Claude Code's output on the server.
    private var output: SSHExecChannel?
    /// The Claude Code process on the server, which outlives connections.
    private var run: DetachedRun?
    /// The run the transcript was built from, and how many bytes of its output it has read.
    private var transcriptRun: DetachedRun?
    private var consumed = 0
    private var requestCounter = 0
    private var lineBuffer = Data()
    /// Bumped whenever connections are replaced, so work for an old one stops.
    private var generation = 0

    init(host: Host, store: HostStore, keys: DeviceKeyStore, prompter: HostKeyPrompter) {
        self.host = host
        self.store = store
        self.keys = keys
        self.prompter = prompter
        self.run = host.runId.map(DetachedRun.init(id:))
    }

    var canSend: Bool {
        phase == .connected && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func addImages(_ images: [UIImage]) {
        for image in images {
            if let attachment = ImagePreparation.attachment(from: image) {
                attachments.append(attachment)
            } else {
                transcript.notice("That image is too large to send.", isError: true)
            }
        }
    }

    func addImageData(_ data: Data) {
        if let attachment = ImagePreparation.attachment(from: data) {
            attachments.append(attachment)
        } else {
            transcript.notice("That image couldn't be read or is too large to send.", isError: true)
        }
    }

    /// Whether Claude Code may still be running on the server from an earlier connection.
    var hasRunOnServer: Bool { run != nil }

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

    /// Connects to the server. Continuing reattaches to Claude Code if it's still running there,
    /// or else resumes the last conversation in a new process; otherwise a new conversation starts.
    func start(continuing: Bool) async {
        if let current = store.host(host.id) { host = current }
        closeConnection()
        generation += 1
        let generation = self.generation
        phase = .connecting

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
            self.connection = connection

            if !continuing {
                if let old = run { _ = try? await connection.run(old.stopCommand) }
                setRun(nil)
                transcript = Transcript()
                transcriptRun = nil
            }

            var resumed = false
            if continuing, let run {
                switch try await connection.run(run.statusCommand).stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
                case "running":
                    try await attach(run, connection: connection, generation: generation)
                    return
                case "exited":
                    // It finished while we were away: show what it said, then carry on in a new process.
                    if transcriptRun != run { startTranscript(for: run) }
                    let rest = try await connection.run(run.readCommand(from: consumed))
                    await apply(Data(rest.stdout.utf8), generation: generation, live: false)
                    _ = try? await connection.run(run.stopCommand)
                    resumed = true
                default:
                    break
                }
                setRun(nil)
            }

            let sessionId = continuing ? (transcript.sessionId ?? host.lastSessionId) : nil
            let run = DetachedRun.new()
            let command = ClaudeCommand(
                directory: host.directory,
                executable: host.claudePath,
                resumeSessionId: sessionId,
                permissionMode: host.permissionMode
            )
            let started = try await connection.run(run.startCommand(command))
            guard started.stdout.contains("started") else {
                throw StartError(detail: (started.stderr + started.stdout).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            setRun(run)
            let hadTranscript = !transcript.items.isEmpty
            startTranscript(for: run, keepingItems: true)
            try await attach(run, connection: connection, generation: generation)
            if sessionId != nil, !hadTranscript, !resumed {
                transcript.notice("Continuing your last conversation. Earlier messages aren't shown here.")
            }
            try await send(Outgoing.initialize(requestId: nextRequestId(prefix: "init")))
        } catch {
            guard generation == self.generation else { return }
            closeConnection()
            let reason = prompter.mismatch(for: host) ?? Self.describe(error)
            phase = .ended(reason)
            transcript.notice(reason, isError: true)
        }
    }

    /// Opens the channels to a running Claude Code and follows its output from where the
    /// transcript left off, or from the beginning for a transcript that hasn't seen this run.
    private func attach(_ run: DetachedRun, connection: SSHConnection, generation: Int) async throws {
        if transcriptRun != run { startTranscript(for: run) }
        let output = try await connection.exec(run.followCommand(from: consumed))
        let input = try await connection.exec(run.inputCommand)
        guard generation == self.generation else {
            await output.close()
            await input.close()
            return
        }
        self.output = output
        self.input = input
        lineBuffer = Data()
        phase = .connected
        Task { await self.follow(output, generation: generation) }
    }

    /// Leaves Claude Code running on the server and closes the connection.
    func disconnect() async {
        closeConnection()
        phase = .ended(nil)
    }

    /// Stops Claude Code on the server.
    func endSession() async {
        let connection = self.connection, run = self.run
        if let connection, let run { _ = try? await connection.run(run.stopCommand) }
        closeConnection()
        setRun(nil)
        transcript.processEnded()
        phase = .ended(nil)
    }

    /// After the app comes back from the background: reconnect if the connection dropped.
    func resumeIfDropped() async {
        if case .ended(let reason) = phase, reason != nil, run != nil {
            await start(continuing: true)
        }
    }

    private func closeConnection() {
        generation += 1
        let input = self.input, output = self.output, connection = self.connection
        self.input = nil
        self.output = nil
        self.connection = nil
        Task {
            await input?.close()
            await output?.close()
            await connection?.close()
        }
    }

    private func setRun(_ run: DetachedRun?) {
        self.run = run
        store.update(host.id) { $0.runId = run?.id }
        host.runId = run?.id
    }

    /// Points the transcript at a run's output, from its start.
    private func startTranscript(for run: DetachedRun, keepingItems: Bool = false) {
        if !keepingItems { transcript = Transcript() }
        transcriptRun = run
        consumed = 0
        lineBuffer = Data()
    }

    struct StartError: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "Parley couldn't start Claude Code on the server." + (detail.isEmpty ? "" : "\n\n" + detail)
        }
    }

    // MARK: - Talking

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments
        guard !text.isEmpty || !images.isEmpty, phase == .connected else { return }
        draft = ""
        attachments = []
        transcript.beginUserTurn(text, images: images)
        do {
            try await send(Outgoing.user(text, images: images))
        } catch {
            draft = text
            attachments = images
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
        try? await send(Outgoing.deny(requestId: request.requestId, message: "The user declined in Parley."))
        transcript.resolvePermission(requestId: request.requestId, state: .denied)
    }

    func answer(_ request: QuestionRequest, with answers: [String: String]) async {
        var input = request.input.object ?? [:]
        input["answers"] = .object(answers.mapValues { .string($0) })
        try? await send(Outgoing.allow(requestId: request.requestId, input: .object(input)))
        transcript.resolveQuestion(requestId: request.requestId, state: .answered(answers))
    }

    func decline(_ request: QuestionRequest) async {
        try? await send(Outgoing.deny(requestId: request.requestId, message: "The user declined in Parley to answer."))
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
        guard let input else { throw SSHError.connectionClosed }
        try await input.write(try message.line())
    }

    private func nextRequestId(prefix: String) -> String {
        requestCounter += 1
        return "\(prefix)-\(requestCounter)"
    }

    // MARK: - Reading

    private func follow(_ output: SSHExecChannel, generation: Int) async {
        for await chunk in output.stdout {
            guard generation == self.generation else { return }
            await apply(chunk, generation: generation, live: true)
        }
        guard generation == self.generation else { return }
        // The output ended without Claude Code exiting: the connection dropped. Claude Code
        // carries on, and reconnecting picks up where this left off.
        closeConnection()
        phase = .ended("The connection was lost. Claude Code is still running on the server.")
    }

    /// Reads complete lines of Claude Code's output.
    private func apply(_ chunk: Data, generation: Int, live: Bool) async {
        lineBuffer.append(chunk)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[lineBuffer.startIndex..<newline])
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            consumed += line.count + 1
            guard let message = JSON.parseLine(line) else { continue }
            if message["type"]?.string == DetachedRun.exitType {
                await processExited(status: message["status"]?.number.map(Int.init), live: live)
                return
            }
            await handle(message)
        }
    }

    /// Claude Code exited on the server.
    private func processExited(status: Int?, live: Bool) async {
        transcript.processEnded()
        guard live else { return }
        var detail = ""
        if let connection, let run {
            detail = (try? await connection.run(run.errorsCommand).stdout) ?? ""
            _ = try? await connection.run(run.stopCommand)
        }
        setRun(nil)
        closeConnection()
        let reason = endReason(status: status, detail: detail)
        transcript.notice(reason ?? "Claude Code ended the session.", isError: reason != nil)
        phase = .ended(reason)
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

    private func endReason(status: Int?, detail: String) -> String? {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 127 || detail.contains("command not found") || detail.contains("not found") && transcript.sessionId == nil {
            return "Claude Code wasn't found on the server. Install it there, or set its path in the server's settings."
                + (detail.isEmpty ? "" : "\n\n" + detail)
        }
        if let status, status != 0 {
            return "Claude Code exited with status \(status)." + (detail.isEmpty ? "" : "\n\n" + detail)
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
        await sessions[id]?.endSession()
        sessions[id]?.shell.close()
        sessions[id] = nil
    }

    func resumeDropped() async {
        for session in sessions.values { await session.resumeIfDropped() }
    }
}
