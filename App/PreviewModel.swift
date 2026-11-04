import Combine
import Foundation
import MiniTermCore
import Network
import SwiftUI
import WebKit

@MainActor
final class PreviewModel: ObservableObject {
    @Published var showing = false
    @Published var editingPort = false
    @Published var portText: String
    @Published var useHTTPS: Bool
    @Published var pathText = "/"
    @Published var shortcutName = ""
    @Published private(set) var shortcuts: [PreviewShortcut] = []
    @Published private(set) var selectedPort: Int
    @Published private(set) var browser: PreviewBrowser?
    @Published private(set) var message: String?
    @Published private(set) var isStarting = false
    @Published private(set) var connected = false
    private weak var transport: SSHTransport?
    private let preferenceKey: String
    private var generation = UUID()
    private var restoreOnConnect = false
    private var wasOpen = false
    private var selectedHTTPS: Bool
    private(set) var selectedPath = "/"
    private var editingShortcutID: UUID?

    init(connection: SSHConnection) {
        preferenceKey = "preview.port." + ConnectionProfile(connection).id
        let saved = UserDefaults.standard.integer(forKey: preferenceKey)
        let port = (1...65535).contains(saved) ? saved : 3000
        let secure = UserDefaults.standard.bool(forKey: preferenceKey + ".https")
        selectedPort = port; portText = String(port)
        useHTTPS = secure; selectedHTTPS = secure
        let savedPath = UserDefaults.standard.string(forKey: preferenceKey + ".path") ?? "/"
        if PreviewShortcut.validPath(savedPath) { selectedPath = savedPath; pathText = savedPath }
        if let data = UserDefaults.standard.data(forKey: preferenceKey + ".shortcuts") {
            shortcuts = (try? PreviewShortcut.decode(data)) ?? []
        }
    }

    func attach(_ transport: SSHTransport) { self.transport = transport }
    func connectionReady() {
        connected = true
        if restoreOnConnect {
            let selected = showing
            restoreOnConnect = false; open(); showing = selected
        }
    }
    func disconnected() {
        connected = false; transport = nil; generation = UUID(); isStarting = false
        if showing { message = "SSH disconnected. Reconnect to reload your preview." }
        browser?.close(); browser = nil
    }
    func restore(from old: PreviewModel) {
        selectedPort = old.selectedPort; portText = String(old.selectedPort)
        selectedHTTPS = old.selectedHTTPS; useHTTPS = old.selectedHTTPS
        selectedPath = old.selectedPath; pathText = old.selectedPath
        showing = old.showing
        wasOpen = old.wasOpen
        restoreOnConnect = old.wasOpen
    }

    func beginEditing() {
        portText = String(selectedPort); useHTTPS = selectedHTTPS
        pathText = selectedPath; shortcutName = ""; editingShortcutID = nil
        message = nil; editingPort = true
    }

