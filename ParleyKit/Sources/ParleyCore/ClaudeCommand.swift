import Foundation

/// The shell command that starts Claude Code on the server, speaking stream-json on stdin and
/// stdout and sending every permission question back to Parley.
public struct ClaudeCommand: Sendable, Equatable {
    /// The folder to start in. `~` and `~/…` are the user's home.
    public var directory: String
    /// The `claude` executable. Empty means `claude` on the login shell's PATH.
    public var executable: String
    /// A session to continue, from a previous run's `session_id`.
    public var resumeSessionId: String?
    /// `--permission-mode`, or nil for the server's own setting.
    public var permissionMode: String?

    public init(directory: String, executable: String = "", resumeSessionId: String? = nil, permissionMode: String? = nil) {
        self.directory = directory
        self.executable = executable
        self.resumeSessionId = resumeSessionId
        self.permissionMode = permissionMode
    }

    public var arguments: [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            // Echo what Parley sends, so the output alone can rebuild the conversation.
            "--replay-user-messages",
        ]
        if let mode = permissionMode, !mode.isEmpty {
            arguments += ["--permission-mode", mode]
        }
        if let session = resumeSessionId, !session.isEmpty {
            arguments += ["--resume", session]
        }
        return arguments
    }

    /// The command line for an SSH exec request. It runs in the user's login shell, so PATH is
    /// what they get when they sign in, plus the places Claude Code's installers use.
    public var shellCommand: String {
        "exec " + backgroundCommand
    }

    /// The same, without the leading `exec`, for starting it in the background.
    public var backgroundCommand: String {
        let trimmedExecutable = executable.trimmingCharacters(in: .whitespaces)
        let claude = trimmedExecutable.isEmpty ? "claude" : Self.quoteHomePath(trimmedExecutable)
        let script = [
            #"export PATH="$HOME/.local/bin:$HOME/.claude/local:$PATH""#,
            Self.changeDirectory(directory) + " && exec " + claude + " " + arguments.map(Self.quote).joined(separator: " "),
        ].joined(separator: "; ")
        return #""${SHELL:-/bin/sh}" -lc "# + Self.quote(script)
    }

    static func changeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" { return "cd" }
        return "cd " + quoteHomePath(trimmed)
    }

    /// Quotes a path for sh, keeping a leading `~/` as the home folder.
    static func quoteHomePath(_ path: String) -> String {
        if path == "~" { return #""$HOME""# }
        if path.hasPrefix("~/") { return #""$HOME"/"# + quote(String(path.dropFirst(2))) }
        return quote(path)
    }

    /// Single-quotes a string for sh.
    public static func quote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
