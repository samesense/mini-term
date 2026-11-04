// Runs with PreviewProbe.swift's generated SSH/HTTP fixtures in a separate app.
@testable import MiniTermCore

private final class WorkspaceSFTPFixture: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private var buffer = ByteBuffer()
    private var sftp = false
    private var readDirectories: Set<String> = []
    let files: PreviewProbeBox<[String: Data]>
    init(files: PreviewProbeBox<[String: Data]>) { self.files = files }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let subsystem = event as? SSHChannelRequestEvent.SubsystemRequest {
            sftp = subsystem.subsystem == "sftp"
            context.triggerUserOutboundEvent(sftp ? ChannelSuccessEvent() as Any : ChannelFailureEvent() as Any, promise: nil)
        } else if event is SSHChannelRequestEvent.PseudoTerminalRequest || event is SSHChannelRequestEvent.ShellRequest || event is SSHChannelRequestEvent.ExecRequest {
            context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let ssh = unwrapInboundIn(data)
        guard sftp, case .byteBuffer(var bytes) = ssh.data else { context.writeAndFlush(data, promise: nil); return }
        buffer.writeBuffer(&bytes)
        do {
            while var packet = try SFTPPacket.next(from: &buffer) {
                if packet.type == 1 {
                    var version = ByteBuffer(); version.writeInteger(UInt32(3)); send(context, type: 2, id: nil, data: version); continue
                }
                guard let id: UInt32 = packet.payload.readInteger() else { throw SFTPError.malformed }
                switch packet.type {
                case 16:
                    let input = try packet.payload.sftpText()
                    let path = input == "." ? "/fixture" : input
                    var result = ByteBuffer(); result.writeInteger(UInt32(1)); result.sftpString(path); result.sftpString(""); attributes(&result, directory: true, size: nil)
                    send(context, type: 104, id: id, data: result)
                case 17:
                    let path = try packet.payload.sftpText()
                    if path == "/fixture" || path == "/fixture/images" {
                        var result = ByteBuffer(); attributes(&result, directory: true, size: nil); send(context, type: 105, id: id, data: result)
                    } else if let bytes = files.access({ $0[path] }) {
                        var result = ByteBuffer(); attributes(&result, directory: false, size: bytes.count); send(context, type: 105, id: id, data: result)
                    } else { status(context, id, 2) }
                case 11:
                    let path = try packet.payload.sftpText(); readDirectories.remove(path)
                    var result = ByteBuffer(); result.sftpString("dir:" + path); send(context, type: 102, id: id, data: result)
                case 12:
                    let handle = try packet.payload.sftpText(); let path = String(handle.dropFirst(4))
                    if readDirectories.contains(path) { status(context, id, 1); continue }; readDirectories.insert(path)
                    let matching = files.access { $0.keys.filter { $0.hasPrefix(path + "/") && !$0.dropFirst(path.count + 1).contains("/") }.sorted() }
                    var result = ByteBuffer(); result.writeInteger(UInt32(matching.count + (path == "/fixture" ? 1 : 0)))
                    if path == "/fixture" { result.sftpString("images"); result.sftpString(""); attributes(&result, directory: true, size: nil) }
                    for file in matching {
                        result.sftpString(String(file.dropFirst(path.count + 1))); result.sftpString("")
                        attributes(&result, directory: false, size: files.access { $0[file]!.count })
                    }
                    send(context, type: 104, id: id, data: result)
                case 3:
                    let path = try packet.payload.sftpText(); let flags: UInt32 = packet.payload.readInteger()!
                    if flags & 2 != 0 {
                        if files.access({ $0[path] != nil }) { status(context, id, 4); continue }
                        files.access { $0[path] = Data() }
                    }
                    var result = ByteBuffer(); result.sftpString("file:" + path); send(context, type: 102, id: id, data: result)
                case 5:
                    let handle = try packet.payload.sftpText(); let offset: UInt64 = packet.payload.readInteger()!; let length: UInt32 = packet.payload.readInteger()!
                    let data = files.access { $0[String(handle.dropFirst(5))] ?? Data() }
                    if offset >= data.count { status(context, id, 1) }
                    else { var result = ByteBuffer(); result.sftpString(data.subdata(in: Int(offset)..<min(data.count, Int(offset) + Int(length)))); send(context, type: 103, id: id, data: result) }
                case 6:
                    let handle = try packet.payload.sftpText(); let offset: UInt64 = packet.payload.readInteger()!; let bytes = try packet.payload.sftpData()
                    files.access { files in
                        let path = String(handle.dropFirst(5)); var data = files[path] ?? Data()
                        if Int(offset) == data.count { data.append(bytes); files[path] = data }
                    }
                    status(context, id, 0)
                case 4: status(context, id, 0)
                default: status(context, id, 8)
                }
            }
        } catch { context.close(promise: nil) }
    }
    private func attributes(_ buffer: inout ByteBuffer, directory: Bool, size: Int?) {
        buffer.writeInteger(UInt32(size == nil ? 4 : 5))
        if let size { buffer.writeInteger(UInt64(size)) }
        buffer.writeInteger(UInt32(directory ? 0o040755 : 0o100644))
    }
    private func status(_ context: ChannelHandlerContext, _ id: UInt32, _ code: UInt32) {
        var result = ByteBuffer(); result.writeInteger(code); result.sftpString(""); result.sftpString("")
        send(context, type: 101, id: id, data: result)
    }
    private func send(_ context: ChannelHandlerContext, type: UInt8, id: UInt32?, data: ByteBuffer) {
        context.writeAndFlush(NIOAny(SSHChannelData(type: .channel, data: .byteBuffer(SFTPPacket.encode(type: type, id: id, payload: data)))), promise: nil)
    }
}

