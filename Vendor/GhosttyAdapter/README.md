# Pinned Ghostty Swift wrapper with input hooks

`Sources/GhosttyTerminal` is copied from [libghostty-spm 2.2.2026102101](https://github.com/Lakr233/libghostty-spm/tree/5b9cb63d83e687b4a66d6c3a3c2a840341c576d9), commit `5b9cb63d83e687b4a66d6c3a3c2a840341c576d9`, under the included MIT license. Resources/notices are retained. The local module is `MiniTermGhosttyTerminal` to avoid conflicting with upstream.

The local target supports iPadOS 17+. Deprecated pre-iOS-16 menu fallbacks are removed, display-scale/color traits use registration callbacks, and SwiftUI uses the current `onChange` closure. These compatibility edits are included in the reviewed patch.

Caret/font geometry changes notify `UITextInputDelegate` without reloading unchanged keyboard/accessory views. Layer sizing touches only the pinned engine's `IOSurfaceLayer`, identified by the class registered in its `src/renderer/metal/IOSurfaceLayer.zig` at engine commit `1e9e14af5df14211892f5fc15fd21a49c7d94868`. UIKit's other layers and animations are left alone. Recheck this engine-layer identification when upgrading the pin. `Scripts/test_input_lifecycle.py` covers ownership, zoom, IME and keyboard continuity with a real surface.

The package still uses that exact upstream `GhosttyKit` product and checksum-verified engine binary. It does not rebuild or replace the engine. DisplayLink stays pinned by the app lockfile.

Upstream’s public `sendKey` immediately presses/releases and derives text from a US table. It cannot model physical holds for arbitrary native keys. Instead of copying keycode tables or adding an encoder, these hooks extend the existing UIKit path:

- Modifier/text policy for native events and repeat.
- Notification before the existing paired shortcut/accessory path.
- Separate special/modifier phases through `sendInputKeyEvent`.
- Native release/repeat cancellation on focus/configuration changes.
- Retain repeat for host-transformed chords UIKit does not own as shortcuts.

[input-hooks.patch](input-hooks.patch) records the narrow source changes against the pin, with zero context (apply to that exact pin using `git apply --unidiff-zero`). On upgrade, refresh from an explicit pin, reapply/review the patch and rerun unit tests, simulator probes and physical keyboard acceptance. Check this directory in; do not modify Xcode’s package cache.
