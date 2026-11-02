#!/usr/bin/env python3
"""Build/run isolated Ghostty adapter tests with UIKit test doubles, not hardware.

Usage: python3 Scripts/test_keyboard_input.py SIMULATOR_UDID
Requires Xcode, Apple Silicon and a booted iPad simulator. Never opens SSH.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = Path(__file__).resolve().parent.parent
    device = sys.argv[1]
    bundle = "com.samesense.mini-term.keyboard-probe"
    with tempfile.TemporaryDirectory(prefix="mini-term-keyboard-input-", dir="/private/tmp") as directory:
        probe = Path(directory)
        for folder in ["App", "Sources", "Tests", "Vendor"]:
            shutil.copytree(root / folder, probe / folder, ignore=shutil.ignore_patterns(".build", ".git", ".swiftpm"))
        for file in ["Package.swift", "Package.resolved"]:
            shutil.copy2(root / file, probe / file)
        (probe / "Scripts").mkdir()
        generator = (root / "Scripts/generate_project.py").read_text().replace("com.samesense.mini-term", bundle)
        (probe / "Scripts/generate_project.py").write_text(generator)
        run(sys.executable, str(probe / "Scripts/generate_project.py"))
        (probe / "App/MiniTermApp.swift").write_text("import SwiftUI\n@main struct ProbeApp: App { var body: some Scene { WindowGroup { KeyboardAdapterProbeView() } } }\n")
        screen = probe / "App/TerminalScreen.swift"
        screen.write_text(screen.read_text() + "\n" + (root / "Tests/KeyboardAdapterProbe.swift").read_text())
        derived = "/private/tmp/mini-term-keyboard-probe-derived"
        log = Path("/private/tmp/mini-term-keyboard-probe-build.log")
        with log.open("w") as output:
            run("xcodebuild", "-project", str(probe / "MiniTerm.xcodeproj"), "-scheme", "MiniTerm",
                "-destination", "id=" + device, "-derivedDataPath", derived,
                "-clonedSourcePackagesDirPath", "/private/tmp/mini-term-switcher-derived/SourcePackages",
                "CODE_SIGN_IDENTITY=-", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build", stdout=output, stderr=subprocess.STDOUT)
        app = Path(derived) / "Build/Products/Debug-iphonesimulator/MiniTerm.app"
        run("xcrun", "simctl", "install", device, str(app))
        try:
            container = run("xcrun", "simctl", "get_app_container", device, bundle, "data", capture_output=True).stdout.strip()
            report_path = Path(container) / "Documents/keyboard-probe.json"
            report_path.unlink(missing_ok=True)
            run("xcrun", "simctl", "launch", device, bundle)
            for _ in range(90):
                if report_path.exists():
                    report = json.loads(report_path.read_text())
                    print(json.dumps(report, indent=2))
                    if report["failures"]:
                        sys.exit("Keyboard adapter probe failed")
                    return
                time.sleep(0.5)
            sys.exit("Keyboard adapter probe timed out; build log: " + str(log))
        finally:
            run("xcrun", "simctl", "uninstall", device, bundle)


if __name__ == "__main__":
    main()
