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

    /// Under XCTest, the real Keychain triggers a password prompt on every access.
    /// Route to an in-memory store instead so tests run unattended and deterministically.
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let memoryLock = NSLock()
    private var memoryStore: [String: String] = [:]

    func saveToken(_ token: String, for accountId: UUID) throws {
        if Self.isTesting {
            memoryLock.lock(); defer { memoryLock.unlock() }
            memoryStore[accountId.uuidString] = token
            return
        }

        let data = Data(token.utf8)
        let account = accountId.uuidString

        // Delete any existing item first so we always re-insert with correct ACL.
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Empty trustedApplications array = any app can access without password prompt.
        // Necessary for ad-hoc signed apps whose identity changes across builds.
        var access: SecAccess?
        SecAccessCreate("\(service).\(account)" as CFString, [] as CFArray, &access)

        var addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let access { addQuery[kSecAttrAccess] = access }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.saveFailed(addStatus) }
    }

    func loadToken(for accountId: UUID) -> String? {
        if Self.isTesting {
            memoryLock.lock(); defer { memoryLock.unlock() }
            return memoryStore[accountId.uuidString]
        }

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
        if Self.isTesting {
            memoryLock.lock(); defer { memoryLock.unlock() }
            memoryStore.removeValue(forKey: accountId.uuidString)
            return
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountId.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
