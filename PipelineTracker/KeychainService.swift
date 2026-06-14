import Foundation
import Security

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Keychain save failed (OSStatus \(status))"
        case .unexpectedData: return "Keychain returned unexpected data"
        }
    }
}

final class KeychainService {
    static let shared = KeychainService()
    private let service = "com.kaustubh.pipeline-tracker"
    private init() {}

    func saveToken(_ token: String, for accountId: UUID) throws {
        let data = Data(token.utf8)
        let account = accountId.uuidString

        // Attempt update first; if not found, insert.
        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateAttrs: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.saveFailed(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }

    func loadToken(for accountId: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId.uuidString,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    func deleteToken(for accountId: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
