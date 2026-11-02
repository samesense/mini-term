// Real app models; connection attempts target only a closed loopback port.
import SwiftUI
import UIKit

struct SessionFeaturesProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SessionFeaturesProbeController { SessionFeaturesProbeController() }
    func updateUIViewController(_ controller: SessionFeaturesProbeController, context: Context) {}
}

final class SessionFeaturesProbeController: UIViewController {
    private var checks: [String] = []
    private var failures: [String] = []

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await runChecks() }
    }

    private func verify(_ label: String, _ condition: Bool) {
        checks.append(label)
        if !condition { failures.append(label) }
    }

    private func waitForFinish(_ model: TerminalSessionModel) async {
        for _ in 0..<100 {
            if model.state.isFinished { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func runChecks() async {
        verify("action symbols exist on iPadOS", ["doc.on.doc", "pencil", "star", "star.fill", "star.slash"].allSatisfy { UIImage(systemName: $0) != nil })
        let connection = try! SSHConnection(host: "127.0.0.1", username: "private-account", port: 1, tmuxSession: "private-session")
        var first: TerminalSessionModel? = TerminalSessionModel(connection: connection, seed: SSHIdentity.generateSeed())
        verify("active/idle model cannot start a duplicate reconnect", first!.reconnectSession() == nil)
        first!.onConnected = {}
        first!.start()
        first!.start()
        verify("repeated start owns just one attempt", first!.diagnostics.attempts == 1)
        await waitForFinish(first!)
        verify("closed loopback port reaches finished state", first!.state.isFinished)
        let next = first!.reconnectSession()
        verify("finished model offers a fresh reconnect", next != nil)
        if let next {
            verify("reconnect has new model identity", next.id != first!.id)
            verify("reconnect preserves destination and tmux name", next.connection == connection)
            verify("reconnect owns a fresh terminal session", next.terminalSession !== first!.terminalSession)
            verify("connected-history callback survives reconnect", next.onConnected != nil)
            verify("new attempt begins from idle", next.state == .idle)
            next.start()
            next.start()
            verify("diagnostic history counts one additional attempt", next.diagnostics.attempts == 2)
            await waitForFinish(next)
            verify("reconnected transport independently reaches finished state", next.state.isFinished)
            verify("retired model did not receive the new attempt", first!.diagnostics.attempts == 1)
            let text = AppDiagnostics.text(next.diagnostics)
            verify("failure report has sanitized network category", text.contains("[network]") || text.contains("[transport]"))
            verify("report omits host/account/session names", !text.contains(connection.host) && !text.contains(connection.username) && !text.contains(connection.tmuxSession!))
            verify("report includes keyboard edge counts", text.contains("Keyboard event counts"))
            weak var retired = first
            first = nil
            try? await Task.sleep(for: .milliseconds(100))
            verify("retired model releases after replacement", retired == nil)
            next.disconnect()
        }
        let data = try! JSONSerialization.data(withJSONObject: ["checks": checks.count, "failures": failures, "labels": checks], options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL.documentsDirectory.appendingPathComponent("session-probe.json"), options: .atomic)
    }
}
