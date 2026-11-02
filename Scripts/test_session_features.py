#!/usr/bin/env python3
"""Verify real app reconnect model isolation with a closed local port, never a remote Mac.

Usage: python3 Scripts/test_session_features.py SIMULATOR_UDID
"""
import sys
from test_keyboard_input import run_probe

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    run_probe(sys.argv[1], fixture_name="SessionFeaturesProbe.swift", view_name="SessionFeaturesProbeView",
              report_name="session-probe.json", bundle="com.samesense.mini-term.session-probe")
