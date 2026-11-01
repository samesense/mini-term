# Validation record and acceptance checklist

## Local evidence — 2026-11-01

Environment: Apple Silicon macOS, Apple Swift 6.4 command-line tools. `xcodebuild -version` reports that the active developer directory is CommandLineTools and requires Xcode; no Xcode application or iOS SDK was found. No physical iPad or personal remote Mac was used.

- **PASS:** independent `MiniTermCore` compilation with pinned NIOSSH/NIO/Crypto.
- **PASS:** full app dependency resolution, including the checksum-verified Ghostty XCFramework and iOS device/simulator slices.
- **PASS:** compile/link of the pinned Ghostty macOS wrapper and the actual `App/TerminalSessionModel.swift` in a temporary verification package. This validates the shared model’s Ghostty/concurrency APIs, not the UIKit view or iOS renderer.
- **PASS:** Swift syntax parsing of all `App/*.swift` files.
- **PASS:** generated `.pbxproj` passes `plutil -lint`; shared scheme XML parses; project generation is deterministic; both dependency lockfiles parse.
- **PASS:** all **11 tests in 2 suites**, including encrypted SSH PTY traffic, backpressure, tmux exec, host mismatch, PTY rejection and cancellation during host verification. Final run: 0.130 seconds after compilation.
- **NOT RUN:** iOS device/simulator compilation, app launch, Keychain operations in a signed iOS app, actual macOS Remote Login, real tmux attachment, interactive Codex, rendering/keyboard/copy-paste device tests, and GitHub Actions.

This machine’s command-line installation has stale Swift 5.10 private PackageDescription interfaces alongside Swift 6.4 public interfaces/libraries. Ordinary `swift build` initially fails at manifest compilation. A temporary copy of `/Library/Developer/CommandLineTools/usr/lib/swift/pm` under `/private/tmp/mini-term-swiftpm-libs`, excluding `*.private.swiftinterface`, lets the current public interface load. `SWIFTPM_CUSTOM_LIBS_DIR` points to that copy for local validation; no system file was modified. The Swift Build engine also omitted the Swift Testing macro plugin on one incremental module-emission step; the expanded suite is run with an explicit plugin path. These are local toolchain workarounds, not app requirements. Prefer a complete, consistently installed Xcode toolchain for development.

Local verification command (specific to this toolchain installation):

```sh
env SWIFTPM_CUSTOM_LIBS_DIR=/private/tmp/mini-term-swiftpm-libs \
  swift test \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

On a standard Xcode 26+ installation, use `swift test` and the README’s `xcodebuild` commands. The repository does not contain or depend on the temporary verification package.

## Automated coverage

Tests use Swift Testing and real encrypted TCP connections to ephemeral NIOSSH loopback servers. They use generated test keys, perform host-key verification, and never read personal SSH credentials. They cover:

- Host/username/port normalization and validation, IPv6 literals, dimension bounds.
- tmux session-name restrictions and safe startup command generation.
- Raw byte preservation, split UTF-8, ANSI, NUL and input queue overflow behavior.
- Stable Ed25519 public-key generation and SHA256 fingerprints checked against `ssh-keygen`.
- Public-key login, PTY-before-shell acknowledgement, 100 KB byte-for-byte echo, read pause/resume, resize, and clean disconnect state ordering.
- Rejected/mismatching host keys block the session.
- Rejected PTY never reports Connected.
- tmux requests a PTY followed by exec.
- Disconnect during first-use verification is final even if a trust reply arrives late.

## Device and real-Mac acceptance

Run these on an iPad mini in both orientations. Record model, iPadOS/Xcode versions, Mac OS/version, and results. Leave unchecked until actually observed.

- [ ] Build both unsigned simulator and device targets; sign and launch on the physical iPad using a Personal Team.
- [ ] Generate the app identity; copy only its public key to the Mac’s authorized_keys; relaunch and confirm the identity persists.
- [ ] Connect to macOS Remote Login on LAN, by IPv4/hostname and (if used) Tailscale name/IP. Verify the SHA256 host fingerprint independently before first trust.
- [ ] Reject first-use trust and confirm no login occurs. Cancel while the alert is open and while a connection is pending.
- [ ] Reconnect to a previously trusted host. Test a controlled changed host key and confirm rejection before authentication; test the explicit forget-and-reverify flow.
- [ ] Invalid hostname, closed port, wrong username/uninstalled client key and server-rejected PTY display useful errors and return to the form cleanly.
- [ ] Run `ls -la`, `top`, and `htop` if installed; ANSI colors, refresh and screen clearing remain correct.
- [ ] Run `vim`; test cursor positioning, arrows, Esc, Ctrl combinations, insert mode and UTF-8 text.
- [ ] Run `tmux new-session -s test`, detach with Ctrl+B then D, and reattach. Enter a named session in Mini Term and verify it creates or attaches correctly. Confirm missing tmux reports its remote error.
- [ ] Start Codex interactively inside tmux. Type prompts, navigate its UI, interrupt a command, scroll and paste multiline text. Repeat for Claude Code if used.
- [ ] Rotate and resize (including Split View/Stage Manager if used). `stty size` and full-screen programs track the visible terminal grid; the prompt stays above the keyboard/accessory bar.
- [ ] Hardware keyboard: arrows, Escape, Tab, Ctrl+C, Ctrl+D, Ctrl+Z, Ctrl+B, Alt combinations, repeat, Command copy/paste and input-language changes.
- [ ] Software keyboard: normal text, delete, Return, accessory modifiers, composing/IME input; no duplicate or dropped input. Open/close/floating keyboard leaves usable terminal rows.
- [ ] Unicode: emoji, combining marks and wide CJK characters. Verify cursor alignment in a full-screen program.
- [ ] Long-press/double-tap selection, copy/paste, multiline bracketed paste and two-finger scrollback. User paste works while remote OSC 52 clipboard requests remain blocked.
- [ ] Interrupt Wi-Fi/Tailscale and disconnect; reconnect manually to the same named tmux session and verify the remote process survived. Background/foreground and lock/unlock the iPad; do not assume an old socket survived.
- [ ] Produce large output (`seq 1 1000000`), scroll and interrupt it. Observe UI responsiveness and bounded memory with Instruments/Xcode. Repeat with the keyboard visible.
- [ ] Repeated connect/disconnect/remote `exit` releases sockets, event-loop threads, terminal surfaces and queued bytes. Final remote output stays visible until Done.

Do not add tabs, automatic reconnect or coding-agent UI until the Ghostty ↔ real SSH terminal passes the core device cases.
