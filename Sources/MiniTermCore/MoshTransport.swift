import Foundation
import MoshNative

/// Byte backend shared by SSH and Mosh; Ghostty remains the sole app input/output pipeline.
public protocol TerminalTransport: AnyObject, Sendable {
    func send(_ data: Data)
    func resize(_ size: TerminalSize)
    func setOutputPaused(_ paused: Bool)
}
extension SSHTransport: TerminalTransport {}

public struct MoshCallbacks: Sendable {
    public let output: @Sendable (Data) -> Void
    public let connected: @Sendable () -> Void
    public let ended: @Sendable (MoshError?) -> Void
    public let networkAvailable: @Sendable (Bool) -> Void
    public init(output: @escaping @Sendable (Data) -> Void, connected: @escaping @Sendable () -> Void,
                ended: @escaping @Sendable (MoshError?) -> Void,
                networkAvailable: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.output = output; self.connected = connected; self.ended = ended; self.networkAvailable = networkAvailable
    }
}

/// One-shot worker. Native protocol state and cryptography stay on one dedicated thread.
/// Cancellation does not block UIKit or an SSH event loop. Credentials live in memory only.
public final class MoshTransport: TerminalTransport, @unchecked Sendable {
    private final class Engine: @unchecked Sendable {
        let native: OpaquePointer
        let callbacks: MoshCallbacks
        let lock = NSLock()
        var overflow = false
        init(native: OpaquePointer, callbacks: MoshCallbacks) { self.native = native; self.callbacks = callbacks }
        deinit { mt_mosh_destroy(native) }
        func run() {
            let context = Unmanaged.passUnretained(self).toOpaque()
            var connected = false
            // Native callbacks run synchronously within mt_mosh_run.
            let result = mt_mosh_run(native, context, { ctx, bytes, count in
                guard let ctx, let bytes else { return }
                let engine = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
                engine.callbacks.output(Data(bytes: bytes, count: count))
            }, { ctx, status in
                guard let ctx else { return }
                let engine = Unmanaged<Engine>.fromOpaque(ctx).takeUnretainedValue()
                if status == 1 { engine.didConnect() }
                else { engine.callbacks.networkAvailable(status == 3) }
            })
            lock.lock(); connected = wasConnected; let overflow = self.overflow; lock.unlock()
            callbacks.ended(overflow ? .inputOverflow : result == 1 ? (connected ? .engine : .udpUnavailable) : nil)
        }
        var wasConnected = false
        func didConnect() { lock.lock(); wasConnected = true; lock.unlock(); callbacks.connected() }
    }
    private let engine: Engine
    private let startLock = NSLock()
    private var started = false
    public init(bootstrap: MoshBootstrap, size: TerminalSize = .init(), callbacks: MoshCallbacks) throws {
        guard let native = mt_mosh_create(bootstrap.ip, bootstrap.port, bootstrap.key, UInt16(size.columns), UInt16(size.rows)) else {
            throw MoshError.invalidBootstrap
        }
        engine = Engine(native: native, callbacks: callbacks)
    }
    deinit { mt_mosh_stop(engine.native) }
    public func start() {
        startLock.lock(); defer { startLock.unlock() }
        guard !started else { return }; started = true
        let engine = engine
        let thread = Thread { engine.run() }
        thread.name = "MiniTerm.Mosh"; thread.qualityOfService = .userInitiated; thread.start()
    }
    public func send(_ data: Data) {
        let accepted = data.withUnsafeBytes { mt_mosh_send(engine.native, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        if accepted == 0 {
            engine.lock.lock(); engine.overflow = true; engine.lock.unlock(); disconnect()
        }
    }
    public func resize(_ size: TerminalSize) { mt_mosh_resize(engine.native, UInt16(size.columns), UInt16(size.rows)) }
    public func setOutputPaused(_ paused: Bool) { mt_mosh_pause(engine.native, paused ? 1 : 0) }
    public func disconnect() { mt_mosh_stop(engine.native) }
}
