// Isolated UIKit + real Ghostty regression fixture. No SSH or personal data.
@testable import MiniTermGhosttyTerminal
import QuartzCore

private final class LifecycleTerminal: TerminalView {
    var reloads = 0
    override func reloadInputViews() { reloads += 1; super.reloadInputViews() }
}

private final class LifecycleInputDelegate: NSObject, UITextInputDelegate {
    var changes: [String] = []
    func selectionWillChange(_ textInput: (any UITextInput)?) { changes.append("will") }
    func selectionDidChange(_ textInput: (any UITextInput)?) { changes.append("did") }
    func textWillChange(_ textInput: (any UITextInput)?) {}
    func textDidChange(_ textInput: (any UITextInput)?) {}
    @available(iOS 18.4, *)
    func conversationContext(_ context: UIConversationContext?, didChange textInput: (any UITextInput)?) {}
}

// Simulates a UIKit-owned layer whose delegate isn't a UIView. Delegate type
// is not a reliable way to decide whether a layer belongs to the renderer.
private final class LifecycleLayerDelegate: NSObject, CALayerDelegate {}

struct InputLifecycleProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InputLifecycleProbeController { InputLifecycleProbeController() }
    func updateUIViewController(_ controller: InputLifecycleProbeController, context: Context) {}
}

final class InputLifecycleProbeController: UIViewController {
    private let terminal = LifecycleTerminal(frame: .zero)
    private var labels: [String] = []
    private var failures: [String] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(InMemoryTerminalSession(write: { _ in }, resize: { _ in })), fontSize: 13)
        terminal.controller = TerminalController()
        terminal.frame = view.bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(terminal)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await runChecks() }
    }
    private func check(_ value: Bool, _ label: String) { labels.append(label); if !value { failures.append(label) } }
    private func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
    private func runChecks() async {
        terminal.becomeFirstResponder()
        await settle()
        check(terminal.surface != nil, "real Ghostty surface mounted")
        check(terminal.isFirstResponder, "terminal acquired keyboard")
        let accessory = terminal.inputAccessoryView
        let delegate = LifecycleInputDelegate()
        let systemDelegate = terminal.inputDelegate
        terminal.inputDelegate = delegate
        let reloads = terminal.reloads
        terminal.inputHandler.notifyGeometryDidChange(reason: "probe")
        check(delegate.changes == ["will", "did"], "caret geometry still notifies UITextInput")
        check(terminal.reloads == reloads, "caret geometry does not reload keyboard")
        terminal.setMarkedText("かな", selectedRange: NSRange(location: 1, length: 0))
        let marked = terminal.markedTextRange.flatMap { terminal.text(in: $0) }
        let selection = terminal.selectedTextRange
        terminal.inputHandler.notifyGeometryDidChange(reason: "marked-probe")
        check(terminal.markedTextRange.flatMap { terminal.text(in: $0) } == marked, "geometry preserves IME preedit")
        check(terminal.selectedTextRange.flatMap { terminal.offset(from: terminal.beginningOfDocument, to: $0.start) } == selection.map { terminal.offset(from: terminal.beginningOfDocument, to: $0.start) }, "geometry preserves IME selection")
        check(terminal.reloads == reloads, "IME geometry does not rebuild keyboard")
        terminal.inputDelegate = systemDelegate
        terminal.unmarkText()
        let oldSize = terminal.fontSize
        check(terminal.surface?.performBindingAction("increase_font_size:1") == true, "real font zoom accepted")
        await settle()
        check(terminal.fontSize != oldSize, "real font size changed")
        check(terminal.reloads == reloads, "font zoom preserves keyboard without reload")
        check(terminal.inputAccessoryView === accessory, "font zoom preserves accessory identity")
        check(terminal.isFirstResponder, "font zoom preserves keyboard focus")

        let foreign = CALayer()
        let owner = LifecycleLayerDelegate()
        foreign.delegate = owner
        foreign.frame = CGRect(x: 9, y: 13, width: 27, height: 31)
        foreign.contentsScale = 1
        terminal.layer.addSublayer(foreign)
        let frame = foreign.frame
        let unmanaged = CALayer()
        unmanaged.frame = frame
        unmanaged.contentsScale = 1
        terminal.layer.addSublayer(unmanaged)
        let renderer = terminal.layer.sublayers?.first { NSStringFromClass(type(of: $0)) == "IOSurfaceLayer" }
        check(renderer != nil, "pinned Ghostty IOSurfaceLayer is identified")
        terminal.updateSublayerFrames()
        check(foreign.frame == frame && foreign.contentsScale == 1, "layout leaves system delegate layers untouched")
        check(unmanaged.frame == frame && unmanaged.contentsScale == 1, "layout leaves other layers untouched")
        check(renderer?.frame == terminal.sublayerFrame, "layout sizes renderer layer")
        terminal.bounds.size.height -= 37
        terminal.enforceSublayerScale()
        check(foreign.frame == frame && foreign.contentsScale == 1, "post-render sync leaves system layers untouched")
        check(unmanaged.frame == frame && unmanaged.contentsScale == 1, "post-render sync leaves other layers untouched")
        check(renderer?.frame == terminal.sublayerFrame, "post-render sync sizes renderer layer")
        foreign.removeFromSuperlayer(); unmanaged.removeFromSuperlayer()
        terminal.resignFirstResponder()
        await settle()
        terminal.becomeFirstResponder()
        await settle()
        check(terminal.isFirstResponder, "keyboard reacquires after geometry updates")
        let layers = (terminal.layer.sublayers ?? []).map { "\(type(of: $0)) delegate=\($0.delegate.map { String(describing: type(of: $0)) } ?? "nil")" }
        let report: [String: Any] = ["checks": labels.count, "failures": failures, "labels": labels, "layers": layers]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("input-lifecycle-probe.json"), options: .atomic)
    }
}