    func editShortcut(_ shortcut: PreviewShortcut) {
        portText = String(shortcut.port); useHTTPS = shortcut.useHTTPS
        pathText = shortcut.path; shortcutName = shortcut.name; editingShortcutID = shortcut.id
        message = nil
    }
    func openShortcut(_ shortcut: PreviewShortcut) { editShortcut(shortcut); open() }
    func saveShortcut() {
        do {
            guard let port = Int(portText) else { throw WorkspacePreferenceError.invalidPreview }
            let entry = try PreviewShortcut(id: editingShortcutID ?? UUID(), name: shortcutName, port: port, useHTTPS: useHTTPS, path: pathText)
            var next = shortcuts.filter { $0.id != entry.id }
            guard next.count < 20 else { throw WorkspacePreferenceError.tooManyShortcuts }
            next.append(entry)
            UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: preferenceKey + ".shortcuts")
            shortcuts = next; editingShortcutID = entry.id; message = "Shortcut saved."
        } catch { message = error.localizedDescription }
    }
    func removeShortcut(_ shortcut: PreviewShortcut) {
        let next = shortcuts.filter { $0.id != shortcut.id }
        guard let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: preferenceKey + ".shortcuts"); shortcuts = next
        if editingShortcutID == shortcut.id { editingShortcutID = nil; shortcutName = "" }
    }

    func open() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            message = PreviewError.invalidPort.localizedDescription; return
        }
        guard connected, let transport else { message = PreviewError.disconnected.localizedDescription; return }
        guard PreviewShortcut.validPath(pathText) else { message = WorkspacePreferenceError.invalidPreview.localizedDescription; return }
        generation = UUID()
        let request = generation
        browser?.close(); browser = nil
        showing = true; editingPort = false; isStarting = true; message = nil
        wasOpen = true
        portText = String(port)
        selectedPort = port; selectedHTTPS = useHTTPS
        selectedPath = pathText
        UserDefaults.standard.set(port, forKey: preferenceKey)
        UserDefaults.standard.set(useHTTPS, forKey: preferenceKey + ".https")
        UserDefaults.standard.set(selectedPath, forKey: preferenceKey + ".path")
        let secure = useHTTPS
        let path = selectedPath
        Task { [weak self] in
            do {
                let tunnel = try await transport.startPreview(remotePort: port).get()
                guard let self, generation == request, connected else { _ = tunnel.close(); return }
                browser = PreviewBrowser(tunnel: tunnel, useHTTPS: secure, path: path)
                isStarting = false
            } catch {
                guard let self, generation == request else { return }
                isStarting = false
                message = "Could not open the preview tunnel. Check SSH and try again."
            }
        }
    }

    func close() {
        generation = UUID(); restoreOnConnect = false
        wasOpen = false
        browser?.close(); browser = nil
        showing = false; isStarting = false; message = nil
    }
}

