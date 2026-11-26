import Foundation

/// Claude Code running on the server apart from any SSH connection, so it keeps working while
/// the phone is away.
///
/// Each run has a folder, `~/.parley/runs/<id>`, holding:
/// - `in`: a named pipe that is Claude Code's stdin. A `sleep` holds it open for writing, so
///   Claude Code doesn't see end-of-file when a connection writing to it drops.
/// - `out`: Claude Code's stdout, kept in full. A connection reads it from where it left off.
///   When Claude Code exits, a last line `{"type":"parley_exit","status":N}` is added.
/// - `err`, `pid` and `run.sh`.
///
/// Everything is plain POSIX sh, so it works on macOS and Linux without tmux or anything else.
public struct DetachedRun: Sendable, Equatable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    /// A new run with a fresh id.
    public static func new() -> DetachedRun {
        DetachedRun(id: UUID().uuidString.lowercased())
    }

    /// The message type of the line added when Claude Code exits.
    public static let exitType = "parley_exit"

    private var folder: String { #""$HOME"/.parley/runs/"# + id }

    /// Starts Claude Code in the background, prints `started`, and returns at once. Also clears
    /// away earlier runs whose Claude Code has ended.
    public func startCommand(_ claude: ClaudeCommand) -> String {
        // Inside run.sh, $d is the run's folder. Claude Code runs in the background so its pid
        // can be recorded for stopping it; `exec` in its command line keeps that pid Claude's.
        let script = """
            d="$1"
            sleep 2147483647 > "$d/in" &
            holder=$!
            \(claude.backgroundCommand) < "$d/in" > "$d/out" 2> "$d/err" &
            echo $! > "$d/pid"
            wait $!
            status=$?
            printf '{"type":"\(Self.exitType)","status":%d}\\n' "$status" >> "$d/out"
            kill "$holder" 2>/dev/null
            """
        return """
            d=\(folder)
            for r in "$HOME"/.parley/runs/*; do
              [ -f "$r/pid" ] || continue
              kill -0 "$(cat "$r/pid")" 2>/dev/null || rm -rf "$r"
            done
            mkdir -p "$d" && rm -f "$d/in" && mkfifo "$d/in" && : > "$d/out" || exit 1
            cat > "$d/run.sh" <<'PARLEY_RUN'
            \(script)
            PARLEY_RUN
            nohup sh "$d/run.sh" "$d" > /dev/null 2>&1 < /dev/null &
            echo started
            """
    }

    /// Prints `running`, `exited` or `missing`.
    public var statusCommand: String {
        """
        d=\(folder)
        if [ ! -f "$d/out" ]; then echo missing
        elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo running
        else echo exited; fi
        """
    }

    /// Streams Claude Code's output from `offset` bytes in, and keeps following it.
    public func followCommand(from offset: Int) -> String {
        "exec tail -c +\(offset + 1) -f \(folder)/out"
    }

    /// Prints Claude Code's output from `offset` bytes in, then exits.
    public func readCommand(from offset: Int) -> String {
        "exec tail -c +\(offset + 1) \(folder)/out"
    }

    /// Passes this connection's stdin to Claude Code.
    public var inputCommand: String {
        "exec cat > \(folder)/in"
    }

    /// The end of Claude Code's stderr, for saying why it stopped.
    public var errorsCommand: String {
        "tail -c 2000 \(folder)/err 2>/dev/null"
    }

    /// Stops Claude Code and removes the run's folder.
    public var stopCommand: String {
        """
        d=\(folder)
        [ -f "$d/pid" ] && kill "$(cat "$d/pid")" 2>/dev/null
        rm -rf "$d"
        """
    }
}
