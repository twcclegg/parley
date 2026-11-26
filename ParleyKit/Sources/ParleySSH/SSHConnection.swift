import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOPosix
import NIOSSH

/// How to sign in, tried in order.
public enum SSHAuthentication: Sendable {
    case privateKey(NIOSSHPrivateKey)
    case password(String)
}

public enum SSHError: Error, LocalizedError, Sendable {
    case hostKeyRejected
    case authenticationFailed
    case connectionClosed
    case commandRefused

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected:
            return "The server's host key wasn't trusted, so Parley didn't sign in."
        case .authenticationFailed:
            return "The server didn't accept this device's key. Install the key on the server, then try again."
        case .connectionClosed:
            return "The connection closed."
        case .commandRefused:
            return "The server refused to run the command."
        }
    }
}

/// One SSH connection to a server.
public final class SSHConnection: @unchecked Sendable {
    private let channel: Channel

    private init(channel: Channel) {
        self.channel = channel
    }

    /// Connects and signs in. `validateHostKey` decides whether to trust the server's host key;
    /// it gets the key as an OpenSSH public key line.
    public static func connect(
        host: String,
        port: Int,
        username: String,
        authentication: [SSHAuthentication],
        validateHostKey: @escaping @Sendable (String) async -> Bool
    ) async throws -> SSHConnection {
        let group = MultiThreadedEventLoopGroup.singleton
        let authenticated = OnceResult(group.next().makePromise(of: Void.self))
        // swift-nio-ssh doesn't report running out of methods; it just stops. Fail here instead.
        let userAuth = UserAuthenticationDelegate(username: username, methods: authentication) {
            authenticated.fail(SSHError.authenticationFailed)
        }
        let serverAuth = HostKeyDelegate(validate: validateHostKey)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandlers([
                        ssh,
                        AuthenticationWatcher(promise: authenticated, hostKeyDelegate: serverAuth),
                    ])
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            authenticated.fail(error)
            throw error
        }
        do {
            try await authenticated.future.get()
        } catch {
            try? await channel.close()
            throw error
        }
        return SSHConnection(channel: channel)
    }

    /// Runs a command, with its stdin, stdout and stderr open as streams.
    public func exec(_ command: String) async throws -> SSHExecChannel {
        try await open(.exec(command))
    }

    /// Starts the user's login shell on a pseudo-terminal, as `ssh` does with no command. With a
    /// terminal, `sudo` and other password prompts work, and what's typed goes only to the server.
    public func shell(terminal: SSHTerminal) async throws -> SSHExecChannel {
        try await open(.shell(terminal))
    }

    private func open(_ request: ExecHandler.Request) async throws -> SSHExecChannel {
        let (stdout, stdoutContinuation) = AsyncStream<Data>.makeStream()
        let (stderr, stderrContinuation) = AsyncStream<Data>.makeStream()
        let exitStatus = channel.eventLoop.makePromise(of: Int?.self)
        let childPromise = channel.eventLoop.makePromise(of: Channel.self)
        let parent = channel

        parent.eventLoop.execute {
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(childPromise, channelType: .session) { child, type in
                    guard type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHError.commandRefused)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ExecHandler(
                                request: request,
                                stdout: stdoutContinuation,
                                stderr: stderrContinuation,
                                exitStatus: exitStatus
                            )
                        )
                    }
                }
            } catch {
                childPromise.fail(error)
            }
        }

        do {
            let child = try await childPromise.futureResult.get()
            return SSHExecChannel(channel: child, stdout: stdout, stderr: stderr, exitStatus: exitStatus.futureResult)
        } catch {
            stdoutContinuation.finish()
            stderrContinuation.finish()
            exitStatus.succeed(nil)
            throw error
        }
    }

    /// Runs a command to completion and returns its exit status and output.
    public func run(_ command: String) async throws -> (status: Int?, stdout: String, stderr: String) {
        let exec = try await exec(command)
        await exec.closeInput()
        async let out = Self.collect(exec.stdout)
        async let err = Self.collect(exec.stderr)
        let (stdout, stderr) = await (out, err)
        return (await exec.exitStatus, stdout, stderr)
    }

    private static func collect(_ stream: AsyncStream<Data>) async -> String {
        var data = Data()
        for await chunk in stream { data.append(chunk) }
        return String(decoding: data, as: UTF8.self)
    }

    public var isActive: Bool { channel.isActive }

    public func close() async {
        try? await channel.close()
    }
}

/// A command running on the server.
public final class SSHExecChannel: @unchecked Sendable {
    private let channel: Channel
    public let stdout: AsyncStream<Data>
    public let stderr: AsyncStream<Data>
    private let exitFuture: EventLoopFuture<Int?>

    init(channel: Channel, stdout: AsyncStream<Data>, stderr: AsyncStream<Data>, exitStatus: EventLoopFuture<Int?>) {
        self.channel = channel
        self.stdout = stdout
        self.stderr = stderr
        self.exitFuture = exitStatus
    }

