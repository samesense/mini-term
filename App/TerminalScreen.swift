import GhosttyTerminal
import MiniTermCore
import SwiftUI
import UIKit

struct TerminalScreen: View {
    @ObservedObject var model: TerminalSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyboardToggleRequest = 0

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
                .disabled(model.state.isFinished)
                Button(model.state.isFinished ? "Done" : "Disconnect") {
                    model.disconnect(); dismiss()
                }.font(.callout).accessibilityIdentifier("terminal.disconnect")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if model.state.isFinished {
                Text(model.state.label).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(10)
            }
            NativeTerminal(model: model, keyboardToggleRequest: keyboardToggleRequest)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the whole host steady while UIKit sizes the terminal above the keyboard/accessory.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color(red: 0.13, green: 0.13, blue: 0.13))
        .preferredColorScheme(.dark)
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
    func makeUIViewController(context: Context) -> TerminalViewController { TerminalViewController(model: model) }
    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {
        uiViewController.updateKeyboardRequest(keyboardToggleRequest)
    }
}

/// Ghostty supplies UITextInput, hardware keys, touch selection, clipboard, scrolling and its shortcut bar.
/// The extra bottom constraint handles iPad versions where the keyboard guide omits the accessory bar.
final class TerminalViewController: UIViewController {
    private let model: TerminalSessionModel
    private let terminal = InteractiveTerminalView(frame: .zero)
    private var lastKeyboardToggleRequest = 0
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

    func updateKeyboardRequest(_ request: Int) {
        guard request != lastKeyboardToggleRequest else { return }
        lastKeyboardToggleRequest = request
        terminal.toggleKeyboardFromToolbar()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        terminal.becomeFirstResponder()
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
        overlap = terminal.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor)
        overlap.priority = UILayoutPriority(999)
        overlap.identifier = "terminal.keyboardAccessoryLimit"
        let fill = terminal.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: safe.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            terminal.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor),
            terminal.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            overlap, fill,
        ])
    }

    func update(keyboardFrame: CGRect?) {
        let safe = host.safeAreaLayoutGuide.layoutFrame
        let docked = keyboardFrame.map {
            $0.minX <= host.bounds.minX + 1 && $0.maxX >= host.bounds.maxX - 1 && $0.maxY >= safe.maxY
        } ?? false
        let offset = docked ? max(-safe.height, min(0, keyboardFrame!.minY - safe.maxY)) : 0
        if overlap.constant != offset { overlap.constant = offset }
    }
}

/// A tap still travels through Ghostty's normal mouse pipeline. While a remote TUI
/// owns the mouse, keep its grid steady instead of toggling the keyboard after each click.
private final class InteractiveTerminalView: TerminalView {
    override func toggleSoftwareKeyboard() {
        guard !isMouseCaptured else { return }
        super.toggleSoftwareKeyboard()
    }

    func toggleKeyboardFromToolbar() {
        super.toggleSoftwareKeyboard()
    }
}
