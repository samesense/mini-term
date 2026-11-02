import Foundation

public struct ConnectionHistorySyncResult: Sendable {
    public let document: ConnectionHistoryDocument
    public let bookmark: Data
    public let folder: URL
}

/// File-provider work stays off the main actor. The user-selected folder needs no iCloud app entitlement.
public actor ConnectionHistoryCloudStore {
    public init() {}

    public func bookmark(for folder: URL) throws -> Data {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        return try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func synchronize(bookmark: Data, deviceID: UUID,
                            local: ConnectionHistoryDocument) throws -> ConnectionHistorySyncResult {
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let refreshed = stale ? try self.bookmark(for: folder) : bookmark
        let result = try synchronize(in: folder, deviceID: deviceID, local: local)
        return .init(document: result, bookmark: refreshed, folder: folder)
    }

    /// Also used by filesystem tests. Each device owns exactly one file, avoiding offline write collisions.
    public func synchronize(in folder: URL, deviceID: UUID,
                            local: ConnectionHistoryDocument) throws -> ConnectionHistoryDocument {
        try Task.checkCancellation()
        let file = folder.appendingPathComponent("MiniTerm-\(deviceID.uuidString).connections.json")
        var merged = local
        let files = try coordinatedRead(at: folder) { url in
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).compactMap { item -> URL? in
                let name = item.lastPathComponent
                if name.hasPrefix("MiniTerm-"), name.hasSuffix(".connections.json") { return item }
                // Older iCloud Drive storage may expose an undownloaded placeholder name.
                if name.hasPrefix(".MiniTerm-"), name.hasSuffix(".connections.json.icloud") {
                    return item.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
                }
                return nil
            }
        }
        var ownDocument: ConnectionHistoryDocument?
        for url in files {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
            let document = try coordinatedRead(at: url) { try ConnectionHistoryDocument.decode(Data(contentsOf: $0)) }
            try merged.merge(document)
            if url.lastPathComponent == file.lastPathComponent { ownDocument = document }
        }
        if ownDocument != merged {
            let data = try merged.encoded()
            try Task.checkCancellation()
            try coordinatedWrite(at: file) { try data.write(to: $0, options: .atomic) }
        }
        return merged
    }

    private func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ConnectionHistoryError.invalidDocument }
        return try result.get()
    }

    private func coordinatedWrite(at url: URL, _ body: (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ConnectionHistoryError.invalidDocument }
        try result.get()
    }
}

/// Directory presenter tells the UI about downloaded/changed replica files without polling.
public final class ConnectionHistoryFolderPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void
    private let hasAccess: Bool
    private let lock = NSLock()
    private var stopped = false

    public init(folder: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = folder
        self.onChange = onChange
        hasAccess = folder.startAccessingSecurityScopedResource()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    public func invalidate() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        NSFileCoordinator.removeFilePresenter(self)
        if hasAccess { presentedItemURL?.stopAccessingSecurityScopedResource() }
    }

    deinit { invalidate() }

    public func presentedItemDidChange() { onChange() }
    public func presentedSubitemDidAppear(at url: URL) { changed(url) }
    public func presentedSubitemDidChange(at url: URL) { changed(url) }
    public func presentedItemDidMove(to newURL: URL) { onChange() }
    private func changed(_ url: URL) {
        guard url.lastPathComponent.hasPrefix("MiniTerm-"), url.pathExtension == "json" else { return }
        onChange()
    }
}
