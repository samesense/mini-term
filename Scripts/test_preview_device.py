#!/usr/bin/env python3
"""Run the isolated preview fixture on a paired physical iPad, then return to MiniTerm.

Requires a Personal Team selected in the local Xcode project. Uses generated
loopback fixtures, never a personal SSH identity or a remote Mac. The test app
briefly takes the foreground and is removed afterward.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Paired physical iPad UDID from xcrun devicectl list devices")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    project = (root / "MiniTerm.xcodeproj/project.pbxproj").read_text()
    match = re.search(r'DEVELOPMENT_TEAM = "?([A-Z0-9]+)"?;', project)
    if not match:
        sys.exit("Select your Personal Team in the local Xcode project before running this device probe.")
    bundle = "com.samesense.mini-term.preview-probe"
    with tempfile.TemporaryDirectory(prefix="mini-term-device-preview-", dir="/private/tmp") as directory:
        probe = Path(directory)
        for folder in ["App", "Sources", "Tests", "Vendor"]:
            shutil.copytree(root / folder, probe / folder, ignore=shutil.ignore_patterns(".build", ".git", ".swiftpm"))
        for filename in ["Package.swift", "Package.resolved"]:
            shutil.copy2(root / filename, probe / filename)
        (probe / "Scripts").mkdir()
        generator = (root / "Scripts/generate_project.py").read_text().replace("com.samesense.mini-term", bundle)
        (probe / "Scripts/generate_project.py").write_text(generator)
        run(sys.executable, str(probe / "Scripts/generate_project.py"))
        (probe / "App/MiniTermApp.swift").write_text(
            "import SwiftUI\n@main struct ProbeApp: App { var body: some Scene { WindowGroup { PreviewProbeView() } } }\n"
        )
        screen = probe / "App/TerminalScreen.swift"
        screen.write_text(screen.read_text() + "\n" + (root / "Tests/PreviewProbe.swift").read_text())
        derived = Path("/private/tmp/mini-term-physical-preview-derived")
        log_path = Path("/private/tmp/mini-term-physical-preview-build.log")
        with log_path.open("w") as log:
            run("xcodebuild", "-project", str(probe / "MiniTerm.xcodeproj"), "-scheme", "MiniTerm",
                "-destination", "id=" + args.device, "-derivedDataPath", str(derived),
                "-clonedSourcePackagesDirPath", "/private/tmp/mini-term-lcars-device-derived/SourcePackages",
                "DEVELOPMENT_TEAM=" + match[1], "-allowProvisioningUpdates", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                "build", stdout=log, stderr=subprocess.STDOUT)
        app = derived / "Build/Products/Debug-iphoneos/MiniTerm.app"
        run("xcrun", "devicectl", "device", "install", "app", "--device", args.device, str(app))
        try:
            run("xcrun", "devicectl", "device", "process", "launch", "--device", args.device, bundle)
            report_path = Path("/private/tmp/mini-term-physical-preview-result.json")
            report_path.unlink(missing_ok=True)
            for _ in range(60):
                copied = subprocess.run([
                    "xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
                    "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                    "--source", "Documents/preview-probe.json", "--destination", str(report_path),
                ], capture_output=True, text=True)
                if copied.returncode == 0 and report_path.exists():
                    report = json.loads(report_path.read_text())
                    print(json.dumps(report, indent=2))
                    if report["failures"]:
                        sys.exit("Physical preview probe failed")
                    return
                time.sleep(1)
            sys.exit("Physical preview probe timed out; build log: " + str(log_path))
        finally:
            run("xcrun", "devicectl", "device", "uninstall", "app", "--device", args.device, bundle)
            subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                            "com.samesense.mini-term"], check=False)


if __name__ == "__main__":
    main()
