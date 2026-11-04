import Foundation
import Testing
@testable import MiniTermCore

struct WorkspacePreferenceTests {
    @Test func previewsKeepTheReservedOriginAndExactPath() throws {
        let shortcut = try PreviewShortcut(name: " App ", port: 5173, useHTTPS: false, path: "/dashboard?q=a%20b#section")
        #expect(shortcut.name == "App")
        #expect(shortcut.url(host: PreviewAddress.host)?.absoluteString == "http://mini-term-preview.invalid:5173/dashboard?q=a%20b#section")
        #expect(shortcut.url(host: "localhost", port: 43210)?.absoluteString == "http://localhost:43210/dashboard?q=a%20b#section")
        #expect(try PreviewShortcut.decode(JSONEncoder().encode([shortcut])) == [shortcut])
    }
    @Test func rejectsExternalAndControlCharacterPaths() throws {
        for path in ["https://evil.example/", "//evil.example/", "dashboard", "/a\nheader", "/" + String(repeating: "a", count: 2048)] {
            #expect(!PreviewShortcut.validPath(path))
            #expect(throws: WorkspacePreferenceError.self) { try PreviewShortcut(name: "App", port: 3000, useHTTPS: false, path: path) }
        }
        #expect(throws: WorkspacePreferenceError.self) { try PreviewShortcut(name: "", port: 3000, useHTTPS: false, path: "/") }
        #expect(throws: WorkspacePreferenceError.self) { try PreviewShortcut(name: "App", port: 0, useHTTPS: false, path: "/") }
    }
    @Test func validatesDecodedShortcutsAndBoundsTheList() throws {
        let invalid = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"A\",\"port\":0,\"useHTTPS\":false,\"path\":\"/\"}]".utf8)
        #expect(throws: (any Error).self) { try PreviewShortcut.decode(invalid) }
        let item = try PreviewShortcut(name: "A", port: 3000, useHTTPS: false, path: "/")
        #expect(throws: WorkspacePreferenceError.self) { try PreviewShortcut.decode(JSONEncoder().encode([item,item])) }
        let tooMany = try (0..<21).map { try PreviewShortcut(name: "\($0)", port: 3000, useHTTPS: false, path: "/") }
        #expect(throws: WorkspacePreferenceError.self) { try PreviewShortcut.decode(JSONEncoder().encode(tooMany)) }
    }
    @Test func noAutomaticFirstUseOrOrdinaryRemoteExit() {
        var policy = ReconnectPolicy()
        #expect(policy.nextDelay(failure: .network) == nil)
        policy.connected()
        #expect(policy.nextDelay(failure: nil) == nil)
        #expect(policy.nextDelay(failure: .authentication) == nil)
    }
    @Test func interruptedSessionHasBoundedBackoff() {
        var policy = ReconnectPolicy(); policy.connected(); policy.interruptedConnection()
        #expect((0..<6).map { _ in policy.nextDelay(failure: nil) } == [1,2,4,8,16,30])
        #expect(policy.nextDelay(failure: nil) == nil)
        policy.connected()
        #expect(policy.nextDelay(failure: .timeout) == 1)
    }
    @Test func stopDisableAndSecurityFailuresBlockRetries() {
        for failure in [ConnectionFailure.Kind.hostKeyChanged, .hostKeyRejected, .invalidHostKey, .authentication, .configuration, .serverRequest, .cancelled, .keychain, .inputOverflow, .outputOverflow, .transport] {
            var policy = ReconnectPolicy(); policy.connected(); policy.interruptedConnection()
            #expect(policy.nextDelay(failure: failure) == nil)
        }
        var policy = ReconnectPolicy(); policy.connected(); policy.stop()
        #expect(policy.nextDelay(failure: .network) == nil)
        policy.connected(); policy.enabled = false
        #expect(policy.nextDelay(failure: .network) == nil)
    }
    @Test func healthyWakeDoesNotTurnLaterRemoteExitIntoARetry() {
        var policy = ReconnectPolicy(); policy.connected(); policy.interruptedConnection()
        policy.verifiedResponsive()
        #expect(policy.nextDelay(failure: nil) == nil)
        #expect(policy.nextDelay(failure: .network) == 1)
    }
}
