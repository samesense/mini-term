# Validation record and acceptance checklist

## Foreground recovery, saved previews and SFTP — 2026-11-04

Implemented on `codex/reconnect-previews-files`. The earlier keyboard/layer fixes are retained in a separate commit on this branch; physical acceptance of those fixes remains pending.

- **PASS:** **79 core tests in 10 suites**, including bounded retry policy/security stops, origin-safe shortcut validation and storage bounds, fragmented SFTP framing/attributes, malformed statuses/IDs, request limits, subsystem timeout and close cleanup.
- **PASS:** real encrypted SSH/SFTP interoperability with macOS's OpenSSH `sftp-server`, using generated keys and temporary fixtures: directory/stat, 350 KB binary upload/download, exclusive 0600 creation, preserved existing local/remote destinations, symbolic links, regular-file checks, in-flight download cancellation with partial cleanup, continued terminal liveness, independent paused-PTY traffic and rejected SFTP isolation.
- **PASS:** **28 simulator workspace checks** using the real app models, Ghostty and WebKit with generated SSH/HTTP/SFTP fixtures. Coverage includes healthy-wake socket retention; new-model recovery after simulated suspension/disconnect; applied preview/path and hidden-preview restoration; shortcut save/edit/delete/persistence; browsing/upload/overwrite refusal/download; native Files picker mounting/cancellation and staging cleanup; retry cancellation; manual reconnect after stopping; and no automatic transfer replay.
- **PASS:** **33 existing preview/workspace regressions**, with zero direct-listener requests. The fixture's full-screen presentation now stays stable while replacing child sessions, matching the production recovery host. Swapping the full-screen-cover item itself could transiently mount/dismiss the incoming controller; a deliberately closed model now correctly refuses to start later.
- **PASS:** **19 reconnect/model-lifetime checks**, including closure before first appearance, manual retry availability after cancelling an idle attempt, fresh transports/surfaces and retirement of old models.
- **PASS:** simulator and unsigned iPad target builds. Only the usual AppIntents metadata-skipped build warning was emitted; app/core compilation produced no source warnings.
- The file-browser screenshot in `docs/design/files-browser.png` uses only fictional/generated simulator data. Native export dismissal cleanup is guarded against a stale dismissal after reopening, and staging remains alive while the export picker covers the browser.

Physical-iPad acceptance is pending because the device is unavailable: actual sleep/lock/Wi-Fi transitions, native file-provider selection/export destinations, sustained large transfers/background interruption, and the earlier runtime log comparison. Simulator scene/network events are synthetic; this does not establish a universal background-networking guarantee. Shortcuts are local per connection and do not join iCloud history sync. SFTP is version 3 with individual regular-file transfers; no overwrite/delete/rename/folder-transfer/resume capability is claimed.

Repeat with `swift test`, `Scripts/test_workspace_features.py SIMULATOR_UDID`, `Scripts/test_preview.py SIMULATOR_UDID` and `Scripts/test_session_features.py SIMULATOR_UDID`. New code and limits are described in [usage](USAGE.md), [previews](PREVIEWS.md) and [files](FILES.md).

## Keyboard/animation log investigation — 2026-11-03

The paired iPad's live Console stream showed repeated QuartzCore `cannot add handler to 0 from 0 - dropping` errors, one AnimationKit `LittleGlowView` transform-decomposition fault, and WebKit/RunningBoard process-cleanup errors. A fresh search found no MiniTerm crash reports. Framework attribution alone does not prove those messages are harmless or that MiniTerm caused them.

Two concrete wrapper issues were reproduced and corrected:

- Caret/font geometry refresh called `reloadInputViews()` even though keyboard/accessory identity and input traits hadn't changed. It now retains the `UITextInputDelegate` selection notifications without replacing UIKit's input views.
- Layout and post-render synchronization resized every direct layer whose delegate wasn't a `UIView`. The real surface also has a UIKit `CALayer` delegated to `WindowAnchor`, so that predicate included layers outside the renderer. Updates now target only the pinned engine's `IOSurfaceLayer`, change properties only when necessary, and disable implicit layer actions. The engine's class registration is verified in [its pinned source](https://github.com/ghostty-org/ghostty/blob/1e9e14af5df14211892f5fc15fd21a49c7d94868/src/renderer/metal/IOSurfaceLayer.zig); this identification must be rechecked on an engine upgrade.

