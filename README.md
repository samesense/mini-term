# Mini Term

A native iPad SSH terminal for connecting to a Mac and resuming tmux coding sessions. SwiftUI hosts a UIKit **Ghostty Metal terminal**; Apple SwiftNIO SSH provides the encrypted PTY transport.

**Status:** initial implementation with **11 passing tests and successful unsigned iOS simulator/device builds in GitHub Actions**. The transport can also be built/tested separately on macOS. Signing, physical iPad operation and real-Mac acceptance testing remain to be completed; no on-device validation is claimed. See [architecture and dependency investigation](docs/ARCHITECTURE.md) and [validation](docs/VALIDATION.md) for exact evidence and remaining risks.

## Build and install on an iPad mini

1. Install **Xcode 26 or later**, open it once, accept its license, and install iOS platform support. Ghostty requires Swift 6.2+. The app targets **iPadOS 17+**, iPad only, portrait and landscape. Zig is unnecessary for normal builds because SwiftPM downloads Ghostty’s prebuilt XCFramework.
2. Clone `git@github.com:samesense/mini-term.git` and open **`MiniTerm.xcodeproj`**, rather than the root `Package.swift` (which contains the transport only). Wait for package resolution and the approximately 77 MB Ghostty binary download.
3. In Xcode → Settings → Accounts, add your Apple ID. In the **MiniTerm** target → Signing & Capabilities, select your Personal Team and enable automatic signing. Change `com.samesense.mini-term` to a unique bundle identifier if needed. No paid membership or special entitlements are required by this app.
4. Connect the iPad by USB, trust the Mac, enable **Developer Mode** on the iPad if prompted, and select the iPad as the run destination. Build and run (⌘R). Follow any device-side developer trust prompt. Free provisioning is temporary; rebuild/reinstall when Xcode’s provisioning expires.
5. Allow **Local Network** access when prompted. For a Tailscale address, connect Tailscale on both the iPad and the Mac first. Mini Term uses ordinary TCP SSH; it does not embed a VPN.

Command-line validation on a Mac with full Xcode selected:

```sh
xcodebuild -resolvePackageDependencies -project MiniTerm.xcodeproj -scheme MiniTerm
xcodebuild -project MiniTerm.xcodeproj -scheme MiniTerm \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MiniTerm.xcodeproj -scheme MiniTerm \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
swift test
```

To select an installed Xcode for the current shell without changing system settings:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The `.xcodeproj` and shared scheme are checked in. To regenerate them after adding app source files, run `python3 Scripts/generate_project.py`. It uses only Python’s standard library. Dependency versions and the full resolved graph are checked in; keep both `Package.resolved` files when updating dependencies.

## Prepare your Mac

1. In System Settings → General → Sharing, enable **Remote Login** for your Mac user. Use that user’s short account name, rather than the display name. The Mac must be awake and reachable on the network.
2. On the iPad, tap **Create iPad SSH key**, then **Copy public key**. Transfer that **public** key to the Mac using a trusted method. Mini Term generates an Ed25519 identity and stores its 32-byte private seed in the device-only, unlocked Keychain. This first version supports that generated identity; importing existing private keys, passphrases and SSH agents is not implemented.
3. On the Mac, create `~/.ssh` if needed, set its permissions to `700`, append the copied `ssh-ed25519 … mini-term-ipad` line to `~/.ssh/authorized_keys`, and set that file’s permissions to `600`. Preserve any existing lines. Never transfer the private seed.
4. For persistent sessions, install tmux on the Mac if necessary. Mini Term checks the usual Apple Silicon and Intel Homebrew binary locations in addition to the remote PATH. You can also create a session beforehand with `tmux new-session -s codex` and start your preferred coding CLI there.

## Connect and resume work

Enter the Mac’s hostname/IP (or Tailscale name/IP), username, and SSH port (usually `22`). Enter an optional tmux session name such as **`codex`**. Tap **Connect**.

The first connection asks you to verify the Mac’s host-key fingerprint. Compare it independently on the Mac, for example:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
```

Match the displayed SHA256 fingerprint to the relevant server key before tapping **Trust and connect**. Subsequent connections must present that same key for that hostname and port. A changed key is blocked. If the Mac was intentionally reinstalled or its SSH keys rotated, verify the new key independently, then use **Forget this host’s saved key…** on the connection screen. Host aliases/IPs have separate trust records.

With a tmux session name, the app requests a PTY and runs `tmux new-session -A -s NAME`: it attaches to the named session or creates it. Launch Codex, Claude Code, Vim, or other programs from that remote shell. Disconnecting closes SSH; tmux owns the continuing remote processes. To resume, reconnect to the same Mac and enter the same name. The original SSH socket is never assumed to survive. An ordinary shell is requested when the tmux name is blank.

Use the Ghostty keyboard accessory bar for terminal keys/modifiers; external keyboards use Ghostty’s native key handling. Long press/double tap for selection and copy, use the edit menu or hardware shortcut to paste, and use two-finger scrolling for local history. Pinch or Ghostty’s font-size keyboard shortcuts adjust the terminal font. Remote OSC 52 clipboard access is denied; user-initiated copy/paste remains available. Only text clipboard contents make sense over SSH; app-local file paths are not uploaded to your Mac.

## Current scope

- One SSH connection and one full-screen terminal.
- App-generated Ed25519 authentication; explicit first-use trust; changed-host rejection.
- PTY/shell acknowledgement, raw bidirectional bytes, rotation/window resize, bounded pending input and output backpressure.
- Optional named tmux attachment for persistent remote work; reconnection is manual.
- Connection errors are shown above the terminal; **Done** returns to the connection form.

Saved host profiles, tabs, automatic reconnect, tmux discovery, configurable keepalives, file transfer, diff viewing, and agent notifications are later work. iPadOS can suspend networking in the background; tmux, not the app, provides process persistence. Connection fields are currently held in memory; the identity and trusted host keys are saved in Keychain.

## Tests

`swift test` runs unit tests plus encrypted SSH connections to ephemeral loopback servers. They do not need an SSH daemon, personal credentials, or a reachable Mac. Tests cover byte-for-byte terminal traffic (including split UTF-8), request ordering, dimensions, connection states, rejected host keys and PTY rejection. See [the validation checklist](docs/VALIDATION.md) for interactive Mac/iPad acceptance tests.

GitHub Actions runs transport tests and unsigned iOS device/simulator builds. See the [successful initial validation run](https://github.com/samesense/mini-term/actions/runs/41339320493) and [latest workflow results](https://github.com/samesense/mini-term/actions).
