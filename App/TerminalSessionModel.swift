import Combine
import Foundation
import MiniTermGhosttyTerminal
import MiniTermCore

/// Synchronous Ghostty callbacks can arrive on rendering/parser threads. This box only routes bytes;
/// the SSH transport owns ordering and its event loop owns all network state.
final class TerminalBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: SSHTransport?
    private var size = TerminalSize()

    func attach(_ transport: SSHTransport) {
        lock.lock()
        self.transport = transport
        let size = self.size
        lock.unlock()
        transport.resize(size)
    }
    func detach() {
        lock.lock(); transport = nil; lock.unlock()
    }
    func send(_ data: Data) { current()?.send(data) }
    func pause(_ paused: Bool) { current()?.setOutputPaused(paused) }
    func resize(_ viewport: InMemoryTerminalViewport) {
        let size = TerminalSize(columns: Int(viewport.columns), rows: Int(viewport.rows),
                                widthPixels: Int(viewport.widthPixels), heightPixels: Int(viewport.heightPixels))
        lock.lock()
        self.size = size
        let transport = transport
        lock.unlock()
        transport?.resize(size)
    }
    private func current() -> SSHTransport? {
        lock.lock(); defer { lock.unlock() }
        return transport
    }
}

struct HostTrustRequest: Identifiable {
    let id = UUID()
    let fingerprint: String
    let key: String
    let completion: @Sendable (Result<Void, Error>) -> Void
}

@MainActor
final class TerminalSessionModel: ObservableObject, Identifiable {
    let id = UUID()
    let connection: SSHConnection
    let terminalSession: InMemoryTerminalSession
    @Published private(set) var state: ConnectionState = .idle
    @Published var trustRequest: HostTrustRequest?
    var onConnected: (() -> Void)?
    private(set) var diagnostics: SessionDiagnostics
    private let seed: Data
    private let keychain = KeychainStore()
    private let bridge: TerminalBridge
    private var transport: SSHTransport?
    private var pendingTrust: HostTrustRequest?

    init(connection: SSHConnection, seed: Data, diagnostics: SessionDiagnostics? = nil) {
        self.connection = connection
        self.seed = seed
        self.diagnostics = diagnostics ?? SessionDiagnostics(usesTmux: connection.tmuxSession != nil)
        let bridge = TerminalBridge()
        self.bridge = bridge
        terminalSession = InMemoryTerminalSession(write: { bridge.send($0) }, resize: { bridge.resize($0) })
        terminalSession.setOutputBacklogHandler(highWater: 1_048_576, lowWater: 262_144) { bridge.pause($0) }
    }

    func start() {
        guard transport == nil else { return }
        diagnostics.beginAttempt()
        let session = terminalSession
        let transport = SSHTransport(callbacks: .init(state: { [weak self] state in
            DispatchQueue.main.async { self?.didChangeState(state) }
        }, output: { data in
            session.receive(data) // Ghostty parses on its serial output queue, never the main thread.
        }, failure: { [weak self] failure in
            DispatchQueue.main.async {
                self?.diagnostics.record(.failed(""), failure: failure)
            }
        }))
        self.transport = transport
        bridge.attach(transport)
        transport.connect(to: connection, seed: seed) { [weak self] key, completion in
            DispatchQueue.main.async {
                guard let self else { completion(.failure(TerminalError.cancelled)); return }
                self.verify(key: key, completion: completion)
            }
        }
    }

    /// A new model owns a new socket, byte queues, bridge and terminal surface.
    /// Old callbacks can only reach the retired model, never the next attempt.
    func reconnectSession() -> TerminalSessionModel? {
        guard state.isFinished else { return nil }
        disconnect()
        let next = TerminalSessionModel(connection: connection, seed: seed, diagnostics: diagnostics)
        next.onConnected = onConnected
        return next
    }

    func disconnect() {
        if let request = pendingTrust {
            pendingTrust = nil
            trustRequest = nil
            request.completion(.failure(TerminalError.cancelled))
        }
        transport?.disconnect()
        bridge.detach() // Break bridge → transport → output callback → session → bridge.
    }

    func answerTrust(_ request: HostTrustRequest, allow: Bool) {
        // Ignore a dismissed or stale alert; its completion was already resolved by disconnect().
        guard pendingTrust?.id == request.id else { return }
        pendingTrust = nil
        trustRequest = nil
        guard allow else { request.completion(.failure(TerminalError.hostKeyRejected)); return }
        do {
            try keychain.save(Data(request.key.utf8), account: "host:\(connection.hostKeyAccount)")
            request.completion(.success(()))
        } catch { request.completion(.failure(error)) }
    }

    private func verify(key: String, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard !state.isFinished else { completion(.failure(TerminalError.cancelled)); return }
        do {
            let storedData = try keychain.read(account: "host:\(connection.hostKeyAccount)")
            let stored = storedData.flatMap { String(data: $0, encoding: .utf8) }
            // A corrupt existing record must never turn into implicit first use.
            if storedData != nil && stored == nil { throw TerminalError.invalidHostKey }
            if try SSHIdentity.checkHostKey(key, stored: stored) {
                completion(.success(()))
            } else {
                let request = HostTrustRequest(fingerprint: try SSHIdentity.fingerprint(openSSHKey: key),
                                               key: key, completion: completion)
                pendingTrust = request
                trustRequest = request
            }
        } catch { completion(.failure(error)) }
    }

    private func didChangeState(_ state: ConnectionState) {
        self.state = state
        diagnostics.record(state)
        if state == .connected { onConnected?() }
        if state.isFinished { bridge.detach() }
        if state.isFinished, let request = pendingTrust {
            pendingTrust = nil
            trustRequest = nil
            request.completion(.failure(TerminalError.cancelled))
        }
    }
}

@MainActor
enum AppDiagnostics {
    static func text(_ diagnostics: SessionDiagnostics) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let report = diagnostics.report(appVersion: "\(version) (\(build))", systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        let keyboard = KeyboardEventDiagnostics.shared
        return report + "\n\nKeyboard event counts (down/up)\nUIKit Caps: \(keyboard.capsDown)/\(keyboard.capsUp)\nUIKit left Control: \(keyboard.controlDown)/\(keyboard.controlUp)\nGameController Caps: \(keyboard.gcDown)/\(keyboard.gcUp)"
    }
}