Validation:

- **REPRODUCED:** the pre-fix fixture observed keyboard reloads during geometry/zoom and modification of unrelated delegate/nil-delegate layers. These are independently observable defects; this does not establish that they caused every reported system log.
- **PASS:** **20 lifecycle checks** with real UIKit/Ghostty: caret notifications, unchanged keyboard/accessory, IME preedit/selection, actual font zoom, foreign-layer preservation, renderer sizing and focus reacquisition.
- **PASS:** existing **19 keyboard**, **33 WebKit/workspace** and **24 layout** checks; zero direct-listener requests in the preview fixture.
- **PASS:** signed iPad build. Only the toolchain's usual AppIntents metadata-skipped warning was emitted; no app-source compiler warnings.
- **PASS:** the updated vendor patch reapplies to the exact upstream pin and reproduces all checked-in wrapper sources.
- **PENDING:** physical post-fix log capture and installation. The iPad required its passcode during verification; the isolated native-framework control app built/installed but could not launch and was removed. No claim that the `LittleGlowView`, QuartzCore or WebKit messages have disappeared on hardware.

`Scripts/test_input_lifecycle.py SIMULATOR_UDID` repeats the new checks. `Scripts/test_preview_device.py DEVICE_UDID --fixture input-lifecycle` runs them on an unlocked paired device. `--fixture system-framework` runs standard UIKit keyboard and nonpersistent `WKWebView` create/load/close cycles without invoking the app's terminal, SSH or preview model, to help distinguish system-generated logs. These signed probe apps use separate identities and are removed afterward.

Preview teardown uses public `stopLoading`, delegate/KVO cleanup and tunnel close; the app does not kill WebKit processes or acquire RunningBoard assertions. WebKit's [assertion implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Cocoa/ProcessAssertionCocoa.mm) emits the observed acquisition-error format. No private entitlement, retained retired browser, or log-suppression workaround was added. The native control experiment and physical reproduction remain necessary before attributing these cleanup messages to an app defect.

## Terminal whole-row bottom alignment — 2026-11-03

The terminal view reached the bottom edge, but Ghostty's two-point vertical padding and the unused fraction of a text row still left tmux's last row above it. The app now removes vertical engine padding, uses Ghostty's actual cell-height metrics to size the view to complete pixel rows, and anchors that view to the keyboard/bottom edge. Fractional leftover space sits above the first row. Touch coordinates follow the actual view position; no renderer scaling, clipping, or tmux configuration changes are used.

- **PASS:** 24 UIKit layout checks, including whole-row sizing/bottom placement, zoom, docked keyboard positioning, stale constraints during a short resize, recovery and unknown-metric fallback.
- **PASS:** 33 simulator checks with the real Ghostty/workspace views, including bottom geometry, switching, browser replacement and reconnect.
- **PASS:** signed iPad build and installation, followed by all 33 workspace checks on the unlocked physical iPad. A fresh screenshot of the real connected tmux session confirms its final status row meets the bottom screen edge; fractional unused space is above the first row.

## Preview bottom-edge layout — 2026-11-03

The physical screenshot showed the preview stopping above the bottom safe area and exposing the gray workspace background. Set the preview host's keyboard guide to `usesBottomSafeArea = false`, matching the terminal host: content fills the bottom region when the keyboard is hidden and still follows the keyboard when shown.

- **PASS:** 14 existing UIKit keyboard-layout checks, including safe areas, dismissal, floating/docked keyboards, accessory overlap and transient container resizing.
- **PASS:** 33 simulator preview/workspace checks. New geometry checks confirm both terminal and preview reach the window bottom after keyboard dismissal. The fixture now uses the production full-screen-cover presentation; its former outer VStack had its own safe-area geometry and was unsuitable for window-edge assertions on hardware.
- **PASS:** signed iPad device build and installation. Real-screen visual confirmation is separate from the simulator geometry checks.
- **PASS on the physical iPad:** a fresh screenshot of the reopened Preview confirms that page content reaches the bottom edge and the lighter safe-area strip is gone. The operating system's resize handle overlays the content.

