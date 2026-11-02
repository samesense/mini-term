#!/usr/bin/env python3
"""Run the real terminal constraints in UIKit on a booted iOS simulator.

Usage: python3 Scripts/test_keyboard_layout.py SIMULATOR_UDID
Requires Xcode and a booted simulator. Uses an isolated test app, without SSH.
"""

import pathlib
import plistlib
import subprocess
import sys
import tempfile


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = (pathlib.Path(__file__).resolve().parent.parent / "App/TerminalScreen.swift").read_text()
    # Compile the production helper itself, not a second copy of its calculations.
    helper = source[source.index("@MainActor\nfinal class TerminalKeyboardLayout"):source.index("/// A tap still travels")]
    harness = r'''
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Probe", sessionRole: session.role)
        configuration.delegateClass = ProbeSceneDelegate.self
        return configuration
    }
}

final class ProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ProbeController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class ProbeController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let host = UIView(frame: CGRect(x: 0, y: 100, width: 700, height: 659))
        view.addSubview(host)
        let terminal = UIView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminal)
        let layout = TerminalKeyboardLayout(terminal: terminal, host: host)
        host.layoutIfNeeded()
        var checks = 0
        func expect(_ height: CGFloat, _ label: String) {
            host.setNeedsLayout()
            host.layoutIfNeeded()
            guard abs(terminal.frame.height - height) < 0.5, !terminal.hasAmbiguousLayout else {
                print("FAIL: \(label): expected \(height), got \(terminal.frame)")
                fflush(stdout)
                exit(1)
            }
            checks += 1
        }
        expect(659, "hidden keyboard fills the host")
        layout.update(keyboardFrame: CGRect(x: 0, y: 191, width: 700, height: 468))
        expect(191, "docked keyboard and accessory")

        // Reproduce the log: a 191-point host still has a 468-point offset.
        // Required geometry stays satisfiable even before the next update.
        host.frame.size.height = 191
        expect(0, "stale offset during a resize")
        layout.update(keyboardFrame: CGRect(x: 0, y: -277, width: 700, height: 468))
        expect(0, "keyboard covers the entire short host")

        host.frame.size.height = 659
        layout.update(keyboardFrame: CGRect(x: 0, y: 191, width: 700, height: 468))
        expect(191, "restore after resize")
        host.frame.size = CGSize(width: 400, height: 400)
        layout.update(keyboardFrame: CGRect(x: 0, y: 250, width: 700, height: 468))
        expect(250, "narrow window")
        layout.update(keyboardFrame: CGRect(x: 100, y: 100, width: 200, height: 200))
        expect(400, "floating keyboard does not collapse the grid")
        layout.update(keyboardFrame: CGRect(x: 0, y: 100, width: 400, height: 100))
        expect(400, "undocked keyboard")
        layout.update(keyboardFrame: CGRect(x: 0, y: 400, width: 400, height: 468))
        expect(400, "dismissed keyboard")
        layout.update(keyboardFrame: nil)
        expect(400, "no frame available")
        print("PASS: \(checks) terminal keyboard layout checks")
        fflush(stdout)
        exit(0)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="mini-term-keyboard-", dir="/private/tmp") as directory:
        root = pathlib.Path(directory)
        app = root / "KeyboardLayoutProbe.app"
        app.mkdir()
        swift = root / "Probe.swift"
        swift.write_text("import UIKit\n" + helper + harness)
        bundle = "com.samesense.mini-term.keyboard-layout-probe"
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "KeyboardLayoutProbe",
            "CFBundleName": "KeyboardLayoutProbe", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "LSRequiresIPhoneOS": True, "UIDeviceFamily": [2],
            "UILaunchScreen": {}, "MinimumOSVersion": "17.0",
            "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        }))
        sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", capture_output=True).stdout.strip()
        run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-sdk", sdk,
            "-target", "arm64-apple-ios17.0-simulator", str(swift), "-o", str(app / "KeyboardLayoutProbe"))
        run("codesign", "--force", "--sign", "-", str(app))
        run("xcrun", "simctl", "install", sys.argv[1], str(app))
        try:
            result = run("xcrun", "simctl", "launch", "--console", sys.argv[1], bundle, capture_output=True, timeout=30)
            print(result.stdout)
            if "PASS: 10 terminal keyboard layout checks" not in result.stdout or "Unable to simultaneously satisfy constraints" in result.stdout + result.stderr:
                sys.exit(result.stderr or "Keyboard layout probe failed")
        finally:
            run("xcrun", "simctl", "uninstall", sys.argv[1], bundle)


if __name__ == "__main__":
    main()
