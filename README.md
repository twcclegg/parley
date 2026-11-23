# Parley

Chat with [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) on a server you reach over SSH, from an iPhone or iPad, in a conversation instead of a terminal.

Parley is for machines where Claude Code's own remote options aren't available and SSH is the only way in. It signs in with a key made in your device's Secure Enclave, starts `claude` on the server, and shows the session as a native chat with the system keyboard, so word suggestions, autocorrect and dictation work as they do everywhere else.

> Parley is an independent project. It isn't made or endorsed by Anthropic.

## What it does

- **A conversation, not a screen of text.** Claude's replies stream in as formatted text. Tool calls show as compact cards you can open to see the command and its output. Scrolling and selecting text work like any other iOS app.
- **Permission prompts as buttons.** When Claude Code asks to run a command or edit a file, Parley shows **Allow**, **Always Allow** (Claude Code's own suggested rule) and **Deny**. Questions Claude asks you show as choices. No arrow keys needed.
- **Your keyboard.** Suggestions, dictation and the rest of the system keyboard. Type `/` to see the session's slash commands.
- **A key that stays on your device.** Parley makes a P-256 key in the Secure Enclave. Install it on a server with your password once, or copy the public key into `~/.ssh/authorized_keys` yourself.
- **Host keys checked.** The first connection shows the server's fingerprint for you to confirm. If the key changes later, Parley refuses to connect.
- **Pick up where you left off.** Parley remembers each server's last session and continues it with `--resume`.
- **Liquid Glass** throughout, on iOS 26 and later.

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
- **`Parley/`**, the SwiftUI app.

Its only dependencies are Apple's `swift-nio` and `swift-nio-ssh`.

## Requirements

- iOS or iPadOS 26 or later.
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

- **The session lives as long as the connection.** iOS closes network connections in apps that are in the background, and Claude Code on the server stops with them. When you come back, Parley reconnects and continues the session with `--resume`, but a turn that was still running is lost, and earlier messages aren't shown again.
- **Subagents are summarized.** A subagent's own tool calls aren't shown in the conversation; its result is.
- **One key per device**, and no SSH agent forwarding, jump hosts or password storage.
- **No plain terminal.** Parley is for Claude Code. Use a terminal app for everything else.

## Ideas

- Keep the session running across disconnects with a small helper on the server (tmux or a relay), and replay history on reconnect.
- Show diffs for edits.
- Attach photos and files.
- A session list from `~/.claude/projects` on the server.
- Jump hosts.

## Licence

MIT. See [LICENSE](LICENSE).
