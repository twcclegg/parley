import Foundation
import Testing
@testable import ParleyCore

@Suite struct TranscriptTests {
    private func load(_ name: String) throws -> [JSON] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).compactMap { JSON.parseLine(Data($0)) }
    }

    @Test func readsATurnWithAPermissionRequest() throws {
        var transcript = Transcript()
        transcript.beginUserTurn("Create b.txt")
        var effects: [TranscriptEffect] = []
        for message in try load("turn-with-permission") {
            effects += transcript.apply(message)
        }

        #expect(effects == [.sessionStarted("0e99c357-6f0c-495a-b643-fcb35ff9e1e9")])
        #expect(transcript.model == "claude-haiku-5-5")
        #expect(transcript.slashCommands.map(\.name) == ["review", "compact"])
        #expect(transcript.isBusy == false)

        let kinds = transcript.items.map(\.kind)
        #expect(kinds.count == 6)
        #expect(kinds[0] == .user("Create b.txt"))
        // The streamed thought survives the empty, redacted complete block.
        #expect(kinds[1] == .thinking("The user wants a file."))
        // The streamed text and the complete text are one item, not two.
        #expect(kinds[2] == .assistant("I'll create the file."))
        guard case .tool(let call) = kinds[3] else { Issue.record("expected a tool"); return }
        #expect(call.name == "Bash")
        #expect(call.summary == "touch b.txt")
        #expect(call.result == "")
        guard case .permission(let request) = kinds[4] else { Issue.record("expected a permission"); return }
        #expect(request.requestId == "req-1")
        #expect(request.state == .pending)
        #expect(request.suggestedRules.count == 1)
        // A subagent's tool call isn't shown in the main conversation.
        #expect(kinds[5] == .assistant("Done."))
    }

    @Test func ignoresLinesThatAreNotJSON() {
        #expect(JSON.parseLine(Data("Last login: yesterday".utf8)) == nil)
        #expect(JSON.parseLine(Data("{\"type\":\"result\"}".utf8))?["type"]?.string == "result")
    }

    @Test func asksAboutUnknownControlRequests() {
        var transcript = Transcript()
        let effects = transcript.apply([
            "type": "control_request", "request_id": "r9",
            "request": ["subtype": "hook_callback"],
        ])
        #expect(effects == [.unsupportedControlRequest("r9")])
    }

    @Test func readsAQuestion() {
        var transcript = Transcript()
        transcript.apply([
            "type": "control_request", "request_id": "q1",
            "request": [
                "subtype": "can_use_tool", "tool_name": "AskUserQuestion",
                "input": ["questions": [[
                    "question": "Which database?", "header": "Database", "multiSelect": false,
                    "options": [["label": "SQLite", "description": "A file"], ["label": "Postgres"]],
                ]]],
            ],
        ])
        guard case .question(let question) = transcript.items.first?.kind else { Issue.record("expected a question"); return }
        #expect(question.questions.first?.options.map(\.label) == ["SQLite", "Postgres"])
    }

    @Test func endingTheConnectionCancelsWhatIsPending() {
        var transcript = Transcript()
        transcript.beginUserTurn("hi")
        transcript.apply([
            "type": "control_request", "request_id": "p1",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"]],
        ])
        transcript.connectionEnded()
        #expect(transcript.isBusy == false)
        guard case .permission(let request) = transcript.items.last?.kind else { Issue.record("expected a permission"); return }
        #expect(request.state == .cancelled)
    }
}

@Suite struct OutgoingTests {
    @Test func allowEchoesTheInputAndKeepsRules() throws {
        let rule: JSON = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "ls"]]]
        let message = Outgoing.allow(requestId: "r1", input: ["command": "ls", "timeout": .number(10)], rules: [rule])
        let line = try #require(String(data: try message.line(), encoding: .utf8))
        #expect(line.hasSuffix("\n"))
        let parsed = try #require(JSON.parseLine(Data(line.utf8)))
        #expect(parsed["response"]?["request_id"]?.string == "r1")
        #expect(parsed["response"]?["response"]?["behavior"]?.string == "allow")
        #expect(parsed["response"]?["response"]?["updatedInput"]?["timeout"]?.number == 10)
        #expect(parsed["response"]?["response"]?["updatedPermissions"]?.array?.count == 1)
        // Integers stay integers on the wire.
        #expect(line.contains("\"timeout\":10") && !line.contains("10.0"))
    }
}

@Suite struct ClaudeCommandTests {
    @Test func quotesForSh() {
        #expect(ClaudeCommand.quote("abc-1.2") == "abc-1.2")
        #expect(ClaudeCommand.quote("it's here") == #"'it'\''s here'"#)
        #expect(ClaudeCommand.quote("") == "''")
    }

    @Test func buildsTheRemoteCommand() {
        let command = ClaudeCommand(directory: "~/code/my app", resumeSessionId: "abc", permissionMode: "acceptEdits")
        let shell = command.shellCommand
        #expect(shell.hasPrefix(#"exec "${SHELL:-/bin/sh}" -lc '"#))
        #expect(shell.contains("--permission-prompt-tool stdio"))
        #expect(shell.contains("--resume abc"))
        #expect(shell.contains("--permission-mode acceptEdits"))
        #expect(ClaudeCommand.changeDirectory("~/code/my app") == #"cd "$HOME"/'code/my app'"#)
        #expect(ClaudeCommand.changeDirectory("~") == "cd")
        #expect(ClaudeCommand.changeDirectory("/srv/x") == "cd /srv/x")
    }

    @Test func runsInAShell() throws {
        // The outer quoting must survive a real sh: run the script with `claude` swapped for echo.
        let command = ClaudeCommand(directory: "/", executable: "/bin/echo")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command.shellCommand]
        process.environment = ["SHELL": "/bin/sh", "HOME": NSTemporaryDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("-p --input-format stream-json --output-format stream-json"))
    }
}

@Suite struct OpenSSHKeyTests {
    @Test func fingerprintsLikeSshKeygen() throws {
        // The fingerprint `ssh-keygen -lf` prints for this public key.
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl example"
        let result = try #require(OpenSSHKey.fingerprint(of: line))
        #expect(result.type == "ssh-ed25519")
        #expect(result.fingerprint == "SHA256:\(try expectedFingerprint(line))")
    }

    private func expectedFingerprint(_ line: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("parley-test-key.pub")
        try line.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-lf", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return String(output.split(separator: " ")[1].dropFirst("SHA256:".count))
    }
}
