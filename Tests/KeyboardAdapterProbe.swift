// Simulator-only test doubles. These do not prove physical event delivery.
import SwiftUI
import UIKit

private final class ProbeKey: UIKey {
    let usage: UIKeyboardHIDUsage
    let typed: String
    let plain: String
    var flags: UIKeyModifierFlags
    init(_ usage: UInt16, _ text: String = "", _ plain: String = "", _ flags: UIKeyModifierFlags = []) {
        self.usage = UIKeyboardHIDUsage(rawValue: Int(usage))!
        self.typed = text; self.plain = plain; self.flags = flags
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("not used by test double") }
    override var keyCode: UIKeyboardHIDUsage { usage }
    override var characters: String { typed }
    override var charactersIgnoringModifiers: String { plain }
    override var modifierFlags: UIKeyModifierFlags { flags }
}

private final class ProbePress: UIPress {
    let value: ProbeKey
    init(_ value: ProbeKey) { self.value = value; super.init() }
    override var key: UIKey? { value }
}

private final class ProbeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    func take() -> [UInt8] { lock.lock(); defer { lock.unlock() }; let result = Array(bytes); bytes.removeAll(); return result }
}

struct KeyboardAdapterProbeView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> KeyboardAdapterProbeController { KeyboardAdapterProbeController() }
    func updateUIViewController(_ controller: KeyboardAdapterProbeController, context: Context) {}
}

