import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public enum PreviewError: Error, LocalizedError, Sendable {
    case invalidPort, disconnected, unavailable, limitReached
    public var errorDescription: String? {
        switch self {
        case .invalidPort: "Enter a port between 1 and 65535."
        case .disconnected: "Reconnect SSH before opening a preview."
        case .unavailable: "Could not open the preview tunnel."
        case .limitReached: "The preview has too many open connections. Reload the page."
        }
    }
}

/// Ephemeral loopback endpoints. Credentials belong only to this browser context; never log/sync them.
public final class SSHPreviewTunnel: Sendable {
    public let proxyPort: Int
    public let safariPort: Int
    public let username: String
    public let password: String
    public let remotePort: Int
    private let owner: PreviewForwarder

    init(owner: PreviewForwarder, proxyPort: Int, safariPort: Int) {
        self.owner = owner; self.proxyPort = proxyPort; self.safariPort = safariPort
        username = owner.username; password = owner.password; remotePort = owner.remotePort
    }

    /// Closing preview does not close the terminal. Safe to call repeatedly, from any queue.
    public func close() -> EventLoopFuture<Void> {
        owner.loop.flatSubmit { [owner] in owner.stop(); return owner.closed() }
    }
}

struct ForwardInitializer: Sendable {
    let loop: any EventLoop
    let install: @Sendable (any Channel) -> EventLoopFuture<Void>
}

/// All mutable state (including relays and listener callbacks) is confined to the transport loop.
final class PreviewForwarder: @unchecked Sendable {
    typealias Connector = @Sendable (String, Int, ForwardInitializer) -> EventLoopFuture<any Channel>
    let loop: any EventLoop
    let remotePort: Int
    let username = UUID().uuidString
    let password = SSHIdentity.generateSeed().base64EncodedString()
    private let connect: Connector
    private var listeners: [any Channel] = []
    private var streams: [UUID: ForwardStream] = [:]
    private var stopped = false
    private var pendingBytes = 0
    private var stopFuture: EventLoopFuture<Void>?
    // With NIOSSH 0.15.1, each unread child also has a bounded 64-packet SSH receive window.
    static let maximumStreams = 12
    static let maximumQueuedBytes = 16 * 1024 * 1024

    init(loop: any EventLoop, remotePort: Int, connect: @escaping Connector) {
        self.loop = loop; self.remotePort = remotePort; self.connect = connect
    }

    func start() -> EventLoopFuture<SSHPreviewTunnel> {
        bind(socks: true).flatMap { [self] proxy in
            bind(socks: false).flatMapThrowing { [self] safari in
                guard !stopped, let proxyPort = proxy.localAddress?.port, let safariPort = safari.localAddress?.port else {
                    throw PreviewError.disconnected
                }
                return SSHPreviewTunnel(owner: self, proxyPort: proxyPort, safariPort: safariPort)
            }
        }.flatMapError { [self] error in stop(); return loop.makeFailedFuture(error) }
    }

    private func bind(socks: Bool) -> EventLoopFuture<any Channel> {
        guard !stopped else { return loop.makeFailedFuture(PreviewError.disconnected) }
        return ServerBootstrap(group: loop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024))
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 32 * 1024, high: 64 * 1024))
            .childChannelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeFailedFuture(PreviewError.disconnected) }
                return channel.eventLoop.makeCompletedFuture {
                    guard !self.stopped, self.streams.count < Self.maximumStreams else { throw PreviewError.limitReached }
                    let stream = ForwardStream(owner: self, local: channel, socks: socks)
                    self.streams[stream.id] = stream
                    try channel.pipeline.syncOperations.addHandler(LocalForwardHandler(stream: stream))
                }
            }.bind(host: "127.0.0.1", port: 0).flatMapThrowing { [self] channel in
                if stopped { channel.close(promise: nil); throw PreviewError.disconnected }
                listeners.append(channel)
                return channel
            }
    }

    func open(host: String, port: Int, stream: ForwardStream) -> EventLoopFuture<any Channel> {
        guard !stopped else { return loop.makeFailedFuture(PreviewError.disconnected) }
        return connect(host, port, ForwardInitializer(loop: loop, install: { [weak stream] channel in
            channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
                channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            }.flatMapThrowing { [weak stream] in
                guard let stream, !stream.finished else { throw PreviewError.disconnected }
                stream.remote = channel
                try channel.pipeline.syncOperations.addHandler(SSHForwardHandler(stream: stream))
            }
        }))
    }

    func reserve(_ count: Int) -> Bool {
        guard !stopped, count <= Self.maximumQueuedBytes - pendingBytes else { return false }
        pendingBytes += count
        return true
    }
    func release(_ count: Int) { pendingBytes -= count }
    func remove(_ id: UUID) { streams.removeValue(forKey: id) }

    func stop() {
        guard !stopped else { return }
        stopped = true
        let futures = listeners.map(\.closeFuture) + streams.values.flatMap(\.closeFutures)
        stopFuture = EventLoopFuture.andAllSucceed(futures, on: loop)
        for listener in listeners { listener.close(promise: nil) }
        for stream in Array(streams.values) { stream.finish() }
    }
    func closed() -> EventLoopFuture<Void> {
        stopFuture ?? loop.makeSucceededVoidFuture()
    }
}

