import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public struct SSHCallbacks: Sendable {
    public var state: @Sendable (ConnectionState) -> Void
    public var output: @Sendable (Data) -> Void
    public var failure: @Sendable (ConnectionFailure) -> Void
    public init(state: @escaping @Sendable (ConnectionState) -> Void,
                output: @escaping @Sendable (Data) -> Void,
                failure: @escaping @Sendable (ConnectionFailure) -> Void = { _ in }) {
        self.state = state
        self.output = output
        self.failure = failure
    }
}

/// Completion must be called once. It may be called from any queue; it must never block a NIO loop.
public typealias HostKeyVerifier = @Sendable (
    _ openSSHKey: String, _ completion: @escaping @Sendable (Result<Void, Error>) -> Void
) -> Void

/// One-shot connection. All mutable state below is confined to `loop`.
/// Public entry points enqueue directly on that loop, preserving keyboard byte order.
public final class SSHTransport: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let loop: any EventLoop
    private let callbacks: SSHCallbacks
    private var parent: (any Channel)?
    private var child: (any Channel)?
    private var state: ConnectionState = .idle
    private var size = TerminalSize()
    private var pending = PendingInput()
    private var writeInFlight = false
    private var readPaused = false
    private var deadline: Scheduled<Void>?
    private var started = false
    private var startupCommand: String?
    private var preview: PreviewForwarder?
    private var sftp: SFTPHandler?
    private var liveness: LivenessProbe?
    private var pausedOutput: [Data] = []
    private var pausedOutputBytes = 0

    public init(callbacks: SSHCallbacks) {
        self.callbacks = callbacks
        loop = group.next()
    }

    deinit { group.shutdownGracefully { _ in } }

    public func connect(to connection: SSHConnection, seed: Data, verifyHostKey: @escaping HostKeyVerifier) {
        loop.execute { [self] in
            guard !started, !state.isFinished else { return }
            started = true
            startupCommand = connection.startupCommand
            transition(.connecting)
            do {
                let privateKey = try NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey(rawRepresentation: seed))
                let bootstrap = ClientBootstrap(group: loop)
                    .connectTimeout(.seconds(15))
                    .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                    .channelInitializer { [weak self] channel in
                        guard let self else { return channel.eventLoop.makeFailedFuture(TerminalError.cancelled) }
                        return channel.eventLoop.makeCompletedFuture {
                            let ssh = NIOSSHHandler(
                                role: .client(.init(
                                    userAuthDelegate: KeyAuthentication(username: connection.username, key: privateKey),
                                    serverAuthDelegate: HostAuthentication(transport: self, verify: verifyHostKey)
                                )),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            )
                            try channel.pipeline.syncOperations.addHandler(ssh)
                            try channel.pipeline.syncOperations.addHandler(ConnectionHandler(transport: self))
                        }
                    }
                deadline = loop.scheduleTask(in: .seconds(30)) { [weak self] in self?.fail(TerminalError.timedOut) }
                bootstrap.connect(host: connection.host, port: connection.port).whenComplete { [weak self] result in
                    guard let self else {
                        if case .success(let channel) = result { channel.close(promise: nil) }
                        return
                    }
                    switch result {
                    case .success(let channel):
                        if state.isFinished { channel.close(promise: nil) } else { parent = channel }
                    case .failure(let error): fail(error)
                    }
                }
            } catch { fail(error) }
        }
    }

    public func send(_ data: Data) {
        // Capture bounded chunks only; an excessively large single paste is rejected explicitly.
        loop.execute { [weak self] in
            guard let self, state == .connected else { return }
            do { try pending.append(data); flushInput() } catch { fail(error) }
        }
    }

    public func resize(_ newSize: TerminalSize) {
        loop.execute { [weak self] in
            guard let self, size != newSize, !state.isFinished else { return }
            size = newSize
            if state == .connected { sendWindowChange() }
        }
    }

    public func setOutputPaused(_ paused: Bool) {
        loop.execute { [weak self] in
            guard let self, !state.isFinished else { return }
            readPaused = paused
            if !paused { deliverPausedOutput() }
            // A child's receive window bounds unread output. Keep the shared socket reading
            // so a paused renderer cannot starve forwarded web connections or SSH control traffic.
            if let child { applyReadPressure(child) }
        }
    }

    public func disconnect() {
        // Keep the transport alive until cleanup has run even if its presenting view is dismissed now.
        loop.execute { [self] in finish(.disconnected) }
    }

    /// Replaces the current preview. Only the existing, fully authenticated connection is used.
    public func startPreview(remotePort: Int) -> EventLoopFuture<SSHPreviewTunnel> {
        loop.flatSubmit { [self] in
            guard state == .connected else { return loop.makeFailedFuture(PreviewError.disconnected) }
            guard (1...65535).contains(remotePort) else { return loop.makeFailedFuture(PreviewError.invalidPort) }
            preview?.stop()
            let forwarder = PreviewForwarder(loop: loop, remotePort: remotePort) { [weak self] host, port, initialize in
                guard let self else { return initialize.loop.makeFailedFuture(PreviewError.disconnected) }
                return self.openForward(host: host, port: port, initialize: initialize)
            }
            preview = forwarder
            return forwarder.start()
        }
    }

    /// Reuse the authenticated socket; SFTP never sends commands through the PTY.
    public func startSFTP() -> EventLoopFuture<SFTPClient> {
        loop.flatSubmit { [self] in
            guard state == .connected, let parent else { return loop.makeFailedFuture(SFTPError.disconnected) }
            sftp?.fail(SFTPError.disconnected)
            let handler = SFTPHandler(loop: loop)
            sftp = handler
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = loop.makePromise(of: (any Channel).self)
                ssh.createChannel(promise, channelType: .session) { channel, _ in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
                }
                promise.futureResult.whenFailure { handler.fail($0) }
                return handler.ready.futureResult
            } catch { handler.fail(error); return handler.ready.futureResult }
        }
    }

    /// Opening an empty session proves a round trip without executing a shell command.
    /// Used after foreground/network restoration to detect half-open suspended sockets.
    public func checkAlive() -> EventLoopFuture<Void> {
        loop.flatSubmit { [self] in
            guard state == .connected, let parent else { return loop.makeFailedFuture(TerminalError.cancelled) }
            if let liveness { return liveness.promise.futureResult }
            let probe = LivenessProbe(loop: loop)
            liveness = probe
            probe.timeout = loop.scheduleTask(in: .seconds(8)) { [weak self] in
                if probe.finish(.failure(TerminalError.timedOut)) { self?.fail(TerminalError.timedOut) }
            }
            do {
                let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = loop.makePromise(of: (any Channel).self)
                ssh.createChannel(promise, channelType: .session) { channel, _ in channel.eventLoop.makeSucceededVoidFuture() }
                promise.futureResult.whenComplete { outcome in
                    if case .success(let channel) = outcome { channel.close(promise: nil) }
                    // A channel rejection still proves SSH is responsive. Transport
                    // closure resolves this probe separately as a disconnection.
                    _ = probe.finish(.success(()))
                    if self.liveness === probe { self.liveness = nil }
                }
            } catch { _ = probe.finish(.failure(error)); liveness = nil }
            return probe.promise.futureResult
        }
    }

    private func openForward(host: String, port: Int, initialize: ForwardInitializer) -> EventLoopFuture<any Channel> {
        guard state == .connected, let parent else { return loop.makeFailedFuture(PreviewError.disconnected) }
        do {
            let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            let promise = loop.makePromise(of: (any Channel).self)
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            ssh.createChannel(promise, channelType: .directTCPIP(.init(targetHost: host, targetPort: port, originatorAddress: origin))) { channel, _ in
                initialize.install(channel)
            }
            return promise.futureResult
        } catch { return loop.makeFailedFuture(error) }
    }

    fileprivate func verifyingHost() {
        guard !state.isFinished else { return }
        // First-use confirmation has no timeout. User cancellation closes the socket.
        deadline?.cancel(); deadline = nil
        transition(.verifyingHost)
    }

    fileprivate func hostAccepted() {
        guard !state.isFinished else { return }
        transition(.authenticating)
        deadline = loop.scheduleTask(in: .seconds(20)) { [weak self] in self?.fail(TerminalError.timedOut) }
    }

    fileprivate func authenticated(on channel: any Channel) {
        guard !state.isFinished else { return }
        transition(.openingShell)
        do {
            let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
            let promise = loop.makePromise(of: (any Channel).self)
            ssh.createChannel(promise, channelType: .session) { [weak self] child, type in
                guard let self, type == .session else { return child.eventLoop.makeFailedFuture(TerminalError.cancelled) }
                return child.eventLoop.makeCompletedFuture {
                    self.child = child
                    try child.pipeline.syncOperations.addHandler(PTYHandler(transport: self, size: self.size, command: self.startupCommand))
                    self.applyReadPressure(child)
                }
            }
            promise.futureResult.whenFailure { [weak self] in self?.fail($0) }
        } catch { fail(error) }
    }

    fileprivate func shellReady() {
        guard !state.isFinished else { return }
        deadline?.cancel(); deadline = nil
        transition(.connected)
        sendWindowChange() // Includes any rotation that occurred during PTY setup.
    }

    fileprivate func receive(_ data: Data) {
        guard !state.isFinished else { return }
        // Disabling child autoRead cannot revoke a read already in flight. Hold that bounded
        // batch here instead of delivering output through a paused renderer callback.
        if readPaused {
            guard data.count <= 4 * 1024 * 1024 - pausedOutputBytes else { fail(TerminalError.outputOverflow); return }
            pausedOutput.append(data); pausedOutputBytes += data.count
            return
        }
        callbacks.output(data)
    }

    fileprivate func closed() { finish(.disconnected) }
    fileprivate func fail(_ error: Error) {
        guard !state.isFinished else { return }
        callbacks.failure(ConnectionFailure(error))
        finish(.failed(error.localizedDescription))
    }

    private func transition(_ next: ConnectionState) {
        guard !state.isFinished, state != next else { return }
        state = next
        callbacks.state(next)
    }

    private func finish(_ final: ConnectionState) {
        guard !state.isFinished else { return }
        deadline?.cancel(); deadline = nil
        // The parent keeps reading while the PTY is paused. Its final close can force a
        // pending child read through; deliver those already-received bytes before ending.
        deliverPausedOutput()
        transition(final)
        pending.removeAll()
        preview?.stop(); preview = nil
        sftp?.fail(SFTPError.disconnected); sftp = nil
        _ = liveness?.finish(.failure(TerminalError.cancelled)); liveness = nil
        child?.close(promise: nil); child = nil
        parent?.close(promise: nil); parent = nil
    }

    private func deliverPausedOutput() {
        let queued = pausedOutput
        pausedOutput.removeAll(); pausedOutputBytes = 0
        for data in queued { callbacks.output(data) }
    }

    private func flushInput() {
        guard !writeInFlight, state == .connected, let child, child.isWritable,
              let data = pending.pop() else { return }
        writeInFlight = true
        let packet = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data)))
        child.writeAndFlush(packet).whenComplete { [weak self] result in
            guard let self else { return }
            writeInFlight = false
            switch result {
            case .success: flushInput()
            case .failure(let error): fail(error)
            }
        }
    }

    fileprivate func writable() { flushInput() }

    private func sendWindowChange() {
        guard let child else { return }
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: size.widthPixels, terminalPixelHeight: size.heightPixels
        )
        child.triggerUserOutboundEvent(event).whenFailure { [weak self] in self?.fail($0) }
    }

    private func applyReadPressure(_ channel: any Channel) {
        channel.setOption(ChannelOptions.autoRead, value: !readPaused).whenFailure { [weak self] in self?.fail($0) }
        if !readPaused { channel.read() }
    }
}

