import Foundation
import NIOCore
import Testing
@testable import MiniTermCore

struct SFTPTests {
    @Test func fragmentedAndCoalescedPacketsRetainOpaqueBytes() throws {
        var payload = ByteBuffer(); payload.sftpString(Data([0,255,13,10]))
        let wire = SFTPPacket.encode(type: 103, id: 7, payload: payload)
        var input = ByteBuffer(); var result: SFTPPacket?
        for byte in wire.readableBytesView {
            input.writeInteger(byte)
            if let packet = try SFTPPacket.next(from: &input) { result = packet }
        }
        #expect(result?.type == 103)
        #expect(result?.payload.readInteger(as: UInt32.self) == 7)
        #expect(try result?.payload.sftpData() == Data([0,255,13,10]))
        input.writeImmutableBuffer(wire); input.writeImmutableBuffer(wire)
        #expect(try SFTPPacket.next(from: &input) != nil)
        #expect(try SFTPPacket.next(from: &input) != nil)
        #expect(input.readableBytes == 0)
    }
    @Test func oversizedAndTruncatedPacketsFailClosed() throws {
        for length in [UInt32(0), UInt32(1_048_577), UInt32.max] {
            var input = ByteBuffer(); input.writeInteger(length)
            #expect(throws: SFTPError.malformed) { try SFTPPacket.next(from: &input) }
        }
        var input = ByteBuffer(bytes: [0,0,0,10,103,0,0])
        #expect(try SFTPPacket.next(from: &input) == nil)
        var data = ByteBuffer(bytes: [0,16,0,1])
        #expect(throws: SFTPError.malformed) { try data.sftpData() }
    }
    @Test func attributesAndExtensionBounds() throws {
        var data = ByteBuffer()
        data.writeInteger(UInt32(0x8000000F)); data.writeInteger(UInt64(123))
        data.writeInteger(UInt32(501)); data.writeInteger(UInt32(20)); data.writeInteger(UInt32(0o100600))
        data.writeInteger(UInt32(1)); data.writeInteger(UInt32(2)); data.writeInteger(UInt32(1))
        data.sftpString("extension"); data.sftpString("value")
        let attrs = try data.sftpAttributes()
        #expect(attrs.size == 123 && attrs.permissions == 0o100600)
        #expect(attrs.modified == Date(timeIntervalSince1970: 2))
        #expect(data.readableBytes == 0)
        var bad = ByteBuffer(); bad.writeInteger(UInt32(0x10))
        #expect(throws: SFTPError.malformed) { try bad.sftpAttributes() }
    }
    @Test func filenamesCannotEscapeTheirDirectory() throws {
        for name in ["", ".", "..", "../secret", "a/b", "a\0b"] {
            #expect(throws: SFTPError.invalidPath) { try RemotePath.join("/tmp/project", name: name) }
        }
        #expect(try RemotePath.join("/", name: "sp ace '☃'") == "/sp ace '☃'")
        #expect(RemotePath.parent("/tmp/project") == "/tmp")
        #expect(RemotePath.parent("/") == "/")
        #expect(RemotePath.parent("/tmp") == "/")
    }
}