@MainActor
final class PreviewBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let tunnel: SSHPreviewTunnel
    @Published private(set) var loading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var canGoBack = false
    private var closed = false
    private var networkRulesReady = false
    private var observations: [NSKeyValueObservation] = []
    private let origin: URL

    init(tunnel: SSHPreviewTunnel, useHTTPS: Bool = false, path: String = "/") {
        self.tunnel = tunnel
        let destination = try? PreviewShortcut(name: "Preview", port: tunnel.remotePort, useHTTPS: useHTTPS, path: path)
        origin = destination?.url(host: PreviewAddress.host) ?? URL(string: "http://\(PreviewAddress.host):\(tunnel.remotePort)/")!
        let store = WKWebsiteDataStore.nonPersistent()
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: .init(rawValue: UInt16(tunnel.proxyPort))!))
        proxy.allowFailover = false
        proxy.applyCredential(username: tunnel.username, password: tunnel.password)
        store.proxyConfigurations = [proxy]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "preview.web"
        observations = [
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.loading = self?.webView.isLoading ?? false }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.canGoBack = self?.webView.canGoBack ?? false }
            },
        ]
        // Explicit loopback page resources bypass proxies on physical iPadOS. Block them;
        // relative URLs on our reserved origin travel through SOCKS and map to the Mac.
        // WebKit's content-rule regular expressions do not support alternation.
        let hosts = [#"localhost\.?"#, #"[^/]*\.localhost\.?"#, #"127\.[0-9.]+"#, #"\[::1\]"#]
        let rules: [[String: Any]] = ["https?", "wss?"].flatMap { scheme in
            hosts.map { host in
                ["trigger": ["url-filter": "^\(scheme)://([^/]*@)?\(host)(:[0-9]+)?/"], "action": ["type": "block"]]
            }
        }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
        Task { [weak self] in
            do {
                let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "mini-term-preview-loopback-v1", encodedContentRuleList: encoded)
                guard let rule else { throw PreviewError.unavailable }
                guard let self, !closed else { return }
                webView.configuration.userContentController.add(rule)
                networkRulesReady = true
                webView.load(URLRequest(url: origin))
            } catch {
                guard let self, !closed else { return }
                loading = false
                errorMessage = "Could not configure the preview's network rules. Close preview and try again. (Rule error \((error as NSError).code))"
            }
        }
    }

    var safariURL: URL {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.host = "localhost"; parts.port = tunnel.safariPort
        return parts.url!
    }
    var addressLabel: String { "Mac · \(origin.scheme!)://localhost:\(tunnel.remotePort)" }
    func reload() {
        guard !closed, networkRulesReady else { return }
        errorMessage = nil
        if webView.url == nil { webView.load(URLRequest(url: origin)) } else { webView.reload() }
    }
    func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        observations.removeAll()
        _ = tunnel.close()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard !closed, let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .cancel
        }
        if navigationAction.targetFrame?.isMainFrame != false {
            guard url.host?.lowercased() == PreviewAddress.host, url.port == tunnel.remotePort else {
                errorMessage = "This link leaves the preview. Use relative links or the preview hostname."
                return .cancel
            }
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { errorMessage = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { errorMessage = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { errorMessage = "Preview stopped. Reload to try again." }
    private func failed(_ error: Error) {
        let failure = error as NSError
        guard !closed, !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
        let category = failure.domain == NSURLErrorDomain ? "URL" : failure.domain == WKErrorDomain ? "WebKit" : "Network"
        let detail: String
        if failure.domain == NSURLErrorDomain {
            switch failure.code {
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                detail = "iPadOS blocked this HTTP preview. The installed app needs its localhost networking configuration."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                detail = "The HTTPS connection failed. Check Use HTTPS and the server certificate."
            case NSURLErrorTimedOut:
                detail = "The preview timed out. Check SSH and the development server, then reload."
            default:
                detail = "Could not load the page. Check that the server is running on port \(tunnel.remotePort) and SSH forwarding is allowed."
            }
        } else { detail = "The preview browser could not load this page. Reload to try again." }
        // Only stable categories/codes are exposed; raw errors can contain private URLs or headers.
        errorMessage = detail + " (\(category) error \(failure.code))"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.host == PreviewAddress.host, url.port == tunnel.remotePort {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

struct PreviewWebView: UIViewRepresentable {
    let browser: PreviewBrowser
    var inputActive = true
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        // Fill the home-indicator/window-handle region when the keyboard is hidden,
        // while still following the keyboard's top edge when it is displayed.
        host.keyboardLayoutGuide.usesBottomSafeArea = false
        let web = browser.webView
        web.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
        ])
        return host
    }
    func updateUIView(_ view: UIView, context: Context) {
        view.isUserInteractionEnabled = inputActive
        if !inputActive { view.endEditing(true) }
    }
}

struct PreviewPane: View {
    @ObservedObject var model: PreviewModel
    var inputActive = true
    var body: some View {
        Group {
            if let browser = model.browser {
                PreviewBrowserPane(browser: browser, inputActive: model.showing && inputActive).id(ObjectIdentifier(browser))
            }
            else if model.isStarting { ProgressView("Opening SSH preview…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ContentUnavailableView {
                    Label("Website preview", systemImage: "network")
                } description: {
                    Text(model.message ?? "Start your website's server in the terminal, then choose its port.")
                } actions: {
                    Button("Choose port") { model.beginEditing() }.disabled(!model.connected)
                }
            }
        }
    }
}

private struct PreviewBrowserPane: View {
    @ObservedObject var browser: PreviewBrowser
    var inputActive: Bool
    @State private var confirmSafari = false
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack)
                    .accessibilityLabel("Back")
                Text(verbatim: browser.addressLabel).font(.caption.monospaced()).lineLimit(1)
                Spacer(minLength: 0)
                if browser.loading { ProgressView().controlSize(.small) }
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload preview")
                Menu {
                    Button("Open in browser (experimental)") { confirmSafari = true }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Preview options")
            }.padding(.horizontal, 14).padding(.vertical, 10)
            if let message = browser.errorMessage {
                Text(message).font(.callout).foregroundStyle(.orange).padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            PreviewWebView(browser: browser, inputActive: inputActive)
        }
        .alert("Open in browser?", isPresented: $confirmSafari) {
            Button("Open browser") { openURL(browser.safariURL) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opens your default browser. The localhost address uses SSH; other destinations use the browser's normal connection. Keep MiniTerm visible alongside it when possible; iPadOS may pause the tunnel in the background. Fixed localhost ports and live reload may need the in-app preview. The browser keeps its own cookies and history.")
        }
    }
}
