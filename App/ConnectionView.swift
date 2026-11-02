import Combine
import Foundation
import MiniTermCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConnectionView: View {
    @StateObject private var history = ConnectionHistoryModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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
    @FocusState private var focusedField: Field?
    private let keychain = KeychainStore()
    private enum Field: Hashable { case host, username, port, session }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let wide = geometry.size.width >= 900 && !typeSize.isAccessibilitySize
                let rail: CGFloat = typeSize.isAccessibilitySize ? 84 : (wide ? 88 : 72)
                ScrollViewReader { proxy in
                    VStack(spacing: 10) {
                        header(rail: rail, wide: wide)
                        HStack(alignment: .top, spacing: 18) {
                            navigationRail(proxy: proxy, width: rail)
                            ScrollView {
                                if wide {
                                    HStack(alignment: .top, spacing: 28) {
                                        VStack(spacing: 28) {
                                            connectionPanel.id("link")
                                            identityPanel.id("keys")
                                        }.frame(maxWidth: .infinity)
                                        VStack(spacing: 28) {
                                            historyPanel.id("saved")
                                            storagePanel.id("sync")
                                        }.frame(maxWidth: .infinity)
                                    }
                                } else {
                                    VStack(spacing: 28) {
                                        connectionPanel.id("link")
                                        historyPanel.id("saved")
                                        storagePanel.id("sync")
                                        identityPanel.id("keys")
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                        }
                        footer(rail: rail)
                    }
                    .padding(.horizontal, wide ? 24 : 18)
                    .padding(.top, 12).padding(.bottom, 10)
                }
            }
            .background(LCARS.background)
            .preferredColorScheme(.dark)
            .tint(LCARS.lavender)
            .toolbar(.hidden, for: .navigationBar)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
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

    private func header(rail: CGFloat, wide: Bool) -> some View {
        HStack(alignment: .center, spacing: 18) {
            LCARSElbow().fill(LCARS.apricot)
                .frame(width: rail, height: wide ? 96 : 108).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("LCARS  /  REMOTE ACCESS")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .tracking(1.4).foregroundStyle(LCARS.apricot)
                Text("MINI TERM")
                    .font(.system(size: typeSize.isAccessibilitySize ? 36 : (wide ? 42 : 49), weight: .black))
                    .fontWidth(.condensed).tracking(-1).foregroundStyle(LCARS.cream)
                    .minimumScaleFactor(0.65).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text("Your Mac. Anywhere.")
                    .font(.subheadline).foregroundStyle(LCARS.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                Image("BrandMark").resizable().scaledToFit()
                    .frame(width: wide ? 90 : 108, height: wide ? 90 : 108)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .accessibilityHidden(true)
            }
        }
    }

    private func navigationRail(proxy: ScrollViewProxy, width: CGFloat) -> some View {
        VStack(spacing: 7) {
            railButton("01", label: "LINK", target: "link", color: LCARS.apricot, proxy: proxy)
            railButton("02", label: "SAVED", target: "saved", color: LCARS.lavender, proxy: proxy)
            railButton("03", label: "SYNC", target: "sync", color: LCARS.coral, proxy: proxy)
            railButton("04", label: "KEYS", target: "keys", color: LCARS.blue, proxy: proxy)
            UnevenRoundedRectangle(bottomLeadingRadius: 26).fill(LCARS.apricot)
                .frame(minHeight: 36, maxHeight: .infinity).accessibilityHidden(true)
        }.frame(width: width)
    }

    private func railButton(_ number: String, label: String, target: String, color: Color, proxy: ScrollViewProxy) -> some View {
        Button {
            focusedField = nil
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }
        } label: {
            VStack(alignment: .trailing, spacing: 10) {
                Text(number).font(.system(.title3, design: .monospaced).weight(.bold))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text(label).font(.system(.caption, design: .default).weight(.heavy)).fontWidth(.condensed)
                    .minimumScaleFactor(0.75).lineLimit(1)
            }
            .foregroundStyle(.black).padding(.horizontal, 10).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(color, in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel("Go to \(label.lowercased())")
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            LCARSSectionHeading(number: "01", title: "REMOTE LINK", color: LCARS.apricot)
            LCARSField(label: "HOST / ADDRESS", color: LCARS.apricot) {
                TextField("Host", text: $host, prompt: Text("mac-mini.local").foregroundStyle(LCARS.muted))
                    .textContentType(.URL).keyboardType(.URL).submitLabel(.next)
                    .focused($focusedField, equals: .host).onSubmit { focusedField = .username }
                    .accessibilityIdentifier("connection.host").accessibilityLabel("Hostname or IP address")
            }
            HStack(alignment: .top, spacing: 14) {
                LCARSField(label: "USERNAME", color: LCARS.apricot) {
                    TextField("Username", text: $username, prompt: Text("Mac username").foregroundStyle(LCARS.muted))
                        .textContentType(.username).submitLabel(.next)
                        .focused($focusedField, equals: .username).onSubmit { focusedField = .port }
                        .accessibilityIdentifier("connection.username").accessibilityLabel("Mac username")
                }
                LCARSField(label: "PORT", color: LCARS.apricot) {
                    TextField("22", text: $port).keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)
                        .accessibilityIdentifier("connection.port").accessibilityLabel("SSH port")
                }.frame(maxWidth: 110)
            }
            LCARSField(label: "TMUX SESSION  /  OPTIONAL", color: LCARS.apricot) {
                TextField("Session", text: $tmuxSession, prompt: Text("codex").foregroundStyle(LCARS.muted)).submitLabel(.go)
                    .focused($focusedField, equals: .session)
                    .onSubmit { if canConnect { connect() } }
                    .accessibilityIdentifier("connection.tmux").accessibilityLabel("Optional tmux session")
            }
            Text("Resume a named session, or leave blank for a regular shell.")
                .font(.footnote).foregroundStyle(LCARS.muted)
            HStack(spacing: 10) {
                Button("SAVE", action: saveConnection)
                    .buttonStyle(LCARSButtonStyle(color: LCARS.lavender))
                    .accessibilityLabel("Save connection").accessibilityIdentifier("connection.save")
                Button(action: connect) {
                    HStack { Text("CONNECT"); Spacer(); Image(systemName: "arrow.up.right") }
                }
                .buttonStyle(LCARSButtonStyle(color: LCARS.apricot))
                .accessibilityIdentifier("connection.connect")
            }.disabled(!canConnect)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(LCARS.coral).textSelection(.enabled)
                    .accessibilityIdentifier("connection.error")
            }
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            LCARSSectionHeading(number: "02", title: "SAVED CONNECTIONS", color: LCARS.lavender)
            if history.document.visibleEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title2).foregroundStyle(LCARS.lavender).accessibilityHidden(true)
                    Text("Your next connection starts here.").font(.callout.weight(.semibold)).foregroundStyle(LCARS.cream)
                    Text("Save a destination above. Successful connections appear here automatically.")
                        .font(.footnote).foregroundStyle(LCARS.muted)
                }.padding(.vertical, 8)
            } else {
                ForEach(Array(history.document.visibleEntries.prefix(30))) { entry in
                    if let profile = entry.profile { savedRow(entry: entry, profile: profile) }
                }
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
                HStack(spacing: 12) {
                    Capsule().fill(selected ? LCARS.apricot : LCARS.lavender).frame(width: 5)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.host).font(.system(.callout, design: .monospaced).weight(.semibold))
                            .foregroundStyle(LCARS.cream).lineLimit(1).truncationMode(.middle)
                        Text("\(profile.username) · \(profile.port) · \(profile.tmuxSession.isEmpty ? "shell" : profile.tmuxSession)")
                            .font(.caption.monospaced()).foregroundStyle(LCARS.muted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark" : "arrow.up.left")
                        .font(.caption.weight(.bold)).foregroundStyle(selected ? LCARS.apricot : LCARS.lavender)
                }.padding(.vertical, 12).padding(.leading, 12).padding(.trailing, 6)
            }.buttonStyle(.plain).accessibilityLabel("Fill connection for \(profile.username) at \(profile.host)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            Menu {
                if let date = entry.lastConnectedAt { Text("Last connected \(date.formatted())") }
                Button(role: .destructive) { history.remove(id: entry.id) } label: {
                    Label("Delete saved connection", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.bold)).foregroundStyle(LCARS.lavender)
                    .frame(width: 44, height: 56)
            }.accessibilityLabel("Options for \(profile.host)")
        }
        .background(selected ? LCARS.lavender.opacity(0.12) : LCARS.field, in: RoundedRectangle(cornerRadius: 8))
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            LCARSSectionHeading(number: "03", title: "CONNECTION STORAGE", color: LCARS.coral)
            HStack(spacing: 10) {
                Image(systemName: history.hasSyncFolder ? "folder.badge.icloud" : "internaldrive")
                    .font(.title3).foregroundStyle(LCARS.coral).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(history.isSyncing ? "Updating history…" : history.hasSyncFolder ? history.syncStatus : "Saved on this iPad")
                        .font(.callout.weight(.semibold)).foregroundStyle(LCARS.cream)
                    Text(history.hasSyncFolder ? "Local history stays available offline." : "Share your destinations through iCloud Drive.")
                        .font(.footnote).foregroundStyle(LCARS.muted)
                }
                Spacer(minLength: 0)
                if history.isSyncing { ProgressView().tint(LCARS.coral) }
            }
            HStack(spacing: 10) {
                Button(history.hasSyncFolder ? "CHANGE FOLDER" : "CHOOSE iCLOUD FOLDER") { showSyncFolder = true }
                    .buttonStyle(LCARSButtonStyle(color: LCARS.coral))
                    .accessibilityIdentifier("connection.chooseFolder")
                if history.hasSyncFolder {
                    Menu {
                        Button("Refresh history") { history.refresh() }
                        Button("Stop folder sync", role: .destructive) { history.stopSyncing() }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 48) }
                    .accessibilityLabel("History storage options")
                }
            }
            Text("Choose the same iCloud Drive folder on each device. Other folders save to that location.")
                .font(.footnote).foregroundStyle(LCARS.muted)
            if let message = history.syncError {
                Text(message).font(.footnote).foregroundStyle(LCARS.coral).textSelection(.enabled)
            }
        }
    }

    private var identityPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            LCARSSectionHeading(number: "04", title: "ACCESS & IDENTITY", color: LCARS.blue)
            Label(publicKey.isEmpty ? "Create this iPad’s SSH identity" : "This iPad’s SSH identity is ready", systemImage: "key.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(LCARS.cream)
            if publicKey.isEmpty {
                Button("CREATE SSH KEY", action: createIdentity).buttonStyle(LCARSButtonStyle(color: LCARS.blue))
            } else {
                Button("COPY PUBLIC KEY") { UIPasteboard.general.string = publicKey }
                    .buttonStyle(LCARSButtonStyle(color: LCARS.blue))
                DisclosureGroup("View public key") {
                    Text(publicKey).font(.caption.monospaced()).foregroundStyle(LCARS.cream).textSelection(.enabled).padding(.top, 8)
                }.font(.footnote).tint(LCARS.blue)
            }
            Text("Add the public key to your Mac’s authorized_keys. The private key stays in this iPad’s Keychain.")
                .font(.footnote).foregroundStyle(LCARS.muted)
            DisclosureGroup("Connection help & host trust") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enable Remote Login on the Mac and use its short username. Both devices need a network path to each other.")
                    Button("Forget this host’s saved key…", role: .destructive) { showForgetTrust = true }
                        .disabled(host.isEmpty)
                }.font(.footnote).padding(.top, 8)
            }.font(.footnote).tint(LCARS.blue)
        }
    }

    private func footer(rail: CGFloat) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(LCARS.apricot).frame(width: rail, height: 14)
            Capsule().fill(LCARS.lavender).frame(maxWidth: .infinity).frame(height: 14)
            Capsule().fill(LCARS.coral).frame(width: 36, height: 14)
            Text("SECURE SHELL / PERSONAL TERMINAL")
                .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(LCARS.apricot)
                .minimumScaleFactor(0.8).lineLimit(1)
        }.accessibilityHidden(true)
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


