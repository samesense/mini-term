import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import MiniTermCore

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

private enum ServerEvent: Sendable { case pty(TerminalSize), shell, exec(String), resize(TerminalSize) }

private final class PublicKeyServerAuth: NIOSSHServerUserAuthenticationDelegate {
    let acceptedKey: NIOSSHPublicKey
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey] }
    init(acceptedKey: NIOSSHPublicKey) { self.acceptedKey = acceptedKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let key) = request.request, key.publicKey == acceptedKey, request.username == "tester" {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}

private final class EchoShell: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let observer: @Sendable (ServerEvent) -> Void
    let rejectPTY: Bool
    let echoThenExit: Bool
    init(rejectPTY: Bool, echoThenExit: Bool = false, observer: @escaping @Sendable (ServerEvent) -> Void) {
        self.rejectPTY = rejectPTY; self.echoThenExit = echoThenExit; self.observer = observer
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let pty as SSHChannelRequestEvent.PseudoTerminalRequest:
            observer(.pty(TerminalSize(columns: pty.terminalCharacterWidth, rows: pty.terminalRowHeight,
                                       widthPixels: pty.terminalPixelWidth, heightPixels: pty.terminalPixelHeight)))
            if rejectPTY { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            else { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        case is SSHChannelRequestEvent.ShellRequest:
            observer(.shell)
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        case let exec as SSHChannelRequestEvent.ExecRequest:
            observer(.exec(exec.command))
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        case let size as SSHChannelRequestEvent.WindowChangeRequest:
            observer(.resize(TerminalSize(columns: size.terminalCharacterWidth, rows: size.terminalRowHeight,
                                          widthPixels: size.terminalPixelWidth, heightPixels: size.terminalPixelHeight)))
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = context.channel
        let write = channel.writeAndFlush(unwrapInboundIn(data))
        if echoThenExit { write.whenComplete { _ in channel.close(promise: nil) } }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

struct SSHIntegrationTests {
    private func server(group: MultiThreadedEventLoopGroup, clientSeed: Data, rejectPTY: Bool = false,
                        echoThenExit: Bool = false,
                        forward: (host: String, port: Int)? = nil,
                        observer: @escaping @Sendable (ServerEvent) -> Void = { _ in }) async throws -> (any Channel, String) {
        let host = NIOSSHPrivateKey(ed25519Key: .init())
        let clientKey = try NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey(rawRepresentation: clientSeed)).publicKey
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [host], userAuthDelegate: PublicKeyServerAuth(acceptedKey: clientKey))),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, type in
                        if case .directTCPIP(let target) = type, let forward,
                           target.targetHost == forward.host, target.targetPort == forward.port {
                            return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                                child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(ForwardEcho()) }
                            }
                        }
                        guard type == .session else { return child.eventLoop.makeFailedFuture(TerminalError.requestRejected) }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(EchoShell(rejectPTY: rejectPTY, echoThenExit: echoThenExit, observer: observer))
                        }
                    }
                ))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        return (server, String(openSSHPublicKey: host.publicKey))
    }

    @Test func authenticatedPTYByteBridgeResizeAndDisconnect() async throws {
        let seed = SSHIdentity.generateSeed()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let sawResize = TestSignal( "remote received rotated size")
        let events = Locked<[String]>([])
        let initial = TerminalSize(columns: 90, rows: 30)
        let rotated = TerminalSize(columns: 120, rows: 18, widthPixels: 1200, heightPixels: 600)
        let (server, hostKey) = try await server(group: group, clientSeed: seed) { event in
            switch event {
            case .pty(let size): events.withValue { $0.append("pty:\(size.columns)x\(size.rows)") }
            case .shell: events.withValue { $0.append("shell") }
            case .exec: Issue.record("Unexpected exec request")
            case .resize(let size): if size == rotated { sawResize.fulfill() }
            }
        }
        defer { server.close(promise: nil) }
        let connected = TestSignal( "shell acknowledged")
        let echoed = TestSignal( "opaque bytes echoed")
        let disconnected = TestSignal( "clean disconnect")
        let states = Locked<[ConnectionState]>([])
        let received = Locked(Data())
        // UTF-8 split across writes, ANSI, control bytes, NUL, and a large output burst.
        let chunks = [Data([0xF0, 0x9F]), Data([0x98, 0x80, 0, 0x1B, 0x5B, 0x41]), Data(repeating: 0x78, count: 100_000)]
        let expected = chunks.reduce(Data(), +)
        let transport = SSHTransport(callbacks: .init(state: { state in
            states.withValue { $0.append(state) }
            if state == .connected { connected.fulfill() }
            if state == .disconnected { disconnected.fulfill() }
            if case .failed(let message) = state { Issue.record("\(message)") }
        }, output: { data in
            let count = received.withValue { $0.append(data); return $0.count }
            if count == expected.count { echoed.fulfill() }
        }))
        transport.resize(initial)
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!), seed: seed) { key, completion in
            do {
                guard try SSHIdentity.checkHostKey(key, stored: hostKey) else { throw TerminalError.hostKeyRejected }
                completion(.success(()))
            } catch { completion(.failure(error)) }
        }
        try await fulfillment(of: [connected], timeout: 8)
        transport.setOutputPaused(true)
        for chunk in chunks { transport.send(chunk) }
        try await Task.sleep(for: .milliseconds(75))
        #expect(received.withValue { $0.isEmpty })
        transport.setOutputPaused(false)
        transport.resize(rotated)
        try await fulfillment(of: [echoed, sawResize], timeout: 8)
        #expect(received.withValue { $0 } == expected)
        #expect(events.withValue { $0 } == ["pty:90x30", "shell"])
        transport.disconnect()
        try await fulfillment(of: [disconnected], timeout: 3)
        #expect(states.withValue { $0 } == [.connecting, .verifyingHost, .authenticating, .openingShell, .connected, .disconnected])
    }

    @Test func hostKeyMismatchBlocksAuthenticationAndShell() async throws {
        let seed = SSHIdentity.generateSeed()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (server, _) = try await server(group: group, clientSeed: seed) { _ in Issue.record("Shell opened for untrusted host") }
        defer { server.close(promise: nil) }
        let failed = TestSignal( "host mismatch rejected")
        let transport = SSHTransport(callbacks: .init(state: { state in
            if case .failed(let message) = state {
                #expect(message.contains("HOST KEY CHANGED")); failed.fulfill()
            }
            #expect(state != .connected)
        }, output: { _ in Issue.record("Untrusted output") }))
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!), seed: seed) { _, completion in
            completion(.failure(TerminalError.hostKeyMismatch))
        }
        try await fulfillment(of: [failed], timeout: 8)
    }

    @Test func ptyFailureDoesNotReportConnected() async throws {
        let seed = SSHIdentity.generateSeed()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (server, hostKey) = try await server(group: group, clientSeed: seed, rejectPTY: true)
        defer { server.close(promise: nil) }
        let failed = TestSignal( "PTY rejection")
        let transport = SSHTransport(callbacks: .init(state: { state in
            if case .failed(let message) = state { #expect(message.contains("rejected")); failed.fulfill() }
            #expect(state != .connected)
        }, output: { _ in }))
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!), seed: seed) { key, completion in
            completion(key == hostKey ? .success(()) : .failure(TerminalError.hostKeyMismatch))
        }
        try await fulfillment(of: [failed], timeout: 8)
    }

    @Test func tmuxUsesPTYThenExec() async throws {
        let seed = SSHIdentity.generateSeed()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let events = Locked<[String]>([])
        let (server, hostKey) = try await server(group: group, clientSeed: seed) { event in
            switch event {
            case .pty: events.withValue { $0.append("pty") }
            case .exec(let command): events.withValue { $0.append(command) }
            case .shell: Issue.record("tmux must use exec rather than typing into a shell")
            case .resize: break
            }
        }
        defer { server.close(promise: nil) }
        let connected = TestSignal("tmux started")
        let transport = SSHTransport(callbacks: .init(state: { state in
            if state == .connected { connected.fulfill() }
            if case .failed(let message) = state { Issue.record("\(message)") }
        }, output: { _ in }))
        let connection = try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!, tmuxSession: "codex")
        transport.connect(to: connection, seed: seed) { key, completion in
            completion(key == hostKey ? .success(()) : .failure(TerminalError.hostKeyMismatch))
        }
        try await connected.wait(timeout: 8)
        #expect(events.withValue { $0 } == ["pty", connection.startupCommand!])
        transport.disconnect()
    }

    @Test func cancellationWhileAwaitingHostTrustIsFinal() async throws {
        let seed = SSHIdentity.generateSeed()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (server, _) = try await server(group: group, clientSeed: seed) { _ in Issue.record("Cancelled connection opened a shell") }
        defer { server.close(promise: nil) }
        let verifying = TestSignal("waiting for human trust decision")
        let disconnected = TestSignal("cancelled")
        let completion = Locked<(@Sendable (Result<Void, Error>) -> Void)?>(nil)
        let states = Locked<[ConnectionState]>([])
        let transport = SSHTransport(callbacks: .init(state: { state in
            states.withValue { $0.append(state) }
            if state == .disconnected { disconnected.fulfill() }
        }, output: { _ in Issue.record("Cancelled output") }))
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!), seed: seed) { _, callback in
            completion.withValue { $0 = callback }
            verifying.fulfill()
        }
        try await verifying.wait(timeout: 8)
        transport.disconnect()
        try await disconnected.wait(timeout: 3)
        // A late confirmation must not revive a cancelled transport.
        completion.withValue { $0 }?(.success(()))
        try await Task.sleep(for: .milliseconds(50))
        #expect(states.withValue { $0 } == [.connecting, .verifyingHost, .disconnected])
    }

}

