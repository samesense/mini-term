import MiniTermGhosttyTerminal
import GameController
import Combine
import MiniTermCore
import SwiftUI
import UIKit

struct TerminalScreen: View {
    @ObservedObject var model: TerminalSessionModel
    var onReconnect: (() -> Void)? = nil
    var body: some View { TerminalWorkspace(model: model, preview: model.preview, onReconnect: onReconnect) }
}

private struct TerminalWorkspace: View {
    @ObservedObject var model: TerminalSessionModel
    @ObservedObject var preview: PreviewModel
    var onReconnect: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var keyboardToggleRequest = 0
    @State private var copiedDiagnostics = false
    @AppStorage("keyboard.dualRoleCaps.enabled") private var dualRoleCaps = true
    @AppStorage("keyboard.dualRoleCaps.source") private var dualRoleSource = DualRoleKeySource.capsLock.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(model.state == .connected ? .green : .orange).frame(width: 7, height: 7)
                Text("\(model.connection.username)@\(model.connection.host)")
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if !model.state.isFinished {
                    Text(model.state.label).font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    keyboardToggleRequest += 1
                } label: {
                    Image(systemName: "keyboard")
                }
                .accessibilityLabel("Show or hide keyboard")
                .accessibilityIdentifier("terminal.keyboard")
                .disabled(model.state.isFinished || preview.showing)
                if preview.browser == nil && !preview.showing {
                    Button { preview.beginEditing() } label: { Image(systemName: "globe") }
                        .accessibilityLabel("Open website preview")
                        .accessibilityIdentifier("terminal.preview")
                        .disabled(model.state != .connected)
                }
                Menu {
                    Button {
                        UIPasteboard.general.string = AppDiagnostics.text(model.diagnostics)
                        copiedDiagnostics = true
                    } label: {
                        Label(copiedDiagnostics ? "Copied diagnostics" : "Copy diagnostics", systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                    }
                } label: { Image(systemName: "ellipsis").frame(minWidth: 36, minHeight: 36) }
                .accessibilityLabel("Connection options")
                Button(model.state.isFinished ? "Done" : "Disconnect") {
                    model.disconnect(); dismiss()
                }.font(.callout).accessibilityIdentifier("terminal.disconnect")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if preview.showing || preview.browser != nil {
                HStack {
                    Picker("Workspace", selection: $preview.showing) {
                        Text("Terminal").tag(false)
                        Text("Preview").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 280)
                    Spacer(minLength: 8)
                    Button("Port \(String(preview.selectedPort))") { preview.beginEditing() }.disabled(!preview.connected)
                    Button { preview.close() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close preview")
                }.font(.callout).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if model.state.isFinished {
                VStack(spacing: 8) {
                    Text(model.state.label).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    if let onReconnect {
                        Button("Reconnect", action: onReconnect).buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("terminal.reconnect")
                        Text(model.connection.tmuxSession == nil ? "Opens a new shell." : "Returns to the same tmux session if it is still running.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(10)
            }
            ZStack {
                NativeTerminal(model: model, keyboardToggleRequest: keyboardToggleRequest, dualRoleCaps: dualRoleCaps,
                               source: DualRoleKeySource(rawValue: dualRoleSource) ?? .capsLock, inputActive: !preview.showing)
                    .opacity(preview.showing ? 0 : 1)
                    .allowsHitTesting(!preview.showing)
                    .accessibilityHidden(preview.showing)
                if preview.showing || preview.browser != nil {
                    PreviewPane(model: preview).background(Color(white: 0.13))
                        .opacity(preview.showing ? 1 : 0)
                        .allowsHitTesting(preview.showing)
                        .accessibilityHidden(!preview.showing)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the whole host steady while UIKit sizes the terminal above the keyboard/accessory.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
        .preferredColorScheme(.dark)
        .tint(LCARS.lavender)
        .sheet(isPresented: $preview.editingPort) {
            NavigationStack {
                Form {
                    Section("Mac development server") {
                        TextField("Port", text: $preview.portText).keyboardType(.numberPad)
                            .accessibilityIdentifier("preview.port")
                        Toggle("Use HTTPS", isOn: $preview.useHTTPS)
                        Text("Start the server in the terminal. Its localhost port will be reached through SSH.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let message = preview.message { Text(message).foregroundStyle(.orange) }
                    Button("Open preview") { preview.open() }.disabled(!preview.connected)
                        .accessibilityIdentifier("preview.open")
                }
                .navigationTitle("Website preview").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { preview.editingPort = false } } }
            }.preferredColorScheme(.dark).tint(LCARS.lavender).presentationDetents([.medium])
        }
        .alert(item: $model.trustRequest) { request in
            Alert(title: Text("Trust this Mac?"),
                  message: Text("\(model.connection.hostKeyAccount)\n\n\(request.fingerprint)\n\nCompare this fingerprint with the Mac before trusting it."),
                  primaryButton: .default(Text("Trust and connect")) { model.answerTrust(request, allow: true) },
                  secondaryButton: .cancel(Text("Cancel")) { model.answerTrust(request, allow: false) })
        }
        .onDisappear { model.disconnect() }
    }
}

private struct NativeTerminal: UIViewControllerRepresentable {
    let model: TerminalSessionModel
    let keyboardToggleRequest: Int
    let dualRoleCaps: Bool
    let source: DualRoleKeySource
    var inputActive = true
    func makeUIViewController(context: Context) -> TerminalViewController { TerminalViewController(model: model) }
    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {
        uiViewController.configureKeyboard(enabled: dualRoleCaps, source: source)
        uiViewController.updateKeyboardRequest(keyboardToggleRequest)
        uiViewController.updateInputActive(inputActive)
    }
}

/// Ghostty supplies UITextInput, hardware keys, touch selection, clipboard, scrolling and its shortcut bar.
/// The extra bottom constraint handles iPad versions where the keyboard guide omits the accessory bar.
final class TerminalViewController: UIViewController {
    private let model: TerminalSessionModel
    private let terminal = InteractiveTerminalView(frame: .zero)
    private var lastKeyboardToggleRequest = 0
    private var inputActive = true
    private let controller = TerminalController { builder in
        builder.withFontSize(13)
        builder.withCustom("clipboard-read", "deny")
        builder.withCustom("clipboard-write", "deny")
    }
    private var keyboardLayout: TerminalKeyboardLayout!
    private var keyboardFrameOnScreen: CGRect?

    init(model: TerminalSessionModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.13, alpha: 1)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(model.terminalSession), fontSize: 13)
        terminal.controller = controller
        terminal.accessibilityIdentifier = "terminal.surface"
        terminal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminal)
        keyboardLayout = TerminalKeyboardLayout(terminal: terminal, host: view)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    func configureKeyboard(enabled: Bool, source: DualRoleKeySource) {
        terminal.configureDualRole(enabled: enabled, source: source)
    }

    func updateKeyboardRequest(_ request: Int) {
        guard request != lastKeyboardToggleRequest else { return }
        lastKeyboardToggleRequest = request
        terminal.toggleKeyboardFromToolbar()
    }

    func updateInputActive(_ active: Bool) {
        guard inputActive != active else { return }
        inputActive = active
        terminal.isUserInteractionEnabled = active
        if active { terminal.becomeFirstResponder() }
        else { _ = terminal.resignFirstResponder(); view.endEditing(true) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if inputActive { terminal.becomeFirstResponder() }
        model.start() // The Metal surface is mounted before remote output can arrive.
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateKeyboardLayout()
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); terminal.fitToSize() }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardFrameOnScreen = end
        updateKeyboardLayout()
        view.setNeedsLayout()
    }

    private func updateKeyboardLayout() {
        let frame = keyboardFrameOnScreen.flatMap { frame in
            view.window.map { view.convert(frame, from: $0.screen.coordinateSpace) }
        }
        keyboardLayout.update(keyboardFrame: frame)
    }
}

/// Keep required constraints valid even while SwiftUI and keyboard geometry update
/// in separate passes. The accessory fallback must never demand a negative height.
@MainActor
final class TerminalKeyboardLayout {
    private let host: UIView
    private let overlap: NSLayoutConstraint

    init(terminal: UIView, host: UIView) {
        self.host = host
        let safe = host.safeAreaLayoutGuide
        // When dismissed, the guide otherwise leaves a home-indicator-sized
        // blank strip below the terminal. Keep top/side protection, but fill down.
        host.keyboardLayoutGuide.usesBottomSafeArea = false
        overlap = terminal.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor)
        overlap.priority = UILayoutPriority(999)
        overlap.identifier = "terminal.keyboardAccessoryLimit"
        let fill = terminal.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: safe.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            terminal.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor),
            terminal.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            overlap, fill,
        ])
    }

