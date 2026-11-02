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
    @Published private(set) var selectedPort: Int
    @Published private(set) var browser: PreviewBrowser?
    @Published private(set) var message: String?
    @Published private(set) var isStarting = false
    @Published private(set) var connected = false
    private weak var transport: SSHTransport?
    private let preferenceKey: String
    private var generation = UUID()
    private var restoreOnConnect = false
    private var selectedHTTPS: Bool

    init(connection: SSHConnection) {
        preferenceKey = "preview.port." + ConnectionProfile(connection).id
        let saved = UserDefaults.standard.integer(forKey: preferenceKey)
        let port = (1...65535).contains(saved) ? saved : 3000
        let secure = UserDefaults.standard.bool(forKey: preferenceKey + ".https")
        selectedPort = port; portText = String(port)
        useHTTPS = secure; selectedHTTPS = secure
    }

    func attach(_ transport: SSHTransport) { self.transport = transport }
    func connectionReady() {
        connected = true
        if restoreOnConnect { restoreOnConnect = false; open() }
    }
    func disconnected() {
        connected = false; transport = nil; generation = UUID(); isStarting = false
        if showing { message = "SSH disconnected. Reconnect to reload your preview." }
        browser?.close(); browser = nil
    }
    func restore(from old: PreviewModel) {
        selectedPort = old.selectedPort; portText = String(old.selectedPort)
        selectedHTTPS = old.selectedHTTPS; useHTTPS = old.selectedHTTPS
        showing = old.showing
        restoreOnConnect = old.showing
    }

    func beginEditing() {
        portText = String(selectedPort); useHTTPS = selectedHTTPS
        message = nil; editingPort = true
    }

    func open() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port) else {
            message = PreviewError.invalidPort.localizedDescription; return
        }
        guard connected, let transport else { message = PreviewError.disconnected.localizedDescription; return }
        generation = UUID()
        let request = generation
        browser?.close(); browser = nil
        showing = true; editingPort = false; isStarting = true; message = nil
        portText = String(port)
        selectedPort = port; selectedHTTPS = useHTTPS
        UserDefaults.standard.set(port, forKey: preferenceKey)
        UserDefaults.standard.set(useHTTPS, forKey: preferenceKey + ".https")
        let secure = useHTTPS
        Task { [weak self] in
            do {
                let tunnel = try await transport.startPreview(remotePort: port).get()
                guard let self, generation == request, connected else { _ = tunnel.close(); return }
                browser = PreviewBrowser(tunnel: tunnel, useHTTPS: secure)
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
    private var observations: [NSKeyValueObservation] = []
    private let origin: URL

    init(tunnel: SSHPreviewTunnel, useHTTPS: Bool = false) {
        self.tunnel = tunnel
        origin = URL(string: "\(useHTTPS ? "https" : "http")://localhost:\(tunnel.remotePort)/")!
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
        webView.load(URLRequest(url: origin))
    }

    var safariURL: URL { URL(string: "\(origin.scheme!)://localhost:\(tunnel.safariPort)/")! }
    var addressLabel: String { "\(origin.scheme!)://localhost:\(tunnel.remotePort)" }
    func reload() {
        guard !closed else { return }
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
            guard url.host?.lowercased() == "localhost", url.port == tunnel.remotePort else {
                errorMessage = "This link leaves the preview. Open the site's local development address instead."
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
        guard !closed, (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = "Could not load the page. Check that the server is running on port \(tunnel.remotePort) and SSH forwarding is allowed. HTTPS also needs a trusted certificate."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.host == "localhost", url.port == tunnel.remotePort {
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
    var body: some View {
        Group {
            if let browser = model.browser {
                PreviewBrowserPane(browser: browser, inputActive: model.showing).id(ObjectIdentifier(browser))
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
