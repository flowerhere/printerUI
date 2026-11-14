import Foundation
import MFConnectCore

/// macOS 伺服器的所有可調整設定（存在 UserDefaults）。
public struct ServerSettings: Codable, Sendable, Equatable {
    public var serverName: String
    public var port: Int
    /// `nil` = 綁定所有網卡；否則只綁定此介面（例如 `en0`）的 IPv4 位址。
    public var bindInterface: String?
    /// CUPS 佇列名稱（`lpstat -e` 的其中一項）。
    public var printerName: String?
    public var requireApproval: Bool
    /// 試跑模式：不真的列印，只寫紀錄。首次安裝預設開啟，避免浪費紙張。
    public var dryRun: Bool
    public var maxUploadBytes: Int64
    public var maxQueueLength: Int
    /// 檔案在列印完成後保留幾小時；0 = 立即刪除。
    public var fileRetentionHours: Int
    /// 工作紀錄保留天數。
    public var recordRetentionDays: Int
    public var maxConnections: Int
    /// 單一請求（含上傳）的最長處理時間。
    public var requestTimeoutSeconds: Int
    /// 連線閒置多久沒有任何資料就中斷（防 slowloris）。
    public var idleTimeoutSeconds: Int
    public var launchAtLogin: Bool
    public var preventIdleSleep: Bool
    /// QR code 是否內含 token（方便家人直接掃描使用）。
    public var qrIncludesToken: Bool

    public init(
        serverName: String = "MFConnect",
        port: Int = MFConnectConstants.defaultPort,
        bindInterface: String? = nil,
        printerName: String? = nil,
        requireApproval: Bool = true,
        dryRun: Bool = true,
        maxUploadBytes: Int64 = MFConnectConstants.defaultMaxUploadBytes,
        maxQueueLength: Int = MFConnectConstants.defaultMaxQueueLength,
        fileRetentionHours: Int = 0,
        recordRetentionDays: Int = 30,
        maxConnections: Int = 16,
        requestTimeoutSeconds: Int = 300,
        idleTimeoutSeconds: Int = 30,
        launchAtLogin: Bool = false,
        preventIdleSleep: Bool = false,
        qrIncludesToken: Bool = false
    ) {
        self.serverName = serverName
        self.port = port
        self.bindInterface = bindInterface
        self.printerName = printerName
        self.requireApproval = requireApproval
        self.dryRun = dryRun
        self.maxUploadBytes = maxUploadBytes
        self.maxQueueLength = maxQueueLength
        self.fileRetentionHours = fileRetentionHours
        self.recordRetentionDays = recordRetentionDays
        self.maxConnections = maxConnections
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.launchAtLogin = launchAtLogin
        self.preventIdleSleep = preventIdleSleep
        self.qrIncludesToken = qrIncludesToken
    }

    /// 將使用者輸入夾在安全範圍內。
    public func clamped() -> ServerSettings {
        var s = self
        s.port = min(max(s.port, 1024), 65535)
        s.maxUploadBytes = min(max(s.maxUploadBytes, 1 * 1024 * 1024), 500 * 1024 * 1024)
        s.maxQueueLength = min(max(s.maxQueueLength, 1), 200)
        s.fileRetentionHours = min(max(s.fileRetentionHours, 0), 24 * 30)
        s.recordRetentionDays = min(max(s.recordRetentionDays, 1), 365)
        s.maxConnections = min(max(s.maxConnections, 2), 256)
        s.requestTimeoutSeconds = min(max(s.requestTimeoutSeconds, 10), 3600)
        s.idleTimeoutSeconds = min(max(s.idleTimeoutSeconds, 5), 300)
        let name = s.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        s.serverName = name.isEmpty ? "MFConnect" : String(name.prefix(60))
        return s
    }

    // 新增欄位時保持向後相容：缺少的 key 使用預設值。
    public init(from decoder: any Decoder) throws {
        let d = ServerSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? d.serverName
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        bindInterface = try c.decodeIfPresent(String.self, forKey: .bindInterface)
        printerName = try c.decodeIfPresent(String.self, forKey: .printerName)
        requireApproval = try c.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? d.requireApproval
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? d.dryRun
        maxUploadBytes = try c.decodeIfPresent(Int64.self, forKey: .maxUploadBytes) ?? d.maxUploadBytes
        maxQueueLength = try c.decodeIfPresent(Int.self, forKey: .maxQueueLength) ?? d.maxQueueLength
        fileRetentionHours = try c.decodeIfPresent(Int.self, forKey: .fileRetentionHours) ?? d.fileRetentionHours
        recordRetentionDays = try c.decodeIfPresent(Int.self, forKey: .recordRetentionDays) ?? d.recordRetentionDays
        maxConnections = try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? d.maxConnections
        requestTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? d.requestTimeoutSeconds
        idleTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .idleTimeoutSeconds) ?? d.idleTimeoutSeconds
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        preventIdleSleep = try c.decodeIfPresent(Bool.self, forKey: .preventIdleSleep) ?? d.preventIdleSleep
        qrIncludesToken = try c.decodeIfPresent(Bool.self, forKey: .qrIncludesToken) ?? d.qrIncludesToken
    }
}
