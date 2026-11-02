import GhosttyTerminal
import MiniTermCore
import SwiftUI

@main
struct MiniTermApp: App {
    init() {
        TerminalDebugLog.disable()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--design-preview") { Self.prepareDesignPreview() }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ConnectionView()
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Explicit simulator-only fixtures for design review. Never touches a physical device or connects to a host.
    private static func prepareDesignPreview() {
        var document = ConnectionHistoryDocument()
        for (host, session) in [("build-mac.local", "work"), ("mac-mini.local", "codex")] {
            let connection = try! SSHConnection(host: host, username: "developer", port: 22, tmuxSession: session)
            document.remember(ConnectionProfile(connection), connected: true)
        }
        UserDefaults.standard.set(try! document.encoded(), forKey: "connections.history.v1")
    }
    #endif
}
