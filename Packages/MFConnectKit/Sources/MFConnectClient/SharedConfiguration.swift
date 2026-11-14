import Foundation
import MFConnectCore
#if canImport(Security)
import Security
#endif

/// 主 App 與 Share Extension 透過 App Group 共用的設定（不含 token）。
public struct SharedSettings: Sendable {
    public static let shared = SharedSettings()

    private enum Key {
        static let serverURL = "serverURL"
        static let serverName = "serverName"
        static let lastOptions = "lastOptions"
    }

    private let suiteName: String

    public init(suiteName: String = MFConnectConstants.appGroupIdentifier) {
        self.suiteName = suiteName
    }

    /// App Group 未設定好（例如簽署錯誤）時退回標準 UserDefaults，並由 `isUsingAppGroup` 告知。
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }
    public var isUsingAppGroup: Bool { UserDefaults(suiteName: suiteName) != nil }

    public var serverURL: URL? {
        get { defaults.string(forKey: Key.serverURL).flatMap(URL.init(string:)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: Key.serverURL) }
    }

    public var serverName: String? {
        get { defaults.string(forKey: Key.serverName) }
        nonmutating set { defaults.set(newValue, forKey: Key.serverName) }
    }

    /// 上次在分享面板選的選項，下次沿用。
    public var lastOptions: JobOptions {
        get {
            guard let data = defaults.data(forKey: Key.lastOptions),
                  let options = try? JSONDecoder().decode(JobOptions.self, from: data) else { return JobOptions() }
            return options
        }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.lastOptions) }
    }
}

#if canImport(Security)
/// token 存在 Keychain 的共用 access group，主 App 與 Share Extension 都能讀取。
///
/// access group 由 Info.plist 的 `MFKeychainAccessGroup`（`$(AppIdentifierPrefix)com.example.mfconnect.shared`）提供，
/// 必須與兩個 target 的 `keychain-access-groups` entitlement 一致。
public struct SharedTokenStore: Sendable {
    public static let infoPlistKey = "MFKeychainAccessGroup"
    public let accessGroup: String?
    private let service = "com.example.mfconnect.client"
    private let account = "server-token"

    public init(accessGroup: String? = Bundle.main.object(forInfoDictionaryKey: SharedTokenStore.infoPlistKey) as? String) {
        // 未展開的變數（例如在單元測試中）視為沒有設定。
        if let group = accessGroup, !group.isEmpty, !group.contains("$(") {
            self.accessGroup = group
        } else {
            self.accessGroup = nil
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
#endif
