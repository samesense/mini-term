# Website previews

MiniTerm can view a Mac development server through the existing SSH connection. The in-app preview uses a per-browser authenticated SOCKS5 proxy and SSH `direct-tcpip` channels. The development server can remain bound to the Mac's localhost; it does not need a public HTTP port or deployment.

The preview has automated simulator and physical iPad mini coverage with isolated fixtures. Actual Safari app behavior, minimum-runtime coverage, and real framework hot reload still need acceptance testing. See [validation](VALIDATION.md#physical-ipad-routing-fix--2026-11-03) and the [implementation plan](PREVIEW_PLAN.md).

## Open a preview

1. Connect to the Mac and start your website's development server in the terminal. Use tmux if it should survive an SSH disconnection.
2. Tap the **globe** beside the keyboard button. Enter the port printed by the development server, such as `3000` or `5173`.
3. Leave **Use HTTPS** off for an ordinary HTTP development server. Turn it on only when that port actually serves HTTPS and the iPad trusts a certificate valid for `mini-term-preview.invalid`. MiniTerm does not bypass TLS verification.
4. Tap **Open preview**. Switch between **Terminal** and **Preview** using the segmented control. The terminal stays connected and retains its surface.
5. Use the preview's back/reload controls. **Port** opens its settings; **×** closes preview and its forwarding channels while leaving SSH connected.

The toolbar shows the **Mac's localhost port**. Internally the browser uses `http://mini-term-preview.invalid:PORT`, a reserved hostname mapped to the Mac's localhost by the authenticated SSH proxy. This avoids physical iPadOS WebKit's implicit proxy bypass for literal localhost URLs; explicit proxy matching and disabling failover did not prevent that bypass in device testing. The reserved name needs no DNS setup.

Normal page navigation stays within that preview host and selected port. External top-level links and application schemes are blocked. Relative assets, fetch, iframe, WebSocket and SSE requests follow the preview origin through SSH. HTTP(S) external subresources also use the proxy. Network rules are installed before loading; explicit localhost, `.localhost`, IPv4 loopback and `::1` page resources are blocked instead of silently opening the iPad's local services.

Development servers with Host/Origin allowlists must allow **`mini-term-preview.invalid`** specifically. MiniTerm preserves HTTP headers; it does not rewrite Host, Origin, cookies, redirects or HTML. Prefer relative URLs or URLs built from the current page origin. Hardcoded `localhost` asset/API/live-reload URLs and `Domain=localhost` cookies need configuration for the preview origin. Browser features requiring a secure origin may require HTTPS and a trusted development certificate for the reserved name. Keep host checks and TLS verification enabled.

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

The embedded proxy explicitly disables direct fallback. Simulator and physical-device tests leave a direct listener reachable on the iPad's localhost at the selected Mac port. The fixed preview loads through SSH, literal localhost fetch/WebSocket requests are blocked, and a new request fails after proxy shutdown rather than taking a direct route. This evidence covers the tested WebKit runtime and TCP web paths. It does not establish absence of speculative DNS traffic, all browser protocols, or all OS versions. WebRTC/UDP, QUIC/WebTransport, downloads outside the embedded web view, and arbitrary untrusted web content are outside the verified scope. The feature is not a VPN or a general browser sandbox.

## Resource handling

Each browser TCP stream gets an independent SSH child. Forwarded errors close only the paired streams; closing preview leaves the terminal connected. Disconnect/replacement closes the listeners and active streams. Both listeners bind only to iPad `127.0.0.1` on OS-assigned ports.

The proxy accepts at most 12 concurrent streams, including pending handshakes, with a 15-second handshake/channel-open deadline. Relayed writes have a 4 MiB per-direction limit and a shared 16 MiB queued-byte limit. Reads follow write completion/writability; the pinned NIOSSH implementation also bounds unread child data through its receive windows. These are queue bounds, not a claim about total app memory. Long-lived established WebSocket/SSE streams have no artificial idle timeout.

Terminal output pressure pauses its SSH child while leaving the shared parent socket reading. An already-issued child read is held in a separate bounded 4 MiB queue until the renderer resumes, so a paused terminal does not starve web traffic. Termination drains those received bytes before reporting the final state. Ghostty's parser backlog thresholds remain 1 MiB/256 KiB.
