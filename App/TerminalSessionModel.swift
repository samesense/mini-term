import Combine
import Foundation
import MiniTermGhosttyTerminal
import MiniTermCore

/// Synchronous Ghostty callbacks can arrive on rendering/parser threads. This box only routes bytes;
/// each transport owns ordering and its network state.
final class TerminalBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: (any TerminalTransport)?
    private var size = TerminalSize()

    func attach(_ transport: any TerminalTransport) {
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
    private func current() -> (any TerminalTransport)? {
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
    let preview: PreviewModel
    let files: RemoteFilesModel
    let usesMosh: Bool
    @Published private(set) var sshToolsAvailable = false
    @Published private(set) var moshWaitingForNetwork = false
    @Published private(set) var state: ConnectionState = .idle
    @Published var trustRequest: HostTrustRequest?
    var onConnected: (() -> Void)?
    private(set) var diagnostics: SessionDiagnostics
    private(set) var lastFailure: ConnectionFailure?
    private let seed: Data
    private let keychain = KeychainStore()
    private let bridge: TerminalBridge
    private var transport: SSHTransport?
    private var mosh: MoshTransport?
    private var sshAttempt = UUID()
    private var bootstrappingMosh = false
    private var sshConnecting = false
    private var pendingTrust: HostTrustRequest?
    private var explicitlyClosed = false

    init(connection: SSHConnection, seed: Data, diagnostics: SessionDiagnostics? = nil, usesMosh: Bool = false) {
        self.connection = connection
        self.seed = seed
        self.usesMosh = usesMosh
        preview = PreviewModel(connection: connection)
        files = RemoteFilesModel()
        self.diagnostics = diagnostics ?? SessionDiagnostics(usesTmux: connection.tmuxSession != nil)
        let bridge = TerminalBridge()
        self.bridge = bridge
        terminalSession = InMemoryTerminalSession(write: { bridge.send($0) }, resize: { bridge.resize($0) })
        terminalSession.setOutputBacklogHandler(highWater: 1_048_576, lowWater: 262_144) { bridge.pause($0) }
    }

    func start() {
        guard transport == nil, !explicitlyClosed else { return }
        diagnostics.beginAttempt()
        connectSSH()
    }

    private func connectSSH() {
        sshConnecting = true
        let attempt = UUID()
        sshAttempt = attempt
        let session = terminalSession
        let transport = SSHTransport(callbacks: .init(state: { [weak self] state in
            DispatchQueue.main.async {
                guard let self, self.sshAttempt == attempt else { return }
                self.sshStateChanged(state)
            }
        }, output: { data in
            session.receive(data) // Ghostty parses on its serial output queue, never the main thread.
        }, failure: { [weak self] failure in
            DispatchQueue.main.async {
                guard self?.sshAttempt == attempt, self?.mosh == nil else { return }
                self?.diagnostics.record(.failed(""), failure: failure)
                self?.lastFailure = failure
            }
        }))
        self.transport = transport
        preview.attach(transport)
        files.attach(transport)
        if !usesMosh { bridge.attach(transport) }
        transport.connect(to: connection, seed: seed, auxiliaryOnly: usesMosh) { [weak self] key, completion in
            DispatchQueue.main.async {
                guard let self, self.sshAttempt == attempt, !self.explicitlyClosed else { completion(.failure(TerminalError.cancelled)); return }
                self.verify(key: key, completion: completion)
            }
        }
    }

    /// A new model owns a new socket, byte queues, bridge and terminal surface.
    /// Old callbacks can only reach the retired model, never the next attempt.
    func reconnectSession() -> TerminalSessionModel? {
        guard state.isFinished else { return nil }
        disconnect()
        let next = TerminalSessionModel(connection: connection, seed: seed, diagnostics: diagnostics, usesMosh: usesMosh)
        next.onConnected = onConnected
        next.preview.restore(from: preview)
        return next
    }

    func disconnect() {
        explicitlyClosed = true
        mosh?.disconnect()
        preview.disconnected()
        files.disconnected()
        if let request = pendingTrust {
            pendingTrust = nil
            trustRequest = nil
            request.completion(.failure(TerminalError.cancelled))
        }
        transport?.disconnect()
        if !state.isFinished { didChangeState(.disconnected) }
        bridge.detach() // Break bridge → transport → output callback → session → bridge.
    }

    func checkConnectionAfterWake() async -> Bool {
        if usesMosh, mosh != nil, state == .connected {
            // Mosh keeps its UDP state across path changes. An auxiliary SSH failure must
            // never replace that live session. Reopen only the tools connection on wake.
            if !sshToolsAvailable, !sshConnecting { transport?.disconnect(); connectSSH() }
            else if let transport {
                do { try await transport.checkAlive().get() }
                catch { if !explicitlyClosed { connectSSH() } }
            }
            return state == .connected
        }
        guard let transport, state == .connected else { return false }
        do { try await transport.checkAlive().get(); return state == .connected }
        catch { return false }
    }

    private func sshStateChanged(_ state: ConnectionState) {
        guard !explicitlyClosed, !self.state.isFinished else { return }
        if !usesMosh { sshToolsAvailable = state == .connected; didChangeState(state); return }
        if state == .connected {
            sshConnecting = false
            sshToolsAvailable = true
            preview.connectionReady(); files.connectionReady()
            if mosh == nil { startMosh() }
        } else if state.isFinished {
            sshConnecting = false
            sshToolsAvailable = false
            preview.disconnected(); files.disconnected()
            if mosh == nil { didChangeState(state) }
        } else if mosh == nil { didChangeState(state) }
    }

    private func startMosh() {
        guard let transport, !bootstrappingMosh, !explicitlyClosed else { return }
        bootstrappingMosh = true
        didChangeState(.openingShell)
        let attempt = sshAttempt
        transport.startMosh(for: connection).whenComplete { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.sshAttempt == attempt, !self.explicitlyClosed, !self.state.isFinished else { return }
                self.bootstrappingMosh = false
                do { self.runMosh(try result.get()) }
                catch { self.moshEnded(.bootstrap) }
            }
        }
    }

    private func runMosh(_ bootstrap: MoshBootstrap) {
        let session = terminalSession
        do {
            let mosh = try MoshTransport(bootstrap: bootstrap, callbacks: .init(output: { session.receive($0) }, connected: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.explicitlyClosed else { return }
                    self.didChangeState(.connected)
                }
            }, ended: { [weak self] error in
                DispatchQueue.main.async { self?.moshEnded(error) }
            }, networkAvailable: { [weak self] available in
                DispatchQueue.main.async { self?.moshWaitingForNetwork = !available }
            }))
            self.mosh = mosh
            bridge.attach(mosh)
            mosh.start()
        } catch { moshEnded(.invalidBootstrap) }
    }

    private func moshEnded(_ error: MoshError?) {
        guard !explicitlyClosed else { return }
        mosh = nil
        transport?.disconnect()
        if let error {
            lastFailure = ConnectionFailure(error)
            diagnostics.record(.failed(""), failure: lastFailure)
            didChangeState(.failed(error.localizedDescription))
        } else { didChangeState(.disconnected) }
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
        if state == .connected { preview.connectionReady(); files.connectionReady(); onConnected?() }
        if state.isFinished { sshToolsAvailable = false; preview.disconnected(); files.disconnected(); bridge.detach() }
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
