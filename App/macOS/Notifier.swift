import Foundation
import MFConnectCore
import UserNotifications

/// 系統通知：新的待核准工作（可直接在通知上核准 / 拒絕）、列印失敗。
@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()

    private enum ID {
        static let approvalCategory = "MFCONNECT_APPROVAL"
        static let approveAction = "APPROVE"
        static let rejectAction = "REJECT"
        static let jobIDKey = "jobID"
    }

    private var onApprove: ((UUID) -> Void)?
    private var onReject: ((UUID) -> Void)?

    func configure(approve: @escaping (UUID) -> Void, reject: @escaping (UUID) -> Void) {
        onApprove = approve
        onReject = reject
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let approveAction = UNNotificationAction(identifier: ID.approveAction, title: "核准列印", options: [])
        let rejectAction = UNNotificationAction(identifier: ID.rejectAction, title: "拒絕", options: [.destructive])
        let category = UNNotificationCategory(identifier: ID.approvalCategory, actions: [approveAction, rejectAction],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyNeedsApproval(_ job: PrintJob) {
        let content = UNMutableNotificationContent()
        content.title = "新的列印工作等待核准"
        content.body = "\(job.displayName)・\(job.options.summary)\n來自 \(job.sourceIP)（\(job.client)）"
        content.sound = .default
        content.categoryIdentifier = ID.approvalCategory
        content.userInfo = [ID.jobIDKey: job.id.uuidString]
        post(id: job.id.uuidString, content: content)
    }

    func notifyFailed(_ job: PrintJob) {
        let content = UNMutableNotificationContent()
        content.title = "列印失敗"
        content.body = "\(job.displayName)：\(job.message ?? "未知錯誤")"
        content.sound = .default
        post(id: "failed-\(job.id.uuidString)", content: content)
    }

    private func post(id: String, content: UNNotificationContent) {
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    fileprivate func handleAction(_ action: String, jobID: UUID) {
        switch action {
        case ID.approveAction: onApprove?(jobID)
        case ID.rejectAction: onReject?(jobID)
        default: break
        }
    }

    nonisolated fileprivate static let jobIDKey = "jobID"
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let raw = response.notification.request.content.userInfo[Notifier.jobIDKey] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            Notifier.shared.handleAction(action, jobID: id)
        }
    }
}