## Physical iPad routing fix — 2026-11-03

Environment: physical iPad mini (A17 Pro), iPadOS 27.2; Xcode 27.2. The user reported that the real Mac's Python server failed to load in Preview. Local HTTP checks on that Mac returned 200 for both IPv4 loopback and localhost; effective SSH settings allowed TCP forwarding with no PermitOpen restriction.

- **REPRODUCED on hardware:** the original preview's `http://localhost:PORT` bypassed the per-store proxy. A direct listener on the iPad received three requests, and the no-fallback assertion failed even with failover disabled. Explicit match domains did not fix it. This contradicts the earlier simulator-only result and limits that earlier evidence to the simulator.
- **FIX:** use `mini-term-preview.invalid:PORT` as the browser origin and map that exact name to Mac localhost inside the authenticated SOCKS proxy. Compile and install network rules before any page load; block explicit loopback HTTP/WebSocket resources instead of allowing implicit direct requests. Preserve headers and standard certificate validation; scoped HTTP ATS exceptions cover the reserved name and the separate Safari localhost forward.
- **PASS:** **31 checks on the physical iPad**, with zero direct-listener requests: page/fetch/image/iframe, WebSocket/SSE through encrypted SSH, blocked literal localhost fetch/WebSocket, external HTTPS destination routing, restricted main-frame navigation, no fallback after proxy close, nonpersistent browser state, separate unproxied web view using the Safari forward, stable workspace switching, browser replacement, and reconnect restoration.
- **PASS:** **61 tests in 6 suites**, including exact reserved-name mapping and an encrypted SOCKS request using that name against a localhost-only SSH destination.
- Added a repeatable physical test runner, `Scripts/test_preview_device.py`. It uses an isolated signed app and generated fixture identities, removes the probe, and reopens MiniTerm. The simulator runner exercises the same fixture; it cannot substitute for hardware routing checks.
- Preview failures now include a safe error category/code, with specific messages for ATS, TLS, and timeout errors; raw error strings, URLs, and headers are not exposed.
- **USER-REPORTED PASS:** the corrected, signed MiniTerm build was installed on the paired iPad and loaded the real Mac's Python HTTP server on port 3000 through SSH. The server remained bound to Mac IPv4 loopback.

Compatibility: HTTP Host/Origin are now the reserved name. Server host allowlists, absolute localhost URLs, cookies scoped to localhost, and HTTPS certificates may need configuration. Real Vite/Next.js HMR, comprehensive HTTPS/WSS, minimum-runtime behavior, and the actual Safari app remain separate acceptance work. These tests cover the described TCP web paths, not a general browser/VPN guarantee.

## Website preview milestone

Environment: Xcode 27.2, iPad mini (A20 Pro) simulator, iOS 27.2. Generated loopback credentials and synthetic servers only; no personal Mac connection or physical iPad was used for these new checks.

- **PASS:** **60 tests in 6 suites**. Added fragmented SOCKS negotiation, authentication downgrade/wrong-credential rejection, CONNECT-only commands, domain/IPv4/IPv6 and port validation; encrypted forwarding via both listener types; 1 MiB opaque binary echo while terminal output is paused; denied-channel isolation; preview replacement/disconnect cleanup; unauthenticated rejection; invalid ports; bounded pending handshakes; and final remote output preserved when a shell closes while the renderer is paused.
- **PASS:** **29 production WebKit/workspace simulator checks**, using `Scripts/test_preview.py`: page/fetch/image/iframe, WebSocket and SSE through encrypted SSH; external HTTPS hostname observed as an SSH destination; external main-frame navigation blocked; independent unproxied web view reaching the Safari forward; nonpersistent data store; stable terminal surface/SSH across view switches; fresh browser mounting after reopening; and manual reconnect restoring the applied port/protocol/selection rather than unsaved form edits.
- **PASS:** a reachable direct listener at the same localhost address received **zero requests**, including when the proxy was closed and a fresh fetch was attempted. That fetch failed rather than falling back directly. This is observed behavior for the tested runtime and paths, not proof for every browser protocol or absence of speculative DNS.
- **PASS:** unsigned physical-iPad target build; simulator fixture builds/launches with signing. Actual device installation and Safari app launch are separate checks.
- **PASS:** existing **19 Ghostty keyboard checks** and **17 reconnect/diagnostics/model-lifetime checks** still pass after workspace changes.
- **PASS:** the running preview workspace capture was inspected. Address ports render without locale grouping separators; terminal/preview selection, port controls, navigation and page content are visible.
- No dependency pins, Ghostty engine/input hooks, Mac SSH configuration, or local signing team were changed. ATS uses local networking and a localhost HTTP exception, with no arbitrary-load exemption.

