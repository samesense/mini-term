# Validation record and acceptance checklist

## Local evidence — 2026-11-01

Environment: Apple Silicon macOS, Apple Swift 6.4 command-line tools. `xcodebuild -version` reports that the active developer directory is CommandLineTools and requires Xcode; no Xcode application or iOS SDK was found. No physical iPad or personal remote Mac was used.

- **PASS:** independent `MiniTermCore` compilation with pinned NIOSSH/NIO/Crypto.
- **PASS:** full app dependency resolution, including the checksum-verified Ghostty XCFramework and iOS device/simulator slices.
- **PASS:** compile/link of the pinned Ghostty macOS wrapper and the actual `App/TerminalSessionModel.swift` in a temporary verification package. This validates the shared model’s Ghostty/concurrency APIs, not the UIKit view or iOS renderer.
- **PASS:** Swift syntax parsing of all `App/*.swift` files.
- **PASS:** generated `.pbxproj` passes `plutil -lint`; shared scheme XML parses; project generation is deterministic; both dependency lockfiles parse.
- **PASS:** all **11 tests in 2 suites**, including encrypted SSH PTY traffic, backpressure, tmux exec, host mismatch, PTY rejection and cancellation during host verification. Latest local run after the lifecycle correction: 0.124 seconds after compilation.
- **PASS in GitHub Actions:** all 11 transport tests, deterministic project generation, full dependency resolution, and unsigned builds for `generic/platform=iOS Simulator` and `generic/platform=iOS`. [Initial successful run](https://github.com/samesense/mini-term/actions/runs/41339320493), commit `67f1c31`, Xcode 26.6 / iOS SDK 26.5. Later lifecycle/layout changes are verified by subsequent workflow runs.
- **NOT RUN:** app launch, signing/installation, Keychain operations in a signed iOS app, actual macOS Remote Login, real tmux attachment, interactive Codex, and rendering/keyboard/copy-paste device tests.

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

## Touch session-switcher milestone — 2026-11-01

- **PASS:** local unsigned iPad device build with Xcode 27.2 after adding mouse-capture-aware keyboard behavior and an explicit keyboard button. Existing Personal Team signing settings were preserved.
- **PASS:** isolated tmux 3.6a integration test using a real pseudo-terminal and SGR mouse events: tap session name → popup remains open → tap beta → attached client switches. Space/quote/leading-hyphen/literal-format names are included. Both top and bottom status bars work; a quote-containing session is selected by tap. An 8-row terminal selects the scrollable tree fallback.
- **USER-REPORTED PASS:** physical iPad testing of the tap-to-switch behavior.

## Connection-history milestone — 2026-11-01

- **PASS:** final unsigned iPad device build with Xcode 27.2.
- **PASS:** all **20 tests in 3 suites**, including the 9 connection-history tests and existing SSH transport tests. Final local test run: 0.129 seconds after compilation.
- **NOT CLAIMED:** physical iCloud Drive synchronization or folder-bookmark restoration on the iPad.

Automated checks cover metadata round trips, stable identity/deduplication, offline merge convergence, deletion propagation, explicit restoration after deletion, skewed device clocks, tied revisions, recent-row limits, invalid/future documents, and two-device coordinated replica-file I/O. A corrupt remote file must not overwrite the local replica. Credentials and terminal content have no fields in this schema.

Device acceptance, not yet claimed:

- [ ] Save a connection, quit/relaunch, and verify the form restores it. Tap another row to fill all fields. A successful login updates recency; a failed login does not add history.
- [ ] Choose/create a folder in iCloud Drive. Save and delete entries, confirm replica files appear in Files, and confirm they upload.
- [ ] On another device, choose the same folder; verify additions, deduplication and deletion propagate. Make changes offline on both devices, reconnect, and check the merged list.
- [ ] Quit/relaunch and confirm the folder bookmark works without another picker. Move/rename the folder and verify bookmark recovery; revoke access and confirm a visible error with local connections still usable.
- [ ] Stop folder sync and confirm local rows remain and folder files are retained. Choose the folder again and merge.
- [ ] Verify selecting On My iPad is described as folder storage, rather than claiming iCloud synchronization.
- [ ] Confirm SSH keys and trusted host records have not appeared in history JSON files, and a second device still requires its own SSH setup.

## LCARS design milestone — 2026-11-01

- **PASS:** iOS simulator and unsigned device builds with Xcode 27.2; signed simulator build launches without Keychain-entitlement errors.
- **PASS:** iPad mini portrait render with populated saved-host fixtures inspected; native fields, all connection actions, storage and identity controls are present.
- **PASS:** portrait render at accessibility-medium Dynamic Type inspected; side-rail labels and connection controls fit, with the remaining sections available by scrolling.
- Added a 1024 × 1024 opaque app icon and matching in-app brand asset. Asset catalogs are wired into both the generated and local Xcode projects while preserving local signing.
- Existing transport and history algorithms were not changed for this visual milestone. Physical iPad interaction, landscape rendering and other Dynamic Type sizes remain device acceptance items.
