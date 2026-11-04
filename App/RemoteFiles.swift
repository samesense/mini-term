import Combine
import Foundation
import MiniTermCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileExportItem: Identifiable { let id = UUID(); let url: URL }

@MainActor
final class RemoteFilesModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var directory = ""
    @Published private(set) var entries: [RemoteFile] = []
    @Published private(set) var busy = false
    @Published private(set) var progress: UInt64 = 0
    @Published private(set) var total: UInt64?
    @Published private(set) var activity = ""
    @Published var message: String?
    @Published var exportItem: FileExportItem?
    private weak var transport: SSHTransport?
    private var client: SFTPClient?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var exportDirectory: URL?

    func attach(_ transport: SSHTransport) { self.transport = transport }
    func connectionReady() { connected = true }
    func disconnected() { connected = false; transport = nil; cancel(); entries = []; message = "SSH disconnected. Reconnect before browsing files." }
    func cancel() {
        if busy && activity.hasPrefix("Uploading") { message = "Upload cancelled. A partial new file may remain on the Mac." }
        generation = UUID(); operation?.cancel(); operation = nil
        client?.close(); client = nil; busy = false; activity = ""
    }
    func clearExport() {
        exportItem = nil
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }
    private func run(_ title: String, work: @escaping @MainActor (SFTPClient, UUID) async throws -> Void) {
        guard !busy, connected, let transport else { return }
        let request = UUID(); generation = request
        busy = true; activity = title; message = nil; progress = 0; total = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let current: SFTPClient
                if let client { current = client }
                else {
                    current = try await transport.startSFTP().get()
                    guard generation == request, !Task.isCancelled else { current.close(); return }
                    client = current
                }
                try await work(current, request)
            } catch {
                guard generation == request else { return }
                client?.close(); client = nil
                if !Task.isCancelled {
                    message = (error as? SFTPError)?.localizedDescription ?? "The file operation failed. Check access permissions, available storage and SSH, then try again."
                }
            }
            guard generation == request else { return }
            busy = false; activity = ""; operation = nil
        }
    }
    func browse(_ path: String? = nil) {
        let target = path ?? (directory.isEmpty ? "." : directory)
        run("Loading files…") { [weak self] client, request in
            let canonical = try await client.realPath(target)
            let files = try await client.listDirectory(canonical)
            guard let self, generation == request else { return }
            directory = canonical; entries = files
        }
    }
    func open(_ file: RemoteFile) {
        if file.isDirectory { browse(file.path); return }
        if file.isSymbolicLink {
            run("Resolving link…") { [weak self] client, request in
                let resolved = try await client.realPath(file.path)
                let attrs = try await client.stat(resolved)
                guard let self, generation == request else { return }
                busy = false
                if attrs.isDirectory { browse(resolved) }
                else if attrs.isRegularFile { download(attrs) }
                else { message = SFTPError.notRegularFile.localizedDescription }
            }
        } else if file.isRegularFile { download(file) }
        else { message = SFTPError.notRegularFile.localizedDescription }
    }
    func download(_ file: RemoteFile) {
        clearExport()
        run("Downloading \(file.name)…") { [weak self] client, request in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MiniTerm-download-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(file.name, isDirectory: false)
            do {
                try await client.download(file.path, to: destination) { [weak self] bytes, total in
                    Task { @MainActor [weak self] in
                        guard let self, generation == request else { return }; progress = bytes; self.total = total
                    }
                }
                guard let self, generation == request else { try? FileManager.default.removeItem(at: folder); return }
                exportDirectory = folder; exportItem = FileExportItem(url: destination)
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        }
    }
    func upload(_ source: URL, name: String) {
        let target: String
        do { target = try RemotePath.join(directory, name: name) }
        catch { message = error.localizedDescription; return }
        run("Uploading \(name)…") { [weak self] client, request in
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw SFTPError.notRegularFile }
            try await client.upload(source, to: target) { [weak self] bytes, total in
                Task { @MainActor [weak self] in
                    guard let self, generation == request else { return }; progress = bytes; self.total = total
                }
            }
            guard let self, generation == request else { return }
            let files = try await client.listDirectory(directory)
            guard generation == request else { return }
            entries = files; message = "Uploaded \(name)."
        }
    }
}

struct RemoteFilesView: View {
    @ObservedObject var model: RemoteFilesModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var uploadURL: URL?
    @State private var uploadName = ""
    @State private var showUpload = false
    @State private var showPath = false
    @State private var path = ""
    @State private var showHidden = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { model.browse(RemotePath.parent(model.directory)) } label: { Image(systemName: "arrow.up") }
                            .accessibilityLabel("Parent directory").disabled(model.busy || model.directory.isEmpty || model.directory == "/")
                        Button { path = model.directory; showPath = true } label: {
                            Text(model.directory.isEmpty ? "Mac home folder" : model.directory).font(.caption.monospaced()).lineLimit(2)
                        }.disabled(model.busy)
                    }
                    if let message = model.message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    if model.busy {
                        VStack(alignment: .leading) {
                            Text(model.activity).font(.callout)
                            if let total = model.total, total > 0 {
                                ProgressView(value: Double(model.progress), total: Double(max(total, model.progress)))
                            } else { ProgressView() }
                            if model.progress > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.progress), countStyle: .file)).font(.caption) }
                            Button("Cancel operation") { model.cancel() }
                            Text("A cancelled upload may leave a partial new file on the Mac.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(model.entries.filter { showHidden || !$0.name.hasPrefix(".") }) { file in
                        Button { model.open(file) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: file.isDirectory ? "folder" : file.isSymbolicLink ? "link" : "doc")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: file.name).foregroundStyle(.primary)
                                    if let size = file.size, !file.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: file.isDirectory ? "chevron.right" : "arrow.down.to.line").font(.caption)
                            }
                        }.disabled(model.busy || !model.connected)
                    }
                } footer: { Text("Tap a file to download and save it in Files. Uploads create a new file and never overwrite an existing one.") }
            }
            .navigationTitle("Mac files").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.browse() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh files").disabled(model.busy || !model.connected)
                    Menu {
                        Button("Upload from Files") { showImporter = true }.disabled(model.directory.isEmpty)
                        Toggle("Show hidden files", isOn: $showHidden)
                    } label: { Image(systemName: "ellipsis") }.disabled(model.busy || !model.connected)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): uploadURL = url; uploadName = url.lastPathComponent; showUpload = true
                case .failure: model.message = "Could not select the file."
                }
            }
            .alert("Upload new file", isPresented: $showUpload) {
                TextField("Filename on Mac", text: $uploadName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Upload") { if let uploadURL { model.upload(uploadURL, name: uploadName) } }
                Button("Cancel", role: .cancel) { uploadURL = nil }
            } message: { Text("Choose a new filename. Existing files will be left unchanged.") }
            .alert("Go to folder", isPresented: $showPath) {
                TextField("Remote path", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open") { model.browse(path) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $model.exportItem, onDismiss: { model.clearExport() }) { item in
                FileExportPicker(url: item.url) { model.exportItem = nil }
            }
            .task { if model.directory.isEmpty || model.entries.isEmpty { model.browse() } }
            // The native export picker can cover this view. Keep its completed
            // staging file alive until picker completion; the presenting sheet
            // owns final cleanup when the file browser itself is dismissed.
            .onDisappear { if model.exportItem == nil { model.cancel() } }
            .preferredColorScheme(.dark).tint(LCARS.lavender)
        }
    }
}

private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}
