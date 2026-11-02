import Foundation
import Testing
@testable import MiniTermCore

struct ConnectionHistoryTests {
    private func profile(_ host: String = "mac.local", session: String = "codex") throws -> ConnectionProfile {
        ConnectionProfile(try SSHConnection(host: host, username: "perry", port: 22, tmuxSession: session))
    }

    @Test func savesDeduplicatesAndRoundTripsMetadata() throws {
        var document = ConnectionHistoryDocument()
        let first = try profile()
        document.remember(first, connected: false, now: Date(timeIntervalSince1970: 10))
        #expect(document.visibleEntries.count == 1)
        #expect(document.visibleEntries[0].lastConnectedAt == nil)
        document.remember(first, connected: true, now: Date(timeIntervalSince1970: 20))
        #expect(document.visibleEntries.count == 1)
        #expect(document.visibleEntries[0].lastConnectedAt == Date(timeIntervalSince1970: 20))
        document.remember(first, connected: true, now: Date(timeIntervalSince1970: 5))
        #expect(document.visibleEntries[0].lastConnectedAt == Date(timeIntervalSince1970: 20))
        #expect(try ConnectionHistoryDocument.decode(document.encoded()) == document)
        let text = String(decoding: try document.encoded(), as: UTF8.self)
        #expect(!text.contains("privateKey"))
        #expect(!text.contains("hostKey"))
        #expect(!text.contains("terminalOutput"))
    }

    @Test func identityNormalizesHostButKeepsUserAndSessionDistinct() throws {
        #expect(try profile("Mac.local").id == profile("mac.local").id)
        #expect(try profile(session: "codex").id != profile(session: "other").id)
        let differentUser = ConnectionProfile(try SSHConnection(host: "mac.local", username: "other", port: 22, tmuxSession: "codex"))
        #expect(try profile().id != differentUser.id)
    }

    @Test func offlineReplicasMergeInBothDirections() throws {
        var first = ConnectionHistoryDocument(), second = ConnectionHistoryDocument()
        first.remember(try profile("first.local"), connected: true, now: Date(timeIntervalSince1970: 10))
        second.remember(try profile("second.local"), connected: true, now: Date(timeIntervalSince1970: 20))
        let original = first
        try first.merge(second)
        try second.merge(original)
        #expect(first == second)
        #expect(first.visibleEntries.count == 2)
        #expect(first.visibleEntries.first?.profile?.host == "second.local")
    }

    @Test func deletionSurvivesOldReplicaAndCanBeExplicitlySavedAgain() throws {
        let item = try profile()
        var first = ConnectionHistoryDocument()
        first.remember(item, connected: true, now: Date(timeIntervalSince1970: 20))
        var oldReplica = first
        first.remove(id: item.id, now: Date(timeIntervalSince1970: 30))
        try first.merge(oldReplica)
        try oldReplica.merge(first)
        #expect(first == oldReplica)
        #expect(first.visibleEntries.isEmpty)
        #expect(first.entries[0].isDeleted)
        // Device clock is behind, but the explicit save observed the tombstone.
        oldReplica.remember(item, connected: false, now: Date(timeIntervalSince1970: 5))
        try first.merge(oldReplica)
        #expect(first.visibleEntries.count == 1)
    }

    @Test func equalTimestampConflictsConvergeAndPreserveLatestVisit() throws {
        let item = try profile()
        var first = ConnectionHistoryDocument(), second = ConnectionHistoryDocument()
        first.remember(item, connected: true, now: Date(timeIntervalSince1970: 100))
        second.remember(item, connected: false, now: Date(timeIntervalSince1970: 100))
        let original = first
        try first.merge(second); try second.merge(original)
        #expect(first == second)
        #expect(first.visibleEntries[0].lastConnectedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func boundsHistoryWithoutResurrectingEvictedRows() throws {
        var document = ConnectionHistoryDocument()
        for index in 0..<40 {
            document.remember(try profile("mac\(index).local"), connected: true, now: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(document.visibleEntries.count == 30)
        #expect(document.entries.count == 40)
        #expect(document.entries.filter(\.isDeleted).count == 10)
    }

    @Test func rejectsMalformedAndFutureDocuments() throws {
        #expect(throws: (any Error).self) { try ConnectionHistoryDocument.decode(Data("{}".utf8)) }
        var future = ConnectionHistoryDocument()
        future.version = 999
        #expect(throws: ConnectionHistoryError.self) { try ConnectionHistoryDocument.decode(future.encoded()) }
        #expect(throws: ConnectionHistoryError.self) { try ConnectionHistoryDocument.decode(Data(repeating: 0, count: 2_000_001)) }
    }

    @Test func separateDeviceFilesMergeOfflineChangesAndDeletions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConnectionHistoryCloudStore()
        let deviceA = UUID(), deviceB = UUID()
        var first = ConnectionHistoryDocument(), second = ConnectionHistoryDocument()
        let a = try profile("first.local"), b = try profile("second.local")
        first.remember(a, connected: true)
        second.remember(b, connected: true)
        first = try await store.synchronize(in: folder, deviceID: deviceA, local: first)
        second = try await store.synchronize(in: folder, deviceID: deviceB, local: second)
        first = try await store.synchronize(in: folder, deviceID: deviceA, local: first)
        #expect(first == second)
        #expect(first.visibleEntries.count == 2)
        first.remove(id: a.id)
        _ = try await store.synchronize(in: folder, deviceID: deviceA, local: first)
        second = try await store.synchronize(in: folder, deviceID: deviceB, local: second)
        #expect(second.visibleEntries.map(\.id) == [b.id])
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
    }

    @Test func invalidRemoteFileDoesNotOverwriteLocalReplica() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConnectionHistoryCloudStore(), device = UUID()
        var document = ConnectionHistoryDocument()
        document.remember(try profile(), connected: true)
        _ = try await store.synchronize(in: folder, deviceID: device, local: document)
        let own = folder.appendingPathComponent("MiniTerm-\(device.uuidString).connections.json")
        let before = try Data(contentsOf: own)
        try Data("invalid".utf8).write(to: folder.appendingPathComponent("MiniTerm-corrupt.connections.json"))
        do {
            _ = try await store.synchronize(in: folder, deviceID: device, local: document)
            Issue.record("Malformed remote file should fail sync")
        } catch { /* local data must remain intact */ }
        #expect(try Data(contentsOf: own) == before)
    }
}
