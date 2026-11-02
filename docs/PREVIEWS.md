# Website previews

MiniTerm can view a Mac development server through the existing SSH connection. The in-app preview uses a per-browser authenticated SOCKS5 proxy and SSH `direct-tcpip` channels. The development server can remain bound to the Mac's localhost; it does not need a public HTTP port or deployment.

This is a first implementation with automated simulator evidence. Physical iPad, Safari app behavior, minimum-runtime coverage, and real framework hot reload still need acceptance testing. See [validation](VALIDATION.md#website-preview-milestone) and the [implementation plan](PREVIEW_PLAN.md).

## Open a preview

1. Connect to the Mac and start your website's development server in the terminal. Use tmux if it should survive an SSH disconnection.
2. Tap the **globe** beside the keyboard button. Enter the port printed by the development server, such as `3000` or `5173`.
3. Leave **Use HTTPS** off for an ordinary HTTP development server. Turn it on only when that port actually serves HTTPS and the iPad trusts its certificate for localhost. MiniTerm does not bypass TLS verification.
4. Tap **Open preview**. Switch between **Terminal** and **Preview** using the segmented control. The terminal stays connected and retains its surface.
5. Use the preview's back/reload controls. **Port** opens its settings; **×** closes preview and its forwarding channels while leaving SSH connected.

The displayed `localhost:PORT` is reached on the **Mac through SSH**. Normal page navigation stays within that localhost host and selected port. External top-level links and application schemes are blocked. HTTP(S) subresources and WebSocket/SSE traffic use the web view's proxy; external HTTPS hostnames are passed to the Mac through SSH rather than opened as direct browser TCP connections.

Port and HTTP/HTTPS choice are saved locally per connection profile. Browser cookies/storage are nonpersistent and isolated to a preview context. Changing the port, reopening preview, or reconnecting creates a fresh browser context. If Preview was selected when disconnected, reconnect restores it and loads the root page; otherwise it returns to Terminal and the globe can reopen preview. It does not restore the previous path or browser login state. Preview preferences, URLs, cookies, and proxy credentials are not added to iCloud connection history or diagnostic reports.

## Safari: experimental

Inside the preview, choose **… → Open in browser (experimental)**. This opens the iPad's default browser, which can be Safari. MiniTerm opens a separate loopback address such as `http://localhost:LOCAL_PORT/`. That local port forwards TCP through the same SSH connection to the selected Mac port. It is valid only while the current preview tunnel is alive; an old Safari tab stops working after close/reconnect/port changes.

This forwards that localhost endpoint, not all of Safari. External resources and other destinations use Safari's normal networking. Absolute redirects to the original Mac port, hardcoded live-reload ports, Host/origin checks, HTTPS certificate names, and cookies can behave differently because Safari sees the local forwarding port. Prefer the in-app browser when these matter; do not disable a development server's host checks to work around them.

iPadOS may suspend MiniTerm after switching to Safari, interrupting the tunnel. Keeping both apps visible in multitasking may help, but is not a background execution guarantee. The automated check uses a separate unproxied `WKWebView` against the local forward; it does **not** establish Safari app compatibility on physical hardware. Safari keeps its own history and cookies. The loopback-only Safari listener is not authenticated, so other software on the same iPad that knows its ephemeral port may reach it while preview is open.

## Failure and scope

- **SSH disconnected:** use the workspace's **Reconnect** action. Host verification still applies. A fresh tunnel and browser load after the new connection is ready.
- **Page cannot load:** confirm the development server is running on the chosen port/protocol. A working shell does not prove SSH forwarding is allowed. OpenSSH restrictions such as `AllowTcpForwarding`, `DisableForwarding`, `PermitOpen`, or authorized-key options can reject it.
- **Live reload:** WebSockets and SSE pass the simulator fixture. Real Vite/Next.js integration is pending; use the project's normal localhost configuration first. Fixed alternate ports and HTTPS setups may need version-specific configuration.
- **HTTPS:** the normal WebKit certificate checks apply. Self-signed or mismatched certificates are not silently trusted.
- **Background/lock:** networking may stop; reconnect manually. tmux preserves the remote development process, not the iPad socket.

The embedded proxy explicitly disables direct fallback. Simulator tests leave a direct listener reachable at the same localhost URL and confirm that supported page requests do not use it, including after proxy shutdown. This evidence covers the tested WebKit runtime and TCP web traffic. It does not establish absence of speculative DNS traffic, all browser protocols, or all OS versions. WebRTC/UDP, QUIC/WebTransport, downloads outside the embedded web view, and arbitrary untrusted web content are outside the verified scope. The feature is not a VPN or a general browser sandbox.

## Resource handling

Each browser TCP stream gets an independent SSH child. Forwarded errors close only the paired streams; closing preview leaves the terminal connected. Disconnect/replacement closes the listeners and active streams. Both listeners bind only to iPad `127.0.0.1` on OS-assigned ports.

The proxy accepts at most 12 concurrent streams, including pending handshakes, with a 15-second handshake/channel-open deadline. Relayed writes have a 4 MiB per-direction limit and a shared 16 MiB queued-byte limit. Reads follow write completion/writability; the pinned NIOSSH implementation also bounds unread child data through its receive windows. These are queue bounds, not a claim about total app memory. Long-lived established WebSocket/SSE streams have no artificial idle timeout.

Terminal output pressure pauses its SSH child while leaving the shared parent socket reading. An already-issued child read is held in a separate bounded 4 MiB queue until the renderer resumes, so a paused terminal does not starve web traffic. Termination drains those received bytes before reporting the final state. Ghostty's parser backlog thresholds remain 1 MiB/256 KiB.
