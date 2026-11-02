# Development

Open `MiniTerm.xcodeproj` to build the iPad app. The root Swift package contains `MiniTermCore` and its unit/integration tests; it can be built independently on macOS without the Ghostty renderer or an SSH daemon.

## Toolchain and builds

Use full Xcode with iOS platform support and Swift 6.2+. If the shell selects Command Line Tools, select Xcode for that shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Resolve dependencies and build unsigned targets:

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

For physical installation, select a Personal Team and automatic signing in Xcode, pair the iPad, enable Developer Mode, and run with **⌘R**. A successful unsigned build does not verify signing or physical behavior.

## Project and dependency maintenance

The Xcode project and shared scheme are checked in. After adding app source files, regenerate with:

```sh
python3 Scripts/generate_project.py
```

Generation replaces the project’s settings, including local signing choices. To inspect a generated copy while preserving your current project, use an existing output directory:

```sh
python3 Scripts/generate_project.py --output-root /private/tmp/mini-term-generated
```

Keep both checked-in `Package.resolved` files when updating dependencies. The app uses the [pinned local Ghostty Swift adapter](../Vendor/GhosttyAdapter/README.md), with the exact upstream engine binary supplied through SwiftPM. Review its source patch when upgrading; do not edit Xcode’s package cache. [Architecture](ARCHITECTURE.md) records pins and integration details.

## Automated checks

`swift test` covers connection validation, key fingerprints, real encrypted SSH loopback traffic, PTY/shell ordering, backpressure, cancellation, history merging, and the dual-role keyboard state machine. It uses generated test credentials and ephemeral loopback servers, not personal keys or a reachable Mac.

The tmux probe uses an isolated server and real mouse sequences:

```sh
python3 Scripts/test_tmux_switcher.py
```

On Apple Silicon with a booted iPad simulator, use its UDID for UIKit/Ghostty probes:

```sh
xcrun simctl list devices booted
python3 Scripts/test_keyboard_layout.py SIMULATOR_UDID
python3 Scripts/test_keyboard_input.py SIMULATOR_UDID
python3 Scripts/test_session_features.py SIMULATOR_UDID
```

The layout probe exercises the production constraints during keyboard/container changes. The input probe mounts a real Ghostty surface but supplies artificial UIKit key/press objects; it does not establish physical Caps Lock delivery. The keyboard probes install isolated test apps, open no SSH connections, and uninstall afterward. The session probe uses real app models against a closed simulator loopback port to verify reconnect isolation, attempt counting, diagnostics redaction, and old-model cleanup; it never contacts a remote Mac. See [keyboard findings](KEYBOARD.md) and [validation](VALIDATION.md) for scope and hardware acceptance.

[GitHub Actions](https://github.com/samesense/mini-term/actions/workflows/build.yml) runs core tests, the tmux interaction probe, deterministic project generation, dependency resolution, and unsigned simulator/device builds. It does not run physical iPad or iCloud-provider checks.

## Design previews

Debug simulator builds accept these launch arguments:

- `--design-preview`: seed fictional saved destinations in that simulator’s local history.
- `--design-settings`: open the Settings sheet.

These flags have no effect on physical devices or Release builds. Use an isolated simulator for fixtures. README screenshots live in `docs/design/`; they are running-app captures, not evidence of physical hardware behavior. The [icon record](design/icon-generation.md) contains the artwork’s generation prompt.
