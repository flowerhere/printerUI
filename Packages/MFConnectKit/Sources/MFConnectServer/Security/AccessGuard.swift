import Foundation

/// 負責 Bearer token 驗證、錯誤次數鎖定與上傳頻率限制。
public actor AccessGuard {
    public enum Decision: Equatable, Sendable {
        case allowed
        case unauthorized
        /// 該 IP 已被鎖定或請求太頻繁；值為建議的重試秒數。
        case tooManyRequests(retryAfter: Int)
    }

    public struct Policy: Sendable {
        public var maxFailures: Int
        public var lockDuration: TimeInterval
        /// 失敗次數在此期間內沒有新的失敗就歸零。
        public var failureWindow: TimeInterval
        public var maxUploadsPerWindow: Int
        public var uploadWindow: TimeInterval

        public init(maxFailures: Int = 5, lockDuration: TimeInterval = 600, failureWindow: TimeInterval = 600,
                    maxUploadsPerWindow: Int = 60, uploadWindow: TimeInterval = 600) {
            self.maxFailures = maxFailures
            self.lockDuration = lockDuration
            self.failureWindow = failureWindow
            self.maxUploadsPerWindow = maxUploadsPerWindow
            self.uploadWindow = uploadWindow
        }
    }

    private struct FailureRecord {
        var count: Int
        var lastFailure: Date
        var lockedUntil: Date?
    }

    private var token: [UInt8]
    private let policy: Policy
    private var failures: [String: FailureRecord] = [:]
    private var uploads: [String: [Date]] = [:]

    public init(token: String, policy: Policy = Policy()) {
        self.token = Array(token.utf8)
        self.policy = policy
    }

    /// 更換 token；舊 token 立即失效。
    public func rotate(to newToken: String) {
        token = Array(newToken.utf8)
    }

    /// 驗證 `Authorization` header。
    public func authorize(authorizationHeader: String?, ip: String, now: Date = Date()) -> Decision {
        if let retry = lockRemaining(ip: ip, now: now) {
            return .tooManyRequests(retryAfter: retry)
        }
        if let presented = Self.bearerToken(from: authorizationHeader),
           ConstantTime.equals(Array(presented.utf8), token) {
            failures[ip] = nil
            return .allowed
        }
        registerFailure(ip: ip, now: now)
        if let retry = lockRemaining(ip: ip, now: now) {
            return .tooManyRequests(retryAfter: retry)
        }
        return .unauthorized
    }

    /// 上傳頻率限制（已通過驗證後才呼叫）。
    public func registerUpload(ip: String, now: Date = Date()) -> Decision {
        var recent = (uploads[ip] ?? []).filter { now.timeIntervalSince($0) < policy.uploadWindow }
        if recent.count >= policy.maxUploadsPerWindow {
            uploads[ip] = recent
            let oldest = recent.min() ?? now
            let retry = Int((policy.uploadWindow - now.timeIntervalSince(oldest)).rounded(.up))
            return .tooManyRequests(retryAfter: max(retry, 1))
        }
        recent.append(now)
        uploads[ip] = recent
        return .allowed
    }

    public func isLocked(ip: String, now: Date = Date()) -> Bool {
        lockRemaining(ip: ip, now: now) != nil
    }

    /// 目前被鎖定的 IP（給選單列顯示）。
    public func lockedIPs(now: Date = Date()) -> [String] {
        failures.compactMap { ip, record in
            if let until = record.lockedUntil, until > now { return ip }
            return nil
        }.sorted()
    }

    public func unlockAll() {
        failures.removeAll()
    }

    private func lockRemaining(ip: String, now: Date) -> Int? {
        guard let until = failures[ip]?.lockedUntil else { return nil }
        if until > now {
            return max(Int(until.timeIntervalSince(now).rounded(.up)), 1)
        }
        // 鎖定期滿：清除紀錄，重新計算。
        failures[ip] = nil
        return nil
    }

    private func registerFailure(ip: String, now: Date) {
        var record = failures[ip] ?? FailureRecord(count: 0, lastFailure: now, lockedUntil: nil)
        if now.timeIntervalSince(record.lastFailure) > policy.failureWindow {
            record.count = 0
        }
        record.count += 1
        record.lastFailure = now
        if record.count >= policy.maxFailures {
            record.lockedUntil = now.addingTimeInterval(policy.lockDuration)
        }
        failures[ip] = record
        // 防止被大量不同 IP 撐爆記憶體。
        if failures.count > 10_000 {
            failures = failures.filter { $0.value.lockedUntil != nil }
        }
    }

    static func bearerToken(from header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value.count > 512 ? nil : value
    }
}