private final class LivenessProbe: @unchecked Sendable {
    let promise: EventLoopPromise<Void>
    var timeout: Scheduled<Void>?
    private var completed = false
    init(loop: any EventLoop) { promise = loop.makePromise() }
    func finish(_ result: Result<Void, any Error>) -> Bool {
        guard !completed else { return false }; completed = true
        timeout?.cancel(); timeout = nil; promise.completeWith(result)
        return true
    }
}

private final class KeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let key: NIOSSHPrivateKey
    var offered = false
    init(username: String, key: NIOSSHPrivateKey) { self.username = username; self.key = key }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(TerminalError.authentication)
            return
        }
        offered = true
        nextChallengePromise.succeed(.init(username: username, serviceName: "ssh-connection",
                                           offer: .privateKey(.init(privateKey: key))))
    }
}

private final class HostAuthentication: NIOSSHClientServerAuthenticationDelegate {
    weak var transport: SSHTransport?
    let verify: HostKeyVerifier
    init(transport: SSHTransport, verify: @escaping HostKeyVerifier) { self.transport = transport; self.verify = verify }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        transport?.verifyingHost()
        let loop = validationCompletePromise.futureResult.eventLoop
        // Completion is returned to the same loop; no promise or mutable transport state crosses queues unsafely.
        verify(String(openSSHPublicKey: hostKey)) { [weak transport] result in
            let currentTransport = transport
            loop.execute {
                if case .success = result { currentTransport?.hostAccepted() }
                validationCompletePromise.completeWith(result)
            }
        }
    }
}

