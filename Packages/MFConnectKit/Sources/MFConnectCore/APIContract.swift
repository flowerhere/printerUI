import Foundation

/// 伺服器與用戶端共用的常數。
public enum MFConnectConstants {
    public static let defaultPort: Int = 8631
    /// Bonjour 服務類型（不含結尾的點）。
    public static let bonjourServiceType = "_mfconnect._tcp"
    public static let appGroupIdentifier = "group.com.example.mfconnect"
    public static let apiVersion = 1
    public static let defaultMaxUploadBytes: Int64 = 50 * 1024 * 1024
    public static let defaultMaxQueueLength = 20
    public static let maxCopies = 99

    /// Bonjour TXT 記錄的 key。**絕不放 token。**
    public enum TXTKey {
        public static let serverName = "name"
        public static let requiresApproval = "approval"
        public static let host = "host"
        public static let apiVersion = "v"
    }
}

/// API 使用的 HTTP header 名稱。
public enum APIHeader {
    public static let authorization = "Authorization"
    public static let filename = "X-Filename"
    public static let copies = "X-Copies"
    public static let duplex = "X-Duplex"
    public static let color = "X-Color"
    /// 選填：用戶端自我描述（例如「iPhone 分享選單」），只用於工作紀錄顯示。
    public static let client = "X-Client"
}

/// `GET /api/info` 的回應。
public struct ServerInfoDTO: Codable, Sendable, Equatable {
    public var serverName: String
    public var allowedFormats: [String]
    public var maxUploadBytes: Int64
    public var requiresApproval: Bool
    public var apiVersion: Int

    public init(serverName: String, allowedFormats: [String], maxUploadBytes: Int64, requiresApproval: Bool, apiVersion: Int = MFConnectConstants.apiVersion) {
        self.serverName = serverName
        self.allowedFormats = allowedFormats
        self.maxUploadBytes = maxUploadBytes
        self.requiresApproval = requiresApproval
        self.apiVersion = apiVersion
    }
}

/// `POST /api/jobs` 成功（201）的回應。
public struct JobCreatedDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var status: JobStatus

    public init(id: UUID, status: JobStatus) {
        self.id = id
        self.status = status
    }
}

/// `GET /api/jobs/{id}` 的回應。
public struct JobStatusDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var status: JobStatus
    /// 給人看的狀態文字（繁體中文）。
    public var statusText: String
    public var filename: String
    public var message: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, status: JobStatus, filename: String, message: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.status = status
        self.statusText = status.displayName
        self.filename = filename
        self.message = message
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 所有錯誤回應的 JSON 格式。
public struct APIErrorDTO: Codable, Sendable, Equatable {
    /// 機器可讀的錯誤代碼，例如 `unauthorized`、`payload_too_large`。
    public var error: String
    /// 給人看的訊息（繁體中文）。
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}

extension JSONEncoder {
    /// API 統一使用的 encoder（ISO 8601 日期）。
    public static func mfConnect() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static func mfConnect() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