Remaining acceptance:

- [ ] Physical iPad mini: HTTP preview of a real Mac loopback-only server; portrait/landscape, keyboard form entry, terminal focus/held-modifier release, reload/back/port changes, Wi-Fi interruption, and reconnect.
- [ ] Actual Safari app: loopback reachability, relative assets, foreground/background and multitasking lifetime. The sibling-web-view result does not establish this.
- [ ] Real Vite and Next.js projects: hot reload, host/origin checks, redirects, cookies, and any alternate WebSocket ports, recording installed framework versions.
- [ ] HTTPS/WSS with valid and invalid certificates, remote IPv6 targets, real Mac hostname resolution and server-side forwarding restrictions; no trust bypass.
- [ ] Oldest supported iPadOS runtime and other current runtimes. API declarations alone do not establish identical behavior.
- [ ] Instruments memory/fairness under sustained concurrent downloads plus heavy terminal output; repeated cancellation during pending channel opens.
- [ ] Speculative DNS and unsupported browser protocols such as WebRTC/UDP, QUIC/WebTransport. Do not claim a general SSH-only browser sandbox.

See [usage and limitations](PREVIEWS.md) and the [design/acceptance plan](PREVIEW_PLAN.md).

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

## Keyboard constraint correction — 2026-11-01

- The user reported a required 468-point keyboard offset inside a 191-point terminal host. The previous constraints demanded a negative terminal height.
- The SwiftUI terminal now explicitly fills the available space. Keyboard frames are converted again during container layout; the accessory offset is bounded by the current safe-area height. Required constraints keep the terminal inside its container with a nonnegative height, while keyboard positioning can yield during transitional geometry.
- **PASS:** signed simulator build with Xcode 27.2.
- **PASS:** `Scripts/test_keyboard_layout.py` compiled the production layout helper into an isolated UIKit simulator app. All 10 checks passed without unsatisfiable-constraint warnings: docked keyboard, the reported short-host/stale-offset scenario, full occlusion, size restoration, narrow window, floating/undocked keyboards, dismissal and absent frame.
- **NOT CLAIMED:** physical iPad retest of the original sequence, keyboard accessory placement or rotation. Rebuild on the iPad and repeat the keyboard show/hide and resizing actions that produced the log.

## Terminal bottom-edge correction — 2026-11-01

- The physical iPad photo showed an unused strip below the tmux status line. Both the SwiftUI container and UIKit terminal constraints stopped at the bottom safe area; the keyboard guide also reserved that inset while dismissed.
- Extended only the bottom of the terminal into the container’s safe area and configured `usesBottomSafeArea = false`. Top/side safe areas and docked-keyboard avoidance remain in effect. The accessory fallback now measures from the same bottom edge.
- **REGRESSION REPRODUCED:** before the fix, the UIKit probe expected a 1058-point terminal but got 1004 points when the host inherited a 54-point bottom inset.
- **PASS:** signed iPad simulator build and all **14 UIKit layout checks**, including filling a nonzero bottom inset, docked keyboard placement, restoration after dismissal and preservation of the top safe area. No unsatisfiable-constraint warnings were emitted.
- **NOT CLAIMED:** physical iPad visual retest. The terminal renderer still rounds its grid to whole character cells.

## Minimal connection screen — 2026-11-01

