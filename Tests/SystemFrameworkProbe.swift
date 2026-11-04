// Control experiment for system logs. The running view uses only standard
// UIKit/WebKit, never the terminal, SSH, proxy, or PreviewBrowser code.
import WebKit
import OSLog

struct SystemFrameworkProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SystemFrameworkProbeController { SystemFrameworkProbeController() }
    func updateUIViewController(_ controller: SystemFrameworkProbeController, context: Context) {}
}

final class SystemFrameworkProbeController: UIViewController {
    private let log = Logger(subsystem: "com.samesense.mini-term.system-baseline", category: "Probe")
    private let field = UITextField()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        field.frame = CGRect(x: 30, y: 60, width: 300, height: 48)
        field.borderStyle = .roundedRect
        field.placeholder = "Native keyboard control experiment"
        view.addSubview(field)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await runChecks() }
    }
    private func runChecks() async {
        var failures: [String] = []
        var checks = 0
        log.notice("Native UIKit keyboard baseline begins")
        for _ in 0..<3 {
            field.becomeFirstResponder()
            try? await Task.sleep(for: .milliseconds(450))
            field.insertText("fixture")
            field.resignFirstResponder()
            try? await Task.sleep(for: .milliseconds(450))
        }
        log.notice("Native WebKit create/load/close baseline begins")
        for _ in 0..<3 {
            await nativeWebViewCycle(&checks, failures: &failures)
            try? await Task.sleep(for: .milliseconds(500))
        }
        log.notice("Native framework baseline finished")
        try! JSONSerialization.data(withJSONObject: ["checks": checks, "failures": failures], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("system-framework-probe.json"), options: .atomic)
    }
    private func nativeWebViewCycle(_ checks: inout Int, failures: inout [String]) async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 130, width: 600, height: 300), configuration: configuration)
        view.addSubview(web)
        web.loadHTMLString("<html><head><title>NATIVE_BASELINE</title></head><body><input placeholder='Native WebKit input'></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if web.title == "NATIVE_BASELINE" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        checks += 1
        if web.title != "NATIVE_BASELINE" { failures.append("Native HTML did not load") }
        web.stopLoading()
        web.removeFromSuperview()
    }
}
