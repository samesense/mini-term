# Mosh native transport

Mosh protocol, AES-OCB, terminal state synchronization, parser and display source is
vendored from [blinksh/mosh](https://github.com/blinksh/mosh/tree/3640d36678dc415ba24f03d7f6fb20a0dac1fa6b),
commit `3640d36678dc415ba24f03d7f6fb20a0dac1fa6b` (Blink 1.4.0+blink-18.4.5).
Only the client core is compiled into the app. No downloaded binary is used.
`Tests/MoshServerFixture` contains the matching upstream server and utilities,
compiled only by the macOS test fixture script.

Mosh is **GPL-3.0-or-later**; see [COPYING](COPYING), [COPYING.iOS](COPYING.iOS)
and source-file notices. The OCB implementation carries its own permissive notice.
Linking this dependency brings GPL distribution obligations to the combined app.
The iOS exception addresses App Store terms; it does not waive the remaining GPL
obligations. This repository does not currently declare a license for the whole
app. Resolve the combined application's distribution license and supply its
corresponding source before distributing builds outside development testing.

The protobuf-lite runtime and headers come from Google's Protobuf **v21.1**
(C++ runtime 3.21.1), with its [BSD license](PROTOBUF-LICENSE). Only upstream's
`cmake/libprotobuf-lite.cmake` source list is built. Generated `.pb.cc`/`.pb.h`
files use the matching official `protoc-21.1-osx-universal_binary.zip` release.
Compiler, full reflection runtime, and test headers are omitted.

Local changes to upstream:

- `upstream/src/include/config.h` selects Apple CommonCrypto and native Apple APIs.
- `terminaldisplayinit_ios.cc` removes unused curses includes; the upstream iOS
  initializer already uses fixed xterm capabilities without curses calls.
- `NativeClient.cc` is a new embedding frontend using upstream state/crypto. It
  uses a dedicated worker, thread-local Darwin `UTF-8` locale and `poll`, with no process
  signal installation, stdio replacement, `exit`, suspension or job-control code.
- Native producer input is bounded to 1 MiB; unacknowledged input is drained in
  order with a 64 KiB protocol-history cap. Output pause stops rendering diffs
  while the protocol continues receiving bounded screen state.

The prototype preserves sessions only while its engine remains in memory. It does
not serialize session keys/state, promise background execution, or provide local
prediction. The existing Ghostty in-memory adapter renders the resulting ANSI
screen diffs. Mosh's remote terminal emulator is in the path, so Ghostty features
outside Mosh's supported terminal protocol may differ from direct SSH.

Protobuf compatibility changes for current Clang: `strutil.cc` uses bounded
`snprintf` with space for the terminator in its four-character byte escape;
`generated_message_tctable_impl.h` explicitly calls `std::abort` after fatal logging
so Clang can verify its `[[noreturn]]` contract. The native target suppresses only
`-Wshorten-64-to-32` for upstream's integer-width conversions. Swift and other C++
diagnostics remain enabled. Build inputs explicitly list translation units; proto
and `.inc` inputs are retained as source/header material rather than build actions.

Physical iPadOS validation confirmed `newlocale("en_US.UTF-8")` is unavailable,
while Darwin’s encoding-only `newlocale("UTF-8")` succeeds. The native worker uses
the latter. Return codes distinguish UTF-8 initialization, engine failure, UDP
startup timeout and cancellation so an initialization bug cannot blame the firewall.
