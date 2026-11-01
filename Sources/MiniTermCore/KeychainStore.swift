import Foundation
import Security

/// No synchronisation or shared access group: keys stay on this device and require it to be unlocked.
public struct KeychainStore: Sendable {
    private let service: String
    public init(service: String = "mini-term.ssh") { self.service = service }

    public func read(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TerminalError.keychain(status) }
        return data
    }

    public func save(_ data: Data, account: String) throws {
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let insertStatus = SecItemAdd(item as CFDictionary, nil)
            guard insertStatus == errSecSuccess else { throw TerminalError.keychain(insertStatus) }
        } else if status != errSecSuccess {
            throw TerminalError.keychain(status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TerminalError.keychain(status) }
    }

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecAttrSynchronizable: false]
    }
}
