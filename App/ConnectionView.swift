import Combine
import Foundation
import MiniTermCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConnectionView: View {
    @StateObject private var history = ConnectionHistoryModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRestoreConnection = false
    @State private var showSyncFolder = false
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
                    Button("Save connection", action: saveConnection)
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty)
                    Button("Connect", action: connect)
                        .accessibilityIdentifier("connection.connect")
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty)
                }
                connectionHistorySection
                syncSection
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
            .onAppear {
                loadPublicKey()
                if !didRestoreConnection {
                    didRestoreConnection = true
                    if let profile = history.lastSelectedProfile { fill(profile) }
                }
                history.refresh()
            }
            .onChange(of: history.document) { _, _ in
                if host.isEmpty, username.isEmpty, port == "22", tmuxSession.isEmpty,
                   let profile = history.lastSelectedProfile { fill(profile) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { history.refresh() }
            }
            .fileImporter(isPresented: $showSyncFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder): history.chooseFolder(folder)
                case .failure(let error): history.showSyncError(error)
                }
            }
        }
    }

    private var connectionHistorySection: some View {
        Section("Saved & recent connections") {
            if history.document.visibleEntries.isEmpty {
                Text("Save a connection or connect successfully to remember it.")
                    .foregroundStyle(.secondary).font(.footnote)
            }
            ForEach(Array(history.document.visibleEntries.prefix(30))) { entry in
                if let profile = entry.profile {
                    Button { fill(profile); history.select(profile) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(profile.username)@\(profile.host):\(profile.port)")
                                .font(.callout.monospaced()).foregroundStyle(.primary)
                            HStack {
                                Text(profile.tmuxSession.isEmpty ? "Shell" : "tmux: \(profile.tmuxSession)")
                                Spacer()
                                if let date = entry.lastConnectedAt { Text(date, style: .relative) }
                                else { Text("Saved") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityLabel("Fill connection for \(profile.username) at \(profile.host)")
                }
            }
            .onDelete { indices in
                let visible = Array(history.document.visibleEntries.prefix(30))
                for index in indices { history.remove(id: visible[index].id) }
            }
        }
    }

    private var syncSection: some View {
        Section {
            Button(history.hasSyncFolder ? "Change history folder…" : "Choose iCloud Drive folder…") {
                showSyncFolder = true
            }
            if history.hasSyncFolder {
                HStack {
                    Text(history.isSyncing ? "Updating history…" : history.syncStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    if history.isSyncing { ProgressView() }
                    else { Button("Refresh") { history.refresh() }.font(.footnote) }
                }
                Button("Stop folder sync", role: .destructive) { history.stopSyncing() }
            }
            if let message = history.syncError {
                Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
        } header: { Text("Connection history storage") }
          footer: {
              Text("Choose the same folder in iCloud Drive on each device to share connections. Other folders save to that location. SSH keys, host trust and terminal contents stay on this device.")
          }
    }

    private func fill(_ profile: ConnectionProfile) {
        host = profile.host; username = profile.username
        port = String(profile.port); tmuxSession = profile.tmuxSession
        error = nil
    }

    private func formConnection() throws -> SSHConnection {
        guard let port = Int(port), host.utf8.count <= 1024, username.utf8.count <= 1024 else {
            throw TerminalError.invalidConnection
        }
        return try SSHConnection(host: host, username: username, port: port, tmuxSession: tmuxSession)
    }

    private func saveConnection() {
        do { history.remember(ConnectionProfile(try formConnection()), connected: false); error = nil }
        catch { self.error = error.localizedDescription }
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
            let connection = try formConnection()
            let seed = try identitySeed()
            error = nil
            let model = TerminalSessionModel(connection: connection, seed: seed)
            model.onConnected = { [history] in history.remember(ConnectionProfile(connection), connected: true) }
            session = model
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

/// Local metadata remains usable offline. Only an explicit folder selection opts into file-provider sync.
@MainActor
final class ConnectionHistoryModel: ObservableObject {
    @Published private(set) var document = ConnectionHistoryDocument()
    @Published private(set) var isSyncing = false
    @Published private(set) var syncStatus = "Saved on this iPad"
    @Published private(set) var syncError: String?
    @Published private(set) var hasSyncFolder = false
    private let defaults = UserDefaults.standard
    private let cloud = ConnectionHistoryCloudStore()
    private let deviceID: UUID
    private var bookmark: Data?
    private var generation = UUID()
    private var syncTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var presenter: ConnectionHistoryFolderPresenter?
    private var needsAnotherSync = false
    private static let dataKey = "connections.history.v1"
    private static let bookmarkKey = "connections.folderBookmark.v1"
    private static let selectionKey = "connections.selection.v1"

    init() {
        let fallback = UUID(uuidString: defaults.string(forKey: "connections.deviceID") ?? "") ?? UUID()
        deviceID = UIDevice.current.identifierForVendor ?? fallback
        defaults.set(deviceID.uuidString, forKey: "connections.deviceID")
        if let bytes = defaults.data(forKey: Self.dataKey) {
            do { document = try ConnectionHistoryDocument.decode(bytes) }
            catch { syncError = error.localizedDescription }
        }
        bookmark = defaults.data(forKey: Self.bookmarkKey)
        hasSyncFolder = bookmark != nil
        if hasSyncFolder { syncStatus = "History folder selected" }
    }

    var lastSelectedProfile: ConnectionProfile? {
        let selected = defaults.string(forKey: Self.selectionKey)
        return document.visibleEntries.first(where: { $0.id == selected })?.profile ?? document.visibleEntries.first?.profile
    }

    func select(_ profile: ConnectionProfile) { defaults.set(profile.id, forKey: Self.selectionKey) }

    func remember(_ profile: ConnectionProfile, connected: Bool) {
        document.remember(profile, connected: connected)
        select(profile)
        persist()
        refresh()
    }

    func remove(id: String) {
        document.remove(id: id)
        persist()
        refresh()
    }

    func showSyncError(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
        syncError = error.localizedDescription
    }

    func chooseFolder(_ folder: URL) {
        // Hold the picker grant until the background actor has made a persistent bookmark.
        let access = folder.startAccessingSecurityScopedResource()
        Task {
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await cloud.bookmark(for: folder)
                stopSyncing()
                bookmark = data
                defaults.set(data, forKey: Self.bookmarkKey)
                hasSyncFolder = true
                syncStatus = "Folder: \(folder.lastPathComponent)"
                refresh()
            } catch { showSyncError(error) }
        }
    }

    func stopSyncing() {
        generation = UUID()
        syncTask?.cancel(); syncTask = nil
        changeTask?.cancel(); changeTask = nil
        presenter?.invalidate(); presenter = nil
        bookmark = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        hasSyncFolder = false
        isSyncing = false
        needsAnotherSync = false
        syncStatus = "Saved on this iPad"
        syncError = nil
    }

    func refresh() {
        guard let bookmark else { return }
        if isSyncing { needsAnotherSync = true; return }
        isSyncing = true
        syncError = nil
        let current = generation
        let snapshot = document
        syncTask = Task { [weak self, cloud, deviceID] in
            do {
                let result = try await cloud.synchronize(bookmark: bookmark, deviceID: deviceID, local: snapshot)
                guard let self, generation == current, !Task.isCancelled else { return }
                // Keep edits made while file-provider I/O was in flight.
                try document.merge(result.document)
                self.bookmark = result.bookmark
                defaults.set(result.bookmark, forKey: Self.bookmarkKey)
                persist()
                syncStatus = "Folder: \(result.folder.lastPathComponent)"
                if presenter?.presentedItemURL != result.folder {
                    presenter?.invalidate()
                    presenter = ConnectionHistoryFolderPresenter(folder: result.folder) { [weak self] in
                        DispatchQueue.main.async { self?.folderChanged() }
                    }
                }
                isSyncing = false
                syncTask = nil
                if needsAnotherSync { needsAnotherSync = false; refresh() }
            } catch {
                guard let self, generation == current, !Task.isCancelled else { return }
                isSyncing = false
                syncTask = nil
                syncError = "Could not update the history folder: \(error.localizedDescription) Local connections are still available."
            }
        }
    }

    private func folderChanged() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.refresh()
        }
    }

    private func persist() {
        do { defaults.set(try document.encoded(), forKey: Self.dataKey) }
        catch { showSyncError(error) }
    }

    isolated deinit {
        syncTask?.cancel()
        changeTask?.cancel()
        presenter?.invalidate()
    }
}