- Removed the numbered navigation rail, large setup panels and decorative section controls. The main screen contains connection fields, Connect, a secondary save action with an explicit saved state, and saved destinations. Port editing is disclosed on demand; SSH identity, storage and host trust are in the gear-button Settings sheet. History sync errors retain a visible entry point.
- **PASS:** signed simulator and unsigned device builds with Xcode 27.2.
- **PASS:** populated portrait and accessibility-medium renders inspected, plus the Settings sheet shown through a simulator-only preview flag. README images and navigation instructions match the new layout.
- **UNCHANGED:** connection-history model and SSH/Keychain action implementations. No transport or terminal-layout changes in this milestone.
- **NOT CLAIMED:** physical iPad interaction, landscape visual validation, or real iCloud provider flow after moving it into Settings. Retest saving/filling, Settings → key copying, folder selection and the host-key confirmation on device.

## Dual-role Caps Lock — 2026-11-01

- **PASS:** all **40 tests in 4 suites**, including 20 dual-role state-machine tests. Coverage includes tap/long hold, Caps+C/A, modifier preservation, repeat, multiple/simultaneous keys, early Caps release, cancellation/focus loss, late events, configuration changes, physical Control ownership, remapped Control and logical Caps flags without physical edges.
- **PASS:** **19 simulator adapter checks** in an isolated app with a real Ghostty surface and artificial UIKit key/press objects. Actual bytes match native Ctrl+C, Ctrl+Shift+C, Option text and shortcut modifier encoding. Three-second hold, repeat timer, simultaneous modifiers, early release, ordinary Caps capitalization masking and focus cleanup pass. Probe app removed afterward.
- **PASS:** final signed simulator and unsigned iPad device builds with Xcode 27.2. App launch and Settings render inspected; the feature defaults to enabled.
- **ARCHITECTURE:** the portable state machine intercepts native events before the existing Ghostty keyboard pipeline. Five pinned Swift-wrapper source files add narrow hooks; the engine binary, layout/HID translation, IME and repeat are reused. The reviewed patch is checked in with upstream licensing/provenance. No raw control-byte encoder or duplicate GameController input stream is added.
- **NOT VERIFIED:** actual Caps Lock down/up delivery from a physical USB/Bluetooth keyboard, system capitalization suppression, alternate layouts/IMEs and reserved shortcuts. Public API inspection and test doubles cannot establish those facts. Settings includes delivery counters and a system-remapped left-Control fallback. [API findings and physical checklist](KEYBOARD.md) distinguish these limits from the simulated results.

## Reconnect, diagnostics, names and favorites — 2026-11-01

- Added manual Reconnect after a finished connection. Each retry creates a fresh model, transport, bridge and Ghostty session using the same immutable destination/tmux name. Host verification remains in place; pending input is never replayed.
- Added explicit Copy diagnostics actions in the terminal menu and below form errors. Reports allowlist phases, timestamps, failure categories/numeric codes, app/OS versions and modifier edge counts. Destination/account/session names, keys, raw errors and terminal contents are excluded.
- Added names and favorites in each saved row’s menu. Metadata merges separately from login recency and accepts old files without annotations. Favorites precede and are retained separately from the 30 ordinary recent destinations.
- **PASS:** all **51 tests in 5 suites**. Eleven new tests cover old-schema loading, stable identity, metadata persistence/convergence, clearing/deletion/restoration, favorite retention, replica-file sync and diagnostics redaction/bounds.
- **PASS:** **17 simulator session checks** using real app models and a closed loopback port: fresh reconnect objects/surfaces, unchanged destination, attempt counting, independent completion, callback preservation, report privacy, old-model release and action symbol availability. **19 Ghostty input checks** still pass after wrapper cleanup.
- **PASS:** final signed simulator and unsigned device builds. The five reported source deprecation warnings are removed using current trait registration, edit menus and SwiftUI change handlers. The wrapper patch was reapplied to a temporary upstream copy and reproduced the checked-in source exactly.
- README shortened and split into usage/development guides. Portrait and accessibility-medium screenshots with fictional names/favorites inspected; links/images/anchors checked locally.
- **NOT CLAIMED:** physical reconnect to an existing remote tmux session, physical iCloud metadata propagation, or user interaction with the new controls on an iPad. Website preview/SSH port forwarding is not part of this milestone.
