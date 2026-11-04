import Foundation

public enum WorkspacePreferenceError: Error, LocalizedError, Sendable {
    case invalidPreview, tooManyShortcuts
    public var errorDescription: String? {
        switch self {
        case .invalidPreview: "Use a name, a port from 1 to 65535, and a relative path beginning with / (up to 2048 bytes)."
        case .tooManyShortcuts: "You can save up to 20 preview shortcuts per connection."
        }
    }
}

public struct PreviewShortcut: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var port: Int
    public var useHTTPS: Bool
    public var path: String
    public init(id: UUID = UUID(), name: String, port: Int, useHTTPS: Bool, path: String) throws {
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port; self.useHTTPS = useHTTPS; self.path = path.isEmpty ? "/" : path
        try validate()
    }
    public func validate() throws {
        guard !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...65535).contains(port), Self.validPath(path) else { throw WorkspacePreferenceError.invalidPreview }
    }
    public static func validPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 2048,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
              parts.user == nil, parts.password == nil else { return false }
        return parts.url != nil
    }
    public func url(host: String, port overridePort: Int? = nil) -> URL? {
        guard Self.validPath(path) else { return nil }
        var parts = URLComponents(string: path)!
        parts.scheme = useHTTPS ? "https" : "http"; parts.host = host; parts.port = overridePort ?? port
        return parts.url
    }
    public static func decode(_ data: Data) throws -> [PreviewShortcut] {
        let entries = try JSONDecoder().decode([PreviewShortcut].self, from: data)
        guard entries.count <= 20, Set(entries.map(\.id)).count == entries.count else { throw WorkspacePreferenceError.tooManyShortcuts }
        for entry in entries { try entry.validate() }
        return entries
    }
}

/// Scheduling policy only; sockets, timers and scene/network observation stay with the host.
public struct ReconnectPolicy: Sendable {
    public var enabled = true
    public private(set) var attempts = 0
    public private(set) var hadConnection = false
    private var interrupted = false
    private var stopped = false
    public init() {}
    public mutating func connected() { hadConnection = true; attempts = 0; interrupted = false; stopped = false }
    public mutating func interruptedConnection() { if hadConnection { interrupted = true } }
    public mutating func verifiedResponsive() { interrupted = false }
    public mutating func stop() { stopped = true }
    public mutating func nextDelay(failure: ConnectionFailure.Kind?) -> TimeInterval? {
        guard enabled, hadConnection, !stopped, attempts < 6 else { return nil }
        let transient = failure == .network || failure == .timeout
        guard transient || (interrupted && failure == nil) else { return nil }
        let delay = min(30, pow(2, Double(attempts)))
        attempts += 1
        return delay
    }
}
