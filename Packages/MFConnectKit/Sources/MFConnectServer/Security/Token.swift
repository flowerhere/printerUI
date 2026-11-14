import Foundation
#if canImport(Security)
import Security
#endif

public enum ConstantTime {
    /// 固定時間比對：不論在哪個位元組不同、長度是否相同，所花時間只取決於較長輸入的長度。
    public static func equals<A: Collection, B: Collection>(_ a: A, _ b: B) -> Bool
    where A.Element == UInt8, B.Element == UInt8 {
        let lhs = Array(a)
        let rhs = Array(b)
        let length = max(lhs.count, rhs.count)
        var diff: UInt64 = UInt64(lhs.count ^ rhs.count)
        for i in 0..<length {
            let x = i < lhs.count ? lhs[i] : 0
            let y = i < rhs.count ? rhs[i] : 0
            diff |= UInt64(x ^ y)
        }
        return diff == 0
    }
}

public enum TokenGenerator {
    public static let byteCount = 32

    /// 產生 32 bytes 隨機 token，以 base64url（無 padding）表示，共 43 字元。
    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator() // 作業系統的 CSPRNG
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// token 的持久化位置。
public protocol TokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(_ value: String? = nil) { self.value = value }

    public func load() throws -> String? { lock.withLock { value } }
    public func save(_ token: String) throws { lock.withLock { value = token } }
}

#if canImport(Security)
/// 存在登入鑰匙圈的 generic password。
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "com.example.mfconnect.server", account: String = "api-token") {
        self.service = service
        self.account = account
    }

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "Keychain 錯誤（OSStatus \(status)）" }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "MFConnect 列印伺服器 token"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }
}
#endif
