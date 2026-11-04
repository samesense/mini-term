// Isolated simulator fixture: generated credentials, loopback SSH and synthetic HTTP/WS.
// Never contacts a user's Mac or reads their identity/history.
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import WebKit

private final class PreviewProbeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

private final class PreviewProbeAuth: NIOSSHServerUserAuthenticationDelegate {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [.publicKey] }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        responsePromise.succeed(.success)
    }
}

private final class PreviewProbeShell: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.PseudoTerminalRequest || event is SSHChannelRequestEvent.ShellRequest {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.writeAndFlush(data, promise: nil) }
}

private final class PreviewProbeHTTP: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let paths: PreviewProbeBox<[String]>
    private var bytes = ByteBuffer()
    private var answered = false
    init(paths: PreviewProbeBox<[String]>) { self.paths = paths }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered, case .byteBuffer(var chunk) = unwrapInboundIn(data).data else { return }
        bytes.writeBuffer(&chunk)
        let request = String(decoding: bytes.readableBytesView, as: UTF8.self)
        guard request.contains("\r\n\r\n") else { return }
        answered = true
        let path = request.components(separatedBy: " ").dropFirst().first ?? "/"
        paths.access { $0.append(path) }
        if path == "/socket" {
            let key = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            var buffer = ByteBuffer(string: response)
            let message = Array("SSH_WS_OK".utf8)
            buffer.writeBytes([0x81, UInt8(message.count)] + message)
            context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: nil)
            return
        }
        let body: Data
        let type: String
        switch path {
        case "/asset": body = Data("SSH_ASSET_OK".utf8); type = "text/plain"
        case "/frame": body = Data("<html><body style='color:#c4b5fd;font:16px -apple-system'>SSH_FRAME_OK</body></html>".utf8); type = "text/html"
        case "/pixel": body = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!; type = "image/gif"
        case "/events": body = Data("data: SSH_SSE_OK\n\n".utf8); type = "text/event-stream"
        default: body = Data(Self.page.utf8); type = "text/html"
        }
        var buffer = ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
        buffer.writeBytes(body)
        let channel = context.channel
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenComplete { _ in
            channel.close(mode: .output, promise: nil)
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    private static let page = """
    <!doctype html><html><head><title>SSH_LOADING</title></head><body style="background:#111827;color:#c4b5fd;font:20px -apple-system;padding:30px">
    <h1>MiniTerm SSH Preview</h1><p id="result">Testing page, fetch, image, iframe, WebSocket and SSE through SSH…</p>
    <script>
    window.results=[];
    const ok = name => { results.push(name); };
    Promise.all([
      fetch('/asset').then(r=>r.text()).then(s=>{if(s!=='SSH_ASSET_OK')throw Error('fetch');ok('fetch')}),
      new Promise((resolve,reject)=>{let i=new Image();i.onload=()=>{ok('image');resolve()};i.onerror=reject;i.src='/pixel';document.body.append(i)}),
      new Promise((resolve,reject)=>{let f=document.createElement('iframe');f.onload=()=>{if(!f.contentDocument.body.textContent.includes('SSH_FRAME_OK'))return reject('frame');ok('iframe');resolve()};f.onerror=reject;f.src='/frame';document.body.append(f)}),
      new Promise((resolve,reject)=>{let w=new WebSocket('ws://'+location.host+'/socket');w.onmessage=e=>{if(e.data!=='SSH_WS_OK')return reject('ws');ok('websocket');w.close();resolve()};w.onerror=reject}),
      new Promise((resolve,reject)=>{let s=new EventSource('/events');s.onmessage=e=>{if(e.data!=='SSH_SSE_OK')return reject('sse');ok('sse');s.close();resolve()};s.onerror=reject})
    ]).then(()=>{document.title='SSH_PREVIEW_OK';document.querySelector('#result').textContent=results.join(', ')})
      .catch(e=>{document.title='SSH_PREVIEW_FAIL';document.querySelector('#result').textContent=String(e)});
    </script></body></html>
    """
}

private final class PreviewDirectDetector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let requests: PreviewProbeBox<Int>
    init(requests: PreviewProbeBox<Int>) { self.requests = requests }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        requests.access { $0 += 1 }
        let response = "<html><head><title>DIRECT_LEAK</title></head><body>Unexpected direct request</body></html>"
        let channel = context.channel
        channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 OK\r\nContent-Length: \(response.utf8.count)\r\nConnection: close\r\n\r\n" + response))
            .whenComplete { _ in channel.close(promise: nil) }
    }
}

