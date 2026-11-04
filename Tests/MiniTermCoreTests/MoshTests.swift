import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import NIOSSH
import Testing
@testable import MiniTermCore

private let testKey = Data(repeating: 7, count: 16).base64EncodedString().replacingOccurrences(of: "=", with: "")
private func bootstrapOutput(_ line: String = "") -> Data {
    Data((line.isEmpty ? "MOSH CONNECT 60001 \(testKey)\r\n" : line).utf8)
}
private final class MoshEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var connected = false
    private var ended = false
    private var stalled = false
    func network(_ available: Bool) { lock.lock(); stalled = !available; lock.unlock() }
    func isStalled() -> Bool { lock.lock(); defer { lock.unlock() }; return stalled }
    private var error: MoshError?
    func output(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    func ready() { lock.lock(); connected = true; lock.unlock() }
    func finish(_ error: MoshError?) { lock.lock(); ended = true; self.error = error; lock.unlock() }
    func snapshot() -> (String, Bool, Bool, MoshError?) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: bytes, as: UTF8.self), connected, ended, error)
    }
}
private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "Mosh condition timed out")
}

struct MoshTests {
    @Test func bootstrapStrictlyParsesAndRedactsSecrets() throws {
        let b = try MoshBootstrap(output: bootstrapOutput(), ip: "127.0.0.1")
        #expect(b.port == 60001)
        #expect(!String(describing: b).contains(testKey))
        #expect(!String(reflecting: b).contains(testKey))
        #expect(!String(reflecting: Mirror(reflecting: b).children.map { String(describing: $0.value) }).contains(testKey))
        for line in ["MOSH CONNECT 0 \(testKey)", "MOSH CONNECT 65536 \(testKey)", "MOSH CONNECT 60001 bad",
                     "MOSH CONNECT 60001 \(testKey) extra", "MOSH CONNECT  60001 \(testKey)",
                     "MOSH CONNECT 60001 $(id)", "MOSH CONNECT 60001 \(String(repeating: "/", count: 22))",
                     "banner only", String(repeating: "x", count: 16_385),
                     "MOSH CONNECT 60001 \(testKey)\nMOSH CONNECT 60002 \(testKey)"] {
            #expect(throws: MoshError.self) { try MoshBootstrap(output: bootstrapOutput(line), ip: "127.0.0.1") }
        }
    }
    @Test func commandUsesValidatedTmuxNameAndHomebrewPath() throws {
        let connection = try SSHConnection(host: "example", username: "me", port: 22, tmuxSession: "work-1")
        let command = MoshBootstrap.command(for: connection)
        #expect(command.contains("/opt/homebrew/bin:/usr/local/bin:"))
        #expect(command.hasSuffix("-- tmux new-session -A -s work-1'"))
        #expect(!command.contains(testKey))
        #expect(!MoshBootstrap.command(for: try SSHConnection(host: "x", username: "y", port: 22)).contains("tmux"))
    }
    @Test func bootstrapChannelRequiresSuccessfulExitAndKeepsSecretOutOfTerminal() throws {
        let channel = EmbeddedChannel()
        let handler = MoshBootstrapHandler(loop: channel.eventLoop, ip: "127.0.0.1", command: "mosh-server new", size: .init())
        try channel.pipeline.syncOperations.addHandler(handler)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        channel.pipeline.fireUserInboundEventTriggered(ChannelSuccessEvent())
        for fragment in ["banner\r\nMOSH CON", "NECT 60001 \(testKey)\r\n"] {
            try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: fragment))))
        }
        channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
        try channel.close().wait()
        #expect(try handler.result.futureResult.wait().port == 60001)
        #expect(try channel.readInbound(as: SSHChannelData.self) == nil)
    }
    @Test func rejectedAndOversizedBootstrapFail() throws {
        for oversized in [false, true] {
            let channel = EmbeddedChannel()
            let h = MoshBootstrapHandler(loop: channel.eventLoop, ip: "127.0.0.1", command: "test", size: .init())
            try channel.pipeline.syncOperations.addHandler(h)
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
            if oversized {
                try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(repeating: 65, count: 16_385))))
            } else { channel.pipeline.fireUserInboundEventTriggered(ChannelFailureEvent()) }
            #expect(throws: MoshError.self) { try h.result.futureResult.wait() }
            _ = try? channel.finish()
        }
    }
    @Test func nativeRejectsHostnameAndCancellationIsBounded() async throws {
        let callbacks = MoshCallbacks(output: { _ in }, connected: {}, ended: { _ in })
        #expect(throws: MoshError.self) { try MoshTransport(bootstrap: MoshBootstrap(output: bootstrapOutput(), ip: "localhost"), callbacks: callbacks) }
        let events = MoshEvents()
        let transport = try MoshTransport(bootstrap: MoshBootstrap(output: bootstrapOutput(), ip: "127.0.0.1"), callbacks: .init(
            output: { events.output($0) }, connected: { events.ready() }, ended: { events.finish($0) }, networkAvailable: { events.network($0) }))
        transport.start(); transport.start() // A duplicate start must not create another worker.
        transport.disconnect()
        try await eventually { events.snapshot().2 }
        #expect(events.snapshot().3 == nil)
    }
    @Test func inputOverflowFailsExplicitly() async throws {
        let events = MoshEvents()
        let transport = try MoshTransport(bootstrap: MoshBootstrap(output: bootstrapOutput(), ip: "127.0.0.1"), callbacks: .init(
            output: { events.output($0) }, connected: { events.ready() }, ended: { events.finish($0) }, networkAvailable: { events.network($0) }))
        transport.send(Data(repeating: 65, count: 1_048_577)); transport.start()
        try await eventually { events.snapshot().2 }
        if case .inputOverflow? = events.snapshot().3 {} else { Issue.record("Expected input overflow") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOSH_TEST_SERVER"] != nil))
    func realServerInputResizeRoamingAndCleanExit() async throws {
        let server = Process()
        server.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOSH_TEST_SERVER"]!)
        server.arguments = ["new", "-i", "127.0.0.1", "-c", "256", "-l", "LANG=en_US.UTF-8", "--", "/bin/sh", "-c",
            "stty -echo; printf 'MOSH_REAL_READY\\n'; while IFS= read -r line; do case \"$line\" in size) stty size;; quit) exit 0;; *) printf 'REPLY:%s\\n' \"$line\";; esac; done"]
        var environment = ProcessInfo.processInfo.environment
        environment["MOSH_SERVER_NETWORK_TMOUT"] = "20"
        server.environment = environment
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = pipe
        try server.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        server.waitUntilExit()
        #expect(server.terminationStatus == 0)
        let serverBootstrap = try MoshBootstrap(output: output, ip: "127.0.0.1")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let proxy = MoshRoamingProxy(loop: group.next(), server: try SocketAddress(ipAddress: "127.0.0.1", port: Int(serverBootstrap.port)))
        let proxyPort = try await proxy.start().get()
        defer { proxy.close() }
        let bootstrap = try MoshBootstrap(output: Data("MOSH CONNECT \(proxyPort) \(serverBootstrap.key)\n".utf8), ip: "127.0.0.1")
        let events = MoshEvents()
        let transport = try MoshTransport(bootstrap: bootstrap, callbacks: .init(output: { events.output($0) }, connected: { events.ready() }, ended: { events.finish($0) }, networkAvailable: { events.network($0) }))
        defer { transport.disconnect() }
        transport.start()
        try await eventually { events.snapshot().1 && events.snapshot().0.contains("MOSH_REAL_READY") }
        transport.send(Data("hello\r".utf8))
        try await eventually { events.snapshot().0.contains("REPLY:hello") }
        transport.send(Data("café🐱\r".utf8))
        try await eventually { events.snapshot().0.contains("REPLY:café🐱") }
        transport.resize(.init(columns: 91, rows: 31))
        try await Task.sleep(for: .milliseconds(300))
        transport.send(Data("size\r".utf8))
        try await eventually { events.snapshot().0.contains("31 91") }
        transport.setOutputPaused(true)
        transport.send(Data("held-output\r".utf8))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!events.snapshot().0.contains("REPLY:held-output"))
        transport.setOutputPaused(false)
        try await eventually { events.snapshot().0.contains("REPLY:held-output") }
        try await proxy.interrupt().get()
        transport.send(Data("queued-offline\r".utf8))
        try await Task.sleep(for: .seconds(4))
        #expect(events.isStalled())
        #expect(!events.snapshot().2)
        #expect(!events.snapshot().0.contains("REPLY:queued-offline"))
        try await proxy.restoreFromNewAddress().get()
        try await eventually { events.snapshot().0.contains("REPLY:queued-offline") && !events.isStalled() }
        transport.send(Data("after-roaming\r".utf8))
        try await eventually { events.snapshot().0.contains("REPLY:after-roaming") }
        transport.send(Data("quit\r".utf8))
        try await eventually { events.snapshot().2 }
        #expect(events.snapshot().3 == nil)
    }
}
