import Crypto
import Foundation

/// Connection metadata only. Credentials, host trust and terminal contents never enter this document.
public struct ConnectionProfile: Codable, Equatable, Sendable, Identifiable {
    public let host: String
    public let username: String
    public let port: Int
    public let tmuxSession: String

    public init(_ connection: SSHConnection) {
        host = connection.host
        username = connection.username
        port = connection.port
        tmuxSession = connection.tmuxSession ?? ""
    }

    public func connection() throws -> SSHConnection {
        try SSHConnection(host: host, username: username, port: port, tmuxSession: tmuxSession)
    }

    /// A stable identity shared by independently created copies on different devices.
    public var id: String {
        let fields = [host.lowercased(), username, String(port), tmuxSession]
        let bytes = try! JSONEncoder().encode(fields) // Strings always encode.
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ConnectionHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let profile: ConnectionProfile?
    public let modifiedAt: Date
    public let operationID: UUID
    public let lastConnectedAt: Date?
    public var isDeleted: Bool { profile == nil }
}

public struct ConnectionHistoryDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public private(set) var entries: [ConnectionHistoryEntry] = []
    public init() {}

    public var visibleEntries: [ConnectionHistoryEntry] {
        entries.filter { !$0.isDeleted }.sorted {
            let left = $0.lastConnectedAt ?? $0.modifiedAt
            let right = $1.lastConnectedAt ?? $1.modifiedAt
            return left == right ? $0.id < $1.id : left > right
        }
    }

    /// Per-entry last-write-wins merge, with a stable tie-break and durable deletion records.
    /// Each device writes its own file, so offline writers cannot overwrite each other's documents.
    public mutating func merge(_ other: Self) throws {
        guard other.version == Self.currentVersion else { throw ConnectionHistoryError.unsupportedVersion }
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        for entry in other.entries {
            guard entry.modifiedAt.timeIntervalSince1970.isFinite,
                  entry.lastConnectedAt?.timeIntervalSince1970.isFinite != false,
                  entry.id.count == 64 else { throw ConnectionHistoryError.invalidDocument }
            if let profile = entry.profile {
                guard profile.id == entry.id, profile.host.utf8.count <= 1024,
                      profile.username.utf8.count <= 1024 else { throw ConnectionHistoryError.invalidDocument }
                _ = try profile.connection()
            }
            if let current = byID[entry.id] {
                let newer = entry.modifiedAt > current.modifiedAt ||
                    (entry.modifiedAt == current.modifiedAt && entry.operationID.uuidString > current.operationID.uuidString)
                let winner = newer ? entry : current
                if winner.profile != nil, current.profile != nil, entry.profile != nil {
                    let connected = [current.lastConnectedAt, entry.lastConnectedAt].compactMap { $0 }.max()
                    byID[entry.id] = .init(id: winner.id, profile: winner.profile, modifiedAt: winner.modifiedAt,
                                           operationID: winner.operationID, lastConnectedAt: connected)
                } else { byID[entry.id] = winner }
            } else { byID[entry.id] = entry }
        }
        entries = byID.values.sorted { $0.id < $1.id }
    }

    public mutating func remember(_ profile: ConnectionProfile, connected: Bool, now: Date = Date()) {
        let previous = entries.first { $0.id == profile.id }
        // A stale device clock must still allow an explicit save/delete after observing newer data.
        let timestamp = max(now, (previous?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
        let lastConnected = connected ? max(now, previous?.lastConnectedAt ?? .distantPast) : previous?.lastConnectedAt
        replace(.init(id: profile.id, profile: profile, modifiedAt: timestamp,
                      operationID: UUID(), lastConnectedAt: lastConnected))
        // Keep the UI bounded; tombstones prevent old cloud replicas from resurrecting evicted rows.
        for entry in visibleEntries.dropFirst(30) { remove(id: entry.id, now: timestamp) }
    }

    public mutating func remove(id: String, now: Date = Date()) {
        guard let old = entries.first(where: { $0.id == id }), !old.isDeleted else { return }
        replace(.init(id: id, profile: nil, modifiedAt: max(now, old.modifiedAt.addingTimeInterval(0.001)),
                      operationID: UUID(), lastConnectedAt: nil))
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw ConnectionHistoryError.tooLarge }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        var validated = Self()
        try validated.merge(decoded)
        return validated
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        guard data.count <= 2_000_000 else { throw ConnectionHistoryError.tooLarge }
        return data
    }

    private mutating func replace(_ entry: ConnectionHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.id < $1.id }
    }
}

public enum ConnectionHistoryError: LocalizedError, Sendable {
    case unsupportedVersion, invalidDocument, tooLarge
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "The connection history was saved by a newer app version. Update Mini Term before syncing it."
        case .invalidDocument: "A connection history file is invalid. Your local connections have been kept."
        case .tooLarge: "A connection history file exceeds the 2 MB limit. Your local connections have been kept."
        }
    }
}