@MainActor
private final class PreviewProbeRunner: ObservableObject {
    @Published var browser: PreviewBrowser?
    @Published var session: TerminalSessionModel?
    @Published var status = "Starting isolated SSH fixture"
    private var failures: [String] = []
    private var checks = 0
    private func check(_ condition: Bool, _ message: String) { checks += 1; if !condition { failures.append(message) } }
    func run() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let paths = PreviewProbeBox<[String]>([])
        let directRequests = PreviewProbeBox(0)
        let connected = PreviewProbeBox(false)
        let destinations = PreviewProbeBox<[String]>([])
        var listeners: [any Channel] = []
        var transport: SSHTransport?
        defer {
            browser?.close(); session?.disconnect(); transport?.disconnect()
            listeners.forEach { $0.close(promise: nil) }
            let report: [String: Any] = ["checks": checks, "failures": failures, "sshPaths": paths.access { $0 }, "sshDestinations": destinations.access { $0 }, "directRequests": directRequests.access { $0 }]
            let file = URL.documentsDirectory.appendingPathComponent("preview-probe.json")
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        }
        do {
            // A real direct listener at the same URL catches implicit localhost proxy bypass and failover.
            let direct = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(PreviewDirectDetector(requests: directRequests)) }
            }.bind(host: "127.0.0.1", port: 0).get()
            listeners.append(direct)
            let remotePort = direct.localAddress!.port!
            let host = NIOSSHPrivateKey(ed25519Key: .init())
            let hostKey = String(openSSHPublicKey: host.publicKey)
            let ssh = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [host], userAuthDelegate: PreviewProbeAuth())), allocator: channel.allocator,
                        inboundChildChannelInitializer: { child, type in
                            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                                if case .directTCPIP(let target) = type {
                                    destinations.access { $0.append(target.targetHost) }
                                    guard target.targetHost == "localhost", target.targetPort == remotePort else { throw PreviewError.unavailable }
                                    try child.pipeline.syncOperations.addHandler(PreviewProbeHTTP(paths: paths))
                                } else if type == .session { try child.pipeline.syncOperations.addHandler(PreviewProbeShell()) }
                                else { throw PreviewError.unavailable }
                            }
                        }))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            listeners.append(ssh)
            let connection = try SSHConnection(host: "127.0.0.1", username: "fixture", port: ssh.localAddress!.port!)
            let client = SSHTransport(callbacks: .init(state: { state in if state == .connected { connected.access { $0 = true } } }, output: { _ in }))
            transport = client
            client.connect(to: connection, seed: SSHIdentity.generateSeed()) { key, completion in
                completion(key == hostKey ? .success(()) : .failure(TerminalError.hostKeyMismatch))
            }
            for _ in 0..<200 { if connected.access({ $0 }) { break }; try await Task.sleep(for: .milliseconds(25)) }
            check(connected.access { $0 }, "SSH did not authenticate")
            let tunnel = try await client.startPreview(remotePort: remotePort).get()
            let browser = PreviewBrowser(tunnel: tunnel)
            self.browser = browser
            status = "Testing WebKit proxy routing"
            for _ in 0..<400 {
                if browser.webView.title?.hasPrefix("SSH_PREVIEW_") == true || browser.webView.title == "DIRECT_LEAK" { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            check(browser.webView.title == "SSH_PREVIEW_OK", "WebKit page/protocol tests failed: \(browser.webView.title ?? "no title"); \(browser.errorMessage ?? "no error")")
            for path in ["/", "/asset", "/pixel", "/frame", "/socket", "/events"] {
                check(paths.access { $0.contains(path) }, "Not observed through SSH: \(path)")
            }
            check(directRequests.access { $0 } == 0, "WebKit bypassed SSH for localhost")
            let blocked = try await browser.webView.callAsyncJavaScript("""
                const target='localhost:'+port;
                const fetchResult=fetch('http://'+target+'/blocked-loopback',{cache:'no-store'}).then(()=> 'OPEN',()=> 'BLOCKED');
                const socketResult=new Promise(resolve=>{
                    const socket=new WebSocket('ws://'+target+'/blocked-socket');
                    socket.onopen=()=>{socket.close();resolve('OPEN')};
                    socket.onerror=()=>resolve('BLOCKED');
                    setTimeout(()=>{socket.close();resolve('TIMEOUT')},2000);
                });
                return (await Promise.all([fetchResult,socketResult])).join('|');
                """, arguments: ["port": remotePort], in: nil, contentWorld: .page)
            check(blocked as? String == "BLOCKED|BLOCKED", "Literal loopback fetch/WebSocket was not blocked")
            check(directRequests.access { $0 } == 0, "Literal loopback resource bypassed SSH")
            _ = try await browser.webView.callAsyncJavaScript("return await fetch('https://preview-fixture.invalid/resource').then(()=> 'UNEXPECTED',()=> 'DENIED')",
                                                              arguments: [:], in: nil, contentWorld: .page)
            check(destinations.access { $0.contains("preview-fixture.invalid") }, "External HTTPS hostname was not sent through SSH")
            browser.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(remotePort)/outside")!))
            try await Task.sleep(for: .milliseconds(250))
            check(browser.errorMessage?.contains("leaves the preview") == true, "External main-frame navigation was not blocked")
            check(directRequests.access { $0 } == 0, "External main-frame navigation made a direct request")
            // A sibling web view (Safari's network path) can reach the plain local forward.
            let safariConfiguration = WKWebViewConfiguration()
            safariConfiguration.websiteDataStore = .nonPersistent()
            let safari = WKWebView(frame: .zero, configuration: safariConfiguration)
            safari.load(URLRequest(url: browser.safariURL))
            for _ in 0..<300 {
                if safari.title?.hasPrefix("SSH_PREVIEW_") == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            check(safari.title == "SSH_PREVIEW_OK", "Plain loopback forward failed in sibling web view")
            safari.stopLoading()
            // Drop only the proxy: a reachable DIRECT listener still must not receive browser fetches.
            try await tunnel.close().get()
            let before = directRequests.access { $0 }
            let result = try await browser.webView.callAsyncJavaScript("return await fetch('/after-close?'+Date.now(),{cache:'no-store'}).then(()=> 'DIRECT_OR_CACHED',()=> 'BLOCKED')",
                                                                      arguments: [:], in: nil, contentWorld: .page)
            check(result as? String == "BLOCKED", "WebKit did not fail closed after proxy shutdown")
            check(directRequests.access { $0 } == before, "WebKit fell back to direct networking")
            check(browser.webView.configuration.websiteDataStore.isPersistent == false, "Preview data store is persistent")
            // Mount the real workspace, using only this fixture's generated host key and identity.
            try KeychainStore().save(Data(hostKey.utf8), account: "host:" + connection.hostKeyAccount)
            check(try KeychainStore().read(account: "host:" + connection.hostKeyAccount) == Data(hostKey.utf8), "Fixture host trust was not stored")
            let model = TerminalSessionModel(connection: connection, seed: SSHIdentity.generateSeed())
            session = model
            try await waitForSession(model, hostKey: hostKey)
            check(model.state == .connected, "Mounted workspace failed to connect")
            let surface = terminalSurface()
            check(surface != nil, "Real Ghostty surface is not mounted")
            model.preview.portText = String(remotePort)
            model.preview.open()
            try await waitForPage(model.preview)
            check(model.preview.browser?.webView.title == "SSH_PREVIEW_OK", "Workspace preview did not load")
            check(terminalSurface() === surface, "Switching to preview replaced the terminal")
            let initialBrowser = model.preview.browser
            model.preview.showing = false
            try await Task.sleep(for: .milliseconds(150))
            check(model.state == .connected, "Switching to terminal disconnected SSH")
            model.preview.showing = true
            try await Task.sleep(for: .milliseconds(150))
            check(model.preview.browser === initialBrowser, "Switching recreated the browser")
            model.preview.open()
            try await waitForPage(model.preview)
            check(model.preview.browser !== initialBrowser, "Changing port did not replace browser context")
            check(mountedWebView() === model.preview.browser?.webView, "SwiftUI kept a retired web view after reopening")
            // Unsaved form edits must not replace the running destination on reconnect.
            model.preview.portText = "99999"; model.preview.useHTTPS = true
            model.disconnect()
            for _ in 0..<100 { if model.state.isFinished { break }; try await Task.sleep(for: .milliseconds(25)) }
            guard let next = model.reconnectSession() else { throw PreviewError.disconnected }
            session = next
            try await waitForSession(next, hostKey: hostKey)
            try await waitForPage(next.preview)
            check(next.id != model.id, "Reconnect reused the old workspace")
            check(next.preview.showing && next.preview.portText == String(remotePort), "Reconnect lost preview port/selection")
            check(!next.preview.useHTTPS, "Reconnect used an unapplied protocol edit")
            check(next.preview.browser?.webView.title == "SSH_PREVIEW_OK", "Reconnect did not restore preview")
            // Fixture account is scoped to this ephemeral listener, not any user destination.
            try? KeychainStore().delete(account: "host:" + connection.hostKeyAccount)
            captureWorkspace()
            status = failures.isEmpty ? "Preview probe passed" : "Preview probe failed"
        } catch { failures.append(String(describing: error)); status = "Preview probe failed" }
    }

    private func waitForSession(_ model: TerminalSessionModel, hostKey: String) async throws {
        for _ in 0..<250 {
            if let trust = model.trustRequest {
                check(trust.key == hostKey, "Unexpected host key in generated fixture")
                model.answerTrust(trust, allow: trust.key == hostKey)
            }
            if model.state == .connected || model.state.isFinished { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PreviewError.unavailable
    }
    private func waitForPage(_ model: PreviewModel) async throws {
        for _ in 0..<400 {
            if model.browser?.webView.title?.hasPrefix("SSH_PREVIEW_") == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PreviewError.unavailable
    }
    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func terminalSurface() -> UIView? { window.flatMap { descendants($0).first { $0.accessibilityIdentifier == "terminal.surface" } } }
    private func mountedWebView() -> UIView? { window.flatMap { descendants($0).first { $0.accessibilityIdentifier == "preview.web" } } }
    private func captureWorkspace() {
        guard let window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("preview-workspace.png"))
    }
}

struct PreviewProbeView: View {
    @StateObject private var runner = PreviewProbeRunner()
    var body: some View {
        VStack {
            if let session = runner.session { TerminalScreen(model: session).id(session.id) }
            else {
                Text(runner.status)
                if let browser = runner.browser { PreviewWebView(browser: browser) }
            }
        }.task { await runner.run() }
    }
}
