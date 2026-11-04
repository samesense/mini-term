#!/usr/bin/env python3
"""Run UIKit keyboard/renderer ownership regression checks in an isolated simulator app."""
import sys
from test_keyboard_input import run_probe

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 Scripts/test_input_lifecycle.py SIMULATOR_UDID")
    run_probe(sys.argv[1], fixture_name="InputLifecycleProbe.swift", view_name="InputLifecycleProbeView",
              report_name="input-lifecycle-probe.json", bundle="com.samesense.mini-term.input-lifecycle-probe")
