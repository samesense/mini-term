import Foundation

public struct SSHConnection: Equatable, Sendable {
    public let host: String
    public let username: String
    public let port: Int
    public let tmuxSession: String?

    public init(host: String, username: String, port: Int, tmuxSession: String = "") throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !username.isEmpty, (1...65535).contains(port) else {
            throw TerminalError.invalidConnection
        }
        // IPv6 literals are accepted without brackets by NIO's resolver.
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.username = username
        self.port = port
        let name = tmuxSession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty || (name.utf8.count <= 64 && name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw TerminalError.invalidSessionName }
        self.tmuxSession = name.isEmpty ? nil : name
    }

    // Session names are restricted above: no shell metacharacters can enter this command.
    // Standard macOS SSH command shells may not inherit Homebrew's PATH.
    public var startupCommand: String? {
        tmuxSession.map { "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; exec tmux new-session -A -s \($0)" }
    }

    public var hostKeyAccount: String { "[\(host.lowercased())]:\(port)" }
}

public struct TerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let widthPixels: Int
    public let heightPixels: Int

    public init(columns: Int = 80, rows: Int = 24, widthPixels: Int = 0, heightPixels: Int = 0) {
        self.columns = min(65535, max(1, columns))
        self.rows = min(65535, max(1, rows))
        self.widthPixels = min(Int(UInt32.max), max(0, widthPixels))
        self.heightPixels = min(Int(UInt32.max), max(0, heightPixels))
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle, connecting, verifyingHost, authenticating, openingShell, connected, disconnected
    case failed(String)

    public var label: String {
        switch self {
        case .idle: "Ready"
        case .connecting: "Connecting…"
        case .verifyingHost: "Verify host key"
        case .authenticating: "Authenticating…"
        case .openingShell: "Opening shell…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .failed(let message): message
        }
    }

    public var isFinished: Bool {
        switch self {
        case .disconnected, .failed: true
        default: false
        }
    }
}

public enum TerminalError: LocalizedError, Sendable {
    case invalidSessionName
    case invalidConnection, authentication, hostKeyRejected, hostKeyMismatch
    case requestRejected, timedOut, inputOverflow, outputOverflow, invalidHostKey, cancelled
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSessionName: "Use at most 64 letters, digits, hyphens or underscores for the tmux session name."
        case .invalidConnection: "Enter a hostname, username, and port between 1 and 65535."
        case .authentication: "SSH public-key authentication failed. Install this iPad’s public key in the Mac’s authorized_keys."
        case .hostKeyRejected: "Host key was not trusted. Connection cancelled."
        case .hostKeyMismatch: "HOST KEY CHANGED. Connection blocked. Verify the Mac’s identity before removing its saved trust record."
        case .requestRejected: "The SSH server rejected the PTY or interactive shell request."
        case .timedOut: "The SSH connection timed out. Check the address, Remote Login, network, and Tailscale connection."
        case .inputOverflow: "Input exceeded the 1 MiB pending limit. Connection closed to avoid losing or reordering input."
        case .outputOverflow: "Paused terminal output exceeded its buffer limit. Connection closed."
        case .invalidHostKey: "The SSH host public key could not be decoded."
        case .cancelled: "Connection cancelled."
        case .keychain(let status): "Keychain operation failed (\(status)). Unlock the iPad and try again."
        }
    }
}