    func update(keyboardFrame: CGRect?) {
        let safe = host.safeAreaLayoutGuide.layoutFrame
        let bottom = host.bounds.maxY
        let height = max(0, bottom - safe.minY)
        let docked = keyboardFrame.map {
            $0.minX <= host.bounds.minX + 1 && $0.maxX >= host.bounds.maxX - 1 && $0.maxY >= bottom
        } ?? false
        let offset = docked ? max(-height, min(0, keyboardFrame!.minY - bottom)) : 0
        if overlap.constant != offset { overlap.constant = offset }
    }
}

/// A tap still travels through Ghostty's normal mouse pipeline. While a remote TUI
/// owns the mouse, keep its grid steady instead of toggling the keyboard after each click.
private final class InteractiveTerminalView: TerminalView {
    private var keyboard = DualRoleKeyboard()
    private var nativeKeys: [UInt16: UIKey] = [:]
    private var dispatchedModifiers: KeyboardModifiers?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
                     UIWindow.didResignKeyNotification, Notification.Name.GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelDualRole), name: name, object: nil)
        }
        _ = KeyboardEventDiagnostics.shared
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configureDualRole(enabled: Bool, source: DualRoleKeySource) {
        if keyboard.enabled != enabled || keyboard.source != source { cancelHardwareKeyRepeat() }
        dispatch(keyboard.configure(enabled: enabled, source: source))
    }

    @objc private func cancelDualRole() {
        cancelHardwareKeyRepeat()
        dispatch(keyboard.cancel())
    }

    override func resignFirstResponder() -> Bool {
        cancelDualRole()
        return super.resignFirstResponder()
    }

    override func didMoveToWindow() {
        if window == nil { cancelDualRole() }
        super.didMoveToWindow()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        route(presses, phase: .down, event: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        route(presses, phase: .up, event: event)
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        cancelDualRole()
        super.pressesCancelled(presses.filter { !isDualKey($0) }, with: event)
    }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remainder = presses.filter { !isDualKey($0) }
        if !remainder.isEmpty { super.pressesChanged(remainder, with: event) }
    }

    private func isDualKey(_ press: UIPress) -> Bool {
        keyboard.enabled && press.key?.keyCode.rawValue == Int(keyboard.source.usage)
    }

    private func route(_ presses: Set<UIPress>, phase: HardwareKeyEvent.Phase, event: UIPressesEvent?) {
        let ordered = presses.sorted {
            let a = isDualKey($0), b = isDualKey($1)
            if a != b { return phase == .down ? a : !a }
            let leftModifier = (0xE0...0xE7).contains($0.key?.keyCode.rawValue ?? 0)
            let rightModifier = (0xE0...0xE7).contains($1.key?.keyCode.rawValue ?? 0)
            if $0.timestamp == $1.timestamp && leftModifier != rightModifier {
                return phase == .down ? leftModifier : !leftModifier
            }
            return $0.timestamp == $1.timestamp
                ? ($0.key?.keyCode.rawValue ?? 0) < ($1.key?.keyCode.rawValue ?? 0)
                : $0.timestamp < $1.timestamp
        }
        for press in ordered {
            guard let key = press.key else {
                if phase == .down { super.pressesBegan([press], with: event) }
                else { super.pressesEnded([press], with: event) }
                continue
            }
            let usage = UInt16(clamping: key.keyCode.rawValue)
            KeyboardEventDiagnostics.shared.recordUIKit(usage: usage, down: phase == .down)
            let output = keyboard.process(.init(usage, phase, .init(key.modifierFlags)))
            for action in output {
                switch action {
                case .synthesize:
                    dispatch([action])
                case .forward:
                    if phase == .down {
                        nativeKeys[usage] = key
                        super.pressesBegan([press], with: event)
                    } else {
                        super.pressesEnded([press], with: event)
                        nativeKeys.removeValue(forKey: usage)
                    }
                }
            }
        }
    }

    private func dispatch(_ actions: [KeyboardDispatch]) {
        for action in actions {
            switch action {
            case .forward(let event):
                if let key = nativeKeys.removeValue(forKey: event.usage) {
                    dispatchedModifiers = event.modifiers
                    releaseHardwareKey(key)
                    dispatchedModifiers = nil
                }
            case .synthesize(let event):
                if event.usage == 0xE0 && event.phase == .up { nativeKeys.removeValue(forKey: event.usage) }
                let key: TerminalKey = event.usage == 0x29 ? .escape : .controlLeft
                var mods: TerminalInputModifiers = []
                if event.modifiers.contains(.control) { mods.insert(.ctrl) }
                if event.modifiers.contains(.shift) { mods.insert(.shift) }
                if event.modifiers.contains(.option) { mods.insert(.alt) }
                if event.modifiers.contains(.command) { mods.insert(.super_) }
                let phase: TerminalKeyAction = event.phase == .up ? .release : event.phase == .down ? .press : .repeat
                _ = sendKey(TerminalKeyPress(key, modifiers: mods), action: phase)
            }
        }
    }

    override func hardwareKeyModifierFlags(_ flags: UIKeyModifierFlags) -> UIKeyModifierFlags {
        guard keyboard.enabled || dispatchedModifiers != nil else { return flags }
        var result = flags.subtracting([.alphaShift, .control, .shift, .alternate, .command])
        let mods = dispatchedModifiers ?? keyboard.modifiers
        if mods.contains(.control) { result.insert(.control) }
        if mods.contains(.shift) { result.insert(.shift) }
        if mods.contains(.option) { result.insert(.alternate) }
        if mods.contains(.command) { result.insert(.command) }
        return result
    }

    override func hardwareKeyCharacters(_ key: UIKey) -> String {
        // UIKit normally collapses native Ctrl+ASCII-letter text to a control
        // byte, which the wrapper replaces with the unmodified letter. Adding
        // Ctrl after dispatch must supply that same canonical text, including
        // under Shift; otherwise Ghostty encodes a different Ctrl+Shift chord.
        if keyboard.enabled, keyboard.modifiers.contains(.control),
           !key.modifierFlags.contains(.control),
           key.modifierFlags.isDisjoint(with: [.alternate, .command]),
           key.charactersIgnoringModifiers.utf8.count == 1,
           let byte = key.charactersIgnoringModifiers.utf8.first, (97...122).contains(byte) {
            return key.charactersIgnoringModifiers
        }
        // UIKit can latch capitalization before dispatch. Mask that effect for
        // ordinary layout-provided text; never invent Option/dead-key mappings.
        guard keyboard.enabled, key.modifierFlags.contains(.alphaShift),
              key.modifierFlags.isDisjoint(with: [.alternate, .command]) else { return key.characters }
        let unmodified = key.charactersIgnoringModifiers
        return keyboard.modifiers.contains(.shift) ? unmodified.uppercased() : unmodified
    }

    override func willSendInputKey(_ press: TerminalKeyPress) {
        var mods: KeyboardModifiers = []
        if press.modifiers.contains(.ctrl) { mods.insert(.control) }
        if press.modifiers.contains(.shift) { mods.insert(.shift) }
        if press.modifiers.contains(.alt) { mods.insert(.option) }
        if press.modifiers.contains(.super_) { mods.insert(.command) }
        dispatch(keyboard.keyCommand(modifiers: mods))
    }

    override func transformInputKey(_ press: TerminalKeyPress) -> TerminalKeyPress {
        guard keyboard.enabled else { return press }
        var result = press
        result.modifiers.remove(.caps)
        if keyboard.modifiers.contains(.control) { result.modifiers.insert(.ctrl) }
        return result
    }

    override func toggleSoftwareKeyboard() {
        guard !isMouseCaptured else { return }
        super.toggleSoftwareKeyboard()
    }
    func toggleKeyboardFromToolbar() { super.toggleSoftwareKeyboard() }
}

