import Foundation
import Observation
import ParleySSH
import SwiftTerm
import UIKit

/// A plain terminal on the server beside the conversation, for running commands yourself:
/// Claude's suggestions, or anything that needs `sudo` or a password. What's typed here goes
/// straight to the server's terminal and never to Claude.
///
/// It has its own SSH connection, so it doesn't disturb Claude Code's.
@MainActor @Observable
final class ShellSession {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case ended(String?)
    }

    private(set) var phase: Phase = .idle
    private(set) var title = ""

    private let host: () -> Host
    private let keys: DeviceKeyStore
    private let prompter: HostKeyPrompter
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var channel: SSHExecChannel?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var size = (columns: 80, rows: 24)
    /// Text to paste once the shell is up.
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private lazy var bridge = Bridge(owner: self)

    /// The terminal, kept here so its scrollback survives the sheet closing.
    @ObservationIgnored private(set) lazy var view: TerminalView = {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.terminalDelegate = bridge
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = .systemBackground
        view.nativeForegroundColor = .label
        return view
    }()

    init(host: @escaping () -> Host, keys: DeviceKeyStore, prompter: HostKeyPrompter) {
        self.host = host
        self.keys = keys
        self.prompter = prompter
    }

    /// Connects if not connected already.
    func startIfNeeded() {
        switch phase {
        case .idle, .ended: Task { await start() }
        case .connecting, .connected: break
        }
    }

    func start() async {
        close()
        generation += 1
        let generation = self.generation
        phase = .connecting
        do {
            let key = try keys.deviceKey()
            let host = self.host()
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
            let channel = try await connection.shell(terminal: SSHTerminal(columns: size.columns, rows: size.rows))
            guard generation == self.generation else {
                await channel.close()
                await connection.close()
                return
            }
            self.connection = connection
            self.channel = channel
            phase = .connected
            for text in queued { paste(text) }
            queued = []
            Task { await self.read(channel.stdout, generation: generation) }
            Task { await self.read(channel.stderr, generation: generation) }
        } catch {
            guard generation == self.generation else { return }
            phase = .ended(error.localizedDescription)
        }
    }

    private func read(_ stream: AsyncStream<Data>, generation: Int) async {
        for await chunk in stream {
            guard generation == self.generation else { return }
            view.feed(byteArray: ArraySlice(chunk))
        }
        guard generation == self.generation, phase == .connected else { return }
        phase = .ended(nil)
        view.feed(text: "\r\n\u{1B}[2m[Disconnected]\u{1B}[0m\r\n")
        close()
    }

    /// Puts a command at the prompt without running it, so it can be checked and edited first.
    /// Several lines go in as one paste where the shell supports that, so none run early.
    func insert(_ command: String) {
        let text = command.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        if phase == .connected {
            paste(text)
        } else {
            queued.append(text)
            startIfNeeded()
        }
    }

    /// Types text at the prompt as a paste. Shells that support bracketed paste (zsh and bash
    /// do) wait for Return even if it has several lines; for any other, only the first line goes
    /// in, so nothing runs before it has been looked at.
    private func paste(_ text: String) {
        if view.getTerminal().bracketedPasteMode {
            send(ArraySlice(Array("\u{1B}[200~".utf8) + Array(text.utf8) + Array("\u{1B}[201~".utf8)))
        } else {
            let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            send(ArraySlice(Array(line.utf8)))
        }
    }

    func close() {
        generation += 1
        let channel = channel, connection = connection
        self.channel = nil
        self.connection = nil
        if case .connected = phase { phase = .ended(nil) }
        if case .connecting = phase { phase = .idle }
        Task {
            await channel?.close()
            await connection?.close()
        }
    }

    fileprivate func send(_ data: ArraySlice<UInt8>) {
        guard let channel else { return }
        let bytes = Data(data)
        Task { try? await channel.write(bytes) }
    }

    fileprivate func resized(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        size = (columns, rows)
        channel?.resize(columns: columns, rows: rows)
    }

    fileprivate func titled(_ title: String) {
        self.title = title
    }

    /// SwiftTerm's delegate, apart from the observable model.
    @MainActor private final class Bridge: @preconcurrency TerminalViewDelegate {
        weak var owner: ShellSession?

        init(owner: ShellSession) {
            self.owner = owner
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            owner?.send(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            owner?.resized(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            owner?.titled(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            UIApplication.shared.open(url)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
    }
}
