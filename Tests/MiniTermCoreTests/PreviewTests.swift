import Foundation
import NIOCore
import Testing
@testable import MiniTermCore

struct PreviewTests {
    @Test func reservedOriginMapsOnlyItsExactNameToMacLoopback() {
        #expect(PreviewAddress.remoteHost(for: PreviewAddress.host) == "localhost")
        #expect(PreviewAddress.remoteHost(for: PreviewAddress.host.uppercased()) == "localhost")
        #expect(PreviewAddress.remoteHost(for: "example.com") == "example.com")
        #expect(PreviewAddress.remoteHost(for: PreviewAddress.host + ".example.com") == PreviewAddress.host + ".example.com")
    }
    private func authenticated() throws -> SOCKSHandshake {
        var parser = SOCKSHandshake(username: "user", password: "secret")
        var greeting = ByteBuffer(bytes: [5, 2, 0, 2])
        #expect(try parser.next(&greeting) == .reply([5, 2], close: false))
        var auth = ByteBuffer(bytes: [1, 4] + Array("user".utf8) + [6] + Array("secret".utf8))
        #expect(try parser.next(&auth) == .reply([1, 0], close: false))
        return parser
    }

    @Test func fragmentedHandshakePreservesPipelinedApplicationBytes() throws {
        var parser = SOCKSHandshake(username: "u", password: "p")
        let bytes: [UInt8] = [5, 1, 2, 1, 1, 117, 1, 112, 5, 1, 0, 3, 9] + Array("localhost".utf8) + [11, 184]
        var input = ByteBuffer()
        var steps: [SOCKSHandshake.Step] = []
        for byte in bytes {
            input.writeInteger(byte)
            while let step = try parser.next(&input) { steps.append(step) }
        }
        #expect(steps == [.reply([5, 2], close: false), .reply([1, 0], close: false), .connect(host: "localhost", port: 3000)])
        let payload: [UInt8] = [0, 1, 255, 13, 10]
        input.writeBytes(payload)
        #expect(try parser.next(&input) == nil)
        #expect(Array(input.readableBytesView) == payload)
    }

    @Test func noAuthenticationDowngradeOrWrongCredentials() throws {
        var parser = SOCKSHandshake(username: "u", password: "p")
        var input = ByteBuffer(bytes: [5, 1, 0])
        #expect(try parser.next(&input) == .reply([5, 255], close: true))
        parser = SOCKSHandshake(username: "u", password: "p")
        input = ByteBuffer(bytes: [5, 1, 2, 1, 1, 117, 1, 120])
        #expect(try parser.next(&input) == .reply([5, 2], close: false))
        #expect(try parser.next(&input) == .reply([1, 1], close: true))
        #expect(try parser.next(&input) == nil)
    }

    @Test func destinationAddressesAndPortLimits() throws {
        for (bytes, host, port) in [
            ([5, 1, 0, 1, 127, 0, 0, 1, 0, 1], "127.0.0.1", 1),
            ([5, 1, 0, 1, 127, 0, 0, 1, 255, 255], "127.0.0.1", 65535),
            ([5, 1, 0, 4] + Array(repeating: 0, count: 15) + [1, 20, 53], "0:0:0:0:0:0:0:1", 5173),
        ] as [([UInt8], String, Int)] {
            var parser = try authenticated()
            var input = ByteBuffer(bytes: bytes)
            #expect(try parser.next(&input) == .connect(host: host, port: port))
        }
        var parser = try authenticated()
        var input = ByteBuffer(bytes: [5, 1, 0, 1, 127, 0, 0, 1, 0, 0])
        #expect(try parser.next(&input) == .reply([5, 1, 0, 1, 0, 0, 0, 0, 0, 0], close: true))
    }

    @Test func rejectsBindUDPAndMalformedDestinations() throws {
        for bytes: [UInt8] in [
            [5, 2, 0, 1], [5, 3, 0, 1], [4, 1, 0, 1], [5, 1, 1, 1], [5, 1, 0, 7],
            [5, 1, 0, 3, 0, 0, 80], [5, 1, 0, 3, 1, 0, 0, 80],
        ] {
            var parser = try authenticated()
            var input = ByteBuffer(bytes: bytes)
            guard case .reply(_, close: true) = try parser.next(&input) else { Issue.record("Malformed request accepted"); continue }
        }
    }
}