private enum ForwardSide { case local, remote }

final class ForwardStream: @unchecked Sendable {
    let id = UUID()
    private weak var owner: PreviewForwarder?
    private var local: (any Channel)?
    var remote: (any Channel)?
    private var handshake: SOCKSHandshake?
    private var input = ByteBuffer()
    private var opening = false
    private var ready = false
    private(set) var finished = false
    private var deadline: Scheduled<Void>?
    private var pending = [0, 0]
    private var reading = [false, false]
    private var eof = [false, false]
    private var outputClosed = [false, false]
    private var lastWrite: [EventLoopFuture<Void>?] = [nil, nil]
    var closeFutures: [EventLoopFuture<Void>] { [local, remote].compactMap { $0?.closeFuture } }

    init(owner: PreviewForwarder, local: any Channel, socks: Bool) {
        self.owner = owner; self.local = local
        handshake = socks ? SOCKSHandshake(username: owner.username, password: owner.password) : nil
    }

    func active() {
        guard let owner else { finish(); return }
        deadline = owner.loop.scheduleTask(in: .seconds(15)) { [weak self] in self?.finish() }
        if handshake == nil { open(host: "localhost", port: owner.remotePort) }
        else { read(.local) }
    }

    func receiveLocal(_ bytes: ByteBuffer) {
        if ready { relay(bytes, from: .local); return }
        guard !finished, input.readableBytes + bytes.readableBytes <= 64 * 1024 else { finish(); return }
        var bytes = bytes; input.writeBuffer(&bytes)
        guard !opening else { return }
        do {
            while let step = try handshake?.next(&input) {
                switch step {
                case .reply(let bytes, let close):
                    let write = local?.writeAndFlush(ByteBuffer(bytes: bytes))
                    if close { opening = true; write?.whenComplete { [weak self] _ in self?.finish() }; return }
                case .connect(let host, let port):
                    open(host: host, port: port)
                    return
                }
            }
            input.discardReadBytes()
        } catch { finish() }
    }

    private func open(host: String, port: Int) {
        guard let owner else { finish(); return }
        opening = true
        owner.open(host: host, port: port, stream: self).whenComplete { [weak self] result in
            guard let self else { if case .success(let channel) = result { channel.close(promise: nil) }; return }
            guard !finished else { if case .success(let channel) = result { channel.close(promise: nil) }; return }
            switch result {
            case .success:
                deadline?.cancel(); deadline = nil
                ready = true; opening = false
                if handshake != nil {
                    local?.writeAndFlush(ByteBuffer(bytes: SOCKSHandshake.connectedReply), promise: nil)
                }
                if input.readableBytes > 0 { relay(input, from: .local); input.clear() }
                read(.local); read(.remote)
            case .failure:
                if handshake != nil {
                    local?.writeAndFlush(ByteBuffer(bytes: SOCKSHandshake.failedReply)).whenComplete { [weak self] _ in self?.finish() }
                } else { finish() }
            }
        }
    }

