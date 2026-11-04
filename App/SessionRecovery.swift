import Combine
import MiniTermCore
import Network
import SwiftUI

@MainActor
final class SessionRecovery: ObservableObject {
    @Published private(set) var session: TerminalSessionModel
    @Published private(set) var message: String?
    private var policy = ReconnectPolicy()
    private var stateObservation: AnyCancellable?
    private var retry: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var foreground = true
    private var networkAvailable = true
    private var checking = false
    private var stopped = false
    init(_ session: TerminalSessionModel, monitorNetwork: Bool = true) {
        self.session = session
        observeSession()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(available) }
        }
        if monitorNetwork { monitor.start(queue: DispatchQueue(label: "MiniTerm.reconnect.path")) }
    }
    deinit { monitor.cancel(); retry?.cancel() }
    private func observeSession() {
        stateObservation = session.$state.sink { [weak self] state in
            // @Published emits before its property changes. Defer so replacement
            // sees the finished state, and reject callbacks from retired models.
            guard let self else { return }
            let id = session.id
            Task { @MainActor [weak self] in
                guard let self, self.session.id == id else { return }
                self.stateChanged(state)
            }
        }
    }
    func sceneActive(_ active: Bool) {
        let waking = active && !foreground
        foreground = active
        if !active { policy.interruptedConnection(); retry?.cancel(); retry = nil; message = nil }
        else if waking { recoverIfNeeded(checkSocket: true) }
    }
    func networkChanged(_ available: Bool) {
        let returned = available && !networkAvailable
        networkAvailable = available
        if !available {
            policy.interruptedConnection(); retry?.cancel(); retry = nil
            if session.state.isFinished { message = "Waiting for network…" }
        } else if returned { recoverIfNeeded(checkSocket: true) }
    }
    private var enabled: Bool { (UserDefaults.standard.object(forKey: "connection.autoReconnect") as? Bool) ?? true }
    private func recoverIfNeeded(checkSocket: Bool) {
        guard foreground, networkAvailable, !stopped, enabled else { return }
        if session.state == .connected, checkSocket, !checking {
            checking = true
            let current = session
            Task { [weak self] in
                let responsive = await current.checkConnectionAfterWake()
                guard let self, self.session === current, !stopped else { return }
                self.checking = false
                if responsive { policy.verifiedResponsive() }
                else if current.state.isFinished { self.scheduleRetry() }
            }
        } else if session.state.isFinished { scheduleRetry() }
    }
    private func stateChanged(_ state: ConnectionState) {
        guard !stopped else { return }
        if state == .connected {
            policy.connected(); retry?.cancel(); retry = nil; message = nil
        } else if state.isFinished { scheduleRetry() }
    }
    private func scheduleRetry() {
        guard !stopped, foreground, networkAvailable, retry == nil else { return }
        policy.enabled = enabled
        guard let seconds = policy.nextDelay(failure: session.lastFailure?.kind) else { message = nil; return }
        let expected = session.id
        message = "Reconnecting in \(Int(seconds))s · attempt \(policy.attempts) of 6"
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled, !stopped, enabled, foreground, networkAvailable, session.id == expected else { return }
            retry = nil
            replaceSession()
        }
    }
    func reconnectManually() {
        retry?.cancel(); retry = nil; message = nil; stopped = false
        replaceSession()
    }
    private func replaceSession() {
        guard let next = session.reconnectSession() else { return }
        checking = false; stateObservation = nil
        session = next
        observeSession()
        // The replacement's Metal surface starts SSH in viewDidAppear.
    }
    func stopRetrying() {
        policy.stop(); retry?.cancel(); retry = nil; message = nil
        if session.state != .connected && !session.state.isFinished { session.disconnect() }
    }
    func close() {
        stopped = true; stopRetrying(); monitor.cancel(); stateObservation = nil
        session.disconnect()
    }
}

struct RecoveringTerminalScreen: View {
    @StateObject private var recovery: SessionRecovery
    @Environment(\.scenePhase) private var scenePhase
    init(model: TerminalSessionModel) { _recovery = StateObject(wrappedValue: SessionRecovery(model)) }
    init(recovery: SessionRecovery) { _recovery = StateObject(wrappedValue: recovery) }
    var body: some View {
        ZStack {
            TerminalScreen(model: recovery.session, onReconnect: { recovery.reconnectManually() },
                       recoveryMessage: recovery.message, onStopRetry: { recovery.stopRetrying() }, onDisconnect: { recovery.close() })
            .id(recovery.session.id)
        }
            .onChange(of: scenePhase, initial: true) { _, phase in recovery.sceneActive(phase == .active) }
            .onDisappear { recovery.close() }
    }
}
