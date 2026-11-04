import Foundation
import NIOCore
import NIOPosix

/// Test-only UDP NAT: drops traffic and changes its server-facing source port.
/// All mutable fields and handlers are confined to one event loop.
final class MoshRoamingProxy: @unchecked Sendable {
    let loop: any EventLoop
    let server: SocketAddress
    var front: (any Channel)?
    var back: (any Channel)?
    var client: SocketAddress?
    var enabled = true
    init(loop: any EventLoop, server: SocketAddress) { self.loop = loop; self.server = server }
    func start() -> EventLoopFuture<Int> {
        DatagramBootstrap(group: loop).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Handler(proxy: self, front: true)) }
        }.bind(host: "127.0.0.1", port: 0).flatMap { channel in
            self.front = channel
            return self.newBackend().map { channel.localAddress!.port! }
        }
    }
    private func newBackend() -> EventLoopFuture<Void> {
        DatagramBootstrap(group: loop).channelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Handler(proxy: self, front: false)) }
        }.bind(host: "127.0.0.1", port: 0).map { channel in
            self.back?.close(promise: nil); self.back = channel
        }
    }
    func interrupt() -> EventLoopFuture<Void> { loop.submit { self.enabled = false } }
    func restoreFromNewAddress() -> EventLoopFuture<Void> {
        loop.flatSubmit { self.newBackend().map { self.enabled = true } }
    }
    func close() { loop.execute { self.front?.close(promise: nil); self.back?.close(promise: nil); self.front = nil; self.back = nil } }
    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        unowned let proxy: MoshRoamingProxy
        let front: Bool
        init(proxy: MoshRoamingProxy, front: Bool) { self.proxy = proxy; self.front = front }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let packet = unwrapInboundIn(data)
            guard proxy.enabled else { return }
            if front {
                proxy.client = packet.remoteAddress
                proxy.back?.writeAndFlush(AddressedEnvelope(remoteAddress: proxy.server, data: packet.data), promise: nil)
            } else if packet.remoteAddress == proxy.server, let client = proxy.client {
                proxy.front?.writeAndFlush(AddressedEnvelope(remoteAddress: client, data: packet.data), promise: nil)
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: any Error) {}
    }
}
