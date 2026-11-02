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
    public let annotation: ConnectionAnnotation?
    public var displayName: String { annotation?.name.isEmpty == false ? annotation!.name : profile?.host ?? "" }
    public var isFavorite: Bool { !isDeleted && annotation?.isFavorite == true }
    public var isDeleted: Bool { profile == nil }

    init(id: String, profile: ConnectionProfile?, modifiedAt: Date, operationID: UUID,
         lastConnectedAt: Date?, annotation: ConnectionAnnotation? = nil) {
        self.id = id; self.profile = profile; self.modifiedAt = modifiedAt
        self.operationID = operationID; self.lastConnectedAt = lastConnectedAt; self.annotation = annotation
    }
}

/// Separate revision keeps an ordinary login on another device from erasing a label/star.
public struct ConnectionAnnotation: Codable, Equatable, Sendable {
    public let name: String
    public let isFavorite: Bool
    public let modifiedAt: Date
    public let operationID: UUID
}

public struct ConnectionHistoryDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public private(set) var entries: [ConnectionHistoryEntry] = []
    public init() {}

    public var visibleEntries: [ConnectionHistoryEntry] {
        entries.filter { !$0.isDeleted }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
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
            if let annotation = entry.annotation {
                guard annotation.modifiedAt.timeIntervalSince1970.isFinite,
                      Self.validName(annotation.name) else { throw ConnectionHistoryError.invalidDocument }
            }
            if let current = byID[entry.id] {
                let newer = entry.modifiedAt > current.modifiedAt ||
                    (entry.modifiedAt == current.modifiedAt && entry.operationID.uuidString > current.operationID.uuidString)
                let winner = newer ? entry : current
                let annotations: [ConnectionAnnotation] = [current.annotation, entry.annotation].compactMap { $0 }
                var annotation = annotations.max { left, right in
                    if left.modifiedAt == right.modifiedAt { return left.operationID.uuidString < right.operationID.uuidString }
                    return left.modifiedAt < right.modifiedAt
                }
                if winner.isDeleted, let observed = annotation {
                    let cleared = observed.name.isEmpty && !observed.isFavorite
                    let date = max(winner.modifiedAt, observed.modifiedAt.addingTimeInterval(cleared ? 0 : 0.001))
                    annotation = .init(name: "", isFavorite: false, modifiedAt: date, operationID: winner.operationID)
                }
                if winner.profile != nil, current.profile != nil, entry.profile != nil {
                    let connected = [current.lastConnectedAt, entry.lastConnectedAt].compactMap { $0 }.max()
                    byID[entry.id] = .init(id: winner.id, profile: winner.profile, modifiedAt: winner.modifiedAt,
                                           operationID: winner.operationID, lastConnectedAt: connected, annotation: annotation)
                } else {
                    byID[entry.id] = .init(id: winner.id, profile: winner.profile, modifiedAt: winner.modifiedAt,
                                          operationID: winner.operationID, lastConnectedAt: winner.lastConnectedAt, annotation: annotation)
                }
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
                      operationID: UUID(), lastConnectedAt: lastConnected, annotation: previous?.annotation))
        // Favorites are bookmarks; connecting elsewhere must not evict them.
        // Bound ordinary recents; tombstones prevent old replicas resurrecting them.
        for entry in visibleEntries.filter({ !$0.isFavorite }).dropFirst(30) { remove(id: entry.id, now: timestamp) }
    }

    public mutating func customize(id: String, name: String? = nil, favorite: Bool? = nil, now: Date = Date()) throws {
        guard let old = entries.first(where: { $0.id == id }), !old.isDeleted else { return }
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? old.annotation?.name ?? ""
        guard Self.validName(name) else { throw ConnectionHistoryError.invalidName }
        let timestamp = max(now, (old.annotation?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
        let annotation = ConnectionAnnotation(name: name, isFavorite: favorite ?? old.isFavorite,
                                               modifiedAt: timestamp, operationID: UUID())
        replace(.init(id: old.id, profile: old.profile, modifiedAt: old.modifiedAt,
                      operationID: old.operationID, lastConnectedAt: old.lastConnectedAt, annotation: annotation))
    }

    private static func validName(_ name: String) -> Bool {
        name.utf8.count <= 160 && name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public mutating func remove(id: String, now: Date = Date()) {
        guard let old = entries.first(where: { $0.id == id }), !old.isDeleted else { return }
        let operation = UUID()
        let annotation = old.annotation.map { value in
            ConnectionAnnotation(name: "", isFavorite: false,
                                 modifiedAt: max(now, value.modifiedAt.addingTimeInterval(0.001)), operationID: operation)
        }
        replace(.init(id: id, profile: nil, modifiedAt: max(now, old.modifiedAt.addingTimeInterval(0.001)),
                      operationID: operation, lastConnectedAt: nil, annotation: annotation))
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
    case unsupportedVersion, invalidDocument, tooLarge, invalidName
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Use a short connection name on one line."
        case .unsupportedVersion: "The connection history was saved by a newer app version. Update Mini Term before syncing it."
        case .invalidDocument: "A connection history file is invalid. Your local connections have been kept."
        case .tooLarge: "A connection history file exceeds the 2 MB limit. Your local connections have been kept."
        }
    }
}
