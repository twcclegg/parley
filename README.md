# Parley

Chat with [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) on a server you reach over SSH, from an iPhone, iPad or Apple Vision Pro, in a conversation instead of a terminal.

Parley is for machines where Claude Code's own remote options aren't available and SSH is the only way in. It signs in with a key made in your device's Secure Enclave, starts `claude` on the server, and shows the session as a native chat with the system keyboard, so word suggestions, autocorrect and dictation work as they do everywhere else.

> Parley is an independent project. It isn't made or endorsed by Anthropic.

## What it does

- **A conversation, not a screen of text.** Claude's replies stream in as formatted text. Tool calls show as compact cards you can open to see the command and its output. Scrolling and selecting text work like any other iOS app.
- **Permission prompts as buttons.** When Claude Code asks to run a command or edit a file, Parley shows **Allow**, **Always Allow** (Claude Code's own suggested rule) and **Deny**. Questions Claude asks you show as choices. No arrow keys needed.
- **Your keyboard.** Suggestions, dictation and the rest of the system keyboard. Type `/` to see the session's slash commands.
- **A key that stays on your device.** Parley makes a P-256 key in the Secure Enclave. Install it on a server with your password once, or copy the public key into `~/.ssh/authorized_keys` yourself.
- **Host keys checked.** The first connection shows the server's fingerprint for you to confirm. If the key changes later, Parley refuses to connect.
- **Pick up where you left off.** Parley remembers each server's last session and continues it with `--resume`.
- **Images.** Paste a screenshot into the message box, or pick photos with **+**, and Claude sees them.
- **A side shell for running things yourself.** The terminal button opens a real terminal on the same server, on its own SSH connection. Use it for commands that need `sudo` or a password: what you type there goes only to the server, never to Claude. Long-press a command Claude ran, a code block, or a permission request for a command and choose **Run in Shell** to put it at the prompt; it runs only when you press Return.
- **Liquid Glass** throughout, on iOS 26 and later. On Vision Pro it uses visionOS's own glass.

## How it works

Parley doesn't drive Claude Code's terminal interface. It runs Claude Code headless over an SSH exec channel:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
       --include-partial-messages --permission-prompt-tool stdio
```

Messages go in and come out as JSON lines. With `--permission-prompt-tool stdio`, every permission check arrives as a `can_use_tool` control request, which Parley answers from the card you tap. The command runs in your login shell, with `~/.local/bin` and `~/.claude/local` added to `PATH` so a standard Claude Code install is found.

The code is in two parts:

- **`ParleyKit/`**, a Swift package with no UI:
  - `ParleyCore` reads the stream-json protocol into a transcript and writes the messages Parley sends. It has unit tests (`swift test`).
  - `ParleySSH` is a small SSH client on Apple's [swift-nio-ssh](https://github.com/apple/swift-nio-ssh): connect, check the host key, sign in, and run one command with its stdin and stdout as streams.
  - `ParleySSH` also opens a login shell on a pseudo-terminal for the side shell.
- **`Parley/`**, the SwiftUI app.

Its dependencies are Apple's `swift-nio` and `swift-nio-ssh`, and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for drawing the side shell.

## Requirements

- iOS, iPadOS or visionOS 26 or later.
- A server with Claude Code installed and signed in, reachable over SSH with key authentication.
- To build: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Building

```sh
brew install xcodegen
xcodegen generate
open Parley.xcodeproj
```

To sign with your own team, create `Config/Signing.local.xcconfig` (it's git-ignored):

```
DEVELOPMENT_TEAM = ABCDE12345
PARLEY_BUNDLE_ID = com.example.parley
```

Run the package tests with `cd ParleyKit && swift test`.

## Using it

1. Open **This Device's Key** (the key button) to make the device's key.
2. Add a server: host, user, and the folder Claude Code should start in.
3. Install the key: **Install This Device's Key…** signs in once with your password and adds it to `~/.ssh/authorized_keys`. If the server doesn't accept passwords, copy the public key there yourself.
4. Open the server and start a conversation.

## Limits

- **Claude Code keeps running while you're away.** iOS closes network connections in apps that are in the background, so Parley starts Claude Code detached from the connection, in `~/.parley/runs/<id>` on the server (a named pipe for its input and a file for its output, using only POSIX `sh`). Reconnecting picks up the output where it left off, and pending permission prompts can still be answered. **End Session** in the chat menu stops it; starting a new conversation stops the previous one. Finished runs are cleaned up the next time Parley starts one.
- A conversation continued from an earlier process (`--resume`) doesn't show messages from before it.
- **Subagents are summarized.** A subagent's own tool calls aren't shown in the conversation; its result is.
- **One key per device**, and no SSH agent forwarding, jump hosts or password storage.
- **The side shell doesn't outlive the connection.** Like any SSH session, it ends when iOS closes the connection in the background; tap **Reconnect**. For something that must keep running, start `tmux` in it.
- **Run in Shell and several lines.** zsh and bash take a multi-line paste whole and wait for Return. A shell without bracketed paste gets only the first line, so nothing runs unseen.

## Ideas

- Show diffs for edits.
- Attach files, and open files from the server.
- A session list from `~/.claude/projects` on the server.
- Jump hosts.

## Licence

MIT. See [LICENSE](LICENSE).
