import Foundation
import NIOCore
import NIOPosix

/// Deliberately no server-supplied strings, addresses, credentials or terminal bytes.
public struct ConnectionFailure: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case authentication, hostKeyRejected, hostKeyChanged, invalidHostKey, serverRequest
        case timeout, inputOverflow, outputOverflow, cancelled, keychain, configuration, network, transport
    }
    public let kind: Kind
    public let systemCode: Int?

    public init(_ error: any Error) {
        var code: Int?
        switch error {
        case let terminal as TerminalError:
            switch terminal {
            case .authentication: kind = .authentication
            case .hostKeyRejected: kind = .hostKeyRejected
            case .hostKeyMismatch: kind = .hostKeyChanged
            case .invalidHostKey: kind = .invalidHostKey
            case .requestRejected: kind = .serverRequest
            case .timedOut: kind = .timeout
            case .inputOverflow: kind = .inputOverflow
            case .outputOverflow: kind = .outputOverflow
            case .cancelled: kind = .cancelled
            case .keychain(let status): kind = .keychain; code = Int(status)
            case .invalidConnection, .invalidSessionName: kind = .configuration
            }
        case let io as IOError: kind = .network; code = Int(io.errnoCode)
        case let connection as NIOConnectionError:
            kind = .network
            code = connection.connectionErrors.compactMap { ($0.error as? IOError).map { Int($0.errnoCode) } }.first
        case is ConnectionHistoryError: kind = .configuration
        default: kind = .transport
        }
        systemCode = code
    }
}

public struct SessionDiagnostics: Sendable {
    public enum Phase: String, Sendable { case ready, connecting, verifyingHost, authenticating, openingShell, connected, disconnected, failed }
    public struct Event: Sendable {
        public let date: Date
        public let phase: Phase
        public let failure: ConnectionFailure?
    }
    public private(set) var events: [Event] = []
    public private(set) var attempts = 0
    public let usesTmux: Bool
    public init(usesTmux: Bool) { self.usesTmux = usesTmux }

    public mutating func beginAttempt(now: Date = Date()) {
        attempts += 1
        record(.connecting, now: now)
    }

    public mutating func record(_ state: ConnectionState, failure: ConnectionFailure? = nil, now: Date = Date()) {
        let phase: Phase
        switch state {
        case .idle: phase = .ready
        case .connecting: phase = .connecting
        case .verifyingHost: phase = .verifyingHost
        case .authenticating: phase = .authenticating
        case .openingShell: phase = .openingShell
        case .connected: phase = .connected
        case .disconnected: phase = .disconnected
        case .failed: phase = .failed // Never store the raw error message.
        }
        if events.last?.phase == phase && failure == nil { return }
        events.append(.init(date: now, phase: phase, failure: failure))
        events = Array(events.suffix(60))
    }

    public func report(appVersion: String, systemVersion: String) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["Mini Term diagnostics", "App: \(appVersion)", "iPadOS: \(systemVersion)",
                     "Attempts: \(attempts)", "Session: \(usesTmux ? "tmux" : "shell")",
                     "Destination, account, session name, keys and terminal contents: omitted", ""]
        for event in events {
            var line = "\(formatter.string(from: event.date))  \(event.phase.rawValue)"
            if let failure = event.failure {
                line += "  [\(failure.kind.rawValue)]"
                if let code = failure.systemCode { line += " system-code=\(code)" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
