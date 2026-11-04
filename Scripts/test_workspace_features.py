#!/usr/bin/env python3
"""Exercise wake/network recovery, saved previews and SFTP models in an isolated simulator app."""
import sys
from test_keyboard_input import run_probe

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 Scripts/test_workspace_features.py SIMULATOR_UDID")
    run_probe(sys.argv[1], fixture_name="WorkspaceFeaturesProbe.swift", view_name="WorkspaceFeaturesProbeView",
              report_name="workspace-features-probe.json", bundle="com.samesense.mini-term.workspace-features-probe",
              capture_name="workspace-files.png", extra_fixtures=("PreviewProbe.swift",))