private final class TestSignal: Sendable {
    let name: String
    private let fulfilled = Locked(false)
    init(_ name: String) { self.name = name }
    func fulfill() { fulfilled.withValue { $0 = true } }
    func wait(timeout: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !fulfilled.withValue({ $0 }) {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out: \(name)")
                throw TerminalError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private func fulfillment(of signals: [TestSignal], timeout: Double) async throws {
    for signal in signals { try await signal.wait(timeout: timeout) }
}

private final class ForwardEcho: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed { context.close(mode: .output, promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
}

private final class PreviewTestReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let bytes = Locked(Data())
    private let ended = Locked(false)
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytes.withValue { $0.append(contentsOf: buffer.readableBytesView) }
    }
    func channelInactive(context: ChannelHandlerContext) { ended.withValue { $0 = true }; context.fireChannelInactive() }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func take(_ count: Int) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
            if let data = bytes.withValue({ bytes -> Data? in
                guard bytes.count >= count else { return nil }
                let data = Data(Array(bytes.prefix(count))); bytes.removeFirst(count); return data
            }) { return data }
            if ended.withValue({ $0 }) || ContinuousClock.now >= deadline { throw TerminalError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

extension SSHIntegrationTests {
    @Test func remoteExitPreservesFinalOutputWhileRendererIsPaused() async throws {
        let seed = SSHIdentity.generateSeed()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (server, hostKey) = try await server(group: group, clientSeed: seed, echoThenExit: true)
        defer { server.close(promise: nil) }
        let connected = TestSignal("shell ready")
        let ended = TestSignal("remote exit")
        let output = Locked(Data())
        let transport = SSHTransport(callbacks: .init(state: { state in
            if state == .connected { connected.fulfill() }
            if state.isFinished { ended.fulfill() }
        }, output: { data in output.withValue { $0.append(data) } }))
        defer { transport.disconnect() }
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!), seed: seed) { key, completion in
            completion(key == hostKey ? .success(()) : .failure(TerminalError.hostKeyMismatch))
        }
        try await connected.wait(timeout: 8)
        transport.setOutputPaused(true)
        let final = Data("final output before remote exit\r\n".utf8)
        transport.send(final)
        try await ended.wait(timeout: 8)
        #expect(output.withValue { $0 } == final)
    }

    private func connectedPreview(group: MultiThreadedEventLoopGroup) async throws -> (SSHTransport, any Channel) {
        let seed = SSHIdentity.generateSeed()
        let (server, hostKey) = try await server(group: group, clientSeed: seed, forward: ("localhost", 3000))
        let connected = TestSignal("preview SSH authenticated")
        let transport = SSHTransport(callbacks: .init(state: { state in
            if state == .connected { connected.fulfill() }
        }, output: { _ in }))
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "tester", port: server.localAddress!.port!), seed: seed) { key, completion in
            completion(key == hostKey ? .success(()) : .failure(TerminalError.hostKeyMismatch))
        }
        try await connected.wait(timeout: 8)
        return (transport, server)
    }

