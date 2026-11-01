import MiniTermCore
import SwiftUI
import UIKit

struct ConnectionView: View {
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var tmuxSession = ""
    @State private var publicKey = ""
    @State private var session: TerminalSessionModel?
    @State private var error: String?
    @State private var showForgetTrust = false
    private let keychain = KeychainStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac connection") {
                    TextField("Hostname, IP, or Tailscale name", text: $host)
                        .textContentType(.URL).keyboardType(.URL)
                        .accessibilityIdentifier("connection.host")
                    TextField("Mac username", text: $username)
                        .textContentType(.username).accessibilityIdentifier("connection.username")
                    TextField("Port", text: $port).keyboardType(.numberPad)
                        .accessibilityIdentifier("connection.port")
                    TextField("tmux session (optional)", text: $tmuxSession)
                        .accessibilityIdentifier("connection.tmux")
                    Button("Connect", action: connect)
                        .accessibilityIdentifier("connection.connect")
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty)
                }
                Section {
                    if publicKey.isEmpty {
                        Button("Create iPad SSH key", action: createIdentity)
                    } else {
                        Text(publicKey).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy public key") { UIPasteboard.general.string = publicKey }
                    }
                } header: {
                    Text("This iPad’s Ed25519 key")
                } footer: {
                    Text("Install this public key in ~/.ssh/authorized_keys on your Mac. The private key stays in this device’s Keychain.")
                }
                Section {
                    Text("Enable Remote Login on the Mac. For persistence, enter a tmux session name; reconnecting attaches to the same session. Leave it blank for an ordinary shell.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Forget this host’s saved key…", role: .destructive) { showForgetTrust = true }
                        .disabled(host.isEmpty)
                }
                if let error {
                    Section("Connection error") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Mini Term")
            .fullScreenCover(item: $session) { model in TerminalScreen(model: model) }
            .confirmationDialog("Forget saved host key?", isPresented: $showForgetTrust, titleVisibility: .visible) {
                Button("Forget host key", role: .destructive) { forgetTrust() }
            } message: {
                Text("Only do this after checking the Mac’s new fingerprint independently. The next connection will ask you to verify it again.")
            }
            .onAppear(perform: loadPublicKey)
        }
    }

    private func loadPublicKey() {
        do {
            if let seed = try keychain.read(account: "identity.ed25519") {
                publicKey = try SSHIdentity.publicKey(seed: seed)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func createIdentity() {
        do { _ = try identitySeed(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func identitySeed() throws -> Data {
        let seed: Data
        if let existing = try keychain.read(account: "identity.ed25519") { seed = existing }
        else {
            seed = SSHIdentity.generateSeed()
            try keychain.save(seed, account: "identity.ed25519")
        }
        publicKey = try SSHIdentity.publicKey(seed: seed)
        return seed
    }

    private func connect() {
        do {
            guard let port = Int(port) else { throw TerminalError.invalidConnection }
            let connection = try SSHConnection(host: host, username: username, port: port,
                                               tmuxSession: tmuxSession)
            let seed = try identitySeed()
            error = nil
            session = TerminalSessionModel(connection: connection, seed: seed)
        } catch { self.error = error.localizedDescription }
    }

    private func forgetTrust() {
        do {
            guard let port = Int(port) else { throw TerminalError.invalidConnection }
            let connection = try SSHConnection(host: host, username: username, port: port)
            try keychain.delete(account: "host:\(connection.hostKeyAccount)")
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
