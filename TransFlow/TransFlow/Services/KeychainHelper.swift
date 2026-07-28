import Foundation
import Security

/// P0-2 修复：Keychain 封装，用于安全存储 Cloud ASR API Key。
///
/// 将 API Key 从 UserDefaults 迁移到 macOS Keychain，避免明文暴露。
/// 按 service="TransFlow.cloudASR" + account="apiKey" 存取。
enum KeychainHelper {

    private static let service = "TransFlow.cloudASR"
    private static let account = "apiKey"

    // MARK: - Errors

    enum KeychainError: LocalizedError {
        case unhandled(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return String(localized: "keychain.error.unhandled") + " (OSStatus: \(status))"
            }
        }
    }

    // MARK: - Save

    /// 将 API Key 安全存储到 Keychain。
    /// - Parameter apiKey: 要存储的 API Key（空字符串会触发删除）。
    static func saveAPIKey(_ apiKey: String) throws {
        // 空 key = 删除条目
        guard !apiKey.isEmpty else {
            deleteAPIKey()
            return
        }

        let data = Data(apiKey.utf8)

        // 先尝试更新已有条目
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // 条目不存在，新增
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unhandled(updateStatus)
        }
    }

    // MARK: - Load

    /// 从 Keychain 读取 API Key。
    /// - Returns: API Key 字符串，若不存在则返回 nil。
    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8) else {
            return nil
        }

        return apiKey
    }

    // MARK: - Delete

    /// 从 Keychain 删除 API Key。
    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration

    /// 将旧版存储在 UserDefaults 中的 API Key 迁移到 Keychain。
    ///
    /// 首次加载时调用：若 UserDefaults 里还有旧 apiKey，迁移到 Keychain 并从 UserDefaults 清除。
    /// 迁移失败时保留 UserDefaults 中的数据，下次启动重试。
    static func migrateAPIKeyFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: "cloudASR"),
              let cfg = try? JSONDecoder().decode(CloudASRConfig.self, from: data) else {
            return
        }

        // 只有当 UserDefaults 里有非空 apiKey 时才需要迁移
        guard !cfg.apiKey.isEmpty else { return }

        // 检查 Keychain 中是否已有值
        if let existing = loadAPIKey(), existing == cfg.apiKey {
            // Keychain 已有相同的 key，只需清理 UserDefaults
            cleanAPIKeyFromUserDefaults()
            return
        }

        // 迁移到 Keychain
        do {
            try saveAPIKey(cfg.apiKey)
            // 迁移成功，从 UserDefaults 清除 apiKey
            cleanAPIKeyFromUserDefaults()
        } catch {
            // 迁移失败，保留 UserDefaults 中的数据，下次启动重试
            ErrorLogger.shared.log(
                "Keychain migration failed: \(error.localizedDescription)",
                source: "KeychainHelper"
            )
        }
    }

    /// 从 UserDefaults 的 cloudASR JSON 中移除 apiKey 字段。
    private static func cleanAPIKeyFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: "cloudASR"),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        dict.removeValue(forKey: "apiKey")

        if let cleanedData = try? JSONSerialization.data(withJSONObject: dict) {
            UserDefaults.standard.set(cleanedData, forKey: "cloudASR")
        }
    }
}
