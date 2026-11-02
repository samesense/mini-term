# Dual-role Caps Lock

Enabled by default in **Settings → Hardware keyboard**. A delivered Caps down/up pair sends Escape on release when used alone, regardless of duration. Another key pressed during the hold activates Control until Caps is released. Shift, Option and Command stay in the native event. Disabling the setting restores the ordinary Ghostty path.

## iPadOS API findings

We inspected the installed public SDK and pinned wrapper. We have **not verified physical Caps Lock delivery on a USB or Bluetooth keyboard**. The existence of a Caps HID constant does not prove every keyboard/OS combination delivers physical edges.

| API | Useful information | Limitation / implementation |
| --- | --- | --- |
| `UIPress`, `UIPressesEvent`, `UIKey` | Down/up/cancel callbacks, HID usage, layout-provided text and modifiers | Used before Ghostty forwarding, only for events iPadOS delivers. Simultaneous dual-key down is processed first and release last. |
| `UIKeyCommand` | Shortcut action and logical modifiers | No physical release/held-key identity. Keep the wrapper’s existing paired press/release path; record that a chord occurred so source release does not also send Escape. |
| `GCKeyboard` | Key states/change callbacks, including Caps; coalesced keyboards | Diagnostic observation only. The inspected public API has no event cancellation/global Caps setter and no layout-aware text. Never mix its callbacks into a second input stream. |
| `.alphaShift` | Logical Caps state on an event | A latched flag does not mean the physical key is held. Never infer a tap/release from it. |

Apple documents [UIKit physical press/release handling](https://developer.apple.com/documentation/uikit/handling-key-presses-made-on-a-physical-keyboard), the [Caps HID usage](https://developer.apple.com/documentation/uikit/uikeyboardhidusage/keyboardcapslock), [GameController key callbacks](https://developer.apple.com/documentation/gamecontroller/gckeyboardvaluechangedhandler), and [coalesced keyboards](https://developer.apple.com/documentation/gamecontroller/gckeyboard). These describe API capabilities, not hardware compatibility results. Apple also documents [Caps language switching](https://support.apple.com/guide/ipad/switch-between-keyboards-ipaddd28d7ed/ipados), which can assign Caps another system role.

**An app cannot guarantee the strict requirement to never toggle system capitalization.** We consume delivered Caps events rather than forwarding them to the text system, remove Caps from Ghostty modifiers, and correct ordinary layout-provided text when UIKit already applied Caps capitalization. We do not invent Option/dead-key/IME mappings, turn off a hardware LED, undo global state, or intercept events the OS never delivers. A swallowed/transformed release cannot be reliably recovered. No timeout guesses a release.

## Best available fallback

If Caps still capitalizes, switches language, or a release is missing:

1. In iPad Settings, open **General → Keyboard → Hardware Keyboard → Modifier Keys**, select the attached keyboard if offered, and map **Caps Lock → Control**. Turn off **Switch Languages using Caps Lock** if present and interfering.
2. In Mini Term **Settings → Hardware keyboard → Input source**, select **Remapped left Control**.
3. Repeat the tests below. This deliberately gives the physical left Control key the same dual role; UIKit cannot distinguish it from Caps remapped to left Control. Right Control keeps its ordinary role.

This avoids asking the app to suppress the original Caps toggle. It still requires usable Control edges. Shortcut-only keys retain the wrapper’s paired-event semantics; their physical release timing is unavailable. Reserved system shortcuts/language switching may never reach the terminal. The app only transforms terminal input; the iPad Settings remap is system-wide.

## Architecture

`MiniTermCore.DualRoleKeyboard` is a reusable, UIKit-independent HID state machine with no clock or text encoder. Normal native keys stay in Ghostty’s input path. Only Control/Escape are synthesized, with separate phases through the same funnel. The [pinned local Swift wrapper](../Vendor/GhosttyAdapter/README.md) adds narrow hooks; the engine binary, HID translation, IME, shortcut deduplication and repeat are reused.

The most recent held key repeats through the existing timer. A host-added Control does not falsely classify that key as a UIKit shortcut. Caps release updates the repeat’s effective modifiers. Cancellation, focus/window/scene loss, keyboard disconnect and configuration changes stop repeat, release keys before virtual Control, swallow late releases and never emit a tap Escape. Physical and virtual left Control share balanced ownership.

## Verification

Run `swift test`. On Apple Silicon with a booted iPad simulator:

```sh
python3 Scripts/test_keyboard_input.py SIMULATOR_UDID
```

The probe builds an isolated app, mounts a real Ghostty surface and invokes the adapter using artificial `UIKey`/`UIPress` test doubles. It checks bytes, modifiers, focus cleanup, long hold and the repeat timer. It never opens SSH and is uninstalled afterward. **It does not inject OS keyboard events or prove physical USB/Bluetooth support.**

Expand **Settings → Hardware keyboard → Check keyboard event delivery**. Test inside the terminal, then return to Settings. Counts contain only Caps/left-Control down/up edges, never typed text, and reset per app launch. GameController counts are separate; a GC pair alone does not establish that UIKit received a suppressible pair. These are delivery diagnostics, not automatic compatibility certification.

## Physical acceptance — not yet tested

Test separately with a standard USB keyboard and a Bluetooth keyboard. Record model, connection, layout, iPad/iPadOS, modifier/language settings and selected input source.

- [ ] Caps tap → one Escape, no capitalization/language toggle.
- [ ] Caps+C and Caps+A → Ctrl+C and Ctrl+A.
- [ ] Caps+Shift+C preserves Shift; also test Option and a non-US layout.
- [ ] Hold Caps at least three seconds, release alone → one Escape.
- [ ] Multiple keys during one hold all receive Control.
- [ ] Repeat a letter; release Caps first → subsequent repeats/releases lose virtual Control.
- [ ] Release Caps before the letter → no extra Escape or stuck modifier.
- [ ] Lose focus/background/disconnect keyboard during a chord; return and type normally.
- [ ] Disable/re-enable and verify ordinary Caps behavior while disabled.
- [ ] Repeat with the system-remapped fallback, including shortcut actions.
- [ ] In a Kitty event-reporting program, verify physical press/repeat/release ordering; distinguish shortcut-only paired events.

**USB and Bluetooth compatibility remain unverified.** Simulator test doubles cannot answer whether your iPad exposes the original Caps Lock edges.