@MainActor
private final class WorkspaceFeatureRunner: ObservableObject {
    @Published var recovery: SessionRecovery?
    @Published var showFiles = false
    @Published var showWorkspace = false
    private var checks: [String] = []
    private var failures: [String] = []
    private var fileSheetDismissals = 0
    func fileSheetDidDismiss() { fileSheetDismissals += 1 }
    private func check(_ condition: Bool, _ label: String) { checks.append(label); if !condition { failures.append(label) } }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw SFTPError.timedOut
    }
    func run() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let files = PreviewProbeBox(["/fixture/hello.txt": Data("hello over SFTP".utf8), "/fixture/images/icon.png": Data([0,1,2,255])])
        let paths = PreviewProbeBox<[String]>([])
        var server: (any Channel)?
        defer {
            recovery?.close(); server?.close(promise: nil); group.shutdownGracefully { _ in }
            let report: [String: Any] = ["checks": checks.count, "failures": failures, "labels": checks]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL.documentsDirectory.appendingPathComponent("workspace-features-probe.json"))
        }
        do {
            UserDefaults.standard.set(true, forKey: "connection.autoReconnect")
            let host = NIOSSHPrivateKey(ed25519Key: .init())
            let hostKey = String(openSSHPublicKey: host.publicKey)
            let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(role: .server(.init(hostKeys: [host], userAuthDelegate: PreviewProbeAuth())), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                        child.eventLoop.makeCompletedFuture {
                            if type == .session { try child.pipeline.syncOperations.addHandler(WorkspaceSFTPFixture(files: files)) }
                            else if case .directTCPIP = type { try child.pipeline.syncOperations.addHandler(PreviewProbeHTTP(paths: paths)) }
                            else { throw SFTPError.unavailable }
                        }
                    }))
                }
            }.bind(host: "127.0.0.1", port: 0).get()
            server = listener
            let connection = try SSHConnection(host: "127.0.0.1", username: "fixture", port: listener.localAddress!.port!, tmuxSession: "fixture")
            try KeychainStore().save(Data(hostKey.utf8), account: "host:" + connection.hostKeyAccount)
            defer { try? KeychainStore().delete(account: "host:" + connection.hostKeyAccount) }
            let model = TerminalSessionModel(connection: connection, seed: SSHIdentity.generateSeed())
            let owner = SessionRecovery(model, monitorNetwork: false)
            recovery = owner; showWorkspace = true
            try await wait { model.state == .connected }
            check(model.state == .connected, "recovery workspace connects")
            try await Task.sleep(for: .milliseconds(200))
            capture(name: "terminal-toolbar.png", toolbarOnly: true)
            owner.sceneActive(false); owner.sceneActive(true)
            try await Task.sleep(for: .milliseconds(200))
            check(owner.session === model && model.state == .connected, "healthy wake verifies existing socket without replacing workspace")
            let preview = model.preview
            preview.portText = "3000"; preview.pathText = "/dashboard?tab=1"; preview.shortcutName = "Dashboard"; preview.saveShortcut()
            check(preview.shortcuts.count == 1, "save preview shortcut")
            check(PreviewModel(connection: connection).shortcuts == preview.shortcuts, "shortcuts persist per connection")
            preview.openShortcut(preview.shortcuts[0])
            try await wait { preview.browser?.webView.title == "SSH_PREVIEW_OK" }
            check(preview.browser?.webView.url?.path == "/dashboard", "shortcut loads saved path")
            check(preview.browser?.safariURL.path == "/dashboard" && preview.browser?.safariURL.query == "tab=1", "external browser URL preserves path/query")
            let shortcut = preview.shortcuts[0]
            preview.editShortcut(shortcut); preview.shortcutName = "Renamed"; preview.saveShortcut()
            check(preview.shortcuts.count == 1 && preview.shortcuts[0].name == "Renamed", "editing preserves shortcut identity")
            preview.pathText = "//bad.example/"; preview.saveShortcut()
            check(preview.shortcuts[0].path == "/dashboard?tab=1", "invalid edits preserve saved shortcut")
            preview.pathText = "/unapplied"; preview.portText = "99999"
            showFiles = true
            model.files.browse()
            try await wait { !model.files.busy && !model.files.directory.isEmpty }
            check(model.files.directory == "/fixture", "SFTP starts at remote home")
            check(model.files.entries.map(\.name) == ["images", "hello.txt"], "file browser lists folders first")
            try await Task.sleep(for: .milliseconds(300))
            capture()
            let source = URL.documentsDirectory.appendingPathComponent("upload.txt")
            try Data("uploaded from iPad".utf8).write(to: source)
            model.files.upload(source, name: "uploaded.txt")
            try await wait { !model.files.busy }
            check(files.access { $0["/fixture/uploaded.txt"] } == Data("uploaded from iPad".utf8), "upload reaches SFTP")
            check(model.files.entries.contains { $0.name == "uploaded.txt" }, "upload refreshes directory")
            model.files.upload(source, name: "uploaded.txt")
            try await wait { !model.files.busy }
            check(model.files.message?.contains("status 4") == true, "existing remote file cannot be overwritten")
            check(model.state == .connected && preview.browser?.webView.title == "SSH_PREVIEW_OK", "file operations keep terminal and preview connected")
            let priorDismissals = fileSheetDismissals
            showFiles = false
            try await wait { self.fileSheetDismissals > priorDismissals }
            // Download at model level to inspect its temporary export before presenting Files.
            if let file = model.files.entries.first(where: { $0.name == "hello.txt" }) {
                model.files.download(file)
                try await wait { !model.files.busy }
                check(model.files.exportItem != nil, "download offers native export")
                if let url = model.files.exportItem?.url {
                    check(try Data(contentsOf: url) == Data("hello over SFTP".utf8), "download bytes match")
                    model.files.clearExport()
                    check(!FileManager.default.fileExists(atPath: url.path), "temporary export removed after use")
                }
                showFiles = true
                try await Task.sleep(for: .milliseconds(250))
                model.files.download(file)
                try await wait { self.exportPicker() != nil }
                check(model.files.exportItem != nil, "native Files export picker mounts with completed download")
                let staged = model.files.exportItem?.url
                if let picker = exportPicker() { picker.delegate?.documentPickerWasCancelled?(picker) }
                try await wait { model.files.exportItem == nil }
                try await wait { staged.map { !FileManager.default.fileExists(atPath: $0.path) } == true }
                check(staged.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "native picker cancellation removes export staging")
                showFiles = false
                try await Task.sleep(for: .milliseconds(200))
            }
            preview.showing = false
            owner.sceneActive(false); model.disconnect()
            try await wait { model.state.isFinished }
            owner.sceneActive(true)
            try await wait { owner.session !== model && owner.session.state == .connected }
            let next = owner.session
            check(next.terminalSession !== model.terminalSession, "wake recovery owns a fresh terminal/input queue")
            check(next.connection == model.connection, "wake recovery retains tmux destination")
            try await wait { next.preview.browser?.webView.title == "SSH_PREVIEW_OK" }
            check(next.preview.selectedPath == "/dashboard?tab=1" && next.preview.selectedPort == 3000, "wake restores applied preview, not unsaved edits")
            check(!next.preview.showing && next.preview.browser != nil, "wake preserves terminal selection and retained preview")
            check(next.files.entries.isEmpty, "transfers and file selections are not replayed")
            owner.networkChanged(false); next.disconnect()
            try await wait { next.state.isFinished }
            owner.networkChanged(true)
            check(owner.message?.contains("Reconnecting") == true, "network restoration schedules retry")
            owner.stopRetrying()
            try await Task.sleep(for: .milliseconds(1200))
            check(owner.session === next, "stop retrying cancels replacement")
            owner.reconnectManually()
            try await wait { owner.session !== next && owner.session.state == .connected }
            check(owner.session.state == .connected, "manual reconnect still works after stop")
            owner.session.preview.removeShortcut(shortcut)
            check(owner.session.preview.shortcuts.isEmpty, "delete preview shortcut")
            owner.close()
        } catch {
            failures.append(String(describing: error))
            if let model = recovery?.session.files {
                failures.append("File state busy=\(model.busy) export=\(model.exportItem != nil) message=\(model.message ?? "none")")
            }
            capture()
        }
    }
    private func capture(name: String = "workspace-files.png", toolbarOnly: Bool = false) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let bounds = toolbarOnly ? CGRect(x: 0, y: 0, width: window.bounds.width, height: min(180, window.bounds.height)) : window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: !toolbarOnly) }
        try? image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name))
    }
    private func exportPicker() -> UIDocumentPickerViewController? {
        func search(_ controller: UIViewController) -> UIDocumentPickerViewController? {
            if let picker = controller as? UIDocumentPickerViewController { return picker }
            if let presented = controller.presentedViewController, let result = search(presented) { return result }
            return controller.children.compactMap { search($0) }.first
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .compactMap { $0.rootViewController.flatMap { search($0) } }.first
    }
}

struct WorkspaceFeaturesProbeView: View {
    @StateObject private var runner = WorkspaceFeatureRunner()
    var body: some View {
        Color.black
            .fullScreenCover(isPresented: $runner.showWorkspace) {
                if let owner = runner.recovery {
                    RecoveringTerminalScreen(recovery: owner)
                        .sheet(isPresented: $runner.showFiles, onDismiss: {
                            if !runner.showFiles { owner.session.files.cancel(); owner.session.files.clearExport() }
                            runner.fileSheetDidDismiss()
                        }) {
                            RemoteFilesView(model: owner.session.files)
                        }
                }
            }
            .task { await runner.run() }
    }
}
