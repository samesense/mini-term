import Combine
import Foundation
import MiniTermCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConnectionView: View {
    @StateObject private var history = ConnectionHistoryModel()
    @ObservedObject private var keyboardDiagnostics = KeyboardEventDiagnostics.shared
    @AppStorage("keyboard.dualRoleCaps.enabled") private var dualRoleCaps = true
    @AppStorage("connection.autoReconnect") private var autoReconnect = true
    @AppStorage("keyboard.dualRoleCaps.source") private var dualRoleSource = DualRoleKeySource.capsLock.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var didRestoreConnection = false
    @State private var showSettings = false
    @State private var showSyncFolder = false
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var tmuxSession = ""
    @State private var publicKey = ""
    @State private var session: TerminalSessionModel?
    @State private var error: String?
    @State private var showForgetTrust = false
    @State private var showRename = false
    @State private var editingID = ""
    @State private var editingName = ""
    @State private var lastFailure: ConnectionFailure?
    @State private var failureDate = Date()
    @State private var copiedDiagnostics = false
    @FocusState private var focusedField: Field?
    private let keychain = KeychainStore()
    private enum Field: Hashable { case host, username, port, session }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var isSaved: Bool {
        guard let connection = try? formConnection() else { return false }
        let id = ConnectionProfile(connection).id
        return history.document.visibleEntries.contains { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 900 && !typeSize.isAccessibilitySize
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        HStack(spacing: 6) {
                            Capsule().fill(LCARS.apricot).frame(width: 88, height: 6)
                            Capsule().fill(LCARS.lavender).frame(width: 28, height: 6)
                            Rectangle().fill(LCARS.muted.opacity(0.18)).frame(height: 1)
                        }.accessibilityHidden(true)
                        if wide {
                            HStack(alignment: .top, spacing: 56) {
                                connectionPanel.frame(maxWidth: .infinity)
                                historyPanel.frame(width: 300)
                            }
                        } else {
                            connectionPanel
                            historyPanel
                        }
                        if history.syncError != nil {
                            Button("History sync needs attention") { showSettings = true }
                                .font(.footnote).foregroundStyle(LCARS.coral)
                        }
                    }
                    .frame(maxWidth: wide ? 960 : 560)
                    .padding(.horizontal, 28).padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(LCARS.background)
            .preferredColorScheme(.dark)
            .tint(LCARS.lavender)
            .toolbar(.hidden, for: .navigationBar)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .fullScreenCover(item: $session) { model in
                RecoveringTerminalScreen(model: model).id(model.id)
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .alert("Name connection", isPresented: $showRename) {
                TextField("Name", text: $editingName).textInputAutocapitalization(.words)
                Button("Save") { customizeSaved(id: editingID, name: editingName) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Leave blank to use the hostname.") }
            .onAppear {
                loadPublicKey()
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--design-settings") { showSettings = true }
                #endif
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
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("BrandMark").resizable().scaledToFit()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Mini Term").font(.system(.title2).weight(.bold)).fontWidth(.condensed)
                    .foregroundStyle(LCARS.cream).accessibilityAddTraits(.isHeader)
                Text("REMOTE ACCESS").font(.system(.caption2, design: .monospaced))
                    .tracking(2).foregroundStyle(LCARS.apricot)
            }
            Spacer(minLength: 12)
            Button {
                focusedField = nil
                showSettings = true
            } label: {
                Image(systemName: "gearshape").font(.title3)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(LCARS.muted)
            .accessibilityLabel("Settings").accessibilityIdentifier("connection.settings")
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect").font(.system(.largeTitle).weight(.semibold)).fontWidth(.condensed)
                    .foregroundStyle(LCARS.cream).accessibilityAddTraits(.isHeader)
                Text("Your Mac. Right where you left it.")
                    .font(.subheadline).foregroundStyle(LCARS.muted)
            }.padding(.bottom, 6)
            LCARSField(label: "HOST") {
                TextField("Host", text: $host, prompt: Text("mac-mini.local").foregroundStyle(LCARS.muted))
                    .textContentType(.URL).keyboardType(.URL).submitLabel(.next)
                    .focused($focusedField, equals: .host).onSubmit { focusedField = .username }
                    .accessibilityIdentifier("connection.host").accessibilityLabel("Hostname or IP address")
            }
            LCARSField(label: "USERNAME") {
                TextField("Username", text: $username, prompt: Text("Mac username").foregroundStyle(LCARS.muted))
                    .textContentType(.username).submitLabel(.next)
                    .focused($focusedField, equals: .username).onSubmit { focusedField = .session }
                    .accessibilityIdentifier("connection.username").accessibilityLabel("Mac username")
            }
            LCARSField(label: "TMUX SESSION") {
                TextField("Session", text: $tmuxSession, prompt: Text("Optional").foregroundStyle(LCARS.muted))
                    .submitLabel(.go).focused($focusedField, equals: .session)
                    .onSubmit { if canConnect { connect() } }
                    .accessibilityIdentifier("connection.tmux").accessibilityLabel("Optional tmux session")
            }
            DisclosureGroup {
                LCARSField(label: "SSH PORT") {
                    TextField("22", text: $port).keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityIdentifier("connection.port").accessibilityLabel("SSH port")
                }.padding(.top, 12)
            } label: {
                Text("SSH port · \(port)").font(.footnote).foregroundStyle(LCARS.muted)
            }.tint(LCARS.muted)
            Button(action: connect) {
                HStack { Spacer(); Text("Connect"); Image(systemName: "arrow.up.right"); Spacer() }
            }
            .buttonStyle(LCARSButtonStyle(color: LCARS.apricot)).disabled(!canConnect)
            .accessibilityIdentifier("connection.connect")
            HStack {
                if isSaved {
                    Label("Saved connection", systemImage: "checkmark").foregroundStyle(LCARS.muted)
                } else {
                    Button("Save connection", action: saveConnection)
                        .disabled(!canConnect).accessibilityIdentifier("connection.save")
                }
                Spacer()
            }.font(.footnote).frame(minHeight: 28)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(LCARS.coral).textSelection(.enabled)
                    .accessibilityIdentifier("connection.error")
                Button(copiedDiagnostics ? "Copied diagnostics" : "Copy diagnostics", action: copyFormDiagnostics)
                    .font(.footnote)
            }
            if publicKey.isEmpty {
                Button("Set up this iPad’s SSH key") {
                    focusedField = nil
                    showSettings = true
                }.font(.footnote).accessibilityIdentifier("connection.setupKey")
            }
        }
    }

    @ViewBuilder private var historyPanel: some View {
        if !history.document.visibleEntries.isEmpty {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("SAVED CONNECTIONS").font(.system(.caption, design: .monospaced).weight(.medium))
                    .tracking(1.5).foregroundStyle(LCARS.lavender).accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)
                ForEach(history.document.visibleEntries) { entry in
                    if let profile = entry.profile { savedRow(entry: entry, profile: profile) }
                }
                Text("Tap a destination to fill the form.")
                    .font(.caption).foregroundStyle(LCARS.muted).padding(.top, 4)
            }
        }
    }

    private func savedRow(entry: ConnectionHistoryEntry, profile: ConnectionProfile) -> some View {
        let selected = host.lowercased() == profile.host.lowercased() && username == profile.username &&
            port == String(profile.port) && tmuxSession == profile.tmuxSession
        return HStack(spacing: 0) {
            Button {
                fill(profile); history.select(profile); focusedField = nil
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if entry.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(LCARS.apricot) }
                            Text(entry.displayName).font(.callout.weight(.medium))
                                .foregroundStyle(LCARS.cream).lineLimit(1).truncationMode(.middle)
                        }
                        Text("\(profile.username)@\(profile.host) · \(profile.port) · \(profile.tmuxSession.isEmpty ? "shell" : profile.tmuxSession)")
                            .font(.caption.monospaced()).foregroundStyle(LCARS.muted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(LCARS.apricot)
                    }
                }.padding(.vertical, 14).padding(.leading, 16)
            }.buttonStyle(.plain).accessibilityLabel("Fill \(entry.displayName), \(profile.username) at \(profile.host)\(entry.isFavorite ? ", favorite" : "")")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Menu {
                Button {
                    editingID = entry.id; editingName = entry.annotation?.name ?? ""; showRename = true
                } label: { Label("Rename", systemImage: "pencil") }
                Button {
                    customizeSaved(id: entry.id, favorite: !entry.isFavorite)
                } label: { Label(entry.isFavorite ? "Remove favorite" : "Favorite", systemImage: entry.isFavorite ? "star.slash" : "star") }
                if let date = entry.lastConnectedAt { Text("Last connected \(date.formatted())") }
                Button(role: .destructive) { history.remove(id: entry.id) } label: {
                    Label("Delete saved connection", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(LCARS.muted).frame(width: 44, height: 56)
            }.accessibilityLabel("Options for \(entry.displayName)")
        }
        .background(selected ? LCARS.lavender.opacity(0.10) : LCARS.field, in: RoundedRectangle(cornerRadius: 12))
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Reconnect after wake or network loss", isOn: $autoReconnect)
                } header: { Text("Connection") } footer: {
                    Text("Retries up to six times while MiniTerm is active. Reattaches your tmux session; a plain shell opens a new shell. Commands and file transfers are never replayed.")
                }
                Section {
                    Toggle("Dual-role Caps Lock", isOn: $dualRoleCaps)
                        .accessibilityIdentifier("settings.dualRoleCaps")
                    if dualRoleCaps {
                        Picker("Input source", selection: $dualRoleSource) {
                            Text("Caps Lock events").tag(DualRoleKeySource.capsLock.rawValue)
                            Text("Remapped left Control").tag(DualRoleKeySource.remappedLeftControl.rawValue)
                        }
                    }
                    DisclosureGroup("Check keyboard event delivery") {
                        Text("UIKit Caps: \(keyboardDiagnostics.capsDown) down / \(keyboardDiagnostics.capsUp) up")
                        Text("UIKit left Control: \(keyboardDiagnostics.controlDown) down / \(keyboardDiagnostics.controlUp) up")
                        Text("GameController Caps: \(keyboardDiagnostics.gcDown) down / \(keyboardDiagnostics.gcUp) up")
                        Text(keyboardDiagnostics.hasGCKeyboard ? "GameController keyboard detected" : "No GameController keyboard detected")
                        Text("Test inside the terminal, then return here. Counts reset when the app restarts. GameController observes events; it cannot suppress Caps Lock.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.font(.footnote)
                } header: { Text("Hardware keyboard") } footer: {
                    Text("Tap Caps alone for Escape; hold with another key for Control. Requires physical press and release events. If Caps still capitalizes or releases are missing, use iPad Settings → General → Keyboard → Hardware Keyboard → Modifier Keys to map Caps Lock to Control, then select Remapped left Control here. That mode also changes the physical left Control key. Global Caps Lock suppression cannot be guaranteed in an app.")
                }
                Section {
                    if publicKey.isEmpty {
                        Button("Create SSH key", action: createIdentity).accessibilityIdentifier("settings.createKey")
                    } else {
                        Button("Copy public key") { UIPasteboard.general.string = publicKey }
                            .accessibilityIdentifier("settings.copyKey")
                        DisclosureGroup("View public key") {
                            Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                } header: { Text("SSH identity") } footer: {
                    Text("Add this iPad’s public key to your Mac’s authorized_keys. The private key stays in this iPad’s Keychain.")
                }
                Section {
                    HStack {
                        Label(history.syncStatus, systemImage: history.hasSyncFolder ? "folder" : "internaldrive")
                        if history.isSyncing { Spacer(); ProgressView() }
                    }
                    Button(history.hasSyncFolder ? "Change history folder" : "Choose iCloud Drive folder") { showSyncFolder = true }
                        .accessibilityIdentifier("connection.chooseFolder")
                    if history.hasSyncFolder {
                        Button("Refresh history") { history.refresh() }
                        Button("Stop folder sync", role: .destructive) { history.stopSyncing() }
                    }
                    if let message = history.syncError {
                        Text(message).foregroundStyle(LCARS.coral).textSelection(.enabled)
                    }
                } header: { Text("Connection history") } footer: {
                    Text("Choose the same iCloud Drive folder on each device. Connections remain available offline. Other folders save to that location.")
                }
                Section {
                    Button("Forget this host’s saved key…", role: .destructive) { showForgetTrust = true }
                        .disabled(host.isEmpty)
                } header: { Text("Host trust") } footer: {
                    Text("For \(host.isEmpty ? "the host in the connection form" : host). Forget a saved key only after independently verifying that your Mac’s SSH key changed.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(LCARS.coral).textSelection(.enabled) }
                }
            }
            .scrollContentBackground(.hidden).background(LCARS.background)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            .fileImporter(isPresented: $showSyncFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder): history.chooseFolder(folder)
                case .failure(let error): history.showSyncError(error)
                }
            }
            .confirmationDialog("Forget saved host key?", isPresented: $showForgetTrust, titleVisibility: .visible) {
                Button("Forget host key", role: .destructive) { forgetTrust() }
            } message: {
                Text("Only do this after checking the Mac’s new fingerprint independently. The next connection will ask you to verify it again.")
            }
        }.preferredColorScheme(.dark).tint(LCARS.lavender)
    }

    private func fill(_ profile: ConnectionProfile) {
        host = profile.host; username = profile.username
        port = String(profile.port); tmuxSession = profile.tmuxSession
        error = nil
        lastFailure = nil; copiedDiagnostics = false
    }

    private func customizeSaved(id: String, name: String? = nil, favorite: Bool? = nil) {
        do { try history.customize(id: id, name: name, favorite: favorite) }
        catch { displayError(error) }
    }

    private func displayError(_ caught: any Error) {
        error = caught.localizedDescription
        lastFailure = ConnectionFailure(caught)
        failureDate = Date()
        copiedDiagnostics = false
    }

    private func copyFormDiagnostics() {
        var report = SessionDiagnostics(usesTmux: !tmuxSession.isEmpty)
        report.record(.failed(""), failure: lastFailure, now: failureDate)
        UIPasteboard.general.string = AppDiagnostics.text(report)
        copiedDiagnostics = true
    }

    private func formConnection() throws -> SSHConnection {
        guard let port = Int(port), host.utf8.count <= 1024, username.utf8.count <= 1024 else {
            throw TerminalError.invalidConnection
        }
        return try SSHConnection(host: host, username: username, port: port, tmuxSession: tmuxSession)
    }

    private func saveConnection() {
        do { history.remember(ConnectionProfile(try formConnection()), connected: false); error = nil }
        catch { displayError(error) }
    }

    private func loadPublicKey() {
        do {
            if let seed = try keychain.read(account: "identity.ed25519") {
                publicKey = try SSHIdentity.publicKey(seed: seed)
            }
        } catch { displayError(error) }
    }

    private func createIdentity() {
        do { _ = try identitySeed(); error = nil }
        catch { displayError(error) }
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
        } catch { displayError(error) }
    }

    private func forgetTrust() {
        do {
            guard let port = Int(port) else { throw TerminalError.invalidConnection }
            let connection = try SSHConnection(host: host, username: username, port: port)
            try keychain.delete(account: "host:\(connection.hostKeyAccount)")
            error = nil
        } catch { displayError(error) }
    }
}


