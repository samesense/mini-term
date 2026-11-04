// Isolated iPad simulator probe. Uses generated SSH identity/host keys and a
// disposable host-side Mosh server; never reads a personal identity or connection.
import Crypto
import NIOCore
import NIOPosix
import NIOSSH

private final class MoshProbeBox<T>: @unchecked Sendable {
    let lock = NSLock(); var value: T
    init(_ value: T) { self.value = value }
    func access<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
private final class MoshProbeAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey] }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) { responsePromise.succeed(.success) }
}
private final class MoshProbeExec: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let bootstrap: String
    let starts: MoshProbeBox<Int>
    init(bootstrap: String, starts: MoshProbeBox<Int>) { self.bootstrap = bootstrap; self.starts = starts }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.PseudoTerminalRequest { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        else if let exec = event as? SSHChannelRequestEvent.ExecRequest, exec.command.contains("mosh-server new") {
            starts.access { $0 += 1 }
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            let channel = context.channel
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: bootstrap)))).flatMap {
                channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0))
            }.whenComplete { _ in channel.close(promise: nil) }
        } else if event is SSHChannelRequestEvent.ShellRequest {
            context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
}
@MainActor
private final class MoshProbeRunner: ObservableObject {
    @Published var model: TerminalSessionModel?
    var checks: [String] = [], failures: [String] = []
    var stage = "starting"
    func check(_ value: Bool, _ label: String) { checks.append(label); if !value { failures.append(label) } }
    func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<600 { if predicate() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw MoshError.engine
    }
    func run() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let parents = MoshProbeBox<[(any Channel)]>([])
        let starts = MoshProbeBox(0)
        var listener: (any Channel)?
        var account: String?
        defer {
            model?.disconnect(); listener?.close(promise: nil)
            parents.access { for channel in $0 { channel.close(promise: nil) }; $0.removeAll() }
            group.shutdownGracefully { _ in }
            if let account { try? KeychainStore().delete(account: account) }
            let report: [String: Any] = ["checks": checks.count, "failures": failures, "labels": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                .write(to: URL.documentsDirectory.appendingPathComponent("mosh-probe.json"))
        }
        do {
            guard let bootstrap = ProcessInfo.processInfo.environment["MINITERM_MOSH_TEST_BOOTSTRAP"] else { throw MoshError.bootstrap }
            let host = NIOSSHPrivateKey(ed25519Key: .init())
            let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                parents.access { $0.append(channel) }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .server(.init(hostKeys: [host], userAuthDelegate: MoshProbeAuth())), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                        guard type == .session else { return child.eventLoop.makeFailedFuture(MoshError.bootstrap) }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(MoshProbeExec(bootstrap: bootstrap, starts: starts))
                        }
                    }))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            listener = server
            let connection = try SSHConnection(host: "127.0.0.1", username: "fixture", port: server.localAddress!.port!)
            account = "host:\(connection.hostKeyAccount)"
            try KeychainStore().save(Data(String(openSSHPublicKey: host.publicKey).utf8), account: account!)
            let session = TerminalSessionModel(connection: connection, seed: SSHIdentity.generateSeed(), usesMosh: true)
            model = session
            session.start()
            try await wait { session.state == .connected && (session.terminalSession.readViewportText()?.contains("MOSH_SIM_READY") ?? false) }
            check(session.usesMosh, "Mosh selected and real remote screen rendered in Ghostty")
            check(session.sshToolsAvailable, "auxiliary SSH available")
            check(starts.access { $0 } == 1, "one Mosh bootstrap without a competing interactive shell")
            session.terminalSession.sendInput(Data("before-loss\r".utf8))
            try await wait { session.terminalSession.readViewportText()?.contains("REPLY:before-loss") ?? false }
            check(true, "Ghostty input crosses native Mosh transport")
            let id = session.id
            stage = "closing auxiliary SSH"
            parents.access { for channel in $0 { channel.close(promise: nil) }; $0.removeAll() }
            try await wait { !session.sshToolsAvailable }
            check(session.state == .connected, "SSH closure preserves Mosh terminal")
            session.terminalSession.sendInput(Data("after-ssh-loss\r".utf8))
            try await wait { session.terminalSession.readViewportText()?.contains("REPLY:after-ssh-loss") ?? false }
            check(true, "Mosh remains interactive after SSH socket closes")
            stage = "restoring auxiliary SSH"
            check(await session.checkConnectionAfterWake(), "wake preserves live Mosh model")
            try await wait { session.sshToolsAvailable }
            check(starts.access { $0 } == 1, "wake reconnects SSH tools without starting another Mosh server")
            check(session.id == id, "terminal identity retained across auxiliary reconnection")
            session.terminalSession.sendInput(Data("after-wake\r".utf8))
            try await wait { session.terminalSession.readViewportText()?.contains("REPLY:after-wake") ?? false }
            check(true, "terminal remains usable after wake check")
            let report = AppDiagnostics.text(session.diagnostics)
            let key = bootstrap.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            check(!key.isEmpty && !report.contains(key), "session key absent from diagnostics")
            session.terminalSession.sendInput(Data("quit\r".utf8))
            try await wait { session.state.isFinished }
            check(session.state == .disconnected, "remote clean exit reported without an SSH overwrite")
            try await Task.sleep(for: .milliseconds(100))
            check(session.state == .disconnected, "terminal final state remains stable")
            check(session.terminalSession.readViewportText()?.contains("REPLY:after-wake") ?? false, "final remote screen survives clean exit")
        } catch { failures.append("Mosh simulator probe failed at \(stage): \(type(of: error)); tools=\(model?.sshToolsAvailable ?? false), phase=\(model?.diagnostics.events.last?.phase.rawValue ?? "none")") }
    }
}
struct MoshProbeView: View {
    @StateObject private var runner = MoshProbeRunner()
    var body: some View {
        Group {
            if let model = runner.model { TerminalScreen(model: model) }
            else { ProgressView("Checking Mosh…") }
        }.task { await runner.run() }
    }
}