private extension KeyboardModifiers {
    init(_ flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.alternate) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.alphaShift) { insert(.capsLock) }
    }
}

/// Counts only Caps/Control edges, never text. GCKeyboard is diagnostic-only:
/// mixing its asynchronous events with UIKit would duplicate/reorder input.
@MainActor
final class KeyboardEventDiagnostics: NSObject, ObservableObject {
    static let shared = KeyboardEventDiagnostics()
    @Published private(set) var capsDown = 0
    @Published private(set) var capsUp = 0
    @Published private(set) var controlDown = 0
    @Published private(set) var controlUp = 0
    @Published private(set) var gcDown = 0
    @Published private(set) var gcUp = 0
    @Published private(set) var hasGCKeyboard = false
    private weak var observedButton: GCControllerButtonInput?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshKeyboard), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshKeyboard), name: .GCKeyboardDidDisconnect, object: nil)
        refreshKeyboard()
    }

    func recordUIKit(usage: UInt16, down: Bool) {
        if usage == 0x39 { if down { capsDown += 1 } else { capsUp += 1 } }
        if usage == 0xE0 { if down { controlDown += 1 } else { controlUp += 1 } }
    }

    @objc private func refreshKeyboard() {
        hasGCKeyboard = GCKeyboard.coalesced != nil
        guard let button = GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: .capsLock),
              button !== observedButton else { return }
        observedButton = button
        let previous = button.pressedChangedHandler
        button.pressedChangedHandler = { [weak self] button, value, pressed in
            previous?(button, value, pressed)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if pressed { self.gcDown += 1 } else { self.gcUp += 1 }
            }
        }
    }
}
