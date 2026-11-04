import Foundation
import NIOCore

public enum SFTPError: Error, LocalizedError, Sendable, Equatable {
    case disconnected, unavailable, malformed, limitReached, timedOut, invalidPath, notRegularFile, fileChanged
    case status(UInt32)
    public var errorDescription: String? {
        switch self {
        case .disconnected: "SSH disconnected. Reconnect before browsing files."
        case .unavailable: "The SSH server did not accept SFTP version 3. Check its SFTP subsystem configuration."
        case .malformed: "The server sent an invalid SFTP response."
        case .limitReached: "The SFTP response or directory exceeds the supported limit."
        case .timedOut: "The file operation timed out. Try again."
        case .invalidPath: "Enter a valid remote path or filename."
        case .notRegularFile: "Only regular files can be transferred."
        case .fileChanged: "The file changed size during the download. Try again when it is no longer being written."
        case .status(2): "The remote file or directory no longer exists."
        case .status(3): "The Mac denied access to that file or directory."
        case .status(let code): "SFTP could not complete the operation (status \(code)). Uploads require a new filename."
        }
    }
}

public struct RemoteFile: Identifiable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let size: UInt64?
    public let permissions: UInt32?
    public let modified: Date?
    public var id: String { path }
    public var isDirectory: Bool { permissions.map { $0 & 0xF000 == 0x4000 } ?? false }
    public var isRegularFile: Bool { permissions.map { $0 & 0xF000 == 0x8000 } ?? false }
    public var isSymbolicLink: Bool { permissions.map { $0 & 0xF000 == 0xA000 } ?? false }
}

public enum RemotePath {
    public static func validate(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 16_384, !path.utf8.contains(0) else { throw SFTPError.invalidPath }
    }
    public static func join(_ directory: String, name: String) throws -> String {
        try validate(directory)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw SFTPError.invalidPath }
        let path = (directory == "/" ? "" : directory) + "/" + name
        try validate(path)
        return path
    }
    public static func parent(_ path: String) -> String {
        guard path != "/" else { return "/" }
        return "/" + path.split(separator: "/").dropLast().joined(separator: "/")
    }
}

struct SFTPAttributes: Sendable {
    var size: UInt64?
    var permissions: UInt32?
    var modified: Date?
}

struct SFTPPacket: Sendable {
    let type: UInt8
    var payload: ByteBuffer
    static let maximumLength = 1_048_576
    static func encode(type: UInt8, id: UInt32? = nil, payload: ByteBuffer = ByteBuffer()) -> ByteBuffer {
        var packet = ByteBuffer()
        packet.writeInteger(UInt32(1 + (id == nil ? 0 : 4) + payload.readableBytes))
        packet.writeInteger(type)
        if let id { packet.writeInteger(id) }
        packet.writeImmutableBuffer(payload)
        return packet
    }
    static func next(from buffer: inout ByteBuffer) throws -> SFTPPacket? {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return nil }
        guard length >= 1, length <= maximumLength else { throw SFTPError.malformed }
        guard buffer.readableBytes >= Int(length) + 4 else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        let type: UInt8 = buffer.readInteger()!
        return .init(type: type, payload: buffer.readSlice(length: Int(length) - 1)!)
    }
}

extension ByteBuffer {
    mutating func sftpString(_ data: Data) { writeInteger(UInt32(data.count)); writeBytes(data) }
    mutating func sftpString(_ string: String) { sftpString(Data(string.utf8)) }
    mutating func sftpData() throws -> Data {
        guard let length: UInt32 = readInteger(), length <= SFTPPacket.maximumLength,
              let bytes = readBytes(length: Int(length)) else { throw SFTPError.malformed }
        return Data(bytes)
    }
    mutating func sftpText() throws -> String {
        guard let text = String(data: try sftpData(), encoding: .utf8) else { throw SFTPError.malformed }
        return text
    }
    mutating func sftpAttributes() throws -> SFTPAttributes {
        guard let flags: UInt32 = readInteger(), flags & ~UInt32(0x8000000F) == 0 else { throw SFTPError.malformed }
        var attrs = SFTPAttributes()
        if flags & 1 != 0 { guard let value: UInt64 = readInteger() else { throw SFTPError.malformed }; attrs.size = value }
        if flags & 2 != 0 { guard let _: UInt32 = readInteger(), let _: UInt32 = readInteger() else { throw SFTPError.malformed } }
        if flags & 4 != 0 { guard let value: UInt32 = readInteger() else { throw SFTPError.malformed }; attrs.permissions = value }
        if flags & 8 != 0 {
            guard let _: UInt32 = readInteger(), let seconds: UInt32 = readInteger() else { throw SFTPError.malformed }
            attrs.modified = Date(timeIntervalSince1970: Double(seconds))
        }
        if flags & 0x80000000 != 0 {
            guard let count: UInt32 = readInteger(), count <= 1024 else { throw SFTPError.malformed }
            for _ in 0..<count { _ = try sftpData(); _ = try sftpData() }
        }
        return attrs
    }
}