enum LCARS {
    static let background = Color(red: 0.025, green: 0.028, blue: 0.037)
    static let field = Color(red: 0.073, green: 0.078, blue: 0.096)
    static let apricot = Color(red: 1, green: 0.70, blue: 0.43)
    static let lavender = Color(red: 0.72, green: 0.65, blue: 0.92)
    static let coral = Color(red: 0.94, green: 0.53, blue: 0.53)
    static let blue = Color(red: 0.62, green: 0.79, blue: 0.91)
    static let cream = Color(red: 0.96, green: 0.92, blue: 0.85)
    static let muted = Color(red: 0.64, green: 0.66, blue: 0.72)
}

private struct LCARSField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(.caption2, design: .default).weight(.bold))
                .tracking(1.2).foregroundStyle(LCARS.muted).accessibilityHidden(true)
            content.font(.system(.body, design: .monospaced)).foregroundStyle(LCARS.cream)
                .padding(.horizontal, 14).frame(minHeight: 52)
                .background(LCARS.field, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct LCARSButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.callout, design: .default).weight(.heavy)).fontWidth(.condensed)
            .tracking(0.8).foregroundStyle(.black)
            .padding(.horizontal, 20).frame(minHeight: 52).frame(maxWidth: .infinity)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35), in: Capsule())
            .contentShape(Capsule())
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

    func customize(id: String, name: String? = nil, favorite: Bool? = nil) throws {
        try document.customize(id: id, name: name, favorite: favorite)
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
