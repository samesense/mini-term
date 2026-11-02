# Mini Term usage details

For installation and the first connection, start with the [README](../README.md).

## SSH identity and host trust

Mini Term generates an Ed25519 identity on the iPad. Open **Settings → SSH identity → Create SSH key**, then **Copy public key**. Its 32-byte private seed is stored in the device-only Keychain and is accessible only while the device is unlocked. Importing private keys, passphrases, and SSH agents is not implemented.

Prepare the Mac’s SSH directory if necessary:

```sh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Append the complete copied public-key line to `~/.ssh/authorized_keys` using a text editor. Keep existing lines intact. The line starts with `ssh-ed25519`; the `mini-term-ipad` comment is just a label. Never copy a private key into this file.

Enable macOS Remote Login for the intended account and use its short username (`whoami`). The Mac must be awake and reachable by hostname/IP, either on the local network or through a VPN such as Tailscale. Mini Term does not embed a VPN.

The first connection asks you to verify the server’s SHA256 host fingerprint independently. On the Mac, inspect the matching public host key:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub
```

Compare the fingerprint for the key type the app displays before choosing **Trust and connect**. Trust records are scoped to hostname and port, so aliases/IPs have separate records. A changed key is rejected before authentication.

If the Mac was intentionally reinstalled or its SSH keys rotated, verify the new key independently. Fill the relevant host and port in the connection form, then use **Settings → Host trust → Forget this host’s saved key…**. The next connection asks for verification again.

## Terminal controls

Ghostty provides the accessory bar’s terminal keys and modifiers, plus native hardware-key handling. Long press/double tap for selection and copy; use the edit menu or keyboard shortcut to paste. Two-finger scrolling moves through local scrollback. Pinch or Ghostty’s font-size shortcuts adjust the font.

While a remote TUI captures mouse input, terminal taps send clicks without toggling the software keyboard. Use the **keyboard button** in the top bar. In an ordinary shell without mouse capture, tapping toggles it.

Remote OSC 52 clipboard requests are blocked; user-initiated copy/paste remains available. Pasting a local file path does not upload the file to your Mac.

Dual-role Caps Lock has its own [setup, API limitations, and test checklist](KEYBOARD.md).

## Reconnect and diagnostic reports

After SSH disconnects or fails, **Reconnect** opens a fresh connection with the same host, account, port, and tmux name. It reuses this iPad’s identity and normal host-verification checks. Old byte queues, keyboard state, sockets, and terminal surfaces are retired; no input is replayed. tmux can restore a continuing remote session, while an ordinary shell starts anew. There is no automatic reconnect in the background.

Choose **… → Copy diagnostics** in the terminal, or **Copy diagnostics** below a connection-form error. Reports include app/OS versions, attempt count, phase timestamps, safe error categories, numeric system codes where available, and Caps/Control event counts. They exclude destination/account/session names, private/public keys, trusted host records, file paths, terminal text, and raw error descriptions. Errors remain visible in the app; the copied report uses an allowlist instead of trying to scrub arbitrary text. Reports stay in memory until explicitly copied and are not stored in connection history or sent automatically.

## Connection history

**Save connection** stores a destination without connecting and changes to **Saved connection** once it is stored. Successful logins update recency automatically; failed logins do not add a new history entry. Tap a row to fill host, username, port, and tmux session. The last selected destination is restored on launch. A row’s **…** menu offers **Rename**, **Favorite / Remove favorite**, and **Delete**. A blank name restores the hostname. Favorites sort first and are retained as bookmarks; up to 30 additional recent destinations are kept. The destination, SSH account, and tmux name still define identity, so renaming never changes where the app connects.

### Choose a shared folder

1. Open **Settings → Connection history → Choose iCloud Drive folder**.
2. In Files, open **iCloud Drive**, create or select a folder such as **Mini Term**, and choose **Open**.
3. On another device using the same Apple account, choose that same folder in Mini Term.

History merges when the app opens, after saves/deletes, and when the file provider reports changes. **Refresh history** retries explicitly. Apple controls upload/download timing, so other devices may not see changes immediately.

This uses ordinary user-selected files and works with Personal Team signing; no CloudKit or app-private iCloud entitlements are requested. Selecting **On My iPad** or another provider stores files there instead of promising iCloud synchronization.

### Privacy, offline use, and recovery

History contains host, username, port, optional tmux session, dates, friendly names, and favorites. Name/favorite metadata has a revision separate from login recency, so a login on another device cannot erase it. Older history files without these fields still load. It excludes private keys, trusted host keys, terminal commands, and output. Another device must install its own public SSH key on the Mac and verify the host fingerprint.

The app keeps a local metadata cache for offline use and a persistent folder-access bookmark on each device. One JSON replica per device, per-entry revisions, and deletion records allow offline changes to merge without one device replacing another’s file.

**Stop folder sync** keeps local connections and leaves the folder’s files untouched. Files also remain if you remove the app. If access is revoked or the folder is unavailable, local history remains usable; choose the folder again to restore sync. A clean reinstall can recover metadata from that folder, but not SSH credentials.

Physical iCloud upload/download and bookmark restoration remain acceptance checks. Automated tests exercise local persistence, merge/deletion behavior, and coordinated replica-file I/O; see [validation](VALIDATION.md).

## tmux session switcher

A named connection requests a PTY and runs `tmux new-session -A -s NAME`. Mini Term checks the usual Apple Silicon and Intel Homebrew tmux paths as well as the remote PATH. You can also create a session yourself with `tmux new-session -s codex` and launch your tools there.

For the touch menu, install the helper on each Mac that runs tmux 3.2+:

```sh
python3 Scripts/install_tmux_switcher.py
```

The installer copies the helper/config to `~/.config/mini-term/`, backs up the tmux config before adding an include, and reloads an already-running server. It detects gpakosz’s `.tmux.conf.local` customization file. It enables mouse mode and binds a left click on the session name at the left of the status line to the menu. Mouse-capable desktop terminals can use it too; existing prefix and keyboard switching bindings are preserved.

Tap a session to switch. A short terminal or a long session list uses tmux’s scrollable tree instead; press `q` to cancel. The menu lists sessions on the current tmux socket, not separate servers.

Use `--config /path/to/tmux.conf` for a custom configuration or `--no-reload` to defer activation until tmux restarts. The installer does not change SSH credentials or install an agent process.
