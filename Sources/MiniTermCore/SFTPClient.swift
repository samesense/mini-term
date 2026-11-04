import Foundation
import NIOCore
import NIOSSH

/// One SFTP subsystem on an already verified SSH connection. Requests are bounded
/// and all wire state is owned by the channel's event loop, independently of PTY flow control.
public final class SFTPClient: @unchecked Sendable {
    let handler: SFTPHandler
    init(handler: SFTPHandler) { self.handler = handler }
    public func close() { handler.loop.execute { [handler] in handler.fail(SFTPError.disconnected) } }

    private func request(_ type: UInt8, _ payload: ByteBuffer) async throws -> SFTPPacket {
        try Task.checkCancellation()
        return try await handler.loop.flatSubmit { [handler] in handler.request(type, payload) }.get()
    }
    private func names(_ packet: SFTPPacket, directory: String) throws -> [RemoteFile] {
        var data = packet.payload
        guard packet.type == 104, let count: UInt32 = data.readInteger(), count <= 10_000 else { throw SFTPError.malformed }
        var files: [RemoteFile] = []
        for _ in 0..<count {
            let name = try data.sftpText(); _ = try data.sftpData() // longname is display-only, never parsed.
            let attrs = try data.sftpAttributes()
            if name == "." || name == ".." { continue }
            files.append(.init(name: name, path: try RemotePath.join(directory, name: name), size: attrs.size,
                               permissions: attrs.permissions, modified: attrs.modified))
        }
        guard data.readableBytes == 0 else { throw SFTPError.malformed }
        return files
    }
    public func realPath(_ path: String) async throws -> String {
        try RemotePath.validate(path)
        var data = ByteBuffer(); data.sftpString(path)
        var result = try await request(16, data)
        guard result.type == 104, let count: UInt32 = result.payload.readInteger(), count == 1 else { throw SFTPError.malformed }
        let canonical = try result.payload.sftpText()
        _ = try result.payload.sftpData(); _ = try result.payload.sftpAttributes()
        try RemotePath.validate(canonical)
        guard canonical.hasPrefix("/"), result.payload.readableBytes == 0 else { throw SFTPError.malformed }
        return canonical
    }
    public func stat(_ path: String) async throws -> RemoteFile {
        try RemotePath.validate(path)
        var data = ByteBuffer(); data.sftpString(path)
        var result = try await request(17, data)
        guard result.type == 105 else { throw SFTPError.malformed }
        let attrs = try result.payload.sftpAttributes()
        guard result.payload.readableBytes == 0 else { throw SFTPError.malformed }
        return .init(name: path.split(separator: "/").last.map(String.init) ?? "/", path: path,
                     size: attrs.size, permissions: attrs.permissions, modified: attrs.modified)
    }
    private func open(_ path: String, directory: Bool = false, write: Bool = false) async throws -> Data {
        try RemotePath.validate(path)
        var data = ByteBuffer(); data.sftpString(path)
        if !directory {
            // Exclusive creation avoids silent overwrites. No truncate/delete/rename commands.
            data.writeInteger(UInt32(write ? 0x2 | 0x8 | 0x20 : 0x1))
            data.writeInteger(UInt32(write ? 4 : 0))
            if write { data.writeInteger(UInt32(0o600)) }
        }
        var result = try await request(directory ? 11 : 3, data)
        guard result.type == 102 else { throw SFTPError.malformed }
        let handle = try result.payload.sftpData()
        guard !handle.isEmpty, handle.count <= 256, result.payload.readableBytes == 0 else { throw SFTPError.malformed }
        return handle
    }
    private func closeHandle(_ handle: Data) async throws {
        var data = ByteBuffer(); data.sftpString(handle)
        let result = try await request(4, data)
        guard result.type == 101 else { throw SFTPError.malformed }
    }
    public func listDirectory(_ path: String) async throws -> [RemoteFile] {
        let handle = try await open(path, directory: true)
        do {
            var files: [RemoteFile] = []; var pages = 0
            while true {
                var data = ByteBuffer(); data.sftpString(handle)
                do {
                    let page = try names(await request(12, data), directory: path)
                    pages += 1
                    guard !page.isEmpty || pages < 2, pages <= 1000, files.count + page.count <= 10_000 else { throw SFTPError.limitReached }
                    files += page
                } catch SFTPError.status(1) { break }
            }
            try await closeHandle(handle)
            return files.sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
        } catch { try? await closeHandle(handle); throw error }
    }
    /// Streams 32 KiB blocks. Local I/O executes on the concurrent executor, not UIKit or NIO.
    @concurrent
    public func download(_ path: String, to destination: URL, progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }) async throws {
        try await withTaskCancellationHandler { try await downloadFile(path, to: destination, progress: progress) }
            onCancel: { self.close() }
    }
    private func downloadFile(_ path: String, to destination: URL, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws {
        let attrs = try await stat(path)
        guard attrs.isRegularFile else { throw SFTPError.notRegularFile }
        let handle = try await open(path)
        var created = false
        do {
            try Data().write(to: destination, options: .withoutOverwriting)
            created = true
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            var offset: UInt64 = 0
            while true {
                var data = ByteBuffer(); data.sftpString(handle); data.writeInteger(offset); data.writeInteger(UInt32(32768))
                do {
                    var packet = try await request(5, data)
                    guard packet.type == 103 else { throw SFTPError.malformed }
                    let bytes = try packet.payload.sftpData()
                    guard !bytes.isEmpty, bytes.count <= 32768, packet.payload.readableBytes == 0 else { throw SFTPError.malformed }
                    try Task.checkCancellation(); try file.write(contentsOf: bytes)
                    offset += UInt64(bytes.count); progress(offset, attrs.size)
                } catch SFTPError.status(1) { break }
            }
            if let size = attrs.size, offset != size { throw SFTPError.fileChanged }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle)
            if created { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }
    @concurrent
    public func upload(_ source: URL, to path: String, progress: @escaping @Sendable (UInt64, UInt64?) -> Void = { _, _ in }) async throws {
        try await withTaskCancellationHandler { try await uploadFile(source, to: path, progress: progress) }
            onCancel: { self.close() }
    }
    private func uploadFile(_ source: URL, to path: String, progress: @escaping @Sendable (UInt64, UInt64?) -> Void) async throws {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init)
        let handle = try await open(path, write: true)
        do {
            var offset: UInt64 = 0
            while let bytes = try file.read(upToCount: 32768), !bytes.isEmpty {
                try Task.checkCancellation()
                var data = ByteBuffer(); data.sftpString(handle); data.writeInteger(offset); data.sftpString(bytes)
                let packet = try await request(6, data)
                guard packet.type == 101 else { throw SFTPError.malformed }
                offset += UInt64(bytes.count); progress(offset, size ?? nil)
            }
            try await closeHandle(handle)
        } catch { try? await closeHandle(handle); throw error } // A cancelled upload can leave a partial new file.
    }
}

