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
    private var keyboardOverlap: NSLayoutConstraint!

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
        keyboardOverlap = terminal.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor)
        let fill = terminal.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            terminal.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
            keyboardOverlap, fill,
        ])
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
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); terminal.fitToSize() }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = view.window?.windowScene?.screen else { return }
        let frame = view.convert(end, from: screen.coordinateSpace)
        let docked = frame.minX <= view.bounds.minX && frame.maxX >= view.bounds.maxX
        keyboardOverlap.constant = docked ? min(0, frame.minY - view.safeAreaLayoutGuide.layoutFrame.maxY) : 0
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
