import Foundation
import NIOCore

/// RFC 1928 CONNECT + RFC 1929 credentials. Incremental and bounded by the caller;
/// no authentication downgrade, UDP, BIND, HTTP parsing, or application-byte rewriting.
struct SOCKSHandshake {
    enum Step: Equatable { case reply([UInt8], close: Bool), connect(host: String, port: Int) }
    private enum State { case greeting, authentication, request, complete }
    private var state = State.greeting
    private let username: [UInt8]
    private let password: [UInt8]
    static let connectedReply: [UInt8] = [5, 0, 0, 1, 127, 0, 0, 1, 0, 0]
    static let failedReply: [UInt8] = [5, 5, 0, 1, 0, 0, 0, 0, 0, 0]

    init(username: String, password: String) {
        self.username = Array(username.utf8); self.password = Array(password.utf8)
    }

    mutating func next(_ buffer: inout ByteBuffer) throws -> Step? {
        let bytes = Array(buffer.readableBytesView.prefix(520))
        switch state {
        case .greeting:
            guard bytes.count >= 2 else { return nil }
            let count = Int(bytes[1])
            guard bytes.count >= 2 + count else { return nil }
            buffer.moveReaderIndex(forwardBy: 2 + count)
            guard bytes[0] == 5, count > 0, bytes[2..<(2 + count)].contains(2) else {
                state = .complete; return .reply([5, 255], close: true)
            }
            state = .authentication
            return .reply([5, 2], close: false)
        case .authentication:
            guard bytes.count >= 2 else { return nil }
            let userLength = Int(bytes[1])
            guard bytes.count >= 3 + userLength else { return nil }
            let passwordLength = Int(bytes[2 + userLength])
            let length = 3 + userLength + passwordLength
            guard bytes.count >= length else { return nil }
            buffer.moveReaderIndex(forwardBy: length)
            guard bytes[0] == 1, userLength > 0, passwordLength > 0,
                  same(Array(bytes[2..<(2 + userLength)]), username),
                  same(Array(bytes[(3 + userLength)..<length]), password) else {
                state = .complete; return .reply([1, 1], close: true)
            }
            state = .request
            return .reply([1, 0], close: false)
        case .request:
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 5, bytes[2] == 0 else { return reject(code: 1) }
            guard bytes[1] == 1 else { return reject(code: 7) }
            let host: String
            let end: Int
            switch bytes[3] {
            case 1:
                end = 8
                guard bytes.count >= end + 2 else { return nil }
                host = bytes[4..<8].map(String.init).joined(separator: ".")
            case 3:
                guard bytes.count >= 5 else { return nil }
                end = 5 + Int(bytes[4])
                guard bytes.count >= end + 2 else { return nil }
                guard bytes[4] > 0, let name = String(bytes: bytes[5..<end], encoding: .utf8),
                      name.utf8.allSatisfy({ $0 > 32 && $0 < 127 }), !name.contains("/") else { return reject(code: 8) }
                host = name
            case 4:
                end = 20
                guard bytes.count >= end + 2 else { return nil }
                host = stride(from: 4, to: 20, by: 2).map {
                    String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16)
                }.joined(separator: ":")
            default: return reject(code: 8)
            }
            let port = Int(bytes[end]) << 8 | Int(bytes[end + 1])
            guard port > 0 else { return reject(code: 1) }
            buffer.moveReaderIndex(forwardBy: end + 2)
            state = .complete
            return .connect(host: host, port: port)
        case .complete: return nil
        }
    }

    private mutating func reject(code: UInt8) -> Step {
        state = .complete
        return .reply([5, code, 0, 1, 0, 0, 0, 0, 0, 0], close: true)
    }

    private func same(_ input: [UInt8], _ expected: [UInt8]) -> Bool {
        guard input.count == expected.count else { return false }
        return zip(input, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
