import Foundation

/// Event-loop confined. A single in-flight write preserves order and bounds the SSH outbound queue.
struct PendingInput {
    private var chunks: [Data] = []
    private var head = 0
    private(set) var byteCount = 0
    let limit: Int
    init(limit: Int = 1_048_576) { self.limit = limit }

    mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard data.count <= limit - byteCount else { throw TerminalError.inputOverflow }
        chunks.append(data)
        byteCount += data.count
    }

    mutating func pop() -> Data? {
        guard head < chunks.count else { return nil }
        let result = chunks[head]
        chunks[head] = Data()
        head += 1
        byteCount -= result.count
        if head == chunks.count { chunks.removeAll(keepingCapacity: true); head = 0 }
        return result
    }

    mutating func removeAll() { chunks.removeAll(); head = 0; byteCount = 0 }
}
