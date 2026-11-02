import Foundation
import NIOCore
import Testing
@testable import MiniTermCore

struct ConnectionConvenienceTests {
    private func profile(_ host: String = "mac.local") throws -> ConnectionProfile {
        ConnectionProfile(try SSHConnection(host: host, username: "user", port: 22, tmuxSession: "codex"))
    }

    @Test func legacyHistoryWithoutAnnotationsStillLoads() throws {
        var history = ConnectionHistoryDocument()
        history.remember(try profile(), connected: true)
        var object = try #require(JSONSerialization.jsonObject(with: history.encoded()) as? [String: Any])
        var rows = try #require(object["entries"] as? [[String: Any]])
        rows[0].removeValue(forKey: "annotation")
        object["entries"] = rows
        let decoded = try ConnectionHistoryDocument.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.visibleEntries.first?.displayName == "mac.local")
        #expect(decoded.visibleEntries.first?.isFavorite == false)
    }

    @Test func customNamesKeepIdentityAndSurviveSuccessfulLogins() throws {
        var history = ConnectionHistoryDocument()
        let item = try profile()
        history.remember(item, connected: false)
        try history.customize(id: item.id, name: "  Mac mini · Codex  ", favorite: true)
        history.remember(item, connected: true)
        let row = try #require(history.visibleEntries.first)
        #expect(row.id == item.id)
        #expect(row.profile == item)
        #expect(row.displayName == "Mac mini · Codex")
        #expect(row.isFavorite)
        #expect(try ConnectionHistoryDocument.decode(history.encoded()) == history)
    }

    @Test func metadataAndIndependentRecencyMergeWithoutLosingNames() throws {
        var first = ConnectionHistoryDocument()
        let item = try profile()
        first.remember(item, connected: false, now: Date(timeIntervalSince1970: 1))
        var second = first
        try first.customize(id: item.id, name: "Work", favorite: true, now: Date(timeIntervalSince1970: 2))
        second.remember(item, connected: true, now: Date(timeIntervalSince1970: 10))
        let original = first
        try first.merge(second); try second.merge(original)
        #expect(first == second)
        #expect(first.visibleEntries.first?.displayName == "Work")
        #expect(first.visibleEntries.first?.isFavorite == true)
        #expect(first.visibleEntries.first?.lastConnectedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func clearingAndUnfavoritingHaveDurableRevisionsEvenWithClockSkew() throws {
        var history = ConnectionHistoryDocument()
        let item = try profile()
        history.remember(item, connected: true)
        try history.customize(id: item.id, name: "Work", favorite: true, now: Date(timeIntervalSince1970: 100))
        let old = history
        try history.customize(id: item.id, name: "", favorite: false, now: Date(timeIntervalSince1970: 1))
        try history.merge(old)
        #expect(history.visibleEntries.first?.displayName == "mac.local")
        #expect(history.visibleEntries.first?.isFavorite == false)
    }

    @Test func tiedMetadataEditsConverge() throws {
        var first = ConnectionHistoryDocument()
        let item = try profile()
        first.remember(item, connected: false)
        var second = first
        let now = Date(timeIntervalSince1970: 10)
        try first.customize(id: item.id, name: "First", now: now)
        try second.customize(id: item.id, name: "Second", now: now)
        let original = first
        try first.merge(second); try second.merge(original)
        #expect(first == second)
    }

    @Test func favoritesSortFirstAndRemainWithinTheHistoryBound() throws {
        var history = ConnectionHistoryDocument()
        let favorite = try profile("favorite.local")
        history.remember(favorite, connected: true, now: Date(timeIntervalSince1970: 1))
        try history.customize(id: favorite.id, favorite: true)
        for index in 0..<40 {
            history.remember(try profile("mac\(index).local"), connected: true, now: Date(timeIntervalSince1970: Double(index + 2)))
        }
        #expect(history.visibleEntries.count == 31) // One bookmark plus thirty recents.
        #expect(history.visibleEntries.first?.id == favorite.id)
    }

    @Test func deleteAndRestoreDoNotResurrectOldAnnotations() throws {
        var history = ConnectionHistoryDocument()
        let item = try profile()
        history.remember(item, connected: true)
        try history.customize(id: item.id, name: "Work", favorite: true)
        let old = history
        history.remove(id: item.id)
        try history.merge(old)
        #expect(history.visibleEntries.isEmpty)
        history.remember(item, connected: false)
        try history.merge(old)
        #expect(history.visibleEntries.first?.displayName == "mac.local")
        #expect(history.visibleEntries.first?.isFavorite == false)
    }

    @Test func invalidLabelsAreRejectedWithoutMutatingHistory() throws {
        var history = ConnectionHistoryDocument()
        let item = try profile()
        history.remember(item, connected: false)
        let before = history
        for name in ["work\nserver", "work\u{1B}server", String(repeating: "a", count: 161)] {
            #expect(throws: ConnectionHistoryError.self) { try history.customize(id: item.id, name: name) }
            #expect(history == before)
        }
    }

    @Test func metadataSurvivesTwoDeviceReplicaSync() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ConnectionHistoryCloudStore(), a = UUID(), b = UUID()
        let item = try profile()
        var first = ConnectionHistoryDocument()
        first.remember(item, connected: false)
        try first.customize(id: item.id, name: "Desk", favorite: true)
        _ = try await store.synchronize(in: folder, deviceID: a, local: first)
        var second = try await store.synchronize(in: folder, deviceID: b, local: ConnectionHistoryDocument())
        #expect(second.visibleEntries.first?.displayName == "Desk")
        try second.customize(id: item.id, favorite: false)
        _ = try await store.synchronize(in: folder, deviceID: b, local: second)
        first = try await store.synchronize(in: folder, deviceID: a, local: first)
        #expect(first.visibleEntries.first?.isFavorite == false)
        #expect(first.visibleEntries.first?.displayName == "Desk")
    }

    @Test func reportsNeverCopyRawErrorsOrTerminalContents() {
        var report = SessionDiagnostics(usesTmux: true)
        report.beginAttempt(now: Date(timeIntervalSince1970: 1))
        report.record(.authenticating)
        report.record(.failed("SECRET_PRIVATE_KEY server.local username terminal-output"), failure: ConnectionFailure(TerminalError.authentication))
        let text = report.report(appVersion: "0.1", systemVersion: "17.0")
        #expect(text.contains("[authentication]"))
        for secret in ["SECRET_PRIVATE_KEY", "server.local", "username", "terminal-output"] { #expect(!text.contains(secret)) }
        #expect(report.attempts == 1)
    }

    @Test func diagnosticsClassifySafeCodesAndBoundTheTimeline() {
        #expect(ConnectionFailure(TerminalError.hostKeyMismatch).kind == .hostKeyChanged)
        #expect(ConnectionFailure(TerminalError.keychain(-25308)).systemCode == -25308)
        #expect(ConnectionFailure(IOError(errnoCode: 61, reason: "secret destination")).systemCode == 61)
        let arbitrary = NSError(domain: "secret", code: 123, userInfo: [NSLocalizedDescriptionKey: "private contents"])
        #expect(ConnectionFailure(arbitrary).kind == .transport)
        #expect(ConnectionFailure(arbitrary).systemCode == nil)
        var report = SessionDiagnostics(usesTmux: false)
        for _ in 0..<100 { report.beginAttempt(); report.record(.disconnected) }
        #expect(report.events.count == 60)
        #expect(report.attempts == 100)
        #expect(report.report(appVersion: "0.1", systemVersion: "17.0").contains("Session: shell"))
    }
}