final class SFTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let loop: any EventLoop
    let ready: EventLoopPromise<SFTPClient>
    private var channel: (any Channel)?
    private var buffer = ByteBuffer()
    private var initialized = false
    private var requested = false
    private var stopped = false
    private var sequence: UInt32 = 0
    private var startupDeadline: Scheduled<Void>?
    private var pending: [UInt32: (EventLoopPromise<SFTPPacket>, Scheduled<Void>)] = [:]
    init(loop: any EventLoop) { self.loop = loop; ready = loop.makePromise() }
    func channelActive(context: ChannelHandlerContext) {
        guard !stopped else { context.close(promise: nil); return }
        channel = context.channel
        startupDeadline = loop.scheduleTask(in: .seconds(15)) { [weak self] in self?.fail(SFTPError.timedOut) }
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true), promise: nil)
        context.fireChannelActive()
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            guard !requested, !stopped else { return }
            requested = true
            var version = ByteBuffer(); version.writeInteger(UInt32(3))
            write(SFTPPacket.encode(type: 1, payload: version))
        case is ChannelFailureEvent: fail(SFTPError.unavailable)
        case ChannelEvent.inputClosed: fail(SFTPError.disconnected)
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func request(_ type: UInt8, _ data: ByteBuffer) -> EventLoopFuture<SFTPPacket> {
        guard initialized, !stopped else { return loop.makeFailedFuture(SFTPError.disconnected) }
        guard pending.count < 16 else { return loop.makeFailedFuture(SFTPError.limitReached) }
        sequence &+= 1
        while pending[sequence] != nil { sequence &+= 1 }
        let id = sequence
        let promise = loop.makePromise(of: SFTPPacket.self)
        let deadline: Scheduled<Void> = loop.scheduleTask(in: .seconds(15)) { [weak self] in self?.fail(SFTPError.timedOut) }
        pending[id] = (promise, deadline)
        write(SFTPPacket.encode(type: type, id: id, payload: data))
        return promise.futureResult
    }
    private func write(_ data: ByteBuffer) {
        guard let channel, !stopped else { return }
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(data))).whenFailure { [weak self] in self?.fail($0) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(var bytes) = packet.data, !stopped else { return }
        buffer.writeBuffer(&bytes)
        do {
            while var message = try SFTPPacket.next(from: &buffer) {
                if !initialized {
                    guard requested, message.type == 2, let version: UInt32 = message.payload.readInteger(), version == 3 else { throw SFTPError.unavailable }
                    while message.payload.readableBytes > 0 { _ = try message.payload.sftpData(); _ = try message.payload.sftpData() }
                    initialized = true; startupDeadline?.cancel(); startupDeadline = nil
                    ready.succeed(SFTPClient(handler: self))
                } else {
                    guard let id: UInt32 = message.payload.readInteger(), let (promise, deadline) = pending.removeValue(forKey: id) else { throw SFTPError.malformed }
                    deadline.cancel()
                    if message.type == 101 {
                        guard let code: UInt32 = message.payload.readInteger() else { promise.fail(SFTPError.malformed); throw SFTPError.malformed }
                        do {
                            _ = try message.payload.sftpData(); _ = try message.payload.sftpData()
                            guard message.payload.readableBytes == 0 else { throw SFTPError.malformed }
                        } catch { promise.fail(SFTPError.malformed); throw SFTPError.malformed }
                        // Never expose server-controlled status strings in errors/diagnostics.
                        if code != 0 { promise.fail(SFTPError.status(code)); continue }
                    }
                    promise.succeed(message)
                }
            }
            guard buffer.readableBytes <= SFTPPacket.maximumLength + 4 else { throw SFTPError.limitReached }
            if buffer.readerIndex > 65536 { buffer.discardReadBytes() }
        } catch { fail(error) }
    }
    func fail(_ error: any Error) {
        guard !stopped else { return }; stopped = true
        startupDeadline?.cancel(); startupDeadline = nil
        if !initialized { ready.fail(error) }
        for (promise, deadline) in pending.values { deadline.cancel(); promise.fail(error) }
        pending.removeAll(); channel?.close(promise: nil); channel = nil
    }
    func channelInactive(context: ChannelHandlerContext) { fail(SFTPError.disconnected); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error) }
}