private final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    weak var transport: SSHTransport?
    init(transport: SSHTransport) { self.transport = transport }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { transport?.authenticated(on: context.channel) }
        context.fireUserInboundEventTriggered(event)
    }
    func channelInactive(context: ChannelHandlerContext) {
        transport?.closed()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        transport?.fail(error)
        context.close(promise: nil)
    }
}

/// Requests are acknowledged in sequence: the shell is never marked ready merely because a write succeeded.
final class PTYHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    weak var transport: SSHTransport?
    let size: TerminalSize
    private var replies = 0
    private let command: String?
    init(transport: SSHTransport, size: TerminalSize, command: String? = nil) {
        self.transport = transport; self.size = size; self.command = command
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: size.widthPixels, terminalPixelHeight: size.heightPixels,
            terminalModes: .init([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            replies += 1
            if replies == 1 {
                if let command {
                    context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
                } else {
                    context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
                }
            } else if replies == 2 { transport?.shellReady() }
        case is ChannelFailureEvent:
            transport?.fail(TerminalError.requestRejected)
            context.close(promise: nil)
        case is SSHChannelRequestEvent.ExitStatus:
            // Wait for channelInactive so final stdout/stderr is delivered before disconnect.
            break
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default: context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel || packet.type == .stdErr,
              case .byteBuffer(let buffer) = packet.data else { return }
        transport?.receive(Data(buffer.readableBytesView))
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        transport?.writable()
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) {
        transport?.closed()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        transport?.fail(error)
        context.close(promise: nil)
    }
}