    /// Writes to the command's stdin.
    public func write(_ data: Data) async throws {
        let buffer = ByteBuffer(data: data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    /// Sends end-of-file on stdin.
    public func closeInput() async {
        try? await channel.close(mode: .output).get()
    }

    public func close() async {
        try? await channel.close().get()
    }

    /// Tells the server the terminal's new size, for a shell started with `shell(terminal:)`.
    public func resize(columns: Int, rows: Int) {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    /// The command's exit status once it has ended; nil if the server didn't say.
    public var exitStatus: Int? {
        get async { (try? await exitFuture.get()) ?? nil }
    }
}

// MARK: - Handlers

/// A promise that may be completed from several places; only the first completion counts.
private final class OnceResult: Sendable {
    private let promise: NIOLockedValueBox<EventLoopPromise<Void>?>
    let future: EventLoopFuture<Void>

    init(_ promise: EventLoopPromise<Void>) {
        self.promise = NIOLockedValueBox(promise)
        self.future = promise.futureResult
    }

    func succeed() { take()?.succeed(()) }
    func fail(_ error: Error) { take()?.fail(error) }

    private func take() -> EventLoopPromise<Void>? {
        promise.withLockedValue { value in
            defer { value = nil }
            return value
        }
    }
}

private final class UserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var remaining: [SSHAuthentication]
    private let exhausted: @Sendable () -> Void

    init(username: String, methods: [SSHAuthentication], exhausted: @escaping @Sendable () -> Void) {
        self.username = username
        self.remaining = methods
        self.exhausted = exhausted
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !remaining.isEmpty {
            switch remaining.removeFirst() {
            case .privateKey(let key) where availableMethods.contains(.publicKey):
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key)))
                )
                return
            case .password(let password) where availableMethods.contains(.password):
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password)))
                )
                return
            default:
                continue
            }
        }
        nextChallengePromise.succeed(nil)
        exhausted()
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let validate: @Sendable (String) async -> Bool
    /// Set when the host key check said no, so the failure can be reported as that.
    var rejected = false

    init(validate: @escaping @Sendable (String) async -> Bool) {
        self.validate = validate
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let validate = self.validate
        Task {
            if await validate(line) {
                validationCompletePromise.succeed(())
            } else {
                self.rejected = true
                validationCompletePromise.fail(SSHError.hostKeyRejected)
            }
        }
    }
}

/// Completes the connect call once the server accepts us, or fails it with why it didn't.
private final class AuthenticationWatcher: ChannelInboundHandler {
    typealias InboundIn = Any

    private let promise: OnceResult
    private let hostKeyDelegate: HostKeyDelegate

    init(promise: OnceResult, hostKeyDelegate: HostKeyDelegate) {
        self.promise = promise
        self.hostKeyDelegate = hostKeyDelegate
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            promise.succeed()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(SSHError.connectionClosed)
        context.fireChannelInactive()
    }

    private func fail(_ error: Error) {
        promise.fail(hostKeyDelegate.rejected ? SSHError.hostKeyRejected : error)
    }
}

/// The size and type of a pseudo-terminal.
public struct SSHTerminal: Sendable {
    public var type: String
    public var columns: Int
    public var rows: Int

    public init(type: String = "xterm-256color", columns: Int, rows: Int) {
        self.type = type
        self.columns = columns
        self.rows = rows
    }
}

private final class ExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    enum Request {
        case exec(String)
        case shell(SSHTerminal)
    }

    private let request: Request
    private let stdout: AsyncStream<Data>.Continuation
    private let stderr: AsyncStream<Data>.Continuation
    private let exitStatus: EventLoopPromise<Int?>
    private var status: Int?

    init(
        request: Request,
        stdout: AsyncStream<Data>.Continuation,
        stderr: AsyncStream<Data>.Continuation,
        exitStatus: EventLoopPromise<Int?>
    ) {
        self.request = request
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        switch request {
        case .exec(let command):
            let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            context.triggerUserOutboundEvent(exec, promise: nil)
        case .shell(let terminal):
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: terminal.type,
                terminalCharacterWidth: terminal.columns,
                terminalRowHeight: terminal.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            context.triggerUserOutboundEvent(pty, promise: nil)
            context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = message.data,
            let bytes = buffer.readData(length: buffer.readableBytes)
        else { return }
        switch message.type {
        case .channel: stdout.yield(bytes)
        case .stdErr: stderr.yield(bytes)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exit as SSHChannelRequestEvent.ExitStatus:
            status = exit.exitStatus
        case is ChannelFailureEvent:
            stderr.yield(Data("The server refused to run the command.\n".utf8))
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            stdout.finish()
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        stdout.finish()
        stderr.finish()
        exitStatus.succeed(status)
        context.fireChannelInactive()
    }
}