final class KeyboardAdapterProbeController: UIViewController {
    private let terminal = InteractiveTerminalView(frame: .zero)
    private let bytes = ProbeBytes()
    private var checks: [String] = []
    private var failures: [String] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        let session = InMemoryTerminalSession(write: { [bytes] in bytes.append($0) }, resize: { _ in })
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 13)
        terminal.controller = TerminalController()
        terminal.frame = view.bounds
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(terminal)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminal.becomeFirstResponder()
        Task { await runChecks() }
    }
    private func down(_ code: UInt16, _ text: String = "", _ plain: String = "", _ flags: UIKeyModifierFlags = []) -> ProbePress {
        let press = ProbePress(ProbeKey(code, text, plain, flags))
        terminal.pressesBegan([press], with: nil)
        return press
    }
    private func up(_ press: ProbePress, _ flags: UIKeyModifierFlags = []) {
        press.value.flags = flags
        terminal.pressesEnded([press], with: nil)
    }
    private func verify(_ label: String, _ condition: Bool) {
        checks.append(label)
        if !condition { failures.append(label) }
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    private func runChecks() async {
        await settle()
        _ = bytes.take()
        let caps = down(0x39, "", "", .alphaShift)
        await settle()
        verify("caps-down emits no bytes", bytes.take().isEmpty)
        up(caps, .alphaShift)
        await settle()
        verify("caps-tap escape", bytes.take() == [0x1B])

        let cap2 = down(0x39, "", "", .alphaShift)
        let c = down(0x06, "C", "c", .alphaShift)
        verify("Caps+C modifiers", terminal.hardwareKeyModifierFlags(.alphaShift) == .control)
        up(c, .alphaShift); up(cap2, .alphaShift)
        await settle()
        verify("Caps+C bytes", bytes.take() == [3])

        let cap3 = down(0x39, "", "", .alphaShift)
        let shift = down(0xE1, "", "", [.shift, .alphaShift])
        let shifted = down(0x06, "c", "c", [.shift, .alphaShift])
        verify("Caps+Shift+C modifiers", terminal.hardwareKeyModifierFlags([.shift, .alphaShift]) == [.control, .shift])
        up(shifted, [.shift, .alphaShift]); up(shift, .alphaShift); up(cap3, .alphaShift)
        await settle()
        let shiftedBytes = bytes.take()
        terminal.configureDualRole(enabled: false, source: .capsLock)
        let nativeCtrl = down(0xE0, "", "", .control)
        let nativeShift = down(0xE1, "", "", [.control, .shift])
        let nativeC = down(0x06, "\u{3}", "c", [.control, .shift])
        up(nativeC, [.control, .shift]); up(nativeShift, .control); up(nativeCtrl)
        await settle()
        let nativeShiftedBytes = bytes.take()
        verify("Caps+Shift+C matches native Ctrl+Shift+C", !shiftedBytes.isEmpty && shiftedBytes == nativeShiftedBytes)
        terminal.configureDualRole(enabled: true, source: .capsLock)

        let simultaneousCaps = ProbePress(ProbeKey(0x39))
        let simultaneousShift = ProbePress(ProbeKey(0xE1, "", "", .shift))
        let simultaneousC = ProbePress(ProbeKey(0x06, "C", "c", .shift))
        terminal.pressesBegan([simultaneousC, simultaneousShift, simultaneousCaps], with: nil)
        simultaneousShift.value.flags = []
        terminal.pressesEnded([simultaneousCaps, simultaneousShift, simultaneousC], with: nil)
        await settle()
        verify("simultaneous Caps+Shift+C matches native chord", bytes.take() == nativeShiftedBytes)

        let optionCaps = down(0x39, "", "", .alphaShift)
        let option = down(0xE2, "", "", [.alternate, .alphaShift])
        let optionC = down(0x06, "ç", "c", [.alternate, .alphaShift])
        verify("Option preserved with virtual Control", terminal.hardwareKeyModifierFlags([.alternate, .alphaShift]) == [.alternate, .control])
        up(optionC, [.alternate, .alphaShift]); up(option, .alphaShift); up(optionCaps)
        await settle()
        let optionBytes = bytes.take()
        terminal.configureDualRole(enabled: false, source: .capsLock)
        let optionCtrl = down(0xE0, "", "", .control)
        let nativeOption = down(0xE2, "", "", [.control, .alternate])
        let nativeOptionC = down(0x06, "ç", "c", [.control, .alternate])
        up(nativeOptionC, [.control, .alternate]); up(nativeOption, .control); up(optionCtrl)
        await settle()
        verify("Option chord matches native layout text encoding", optionBytes == bytes.take())
        terminal.configureDualRole(enabled: true, source: .capsLock)

        let cap4 = down(0x39)
        let c4 = down(0x06, "c", "c")
        let a4 = down(0x04, "a", "a")
        up(cap4)
        verify("early Caps release removes Control", !terminal.hardwareKeyModifierFlags([]).contains(.control))
        up(c4); up(a4)
        await settle()
        verify("multiple chord bytes, no escape", bytes.take() == [3, 1])

        let cap5 = down(0x39)
        let held = down(0x06, "c", "c")
        terminal.resignFirstResponder()
        terminal.becomeFirstResponder()
        up(held); up(cap5)
        let plain = down(0x04, "a", "a"); up(plain)
        await settle()
        verify("focus reset no stuck Control or escape", bytes.take() == [3, 97])

        let latch = down(0x06, "C", "c", .alphaShift); up(latch, .alphaShift)
        await settle()
        verify("ignore Caps capitalization for ordinary native text", bytes.take() == [99])

        terminal.configureDualRole(enabled: true, source: .remappedLeftControl)
        let remapped = down(0xE0, "", "", .control)
        _ = terminal.sendKey(.c, modifiers: .ctrl) // Existing paired UIKeyCommand path.
        up(remapped)
        await settle()
        verify("remapped command path suppresses extra escape", bytes.take() == [3])

        terminal.configureDualRole(enabled: true, source: .capsLock)
        let commandCaps = down(0x39)
        _ = terminal.sendKey(.c, modifiers: .super_)
        let transformedCommand = terminal.transformInputKey(TerminalKeyPress(.c, modifiers: .super_))
        verify("shortcut preserves Command plus virtual Control", transformedCommand.modifiers.contains([.ctrl, .super_]))
        up(commandCaps)
        await settle()
        let commandBytes = bytes.take()
        terminal.configureDualRole(enabled: false, source: .capsLock)
        _ = terminal.sendKey(.c, modifiers: [.ctrl, .super_])
        await settle()
        verify("shortcut matches native modifier encoding", commandBytes == bytes.take())
        terminal.configureDualRole(enabled: true, source: .capsLock)

        let long = down(0x39)
        try? await Task.sleep(for: .seconds(3))
        verify("long hold still silent", bytes.take().isEmpty)
        up(long)
        await settle()
        verify("long hold release escape", bytes.take() == [0x1B])

        let repeatCaps = down(0x39)
        let repeating = down(0x06, "c", "c")
        try? await Task.sleep(for: .seconds(1.5))
        up(repeating); up(repeatCaps)
        await settle()
        let repeats = bytes.take()
        verify("existing repeat timer emits repeated Ctrl+C", repeats.count > 1 && repeats.allSatisfy { $0 == 3 })

        let report: [String: Any] = ["checks": checks.count, "failures": failures, "labels": checks]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL.documentsDirectory.appendingPathComponent("keyboard-probe.json"), options: .atomic)
    }
}