private enum LCARS {
    static let background = Color(red: 0.025, green: 0.028, blue: 0.037)
    static let field = Color(red: 0.073, green: 0.078, blue: 0.096)
    static let apricot = Color(red: 1, green: 0.70, blue: 0.43)
    static let lavender = Color(red: 0.72, green: 0.65, blue: 0.92)
    static let coral = Color(red: 0.94, green: 0.53, blue: 0.53)
    static let blue = Color(red: 0.62, green: 0.79, blue: 0.91)
    static let cream = Color(red: 0.96, green: 0.92, blue: 0.85)
    static let muted = Color(red: 0.64, green: 0.66, blue: 0.72)
}

private struct LCARSSectionHeading: View {
    let number: String
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 10) {
            Text(number).font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.black).padding(.horizontal, 12).padding(.vertical, 6)
                .background(color, in: Capsule()).accessibilityHidden(true)
            Text(title).font(.system(.subheadline, design: .default).weight(.heavy)).fontWidth(.condensed)
                .tracking(1).foregroundStyle(color).accessibilityAddTraits(.isHeader)
            Rectangle().fill(color).frame(height: 4).accessibilityHidden(true)
        }
    }
}

private struct LCARSField<Content: View>: View {
    let label: String
    let color: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(.caption2, design: .default).weight(.bold))
                .fontWidth(.condensed).tracking(1.2).foregroundStyle(color).accessibilityHidden(true)
            content.font(.system(.body, design: .monospaced)).foregroundStyle(LCARS.cream)
                .padding(.horizontal, 12).frame(minHeight: 48)
                .background(LCARS.field, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(0.65)).frame(height: 2) }
        }
    }
}

private struct LCARSButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.callout, design: .default).weight(.heavy)).fontWidth(.condensed)
            .tracking(0.8).foregroundStyle(.black)
            .padding(.horizontal, 20).frame(minHeight: 48).frame(maxWidth: .infinity)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35), in: Capsule())
            .contentShape(Capsule())
    }
}

private struct LCARSElbow: Shape {
    func path(in rect: CGRect) -> Path {
        let stem = min(34.0, rect.width * 0.5)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: 46))
        path.addQuadCurve(to: CGPoint(x: 46, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 27))
        path.addLine(to: CGPoint(x: stem + 20, y: 27))
        path.addQuadCurve(to: CGPoint(x: stem, y: 47), control: CGPoint(x: stem, y: 27))
        path.addLine(to: CGPoint(x: stem, y: rect.height))
        path.closeSubpath()
        return path
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
