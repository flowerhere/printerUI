import Foundation

/// 一筆列印工作紀錄（伺服器端持久化為 JSON）。
public struct PrintJob: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// 清理後的檔名，僅供顯示。
    public var displayName: String
    public var fileKind: FileKind
    public var byteCount: Int64
    public var sourceIP: String
    /// 誰送來的：用戶端自述（X-Client）＋ User-Agent 摘要。
    public var client: String
    public var createdAt: Date
    public var updatedAt: Date
    public private(set) var status: JobStatus
    public var options: JobOptions
    /// 實際送印時套用 / 降級的選項說明，例如「印表機不支援雙面，已改為單面」。
    public var notes: [String]
    /// 失敗或拒絕原因。
    public var message: String?
    /// CUPS 工作編號，例如 `Canon_MF642C-42`。
    public var cupsJobID: String?
    /// 磁碟上的檔案是否已刪除。
    public var fileDeleted: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        fileKind: FileKind,
        byteCount: Int64,
        sourceIP: String,
        client: String,
        createdAt: Date = Date(),
        status: JobStatus,
        options: JobOptions
    ) {
        self.id = id
        self.displayName = displayName
        self.fileKind = fileKind
        self.byteCount = byteCount
        self.sourceIP = sourceIP
        self.client = client
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.status = status
        self.options = options
        self.notes = []
        self.message = nil
        self.cupsJobID = nil
        self.fileDeleted = false
    }

    /// 依狀態機規則轉換狀態；不合法時丟出錯誤且不改變任何內容。
    public mutating func transition(to next: JobStatus, at date: Date = Date(), message: String? = nil) throws(InvalidTransitionError) {
        guard status.canTransition(to: next) else {
            throw InvalidTransitionError(from: status, to: next)
        }
        status = next
        updatedAt = date
        if let message { self.message = message }
    }

    public var statusDTO: JobStatusDTO {
        JobStatusDTO(id: id, status: status, filename: displayName, message: message, createdAt: createdAt, updatedAt: updatedAt)
    }
}
