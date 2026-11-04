import Foundation
import NIOCore
import NIOSSH

public enum MoshError: LocalizedError, Sendable {
    case bootstrap, invalidBootstrap, udpUnavailable, engine, inputOverflow
    public var errorDescription: String? {
        switch self {
        case .bootstrap: "Could not start mosh-server. Install Mosh on the Mac (brew install mosh), and allow SSH command execution."
        case .invalidBootstrap: "The Mac returned an invalid Mosh startup response."
        case .udpUnavailable: "Mosh received no response. Allow UDP ports 60000–61000 to the Mac, or connect over Tailscale. SSH alone cannot carry Mosh traffic."
        case .engine: "The Mosh session ended unexpectedly. Reconnect to resume your tmux session."
        case .inputOverflow: "Mosh input exceeded its 1 MiB queue limit. The session was closed to avoid losing input."
        }
    }
}

/// An ephemeral session secret. Deliberately redacted in descriptions/reflection and never persisted.
public struct MoshBootstrap: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let ip: String
    public let port: UInt16
    let key: String
    public var description: String { "MoshBootstrap(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["credentials": "<redacted>"]) }

    public init(output: Data, ip: String) throws {
        guard output.count <= 16_384, let text = String(data: output, encoding: .utf8) else { throw MoshError.invalidBootstrap }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidates = lines.filter { $0.hasPrefix("MOSH CONNECT ") }
        guard candidates.count == 1 else { throw MoshError.invalidBootstrap }
        let parts = candidates[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4, let port = UInt16(parts[2]), port > 0 else { throw MoshError.invalidBootstrap }
        let key = String(parts[3])
        guard key.utf8.count == 22, let decoded = Data(base64Encoded: key + "=="), decoded.count == 16,
              decoded.base64EncodedString() == key + "==" else { throw MoshError.invalidBootstrap }
        self.ip = ip; self.port = port; self.key = key
    }

    public static func command(for connection: SSHConnection) -> String {
        // tmux names were restricted to letters, digits, '-' and '_' by SSHConnection.
        let command = "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; export PATH; exec mosh-server new -s -c 256 -l LANG=en_US.UTF-8"
        let tmux = connection.tmuxSession.map { " -- tmux new-session -A -s \($0)" } ?? ""
        return "exec /bin/sh -c '\(command)\(tmux)'"
    }
}

// Every method and scheduled completion is confined to the parent SSH event loop.
final class MoshBootstrapHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let result: EventLoopPromise<MoshBootstrap>
    private let ip: String
    private let command: String
    private let size: TerminalSize
    private var bytes = Data()
    private var replies = 0
    private var exitStatus: Int?
    private var completed = false
    private var timeout: Scheduled<Void>?
    private weak var channel: (any Channel)?
    init(loop: any EventLoop, ip: String, command: String, size: TerminalSize) {
        result = loop.makePromise(); self.ip = ip; self.command = command; self.size = size
    }
    func channelActive(context: ChannelHandlerContext) {
        channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(20)) { [weak self] in self?.fail() }
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: size.columns, terminalRowHeight: size.rows,
            terminalPixelWidth: size.widthPixels, terminalPixelHeight: size.heightPixels, terminalModes: .init([:])), promise: nil)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            replies += 1
            if replies == 1 { context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil) }
        case is ChannelFailureEvent: fail()
        case let status as SSHChannelRequestEvent.ExitStatus: exitStatus = status.exitStatus
        case ChannelEvent.inputClosed: context.close(promise: nil)
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard !completed, case .byteBuffer(let buffer) = packet.data else { return }
        guard buffer.readableBytes <= 16_384 - bytes.count else { fail(); return }
        bytes.append(contentsOf: buffer.readableBytesView)
    }
    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        // Require successful execution and closure: no credentials from a rejected/truncated command.
        guard replies == 2, exitStatus == 0 else { fail(); return }
        do {
            let bootstrap = try MoshBootstrap(output: bytes, ip: ip)
            completed = true; timeout?.cancel(); bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll()
            result.succeed(bootstrap)
        } catch { fail() }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail() }
    func fail() {
        guard !completed else { return }; completed = true
        timeout?.cancel(); bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll()
        result.fail(MoshError.bootstrap); channel?.close(promise: nil)
    }
}