    private func client(port: Int, group: MultiThreadedEventLoopGroup) async throws -> (any Channel, PreviewTestReader) {
        let reader = PreviewTestReader()
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in channel.pipeline.addHandler(reader) }
            .connect(host: "127.0.0.1", port: port).get()
        return (channel, reader)
    }

    private func socks(tunnel: SSHPreviewTunnel, group: MultiThreadedEventLoopGroup, port: Int = 3000, host: String = "localhost") async throws -> (any Channel, PreviewTestReader) {
        let (channel, reader) = try await client(port: tunnel.proxyPort, group: group)
        try await channel.writeAndFlush(ByteBuffer(bytes: [5, 1, 2])).get()
        #expect(try await reader.take(2) == Data([5, 2]))
        let user = Array(tunnel.username.utf8), password = Array(tunnel.password.utf8)
        try await channel.writeAndFlush(ByteBuffer(bytes: [1, UInt8(user.count)] + user + [UInt8(password.count)] + password)).get()
        #expect(try await reader.take(2) == Data([1, 0]))
        let hostname = Array(host.utf8)
        try await channel.writeAndFlush(ByteBuffer(bytes: [5, 1, 0, 3, UInt8(hostname.count)] + hostname + [UInt8(port >> 8), UInt8(port & 255)])).get()
        let reply = try await reader.take(10)
        #expect(reply[1] == (port == 3000 ? 0 : 5))
        return (channel, reader)
    }

    @Test func previewSOCKSAndSafariShareSSHAndSurvivePausedTerminal() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (transport, server) = try await connectedPreview(group: group)
        defer { transport.disconnect(); server.close(promise: nil) }
        let tunnel = try await transport.startPreview(remotePort: 3000).get()
        #expect(tunnel.proxyPort != tunnel.safariPort)
        transport.setOutputPaused(true)
        let (socksChannel, socksReader) = try await socks(tunnel: tunnel, group: group, host: PreviewAddress.host)
        let (safari, safariReader) = try await client(port: tunnel.safariPort, group: group)
        defer { socksChannel.close(promise: nil); safari.close(promise: nil) }
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        try await socksChannel.writeAndFlush(ByteBuffer(bytes: payload)).get()
        #expect(try await socksReader.take(payload.count) == payload)
        let request = Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        try await safari.writeAndFlush(ByteBuffer(bytes: request)).get()
        #expect(try await safariReader.take(request.count) == request)
        // A denied destination affects only that forwarded stream.
        let (denied, _) = try await socks(tunnel: tunnel, group: group, port: 3001)
        denied.close(promise: nil)
        try await socksChannel.writeAndFlush(ByteBuffer(bytes: [42])).get()
        #expect(try await socksReader.take(1) == Data([42]))
        // Half-close after a request preserves its final response bytes.
        try await socksChannel.close(mode: .output).get()
        try await tunnel.close().get()
        transport.setOutputPaused(false)
        // Closing preview leaves SSH authenticated and allows a new preview.
        let replacement = try await transport.startPreview(remotePort: 3000).get()
        try await replacement.close().get()
    }

    @Test func previewRejectsBeforeAuthenticationAndInvalidPorts() async throws {
        let transport = SSHTransport(callbacks: .init(state: { _ in }, output: { _ in }))
        do { _ = try await transport.startPreview(remotePort: 3000).get(); Issue.record("Unauthenticated forwarding") }
        catch { #expect(error as? PreviewError == .disconnected) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (connected, server) = try await connectedPreview(group: group)
        defer { connected.disconnect(); server.close(promise: nil) }
        for port in [0, -1, 65536, Int.max] {
            do { _ = try await connected.startPreview(remotePort: port).get(); Issue.record("Invalid port accepted") }
            catch { #expect(error as? PreviewError == .invalidPort) }
        }
    }

    @Test func previewReplacementAndDisconnectCloseListenersAndStreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (transport, server) = try await connectedPreview(group: group)
        defer { transport.disconnect(); server.close(promise: nil) }
        let first = try await transport.startPreview(remotePort: 3000).get()
        let (channel, reader) = try await client(port: first.safariPort, group: group)
        try await channel.writeAndFlush(ByteBuffer(bytes: [23])).get()
        #expect(try await reader.take(1) == Data([23]))
        let second = try await transport.startPreview(remotePort: 3000).get()
        try await first.close().get()
        try await channel.closeFuture.get()
        do { let (unexpected, _) = try await client(port: first.proxyPort, group: group); unexpected.close(promise: nil); Issue.record("Old listener remained open") }
        catch {}
        transport.disconnect()
        try await second.close().get()
        do { let (unexpected, _) = try await client(port: second.safariPort, group: group); unexpected.close(promise: nil); Issue.record("Disconnected listener remained open") }
        catch {}
    }

    @Test func previewRejectsBadCredentialsAndBoundsPendingHandshakes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let (transport, server) = try await connectedPreview(group: group)
        defer { transport.disconnect(); server.close(promise: nil) }
        let tunnel = try await transport.startPreview(remotePort: 3000).get()
        let (bad, reader) = try await client(port: tunnel.proxyPort, group: group)
        try await bad.writeAndFlush(ByteBuffer(bytes: [5, 1, 2, 1, 1, 120, 1, 121])).get()
        #expect(try await reader.take(4) == Data([5, 2, 1, 1]))
        try await bad.closeFuture.get()
        var pending: [any Channel] = []
        defer { for channel in pending { channel.close(promise: nil) } }
        for _ in 0..<PreviewForwarder.maximumStreams {
            let (channel, _) = try await client(port: tunnel.proxyPort, group: group)
            pending.append(channel)
        }
        let (overLimit, _) = try await client(port: tunnel.proxyPort, group: group)
        try await overLimit.closeFuture.get()
        try await tunnel.close().get()
        for channel in pending { try await channel.closeFuture.get() }
    }
}
