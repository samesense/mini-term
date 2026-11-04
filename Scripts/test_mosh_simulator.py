#!/usr/bin/env python3
"""Test real Mosh UDP + Ghostty + auxiliary SSH recovery in an isolated iPad app.
Usage: python3 Scripts/test_mosh_simulator.py SIMULATOR_UDID MOSH_TEST_SERVER
Build the host fixture with Scripts/build_mosh_test_server.py first.
"""
import ctypes, os, re, signal, subprocess, sys
from pathlib import Path
from test_keyboard_input import run_probe

if len(sys.argv) != 3:
    sys.exit(__doc__)
env = dict(os.environ, MOSH_SERVER_NETWORK_TMOUT='600')
server = subprocess.run([sys.argv[2], 'new', '-i', '127.0.0.1', '-c', '256', '-l', 'LANG=en_US.UTF-8', '--', '/bin/sh', '-c',
    "stty -echo; printf 'MOSH_SIM_READY\\n'; while IFS= read -r line; do case \"$line\" in quit) exit 0;; *) printf 'REPLY:%s\\n' \"$line\";; esac; done"],
    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
match = re.search(rb'^MOSH CONNECT (\d+) ([A-Za-z0-9/+]{22})\r?$', server.stdout, re.M)
if not match:
    sys.exit('Test server did not return valid startup credentials')
os.environ['SIMCTL_CHILD_MINITERM_MOSH_TEST_BOOTSTRAP'] = match.group().decode() + '\n'
try:
    run_probe(sys.argv[1], fixture_name='MoshProbe.swift', view_name='MoshProbeView', report_name='mosh-probe.json', bundle='com.samesense.mini-term.mosh-probe')
finally:
    os.environ.pop('SIMCTL_CHILD_MINITERM_MOSH_TEST_BOOTSTRAP', None)
    pid = re.search(rb'\[mosh-server detached, pid = (\d+)\]', server.stdout)
    if pid:
        try:
            # Verify the executable before signalling a detached PID, which may
            # already have exited (and could theoretically have been reused).
            path = ctypes.create_string_buffer(4096)
            proc = ctypes.CDLL('/usr/lib/libproc.dylib')
            if proc.proc_pidpath(int(pid[1]), path, len(path)) > 0 and Path(os.fsdecode(path.value)).resolve() == Path(sys.argv[2]).resolve():
                os.kill(int(pid[1]), signal.SIGTERM)
        except ProcessLookupError:
            pass
