#if os(macOS)
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import MiniTermCore

private final class SFTPTestAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey] }
    let key: NIOSSHPublicKey
    init(key: NIOSSHPublicKey) { self.key = key }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .publicKey(let offered) = request.request, offered.publicKey == key { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}

/// Test-only adapter to the OS's real OpenSSH SFTP server. No personal keys/config.
private final class OpenSFTPFixture: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let directory: URL
    let reject: Bool
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var running = false
    init(directory: URL, reject: Bool) { self.directory = directory; self.reject = reject }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let request = event as? SSHChannelRequestEvent.SubsystemRequest {
            guard request.subsystem == "sftp", !reject else { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); return }
            process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
            process.arguments = ["-d", directory.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let channel = context.channel
            output.fileHandleForReading.readabilityHandler = { handle in
                let bytes = handle.availableData
                channel.eventLoop.execute {
                    guard channel.isActive else { return }
                    if bytes.isEmpty { channel.close(promise: nil) }
                    else { channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes))), promise: nil) }
                }
            }
            do { try process.run(); running = true; context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            catch { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
        } else if event is SSHChannelRequestEvent.PseudoTerminalRequest || event is SSHChannelRequestEvent.ShellRequest {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = packet.data else { return }
        if running { try? input.fileHandleForWriting.write(contentsOf: Data(bytes.readableBytesView)) }
        else { context.writeAndFlush(data, promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        context.fireChannelInactive()
    }
}

private final class SFTPTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    func set(_ value: Bool) { lock.lock(); connected = value; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return connected }
}

struct SFTPIntegrationTests {
    private func withFixture(reject: Bool = false, test: (SSHTransport, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniTerm-SFTP-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = SSHIdentity.generateSeed()
        let key = try NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey(rawRepresentation: seed))
        let host = NIOSSHPrivateKey(ed25519Key: .init())
        let hostKey = String(openSSHPublicKey: host.publicKey)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .server(.init(hostKeys: [host], userAuthDelegate: SFTPTestAuth(key: key.publicKey))), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(SFTPError.unavailable) }
                    return child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(OpenSFTPFixture(directory: directory, reject: reject)) }
                }))
            }
        }.bind(host: "127.0.0.1", port: 0).get()
        defer { server.close(promise: nil) }
        let state = SFTPTestState()
        let transport = SSHTransport(callbacks: .init(state: { state.set($0 == .connected) }, output: { _ in }))
        defer { transport.disconnect() }
        transport.connect(to: try SSHConnection(host: "127.0.0.1", username: "fixture", port: server.localAddress!.port!), seed: seed) { key, completion in
            completion(key == hostKey ? .success(()) : .failure(TerminalError.hostKeyMismatch))
        }
        for _ in 0..<200 { if state.get() { break }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(state.get())
        try await test(transport, directory)
    }
    @Test func realOpenSSHBrowseRoundTripAndExclusiveUpload() async throws {
        try await withFixture { transport, root in
            let bytes = Data((0..<350_000).map { UInt8(truncatingIfNeeded: $0) })
            let source = root.appendingPathComponent("source '☃'.bin")
            try bytes.write(to: source)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
            let client = try await transport.startSFTP().get()
            defer { client.close() }
            let directory = try await client.realPath(".")
            let files = try await client.listDirectory(directory)
            #expect(files.first?.name == "folder")
            #expect(files.contains { $0.name == "source '☃'.bin" && $0.size == UInt64(bytes.count) && $0.isRegularFile })
            let download = root.appendingPathComponent("download.bin")
            try await client.download(source.path, to: download)
            #expect(try Data(contentsOf: download) == bytes)
            await #expect(throws: (any Error).self) { try await client.download(source.path, to: download) }
            #expect(try Data(contentsOf: download) == bytes)
            let link = root.appendingPathComponent("source-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            let canonicalLink = try await client.realPath(link.path)
            #expect(canonicalLink == directory + "/" + source.lastPathComponent)
            await #expect(throws: SFTPError.notRegularFile) { try await client.download(root.path, to: root.appendingPathComponent("directory-copy")) }
            let upload = root.appendingPathComponent("upload.bin")
            try await client.upload(source, to: upload.path)
            #expect(try Data(contentsOf: upload) == bytes)
            await #expect(throws: (any Error).self) { try await client.upload(download, to: upload.path) }
            #expect(try Data(contentsOf: upload) == bytes)
            let attrs = try FileManager.default.attributesOfItem(atPath: upload.path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.uint32Value == 0o600)
            try await transport.checkAlive().get()
            transport.setOutputPaused(true)
            #expect(try await client.stat(upload.path).size == UInt64(bytes.count))
            client.close()
            let next = try await transport.startSFTP().get()
            #expect(try await next.realPath(".") == directory)
            next.close()
        }
    }
    @Test func rejectedSFTPDoesNotCloseTerminalAndDisconnectFailsOperations() async throws {
        try await withFixture(reject: true) { transport, _ in
            await #expect(throws: SFTPError.self) { try await transport.startSFTP().get() }
            try await transport.checkAlive().get()
        }
        try await withFixture { transport, _ in
            let client = try await transport.startSFTP().get()
            transport.disconnect()
            await #expect(throws: (any Error).self) { try await client.realPath(".") }
        }
    }
    @Test func cancelledDownloadRemovesPartialAndLeavesSSHUsable() async throws {
        try await withFixture { transport, root in
            let source = root.appendingPathComponent("large.bin")
            try Data(repeating: 0xA5, count: 20 * 1024 * 1024).write(to: source)
            let client = try await transport.startSFTP().get()
            let destination = root.appendingPathComponent("cancelled.bin")
            let started = SFTPTestState()
            let task = Task { try await client.download(source.path, to: destination) { _, _ in started.set(true) } }
            for _ in 0..<500 { if started.get() { break }; try await Task.sleep(for: .milliseconds(2)) }
            #expect(started.get())
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            try await transport.checkAlive().get()
            let next = try await transport.startSFTP().get()
            #expect(try await next.stat(source.path).size == 20 * 1024 * 1024)
            next.close()
        }
    }
}
#endif
