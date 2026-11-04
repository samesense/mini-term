# Dependency investigation and architecture

Investigated 2026-11-01, before implementing the app. This repository was empty.

## Decision

Use Lakr233’s **full Ghostty embedding fork**, not libghostty-vt alone and not an alternative terminal emulator. Use **Apple SwiftNIO SSH directly** for the transport. A SwiftUI connection form presents a UIKit terminal controller. All SSH state and writes live on one NIO event loop; Ghostty receives raw `Data` on its own parser queue.

| Dependency | Pin | Reason |
| --- | --- | --- |
| [libghostty-spm](https://github.com/Lakr233/libghostty-spm/tree/2.2.2026102101) | `2.2.2026102101`, `5b9cb63d83e687b4a66d6c3a3c2a840341c576d9` | iOS Metal rendering, native input/selection, host-managed I/O |
| [Upstream Ghostty](https://github.com/ghostty-org/ghostty/tree/1e9e14af5df14211892f5fc15fd21a49c7d94868) | embedded fork’s `Ghostty.ref`: `1e9e14af5df14211892f5fc15fd21a49c7d94868` | Terminal parser, grid, Unicode, renderer and font pipeline |
| [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh/tree/0.15.1) | `0.15.1`, `d1985926494b624e751b379009dc83f3395fd88a` | Apple implementation, Ed25519, host-verification delegate, PTY/shell/window events |
| [SwiftNIO](https://github.com/apple/swift-nio/tree/2.81.0) | `2.81.0` | Ordered byte transport, channel lifecycle and backpressure |
| [Swift Crypto](https://github.com/apple/swift-crypto/tree/4.0.0) | `4.0.0` | Ed25519 and SHA256; matches NIOSSH’s accepted range |

Both resolved files pin transitive versions/revisions, including DisplayLink `3.0.1`. Ghostty’s binary target URL points to `upstream.1e9e14af5df1-3/GhosttyKit.xcframework.zip`, with package-verified SHA256 checksum `0bf7e5e13f8e42ffca040a6cef7e985fc30bcaa81ff513bd2a93eb097398c6d8`.

## Host keyboard adapter

The app imports `MiniTermGhosttyTerminal`, a checked-in copy of the pinned Swift wrapper under `Vendor/GhosttyAdapter`. Narrow policy/phase hooks support dual-role input, and obsolete compatibility paths are updated for iPadOS 17; [provenance and patch](../Vendor/GhosttyAdapter/README.md) document them. It still links the exact upstream `GhosttyKit` engine binary and uses the wrapper’s HID translation, text handling, repeat and input funnel. `MiniTermCore.DualRoleKeyboard` contains only the portable state machine. [Keyboard API findings](KEYBOARD.md) separate simulated tests from unverified physical event delivery.

## APIs verified in the pinned source

`GhosttyTerminal` supplies `TerminalView` (an alias for `UITerminalView` on iOS), `TerminalController`, `TerminalSurfaceOptions`, and `InMemoryTerminalSession`. Selecting `TerminalSurfaceOptions(backend: .inMemory(session))` activates the fork’s `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` extension. This avoids spawning a local PTY or subprocess inside iPadOS.

- `InMemoryTerminalSession(write:resize:)`: raw terminal-generated keyboard/protocol bytes → `SSHTransport.send`; viewport callback → `SSHTransport.resize`.
- `session.receive(Data)`: SSH stdout/stderr → Ghostty parser → Metal renderer. Never decode and re-encode chunks as strings; UTF-8 and escape sequences can span packets.
- `session.setOutputBacklogHandler(highWater:lowWater:_:)`: pauses/resumes PTY child auto-read at 1 MiB/256 KiB of unparsed output. An already-issued read is retained in a bounded 4 MiB transport queue until resume. The parent TCP channel continues reading so forwarded web channels and SSH control traffic make progress; the pinned SSH child's receive window bounds unread data.
- `TerminalView.fitToSize()`: recomputes dimensions after layout changes. A keyboard-layout-guide constraint plus the full keyboard frame (including the accessory bar) keeps the last terminal rows visible.
- `UITerminalView`: `UITextInput`, hardware keyboard handling, IME, key repeat, touch selection, local history scrolling, copy/paste, font zoom and accessory bar are supplied by the package. We do not encode keystrokes ourselves.

The upstream [embedding header](https://github.com/ghostty-org/ghostty/blob/1e9e14af5df14211892f5fc15fd21a49c7d94868/include/ghostty.h) identifies this as an internal embedder API. The stable VT-focused library offers terminal state/parsing; it is not a drop-in replacement for this fork’s native Metal view and host-managed I/O. The integration is therefore deliberately isolated in `App/`.

## SSH library comparison

Apple NIOSSH provides everything needed for an interactive PTY, but requires application code for key storage, request acknowledgements and lifecycle. We use `NIOSSHClientUserAuthenticationDelegate`, `NIOSSHClientServerAuthenticationDelegate`, `UserAuthSuccessEvent`, a `.session` child channel, `PseudoTerminalRequest`, `ShellRequest` (or `ExecRequest` for tmux), `SSHChannelData`, and `WindowChangeRequest`. A successful socket write does not imply that the server accepted a PTY: requests are explicitly acknowledged in order before reporting Connected.

[Citadel 0.12.1](https://github.com/orlandos-nl/Citadel/tree/0.12.1) was also inspected. It offers `withPTY`, a stdin writer, resize and private-key parsers over a fork of NIOSSH. Its convenience output stream uses an unbounded `AsyncThrowingStream`; the public writer does not expose direct channel read-pressure controls. Direct Apple NIOSSH makes terminal backpressure and cancellation easier to control and keeps the dependency graph smaller. Key import is deferred instead of bringing in a second SSH stack.

## Lifecycle and security

State: idle → connecting → verifying host → authenticating → opening shell → connected → disconnected/failed. A transport is one-shot; a fresh connection gets a fresh transport and terminal. Network operations never block the main thread. A 15-second TCP timeout, 30-second initial handshake timeout and 20-second post-verification setup timeout bound stalls. First-use host confirmation pauses the handshake timer while waiting for the user; cancellation closes the connection and resolves the pending verifier.

The initial identity is a generated Ed25519 key. Its private seed and full trusted host keys use Keychain generic-password records with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, no synchronization and no access group. No private key enters UserDefaults, source control, terminal output or logs. Host trust is scoped by normalized hostname + port, independent of username. A corrupt/mismatching record fails closed; replacing trust requires an explicit user action after independent verification. Ghostty debug traffic logging is disabled. Remote OSC 52 clipboard access is denied.

Input writes are serialized, with at most one write in flight and a 1 MiB pending-input limit. Overflow fails visibly instead of silently dropping terminal input. The NIO child’s writability gates further writes. Disconnect/error cancels deadlines, clears queued input and closes both channels. The UI detaches the byte bridge at termination to break its session/transport callback ownership cycle. Final stdout is consumed until channel close. Foreground socket checks and bounded recovery are described below.

Optional tmux attachment is a PTY followed by `ExecRequest` for `tmux new-session -A -s NAME`. Session names allow only ASCII letters, digits, hyphens and underscores (maximum 64 bytes). This avoids shell injection. tmux keeps the remote processes; TCP/SSH connections themselves are disposable. Multiple clients attaching to one tmux session follow tmux’s normal shared-session sizing behavior.

## Build requirements and risks

- App: Xcode 26+, Swift 6.2+, iOS SDK, iPadOS 17+, Metal-capable iPad mini. The Ghostty package itself supports iOS 15+, macOS 13+, Catalyst 15+ and visionOS 1+. Our target is deliberately narrower.
- Normal builds download a prebuilt XCFramework. **No Zig installation or custom renderer is required.** Source rebuilding needs the fork’s patches/build scripts and Zig 0.16.0 for this pin. Its README notes Xcode 27’s optional Metal toolchain component (`xcodebuild -downloadComponent MetalToolchain`) for source builds.
- The binary is a trimmed upstream build: VT, Metal, CoreText shaping and input remain; standalone runtime, custom shaders, inspector and Sentry are excluded. The fork adds iOS fixes and host-managed I/O. This patch dependency is the largest maintenance risk.
- Device testing must confirm rotation, safe areas, keyboard accessory sizing, IME, clipboard, Unicode/font fallback, scrollback and high-volume output. Compiling the transport does not validate these.
- App sandboxing is kept enabled. No local shell, private blur API or subprocess workaround is used by this app.
- SSH term is `xterm-256color` so standard macOS terminfo works without installing a Ghostty terminfo entry. Remote shell integration scripts/file upload are not installed.
- iPadOS may suspend the app or networking; foreground recovery/manual reconnect restore SSH, while tmux provides remote process persistence. Neither the Mac nor tmux can be assumed to survive a Mac restart.

## Licenses

Ghostty and libghostty-spm are MIT. Apple SwiftNIO, SwiftNIO SSH and Swift Crypto are Apache-2.0 (SwiftNIO also includes its runtime exception). DisplayLink is MIT. Their transitive distributions include additional notices; preserve those if redistributing binaries. The wrapper’s optional theme catalog and sandbox shell are not linked by this app. See `THIRD_PARTY_NOTICES.md` and the pinned source licenses. Personal provisioning does not change third-party license obligations.

## Sequence

1. Investigate source APIs and pin dependencies — done.
2. Build/test the independent SSH transport — see validation record.
3. Wire the native Ghostty surface and minimal connection/trust UI — implemented; unsigned iOS simulator and device builds passed in Xcode CI.
4. Complete signing/device installation, Mac shell, tmux and interactive coding-tool acceptance checks before expanding saved hosts/tabs or agent features.

## Saved connections and iCloud Drive history

The Personal Team build uses a **user-selected folder** through SwiftUI’s Files importer rather than app-private CloudKit/KVS. This preserves the existing signing configuration. See Apple’s [directory access guide](https://developer.apple.com/documentation/uikit/providing-access-to-directories?changes=l_5&language=objc) and [capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios).

`ConnectionHistoryDocument` holds only connection metadata. Stable SHA256 identities deduplicate host/user/port/tmux combinations. Per-entry modification times and operation UUIDs converge deterministically; latest successful-connection dates are merged independently. Tombstones propagate deletion without old replicas resurrecting rows. The UI shows up to 30 records. The last selected profile and an offline cache use local UserDefaults; private keys and host trust remain in Keychain.

`ConnectionHistoryCloudStore` runs coordinated file-provider I/O on an actor. Each device owns a replica file named `MiniTerm-<device UUID>.connections.json`, and imports the others before updating its own. Atomic writes, a 2 MB document limit, version checks and validation protect existing data from malformed files. Unchanged replicas are not rewritten. A directory `NSFilePresenter` observes external arrivals/changes; callbacks are debounced, and saves during an in-flight sync are merged and queued for another pass. Security-scoped access is balanced, the folder is persisted as a minimal bookmark, stale bookmarks are renewed, and revoked access produces a visible error while local history remains usable. Stopping sync invalidates the presenter, cancels pending work and removes the local bookmark without deleting cloud files.

There is no assertion that a coordinated save means iCloud has uploaded it. Files-provider synchronization and cross-device delivery are eventual and require physical-device validation. Selecting a non-iCloud folder is supported but is not described as iCloud sync. Terminal commands/output and credentials are outside the history schema.


## Reconnect, diagnostics, and connection annotations

Reconnect creates a new `TerminalSessionModel`, bridge, in-memory terminal session, and one-shot transport. The immutable SSH destination is reused and host trust runs normally. The old view/model is retired instead of sharing a stream across attempts. A bounded value-type diagnostics timeline carries forward; old callbacks cannot mutate the new model or replay pending input.

Transport failures supply an allowlisted `ConnectionFailure` separately from the human-readable UI error. Diagnostic reports serialize only phases, categories/codes, versions, and modifier edge counts; arbitrary error messages and SSH/terminal data are never inputs to the report.

Optional name/favorite annotations extend the existing history schema. Their own timestamp/operation ID merges independently from connection recency, preserving customizations when older clients update a visit. Deletions carry cleared metadata revisions, and explicit clearing/unfavoriting is a real revision. Favorites are retained separately from the 30 ordinary recent entries.

## Website preview workspace

`TerminalWorkspace` keeps the native terminal and active browser mounted while switching visibility/input focus. Dismissal disconnects the workspace; switching does not. `PreviewModel` owns the browser and binds asynchronous startup to a request generation. A fresh reconnect model restores the local port/protocol and preview selection, creating a fresh route/browser only after SSH is connected.

`SSHTransport.startPreview` creates two loopback listeners on its existing event loop: an authenticated SOCKS5 endpoint for a nonpersistent `WKWebsiteDataStore`, and a plain fixed-destination endpoint for experimental Safari use. Both use independent NIOSSH `directTCPIP` children of the already authenticated SSH parent. The incremental SOCKS parser supports username/password authentication and CONNECT with domain/IPv4/IPv6 destinations; it rejects downgrade, BIND, UDP association and invalid ports. Relays use manual reads, bounded write accounting, half-closes, per-stream deadlines and isolated failure cleanup. No new package dependency is required.

WebKit's per-store proxy has direct failover disabled. Physical iPadOS still implicitly bypasses the proxy for localhost, unlike the simulator. The browser therefore uses the reserved `mini-term-preview.invalid` origin, mapped only by the authenticated proxy to the Mac's localhost. Page navigation stays at this host/selected port. A compiled content-rule list blocks explicit loopback page resources and is installed before loading; reload cannot bypass rule setup. Normal TLS validation remains enabled, so HTTPS requires a certificate for the reserved origin. ATS has narrow HTTP exceptions for localhost (external-browser forwarding) and the reserved preview name, with no arbitrary web-load exemption. Host/Origin headers are preserved; development-server allowlists and hardcoded localhost URLs may need configuration. Safari has a distinct ephemeral local URL and the normal external-resource/background limitations described in [preview documentation](PREVIEWS.md). The preview is verified for specific TCP web paths, not every protocol WebKit can initiate.

## Foreground recovery, preview shortcuts and SFTP

`RecoveringTerminalScreen` owns a `SessionRecovery` coordinator above the replaceable terminal workspace. Scene activity and `NWPathMonitor` signals feed the pure, bounded `ReconnectPolicy`. A previously connected but interrupted session is retried only in the foreground with a usable network path. A healthy socket is retained after an empty-session round trip; an unresponsive one fails after eight seconds. Every retry uses the existing `reconnectSession()` fresh-model path, including host verification and new byte queues/surface. Explicit closure, security failures and ordinary foreground remote exit stop recovery. A generation/model identity check rejects retired callbacks; closing before first appearance also prevents SSH from starting later.

`PreviewShortcut` validates names, ports and origin-relative paths, and constructs URLs without allowing a saved path to replace the origin. `PreviewModel` stores bounded shortcut JSON in local preferences per connection profile, separate from iCloud history. Reconnect restores applied settings, retained-preview intent and selection; unsaved form edits and browser session state are discarded.

`SSHTransport.startSFTP()` opens a `session` child and requests `subsystem=sftp` after the main SSH connection is authenticated and the terminal is ready. It shares host trust/authentication and socket lifetime, but owns its own flow-controlled channel. A terminal output pause cannot prevent SFTP responses from being read. Closing/replacing SFTP does not close the PTY or preview. Transport teardown closes all three.

`SFTPHandler` confines protocol state to the NIO loop: bounded length-prefixed framing, version-3 negotiation, request identifiers, status handling and deadlines. `SFTPClient` streams local I/O on the concurrent executor and awaits each bounded block. Uploads use WRITE|CREAT|EXCL with 0600 permissions; no delete/truncate/rename request is emitted. Cancellation closes the child, resolving all pending requests and releasing server handles. `RemoteFilesModel` gates UI operations with a generation, cancels on disconnect, and offers completed temporary downloads to the native Files export picker. It never serializes file contents/paths into history or diagnostics. See [file behavior/limits](FILES.md).

## Experimental Mosh backend

`TerminalTransport` is the byte/resize/backpressure interface used by the existing
`TerminalBridge`. Direct SSH implements it unchanged; `MoshTransport` supplies a
one-shot dedicated worker through a small C ABI. Ghostty input and screen rendering
keep using the same in-memory adapter. The app's optional Mosh path authenticates
an auxiliary-only SSH socket (no interactive shell), then starts `mosh-server` on a
separate bounded exec channel. The native client uses the SSH socket's actual peer
address and the ephemeral bootstrap secret.

`NativeClient.cc` embeds pinned Mosh crypto/state synchronization/terminal source
and protobuf-lite, compiled with Apple CommonCrypto. It produces ANSI screen diffs,
with a thread-local UTF-8 locale, `poll`, bounded producer/history queues, remote
resizing, a network-wait callback and bounded asynchronous cancellation. It never
installs process signals, redirects process stdio, invokes a local shell, or uses
the CLI frontend's `exit`/`pthread_exit`/job-control paths. Local prediction and
serialized restoration are deliberately absent.

`TerminalSessionModel` owns Mosh separately from the auxiliary SSH socket. A closed
SSH parent invalidates tools without finishing a live Mosh session. The parent
socket's `closeFuture` is observed because NIOSSH consumes `channelInactive` and
auxiliary mode has no persistent PTY child to report closure. Wake recovery replaces
only that SSH socket, with generation checks rejecting callbacks from older sockets.
An actual Mosh end still follows the existing whole-terminal recovery path.

See [Mosh setup and limitations](MOSH.md) and the native component's
[licensing/provenance](../Vendor/MoshNative/PROVENANCE.md).
