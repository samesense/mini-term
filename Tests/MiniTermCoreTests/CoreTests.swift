import Foundation
import Testing
@testable import MiniTermCore

struct CoreTests {
    @Test func validatesAndNormalizesConnection() throws {
        let connection = try SSHConnection(host: " [::1] ", username: " perry ", port: 22)
        #expect(connection.host == "::1")
        #expect(connection.username == "perry")
        #expect(connection.hostKeyAccount == "[::1]:22")
        #expect(throws: TerminalError.self) { try SSHConnection(host: "", username: "p", port: 22) }
        #expect(throws: TerminalError.self) { try SSHConnection(host: "mac", username: "", port: 22) }
        #expect(throws: TerminalError.self) { try SSHConnection(host: "mac", username: "p", port: 65536) }
    }

    @Test func tmuxNamesCannotInjectShellSyntax() throws {
        let c = try SSHConnection(host: "mac", username: "p", port: 22, tmuxSession: "codex-work_1")
        #expect(c.startupCommand?.hasSuffix("exec tmux new-session -A -s codex-work_1") == true)
        #expect(try SSHConnection(host: "mac", username: "p", port: 22).startupCommand == nil)
        for name in ["a;whoami", "$(id)", "a b", "a\nb", "café", String(repeating: "x", count: 65)] {
            #expect(throws: TerminalError.self) { try SSHConnection(host: "mac", username: "p", port: 22, tmuxSession: name) }
        }
    }

    @Test func boundsTerminalDimensions() {
        #expect(TerminalSize(columns: 0, rows: -2, widthPixels: -1).columns == 1)
        #expect(TerminalSize(columns: 90000, rows: 99999).rows == 65535)
        #expect(TerminalSize(widthPixels: -1).widthPixels == 0)
    }

    @Test func preservesOpaqueBytesAndAppliesInputLimit() throws {
        var queue = PendingInput(limit: 8)
        let chunks = [Data([0xF0, 0x9F]), Data([0x98, 0x80, 0, 0x1B]), Data([0x5B, 0x41])]
        for chunk in chunks { try queue.append(chunk) }
        #expect(queue.byteCount == 8)
        #expect(throws: TerminalError.self) { try queue.append(Data([0])) }
        for chunk in chunks { #expect(queue.pop() == chunk) }
        #expect(queue.pop() == nil)
        #expect(queue.byteCount == 0)
        try queue.append(Data([42]))
        queue.removeAll()
        #expect(queue.pop() == nil)
    }

    @Test func generatesStablePublicKeyAndRejectsChangedHost() throws {
        let seed = SSHIdentity.generateSeed()
        #expect(seed.count == 32)
        let first = try SSHIdentity.publicKey(seed: seed)
        #expect(try first == SSHIdentity.publicKey(seed: seed))
        #expect(first.hasPrefix("ssh-ed25519 "))
        #expect(try !SSHIdentity.checkHostKey(first, stored: nil))
        #expect(try SSHIdentity.checkHostKey(first, stored: first))
        let different = try SSHIdentity.publicKey(seed: SSHIdentity.generateSeed())
        #expect(throws: TerminalError.self) { try SSHIdentity.checkHostKey(different, stored: first) }
        #expect(throws: TerminalError.self) { try SSHIdentity.fingerprint(openSSHKey: "bad") }
        #expect(try SSHIdentity.fingerprint(openSSHKey: first).hasPrefix("SHA256:"))
        #expect(try !SSHIdentity.fingerprint(openSSHKey: first).hasSuffix("="))
    }

    @Test func fingerprintMatchesOpenSSHReference() throws {
        // RFC 8032 test-vector public key, serialized as an OpenSSH key blob.
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINdamAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea"
        #expect(try SSHIdentity.fingerprint(openSSHKey: key) == "SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8")
    }
}
