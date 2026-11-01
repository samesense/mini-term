import Crypto
import Foundation
import NIOSSH

public enum SSHIdentity {
    public static func generateSeed() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }

    public static func publicKey(seed: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " mini-term-ipad"
    }

    public static func fingerprint(openSSHKey: String) throws -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let bytes = Data(base64Encoded: String(parts[1])) else {
            throw TerminalError.invalidHostKey
        }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public static func checkHostKey(_ presented: String, stored: String?) throws -> Bool {
        guard let stored else { return false }
        guard try NIOSSHPublicKey(openSSHPublicKey: presented) == NIOSSHPublicKey(openSSHPublicKey: stored) else {
            throw TerminalError.hostKeyMismatch
        }
        return true
    }
}