    fileprivate func relay(_ bytes: ByteBuffer, from side: ForwardSide) {
        guard ready, !finished, let owner, let destination = channel(opposite(side)) else { return }
        let count = bytes.readableBytes
        let index = index(side)
        guard count <= 4 * 1024 * 1024 - pending[index], owner.reserve(count) else { finish(); return }
        pending[index] += count
        let write: EventLoopFuture<Void>
        if side == .local { write = destination.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bytes))) }
        else { write = destination.writeAndFlush(bytes) }
        lastWrite[index] = write
        write.whenComplete { [weak self, weak owner] result in
            owner?.release(count)
            guard let self else { return }
            pending[index] -= count
            if case .failure = result { finish() } else { read(side) }
        }
    }

    fileprivate func readComplete(_ side: ForwardSide) { reading[index(side)] = false; read(side) }
    fileprivate func writable(_ side: ForwardSide) { read(opposite(side)) }
    private func read(_ side: ForwardSide) {
        let i = index(side)
        guard !finished, !eof[i], !reading[i], pending[i] == 0, let source = channel(side),
              (ready ? channel(opposite(side))?.isWritable == true : side == .local && !opening) else { return }
        reading[i] = true
        source.eventLoop.execute { [weak self] in if self?.finished == false { source.read() } }
    }

    fileprivate func inputClosed(_ side: ForwardSide) {
        eof[index(side)] = true
        guard ready, let destination = channel(opposite(side)) else { finish(); return }
        let flush = lastWrite[index(side)] ?? destination.eventLoop.makeSucceededVoidFuture()
        flush.whenComplete { [weak self] result in
            guard let self, !finished else { return }
            if case .failure = result { finish(); return }
            destination.close(mode: .output).whenComplete { [weak self] result in
                guard let self else { return }
                if case .failure = result { finish() }
                else {
                    outputClosed[index(side)] = true
                    if outputClosed.allSatisfy({ $0 }) { finish() }
                }
            }
        }
    }

    fileprivate func inactive(_ side: ForwardSide) {
        guard !finished else { return }
        if side == .remote, opening, !ready { return } // Channel-open rejection is answered by its promise.
        // Drain the final read's writes before closing the peer (notably HTTP close-delimited responses).
        let flush = lastWrite[index(side)]
        if let flush { flush.whenComplete { [weak self] _ in self?.finish() } }
        else { finish() }
    }
    func finish() {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        local?.close(promise: nil); remote?.close(promise: nil)
        local = nil; remote = nil
        owner?.remove(id)
    }
    func remoteError() { if ready { finish() } }
    private func channel(_ side: ForwardSide) -> (any Channel)? { side == .local ? local : remote }
    private func opposite(_ side: ForwardSide) -> ForwardSide { side == .local ? .remote : .local }
    private func index(_ side: ForwardSide) -> Int { side == .local ? 0 : 1 }
}

private final class LocalForwardHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let stream: ForwardStream
    init(stream: ForwardStream) { self.stream = stream }
    func channelActive(context: ChannelHandlerContext) { stream.active(); context.fireChannelActive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { stream.receiveLocal(unwrapInboundIn(data)) }
    func channelReadComplete(context: ChannelHandlerContext) { stream.readComplete(.local) }
    func channelWritabilityChanged(context: ChannelHandlerContext) { stream.writable(.local) }
    func channelInactive(context: ChannelHandlerContext) { stream.inactive(.local); context.fireChannelInactive() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed { stream.inputClosed(.local) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { stream.finish() }
}

private final class SSHForwardHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let stream: ForwardStream
    init(stream: ForwardStream) { self.stream = stream }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        if packet.type == .channel, case .byteBuffer(let buffer) = packet.data { stream.relay(buffer, from: .remote) }
    }
    func channelReadComplete(context: ChannelHandlerContext) { stream.readComplete(.remote) }
    func channelWritabilityChanged(context: ChannelHandlerContext) { stream.writable(.remote) }
    func channelInactive(context: ChannelHandlerContext) { stream.inactive(.remote); context.fireChannelInactive() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed { stream.inputClosed(.remote) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { stream.remoteError(); context.close(promise: nil) }
}
