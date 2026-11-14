import Foundation

/// 工作狀態機：
///
/// ```
/// pendingApproval ──核准──▶ queued ──▶ printing ──▶ done
///        │                   │            │
///        └──拒絕──▶ rejected ◀┘(取消)      └──▶ failed ──重試──▶ queued
/// ```
/// `queued` 也可能在準備檔案階段直接 `failed`（例如 PDF 損毀）。
public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case pendingApproval
    case queued
    case printing
    case done
    case failed
    case rejected

    public var displayName: String {
        switch self {
        case .pendingApproval: "等待核准"
        case .queued: "排隊中"
        case .printing: "列印中"
        case .done: "完成"
        case .failed: "失敗"
        case .rejected: "已拒絕"
        }
    }

    /// 終止狀態：不會再自動改變（`failed` 可由管理者手動重試）。
    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .rejected: true
        case .pendingApproval, .queued, .printing: false
        }
    }

    /// 仍佔用佇列名額的狀態。
    public var occupiesQueue: Bool { !isTerminal }

    public var allowedNextStates: Set<JobStatus> {
        switch self {
        case .pendingApproval: [.queued, .rejected]
        case .queued: [.printing, .failed, .rejected]
        case .printing: [.done, .failed]
        case .failed: [.queued]
        case .done, .rejected: []
        }
    }

    public func canTransition(to next: JobStatus) -> Bool {
        allowedNextStates.contains(next)
    }
}

public struct InvalidTransitionError: Error, Equatable, Sendable, CustomStringConvertible {
    public let from: JobStatus
    public let to: JobStatus

    public init(from: JobStatus, to: JobStatus) {
        self.from = from
        self.to = to
    }

    public var description: String { "不允許的狀態轉換：\(from.rawValue) → \(to.rawValue)" }
}
