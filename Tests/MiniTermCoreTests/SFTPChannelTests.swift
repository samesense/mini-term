import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import MiniTermCore

struct SFTPChannelTests {
    private func start(version: UInt32 = 3) throws -> (EmbeddedEventLoop, EmbeddedChannel, SFTPHandler) {
        let loop = EmbeddedEventLoop()
        let handler = SFTPHandler(loop: loop)
        let channel = EmbeddedChannel(handler: handler, loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        _ = try channel.readOutbound(as: SSHChannelData.self)
        var data = ByteBuffer(); data.writeInteger(version)
        try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(SFTPPacket.encode(type: 2, payload: data))))
        return (loop, channel, handler)
    }
    @Test func rejectsUnsupportedVersion() throws {
        let (_, channel, handler) = try start(version: 4)
        #expect(throws: SFTPError.unavailable) { try handler.ready.futureResult.wait() }
        #expect(!channel.isActive)
        _ = try? channel.finish()
    }
    @Test func boundedRequestsAndCloseFailEveryPendingPromise() throws {
        let (loop, channel, handler) = try start()
        let client = try handler.ready.futureResult.wait()
        let requests = (0..<16).map { _ in handler.request(16, ByteBuffer()) }
        #expect(throws: SFTPError.limitReached) { try handler.request(16, ByteBuffer()).wait() }
        client.close(); loop.run()
        for request in requests { #expect(throws: SFTPError.disconnected) { try request.wait() } }
        #expect(!channel.isActive)
        _ = try? channel.finish()
    }
    @Test func timeoutClosesSubsystemAndFailsPendingRequests() throws {
        let (loop, channel, handler) = try start()
        _ = try handler.ready.futureResult.wait()
        let request = handler.request(16, ByteBuffer())
        loop.advanceTime(by: .seconds(16))
        #expect(throws: SFTPError.timedOut) { try request.wait() }
        #expect(!channel.isActive)
        _ = try? channel.finish()
    }
    @Test func wrongRequestIdentifierAndMalformedStatusFailClosed() throws {
        for invalidID in [true, false] {
            let (_, channel, handler) = try start()
            _ = try handler.ready.futureResult.wait()
            let request = handler.request(4, ByteBuffer())
            var status = ByteBuffer(); status.writeInteger(UInt32(0)) // missing v3 message/language strings
            try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(SFTPPacket.encode(type: 101, id: invalidID ? 999 : 1, payload: status))))
            #expect(throws: SFTPError.malformed) { try request.wait() }
            #expect(!channel.isActive)
            _ = try? channel.finish()
        }
    }
}
