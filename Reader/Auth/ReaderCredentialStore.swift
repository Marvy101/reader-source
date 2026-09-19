import Foundation
import Security

protocol ReaderCredentialStoring: Sendable {
    func load() throws -> ReaderAuthSession?
    func save(_ session: ReaderAuthSession) throws
    func remove() throws
}

enum ReaderCredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Reader could not access the secure credential store (\(status))."
        }
    }
}

struct KeychainReaderCredentialStore: ReaderCredentialStoring {
    private let service: String
    private let account = "reader-backend-session"

    init(service: String? = nil) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.example.reader"
        self.service = service ?? "\(bundleIdentifier).auth"
    }

    func load() throws -> ReaderAuthSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReaderCredentialStoreError.keychain(status)
        }
        return try JSONDecoder().decode(ReaderAuthSession.self, from: data)
    }

    func save(_ session: ReaderAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ReaderCredentialStoreError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw ReaderCredentialStoreError.keychain(updateStatus)
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReaderCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
