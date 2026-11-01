import GhosttyTerminal
import SwiftUI

@main
struct MiniTermApp: App {
    init() { TerminalDebugLog.disable() }
    var body: some Scene {
        WindowGroup { ConnectionView() }
    }
}
