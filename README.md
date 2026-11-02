# Mini Term

<img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Mini Term ghost-terminal app icon" width="120">

A native iPad SSH terminal for connecting to a Mac and resuming tmux coding sessions. SwiftUI hosts a UIKit **Ghostty Metal terminal**; Apple SwiftNIO SSH provides the encrypted PTY transport.

**Status:** **20 passing tests**, successful iOS simulator/device builds, and user-reported physical iPad SSH and touch session-switcher testing. Connection history supports an optional shared iCloud Drive folder; physical cloud synchronization remains to be verified. See [architecture and dependency investigation](docs/ARCHITECTURE.md) and [validation](docs/VALIDATION.md) for the recorded evidence and remaining checks.

## A look inside

An LCARS-inspired connection console, saved destinations, and quick access to storage and SSH identity controls.

| Connection console | Larger text |
| :---: | :---: |
| <img src="docs/design/lcars-portrait.png" alt="Mini Term on iPad mini: LCARS connection form, saved hosts, iCloud folder controls and SSH identity" width="360"> | <img src="docs/design/lcars-accessibility.png" alt="Mini Term connection console using an accessibility Dynamic Type size" width="360"> |

Captured from the running iPad mini simulator with fictional connection details. The second screenshot uses an accessibility Dynamic Type size.

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

## Save connections and share history through iCloud Drive

Rebuild/run Mini Term with **⌘R**. The connection form now has **Save connection** and **Saved & recent connections**. Successful logins are remembered automatically. Tap a history row to fill host, username, port and tmux session; the last selected connection is restored on launch. Use a row’s **…** menu to delete it. Up to 30 recent rows are shown.

For iCloud storage:

1. Tap **CHOOSE iCLOUD FOLDER** under Connection Storage.
2. In the Files picker, go to **iCloud Drive**, create/select a folder such as **Mini Term**, and choose **Open**.
3. On another device running Mini Term, select that same folder using the same Apple account. Connection metadata is merged when the app opens, after saves/deletes, and when the file provider reports changes. **Refresh** retries explicitly.

This uses ordinary user-selected iCloud Drive files, which works with the existing Personal Team build. It does not request CloudKit or app-private iCloud entitlements. Selecting **On My iPad** or another provider saves to that location instead; select iCloud Drive when you want iCloud synchronization. Apple controls upload/download timing, so updates may not appear on other devices immediately.

Only host, username, port, optional tmux name and dates are stored. SSH private keys, trusted host keys, terminal commands and terminal output are excluded. Each device continues to use its own Keychain identity and host-verification records. A new device still needs its public key installed on the Mac and must verify the host fingerprint.

The app keeps a local metadata cache for offline use and saves a persistent folder-access bookmark on this device. One JSON file per device avoids offline writers replacing each other's data; per-entry revisions and deletion records merge the history. Files remain in the chosen folder if you stop sync or remove the app. **Stop folder sync** in the storage **…** menu keeps your local connections and leaves those files untouched. If folder access is revoked or the folder is unavailable, reconnecting to SSH still works using the local history; select the folder again to restore sync.

A clean reinstall can recover metadata by selecting the same folder again; recovering connection metadata does not recover SSH credentials. Physical iCloud Drive upload/download and bookmark restoration must be verified on device; the automated tests exercise local persistence, merge/conflict/deletion behavior and coordinated replica-file I/O.

## Tap to switch tmux sessions

On the Mac that runs tmux (3.2+), from this checkout run:

```sh
python3 Scripts/install_tmux_switcher.py
```

The installer copies a small menu helper and config into `~/.config/mini-term/`, backs up your tmux config before adding an include, and enables the binding on an already-running server. It detects gpakosz’s `.tmux.conf.local` customization file. It enables tmux mouse mode and binds a left click on the **session name at the left of the status line** to a popup listing all sessions on that tmux server. This binding also works from mouse-capable desktop terminals. It preserves your existing prefix and keyboard session-switching bindings.

Rebuild Mini Term in Xcode with **⌘R** to install the touch behavior update. Tap the status-line session name, then tap a session in the popup. Other sessions and their programs keep running. A very short terminal or long session list uses tmux’s scrollable session tree instead; select an item or press `q` to cancel. The popup lists sessions on the current tmux socket, not separate tmux servers.

While tmux (or another remote TUI) has mouse capture enabled, terminal taps send clicks without opening/closing the software keyboard. Use the **keyboard button in the top bar** to show or hide it. In an ordinary shell without mouse capture, tapping still toggles the keyboard as before.

For another Mac, install the same files there. The script accepts `--config /path/to/tmux.conf` for a custom setup and `--no-reload` to defer activation until the next tmux startup. No SSH credentials or agent processes are changed.

To validate the menu against an isolated tmux server, run `python3 Scripts/test_tmux_switcher.py`. The test sends real terminal mouse sequences, verifies the popup stays open after a tap and switches on the next tap, checks names containing spaces/quotes/literal formats, and exercises the short-screen fallback.

## Current scope

- One SSH connection and one full-screen terminal.
- App-generated Ed25519 authentication; explicit first-use trust; changed-host rejection.
- PTY/shell acknowledgement, raw bidirectional bytes, rotation/window resize, bounded pending input and output backpressure.
- Optional named tmux attachment for persistent remote work; reconnection is manual.
- Connection errors are shown above the terminal; **Done** returns to the connection form.

Saved connections and recent history are available locally and optionally through a selected iCloud Drive folder. Tabs, automatic reconnect, tmux discovery, configurable keepalives, file transfer, diff viewing, and agent notifications are later work. iPadOS can suspend networking in the background; tmux provides process persistence. The SSH identity and trusted host keys remain in Keychain.

## Tests

`swift test` runs unit tests plus encrypted SSH connections to ephemeral loopback servers. They do not need an SSH daemon, personal credentials, or a reachable Mac. Tests cover byte-for-byte terminal traffic (including split UTF-8), request ordering, dimensions, connection states, rejected host keys and PTY rejection. See [the validation checklist](docs/VALIDATION.md) for interactive Mac/iPad acceptance tests.

GitHub Actions runs transport tests and unsigned iOS device/simulator builds. See the [successful initial validation run](https://github.com/samesense/mini-term/actions/runs/41339320493) and [latest workflow results](https://github.com/samesense/mini-term/actions).

## LCARS connection console and icon

The connection page uses an LCARS-inspired palette and curved side rail. **LINK**, **SAVED**, **SYNC** and **KEYS** jump to the corresponding section. Landscape uses two columns; portrait and accessibility text sizes use a single scrolling column. Native text fields, keyboard focus, VoiceOver labels, saved-host selection, storage controls and host trust remain available. The main terminal screen keeps its existing layout.

The ghost-terminal app icon is installed through `App/Assets.xcassets`; generation details and the prompt are in [the icon record](docs/design/icon-generation.md). Rebuild/run with **⌘R** to update the page and Home Screen icon. If iPadOS retains the old icon briefly, close/reopen the app or give the Home Screen cache time to refresh; reinstalling is unnecessary.

Design previews use an isolated iPad mini simulator and sample metadata. Debug simulator builds accept `--design-preview` to seed fictional destinations. These flags have no effect in physical-device or Release builds. Screenshots are in `docs/design/`.
