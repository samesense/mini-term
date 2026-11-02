#!/usr/bin/env python3
"""Verify real WebKit + production forwarding against isolated, generated loopback SSH fixtures.

Usage: python3 Scripts/test_preview.py SIMULATOR_UDID
Never contacts a remote Mac or uses personal credentials. Does not automate the Safari app.
"""
import sys
from test_keyboard_input import run_probe

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run_probe(sys.argv[1], fixture_name="PreviewProbe.swift", view_name="PreviewProbeView",
              report_name="preview-probe.json", bundle="com.samesense.mini-term.preview-probe", capture_name="preview-workspace.png")
