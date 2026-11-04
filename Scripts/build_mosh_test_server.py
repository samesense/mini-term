#!/usr/bin/env python3
"""Build a host-only, pinned upstream mosh-server fixture after `swift build`.
No installed Mosh, user SSH credentials or system service changes are needed.
Usage: python3 Scripts/build_mosh_test_server.py SCRATCH_PATH OUTPUT
"""
from pathlib import Path
import platform, subprocess, sys
root = Path(__file__).resolve().parent.parent
scratch, output = map(Path, sys.argv[1:])
objects = list(scratch.rglob('MoshNative-t.build/Objects-normal/' + platform.machine() + '/*.o'))
if not objects:
    objects = list(scratch.rglob('MoshNative.build/**/*.o'))
if not objects:
    sys.exit('Build MiniTermCore for macOS first with swift build --scratch-path SCRATCH_PATH')
fixture = root / 'Tests/MoshServerFixture'
command = ['xcrun', 'clang++', '-std=c++17', '-DHAVE_UTIL_H=1', '-DHAVE_FORKPTY=1', '-DHAVE_CFMAKERAW=1', '-DBUILD_VERSION="miniterm-test"',
           '-I'+str(fixture), '-I'+str(root/'Vendor/MoshNative/upstream'), '-I'+str(root/'Vendor/MoshNative/upstream/src/include'),
           '-I'+str(root/'Vendor/MoshNative/protobuf'), *map(str, fixture.rglob('*.cc')), *map(str,objects), '-lz', '-o',str(output)]
subprocess.run(command, check=True)
print(output)
