# Experimental Mosh transport

Mosh is opt-in, under **Settings → Experimental transport → Use Mosh**. It applies
to new connections and defaults off. Host, user, SSH port, identity, trusted host
key and optional tmux name work as before. This setting is local to the iPad and
is not part of shared connection history.

## Mac setup

```sh
brew install mosh tmux
```

Keep Remote Login enabled. Allow UDP **60000–61000** from the iPad to the Mac as
well as your SSH port. A Tailscale address is useful when the Mac is behind NAT.
An SSH TCP forward alone cannot carry Mosh. MiniTerm uses the actual SSH peer's
numeric address for UDP, avoiding an unrelated second hostname lookup. SSH proxy
jumps and a separately configured Mosh endpoint/port range are not included.

Choose a tmux session name before connecting so remote work remains available if
the app is terminated or the Mac's Mosh server goes away. MiniTerm adds Homebrew's
Apple Silicon and Intel paths when starting `mosh-server`. Without a tmux name,
Mosh starts the Mac account's default shell.

Normal host-key confirmation and Ed25519 public-key authentication happen before
Mosh starts. The bootstrap runs on a separate SSH exec channel with a PTY and
requires an acknowledged request, bounded valid `MOSH CONNECT` output and a
successful server exit. It never starts a competing interactive SSH shell. The
session key stays in memory; it is not put in Keychain, history, preferences,
terminal output, command arguments, diagnostic reports or state-restoration files.

## During interruptions

The native Mosh worker keeps the encrypted protocol state and queues input in
order. After three seconds without a response the toolbar says **Waiting for
network…**. It resumes when authenticated packets return. Pending input is bounded
and may reach the remote terminal after connectivity returns; commands are not
reissued by the app's reconnect coordinator.

The SSH connection remains available for SFTP and web previews. Losing that socket
closes its routes/transfers and marks **SSH tools offline**, while the Mosh terminal
continues. Foreground or network recovery checks/reopens the SSH connection, with
normal host verification, without replacing the live Mosh engine. If automatic
recovery is disabled, return to Settings to enable it or reconnect manually after
the terminal ends. Transfers are not automatically resumed. An SSH-only failure
while continuously foregrounded may wait until the next wake/network event for
reconnection.

Tap **Disconnect** to stop the terminal and SSH tools. Native shutdown attempts an
acknowledged Mosh close for up to one second without blocking UIKit. A network
failure may prevent the server receiving that close. tmux is independent and stays
running. Startup/UDP configuration failures require manual correction/reconnection
rather than spawning repeated Mosh servers automatically.

## Prototype limits

- Physical iPad sleep, lock, Wi-Fi/cellular/VPN changes and long background periods
  remain untested. iPadOS may suspend or terminate MiniTerm; this feature does not
  create a background-execution entitlement or guarantee continuous networking.
- Protocol state/session keys are not saved to disk. Relaunching starts a new Mosh
  server and reattaches tmux; the previous plain shell is not restored by MiniTerm.
- Mosh synchronizes the visible terminal screen, so use tmux copy mode for remote
  scrollback. Ghostty's supported protocols may differ through Mosh's own remote
  terminal emulator. Local typing prediction is not included in this prototype.
- One terminal workspace. No custom UDP range, separate UDP hostname, ProxyJump,
  suspend/resume snapshots or SSH-only UDP tunneling. Standard IPv4 and unscoped
  IPv6 numeric peer addresses are accepted; scoped link-local IPv6 is not supported.
- Native client input has a 1 MiB producer limit and bounded 64 KiB unacknowledged
  protocol history. Output backpressure pauses ANSI rendering while screen state
  synchronization continues. Disconnect on overflow is explicit.

## Repeatable development checks

```sh
swift build --scratch-path /private/tmp/mini-term-core
python3 Scripts/build_mosh_test_server.py /private/tmp/mini-term-core /private/tmp/mini-term-mosh-server
MOSH_TEST_SERVER=/private/tmp/mini-term-mosh-server swift test --scratch-path /private/tmp/mini-term-core
python3 Scripts/test_mosh_simulator.py SIMULATOR_UDID /private/tmp/mini-term-mosh-server
```

The host-only server fixture is compiled from the same pinned upstream source. It
binds loopback and uses disposable credentials, without installing a service or
accessing personal SSH keys. The encrypted integration test inserts a UDP NAT proxy
that drops packets and changes its server-facing source port. The simulator probe
uses the real Ghostty surface and app model with an isolated generated SSH server.
See [validation](VALIDATION.md) for the current results.

The native Mosh component is GPL-3.0-or-later; Protobuf is BSD-3-Clause. Read
[provenance and distribution obligations](../Vendor/MoshNative/PROVENANCE.md) before
distributing the combined application.
