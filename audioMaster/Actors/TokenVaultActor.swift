import Foundation
import Security

actor TokenVaultActor {
    static let shared = TokenVaultActor()

    private let service = "nyi.htet.audioMaster"
    private let account = "elevenlabs_api_token"
    private let legacyOpenAIAccount = "openai_api_token"

    func saveElevenLabsToken(_ token: String) throws {
        let encoded = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = encoded
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "TokenVaultActor", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not save API token"])
        }
    }

    func loadElevenLabsToken() -> String? {
        if let key = load(account: account) {
            return key
        }
        // Support migration from previous builds that saved the OpenAI key label.
        return load(account: legacyOpenAIAccount)
    }

    private func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
